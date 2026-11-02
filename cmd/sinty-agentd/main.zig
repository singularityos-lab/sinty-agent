const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("gio-import.h");
});
const policy = @import("policy.zig");
const catalog = @import("catalog.zig");
const mcp = @import("mcp.zig");

const NAME = "dev.sinty.Agent";
const PATH = "/dev/sinty/Agent";
const IFACE = "dev.sinty.Agent1";
const APP_IFACE = "dev.sinty.AppAgent1";
const CALL_MS = 120000;
const CONFIRM_US: i64 = 120 * 1000 * 1000;
const LINE_MAX = 16 * 1024 * 1024;

const XML =
    \\<node>
    \\  <interface name="dev.sinty.Agent1">
    \\    <method name="SetMode"><arg name="mode" type="s" direction="in"/></method>
    \\    <method name="GetStatus"><arg name="status" type="s" direction="out"/></method>
    \\    <method name="Stop"/>
    \\    <method name="Resume"/>
    \\    <method name="Answer"><arg name="id" type="u" direction="in"/><arg name="allow" type="b" direction="in"/></method>
    \\    <signal name="ConfirmRequested"><arg name="id" type="u"/><arg name="text" type="s"/></signal>
    \\    <signal name="ActionDone"><arg name="tool" type="s"/><arg name="outcome" type="s"/></signal>
    \\  </interface>
    \\</node>
;

const Answer = enum { none, allow, deny };

var bus: ?*c.GDBusConnection = null;
var lock: c.GMutex = undefined;
var changed: c.GCond = undefined;
var mode: policy.Mode = .ask;
var stopped = false;
var next_confirm: u32 = 1;
var waiting: u32 = 0;
var answer: Answer = .none;
var receipts_path: [:0]const u8 = "";

const Session = struct {
    tainted: bool = false,
};

fn vt(s: [*:0]const u8) *const c.GVariantType {
    return @ptrCast(s);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("sinty-agentd: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn receipt(a: std.mem.Allocator, tool: []const u8, args: std.json.Value, verdict: []const u8, o: mcp.Outcome) void {
    const line = std.json.Stringify.valueAlloc(a, .{
        .time = @divTrunc(c.g_get_real_time(), 1000000),
        .tool = tool,
        .args = args,
        .verdict = verdict,
        .failed = o.failed,
    }, .{}) catch return;
    const f = std.c.open(receipts_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c.mode_t, 0o600));
    if (f < 0) return;
    defer _ = std.c.close(f);
    _ = std.c.write(f, line.ptr, line.len);
    _ = std.c.write(f, "\n", 1);
}

fn emit(signal: [*:0]const u8, params: *c.GVariant) void {
    _ = c.g_dbus_connection_emit_signal(bus, null, PATH, IFACE, signal, params, null);
}

fn confirm(a: std.mem.Allocator, tool: []const u8, args: std.json.Value) bool {
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    while (waiting != 0) c.g_cond_wait(&changed, &lock);
    const id = next_confirm;
    next_confirm += 1;
    waiting = id;
    answer = .none;
    const shown = std.json.Stringify.valueAlloc(a, args, .{}) catch "";
    const text = std.fmt.allocPrintSentinel(a, "{s} {s}", .{ tool, shown }, 0) catch "";
    emit("ConfirmRequested", c.g_variant_new("(us)", id, text.ptr).?);
    const end = c.g_get_monotonic_time() + CONFIRM_US;
    while (answer == .none and !stopped) {
        if (c.g_cond_wait_until(&changed, &lock, end) == 0) break;
    }
    const ok = answer == .allow and !stopped;
    waiting = 0;
    c.g_cond_broadcast(&changed);
    return ok;
}

fn str(args: std.json.Value, key: []const u8) ?[:0]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    if (v != .string) return null;
    const a = std.heap.c_allocator;
    return a.dupeZ(u8, v.string) catch null;
}

fn fail(text: []const u8) mcp.Outcome {
    return .{ .text = text, .failed = true };
}

fn appPath(a: std.mem.Allocator, app: []const u8) ![:0]u8 {
    var out = try a.allocSentinel(u8, app.len + 1, 0);
    out[0] = '/';
    for (app, 0..) |ch, i| out[i + 1] = switch (ch) {
        '.' => '/',
        '-' => '_',
        else => ch,
    };
    return out;
}

fn appCall(a: std.mem.Allocator, app: [:0]const u8, iface: [*:0]const u8, method: [*:0]const u8, params: ?*c.GVariant, ret: [*:0]const u8) mcp.Outcome {
    if (c.g_dbus_is_name(app.ptr) == 0) return fail("invalid application id");
    const path = appPath(a, app) catch return fail("out of memory");
    var err: [*c]c.GError = null;
    const r = c.g_dbus_connection_call_sync(bus, app.ptr, path.ptr, iface, method, params, vt(ret), c.G_DBUS_CALL_FLAGS_NONE, CALL_MS, null, &err);
    if (r == null) {
        defer c.g_clear_error(&err);
        return fail(a.dupe(u8, std.mem.span(err.*.message)) catch "call failed");
    }
    defer c.g_variant_unref(r);
    if (std.mem.eql(u8, std.mem.span(ret), "(s)")) {
        var s: [*c]const u8 = null;
        c.g_variant_get(r, "(&s)", &s);
        return .{ .text = a.dupe(u8, std.mem.span(s)) catch "" };
    }
    return .{ .text = "done" };
}

fn intentRisk(a: std.mem.Allocator, app: [:0]const u8, intent: []const u8) ?policy.Risk {
    const o = appCall(a, app, APP_IFACE, "ListIntents", null, "(s)");
    if (o.failed) return .irreversible;
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, o.text, .{}) catch return .irreversible;
    if (v != .array) return .irreversible;
    for (v.array.items) |item| {
        if (item != .object) continue;
        const n = item.object.get("name") orelse continue;
        if (n != .string or !std.mem.eql(u8, n.string, intent)) continue;
        const r = item.object.get("risk") orelse return .irreversible;
        return if (r == .string) policy.Risk.parse(r.string) else .irreversible;
    }
    return null;
}

fn appsList(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    const query = str(args, "query");
    const all = c.g_app_info_get_all();
    defer c.g_list_free_full(all, c.g_object_unref);
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch return fail("out of memory");
    var first = true;
    var l = all;
    while (l != null) : (l = l.*.next) {
        const info: *c.GAppInfo = @ptrCast(@alignCast(l.*.data));
        if (c.g_app_info_should_show(info) == 0) continue;
        const id_raw = c.g_app_info_get_id(info) orelse continue;
        const id = std.mem.span(id_raw);
        const bare = if (std.mem.endsWith(u8, id, ".desktop")) id[0 .. id.len - 8] else id;
        const name = std.mem.span(c.g_app_info_get_display_name(info));
        if (query) |q| {
            if (std.ascii.indexOfIgnoreCase(name, q) == null and std.ascii.indexOfIgnoreCase(bare, q) == null) continue;
        }
        const row = std.json.Stringify.valueAlloc(a, .{ .id = bare, .name = name }, .{}) catch continue;
        if (!first) out.append(a, ',') catch {};
        first = false;
        out.appendSlice(a, row) catch {};
    }
    out.append(a, ']') catch {};
    return .{ .text = out.items };
}

fn appOpen(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    const app = str(args, "app") orelse return fail("missing app");
    const file = std.fmt.allocPrintSentinel(a, "{s}.desktop", .{app}, 0) catch return fail("out of memory");
    const info = c.g_desktop_app_info_new(file.ptr) orelse return fail("application not found");
    defer c.g_object_unref(info);
    var err: [*c]c.GError = null;
    if (c.g_app_info_launch(@ptrCast(info), null, null, &err) == 0) {
        defer c.g_clear_error(&err);
        return fail(a.dupe(u8, std.mem.span(err.*.message)) catch "launch failed");
    }
    return .{ .text = "opened" };
}

fn actionsOf(a: std.mem.Allocator, app: [:0]const u8) []const u8 {
    const path = appPath(a, app) catch return "[]";
    const r = c.g_dbus_connection_call_sync(bus, app.ptr, path.ptr, "org.gtk.Actions", "List", null, vt("(as)"), c.G_DBUS_CALL_FLAGS_NONE, 5000, null, null);
    if (r == null) return "[]";
    defer c.g_variant_unref(r);
    var names: std.ArrayList([]const u8) = .empty;
    const inner = c.g_variant_get_child_value(r, 0);
    defer c.g_variant_unref(inner);
    var i: usize = 0;
    while (i < c.g_variant_n_children(inner)) : (i += 1) {
        const child = c.g_variant_get_child_value(inner, i);
        defer c.g_variant_unref(child);
        names.append(a, a.dupe(u8, std.mem.span(c.g_variant_get_string(child, null))) catch continue) catch {};
    }
    return std.json.Stringify.valueAlloc(a, names.items, .{}) catch "[]";
}

fn appIntents(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    const app = str(args, "app") orelse return fail("missing app");
    const o = appCall(a, app, APP_IFACE, "ListIntents", null, "(s)");
    const intents = if (o.failed) "[]" else o.text;
    const text = std.fmt.allocPrint(a, "{{\"intents\":{s},\"actions\":{s}}}", .{ intents, actionsOf(a, app) }) catch return fail("out of memory");
    return .{ .text = text };
}

fn appInvoke(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    const app = str(args, "app") orelse return fail("missing app");
    const intent = str(args, "intent") orelse return fail("missing intent");
    const payload: std.json.Value = if (args.object.get("args")) |v| v else .{ .object = .empty };
    const raw = std.json.Stringify.valueAlloc(a, payload, .{}) catch return fail("out of memory");
    const shown = a.dupeZ(u8, raw) catch return fail("out of memory");
    return appCall(a, app, APP_IFACE, "Invoke", c.g_variant_new("(ss)", intent.ptr, shown.ptr), "(s)");
}

fn appAction(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    const app = str(args, "app") orelse return fail("missing app");
    const action = str(args, "action") orelse return fail("missing action");
    const b = c.g_variant_builder_new(vt("av"));
    defer c.g_variant_builder_unref(b);
    if (str(args, "parameter")) |p| {
        c.g_variant_builder_add(b, "v", c.g_variant_new_string(p.ptr));
    }
    const pd = c.g_variant_builder_new(vt("a{sv}"));
    defer c.g_variant_builder_unref(pd);
    return appCall(a, app, "org.gtk.Actions", "Activate", c.g_variant_new("(sava{sv})", action.ptr, b, pd), "()");
}

fn status(a: std.mem.Allocator) []const u8 {
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    return std.json.Stringify.valueAlloc(a, .{ .mode = @tagName(mode), .stopped = stopped, .waiting = waiting }, .{}) catch "{}";
}

fn riskOf(a: std.mem.Allocator, tool: *const catalog.Tool, args: std.json.Value) ?policy.Risk {
    if (!std.mem.eql(u8, tool.name, "app_invoke")) return tool.risk;
    const app = str(args, "app") orelse return .irreversible;
    const intent = str(args, "intent") orelse return .irreversible;
    return intentRisk(a, app, intent);
}

fn run(a: std.mem.Allocator, name: []const u8, args: std.json.Value) mcp.Outcome {
    if (std.mem.eql(u8, name, "apps_list")) return appsList(a, args);
    if (std.mem.eql(u8, name, "app_open")) return appOpen(a, args);
    if (std.mem.eql(u8, name, "app_intents")) return appIntents(a, args);
    if (std.mem.eql(u8, name, "app_invoke")) return appInvoke(a, args);
    if (std.mem.eql(u8, name, "app_action")) return appAction(a, args);
    if (std.mem.eql(u8, name, "agent_status")) return .{ .text = status(a) };
    if (std.mem.eql(u8, name, "app_context")) {
        const app = str(args, "app") orelse return fail("missing app");
        return appCall(a, app, APP_IFACE, "Context", null, "(s)");
    }
    return fail("unknown tool");
}

fn call(ctx: *anyopaque, a: std.mem.Allocator, name: []const u8, args: std.json.Value) mcp.Outcome {
    const session: *Session = @ptrCast(@alignCast(ctx));
    const tool = catalog.find(name) orelse return fail("unknown tool");
    const risk = riskOf(a, tool, args) orelse {
        const o = fail("this application has no such intent");
        receipt(a, name, args, "refuse", o);
        return o;
    };
    c.g_mutex_lock(&lock);
    const verdict = policy.decide(mode, risk, session.tainted, stopped);
    c.g_mutex_unlock(&lock);
    var label: []const u8 = @tagName(verdict);
    var o: mcp.Outcome = undefined;
    switch (verdict) {
        .refuse => o = fail("refused by the current mode"),
        .confirm => {
            if (confirm(a, name, args)) {
                label = "confirmed";
                o = run(a, name, args);
            } else {
                label = "denied";
                o = fail("the user did not allow this");
            }
        },
        .run => o = run(a, name, args),
    }
    if (!o.failed and (std.mem.eql(u8, name, "app_context") or (std.mem.eql(u8, name, "app_invoke") and risk == .read))) session.tainted = true;
    receipt(a, name, args, label, o);
    const tz = a.dupeZ(u8, name) catch return o;
    const lz = a.dupeZ(u8, label) catch return o;
    emit("ActionDone", c.g_variant_new("(ss)", tz.ptr, lz.ptr).?);
    return o;
}

fn serve(fd: c_int) void {
    defer _ = std.c.close(fd);
    const gpa = std.heap.c_allocator;
    var session: Session = .{};
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) return;
        pending.appendSlice(gpa, buf[0..@intCast(n)]) catch return;
        if (pending.items.len > LINE_MAX) return;
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |end| {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const answerLine = mcp.handle(arena.allocator(), pending.items[0..end], .{ .ctx = &session, .call = call }) catch null;
            if (answerLine) |r| {
                if (!writeAll(fd, r) or !writeAll(fd, "\n")) return;
            }
            pending.replaceRange(gpa, 0, end + 1, &.{}) catch return;
        }
    }
}

fn writeAll(fd: c_int, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn acceptLoop(listener: c_int) void {
    while (true) {
        const fd = std.c.accept(listener, null, null);
        if (fd < 0) continue;
        const t = std.Thread.spawn(.{}, serve, .{fd}) catch {
            _ = std.c.close(fd);
            continue;
        };
        t.detach();
    }
}

fn listen(path: [:0]const u8) c_int {
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) fatal("socket failed", .{});
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path.len >= addr.sun_path.len) fatal("socket path too long", .{});
    @memcpy(addr.sun_path[0..path.len], path);
    _ = c.unlink(path.ptr);
    const old = c.umask(0o177);
    defer _ = c.umask(old);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) fatal("cannot bind {s}", .{path});
    if (c.listen(fd, 16) != 0) fatal("listen failed", .{});
    return fd;
}

fn onMethod(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, method: [*c]const u8, params: ?*c.GVariant, inv: ?*c.GDBusMethodInvocation, _: c.gpointer) callconv(.c) void {
    const m = std.mem.span(method);
    if (std.mem.eql(u8, m, "GetStatus")) {
        const a = std.heap.c_allocator;
        const s = a.dupeZ(u8, status(a)) catch "{}";
        c.g_dbus_method_invocation_return_value(inv, c.g_variant_new("(s)", s.ptr));
        return;
    }
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    if (std.mem.eql(u8, m, "SetMode")) {
        var s: [*c]const u8 = null;
        c.g_variant_get(params, "(&s)", &s);
        mode = policy.Mode.parse(std.mem.span(s)) orelse {
            c.g_dbus_method_invocation_return_dbus_error(inv, "org.freedesktop.DBus.Error.InvalidArgs", "unknown mode");
            return;
        };
    } else if (std.mem.eql(u8, m, "Stop")) {
        stopped = true;
        c.g_cond_broadcast(&changed);
    } else if (std.mem.eql(u8, m, "Resume")) {
        stopped = false;
    } else if (std.mem.eql(u8, m, "Answer")) {
        var id: c.guint32 = 0;
        var allow: c.gboolean = 0;
        c.g_variant_get(params, "(ub)", &id, &allow);
        if (id == waiting and id != 0) {
            answer = if (allow != 0) .allow else .deny;
            c.g_cond_broadcast(&changed);
        }
    }
    c.g_dbus_method_invocation_return_value(inv, null);
}

const vtable = c.GDBusInterfaceVTable{ .method_call = onMethod, .get_property = null, .set_property = null, .padding = undefined };

fn onBus(conn: ?*c.GDBusConnection, _: [*c]const u8, _: c.gpointer) callconv(.c) void {
    var err: [*c]c.GError = null;
    const info = c.g_dbus_node_info_new_for_xml(XML, &err) orelse fatal("bad interface", .{});
    if (c.g_dbus_connection_register_object(conn, PATH, info.*.interfaces[0], &vtable, null, null, &err) == 0)
        fatal("cannot export {s}", .{PATH});
}

fn onLost(_: ?*c.GDBusConnection, _: [*c]const u8, _: c.gpointer) callconv(.c) void {
    fatal("lost {s}", .{NAME});
}

pub fn main() void {
    const a = std.heap.c_allocator;
    c.g_mutex_init(&lock);
    c.g_cond_init(&changed);
    var err: [*c]c.GError = null;
    bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &err) orelse fatal("no session bus", .{});

    const runtime = std.mem.span(c.g_get_user_runtime_dir());
    const dir = std.fmt.allocPrintSentinel(a, "{s}/sinty-agent", .{runtime}, 0) catch fatal("out of memory", .{});
    _ = c.g_mkdir_with_parents(dir.ptr, 0o700);
    const sock = std.fmt.allocPrintSentinel(a, "{s}/mcp.sock", .{dir}, 0) catch fatal("out of memory", .{});

    const state = std.mem.span(c.g_get_user_state_dir());
    const sdir = std.fmt.allocPrintSentinel(a, "{s}/sinty-agent", .{state}, 0) catch fatal("out of memory", .{});
    _ = c.g_mkdir_with_parents(sdir.ptr, 0o700);
    receipts_path = std.fmt.allocPrintSentinel(a, "{s}/receipts.jsonl", .{sdir}, 0) catch fatal("out of memory", .{});

    const listener = listen(sock);
    const t = std.Thread.spawn(.{}, acceptLoop, .{listener}) catch fatal("cannot start the listener", .{});
    t.detach();

    _ = c.g_bus_own_name_on_connection(bus, NAME, c.G_BUS_NAME_OWNER_FLAGS_NONE, onBus, onLost, null, null);
    c.g_main_loop_run(c.g_main_loop_new(null, 0));
}
