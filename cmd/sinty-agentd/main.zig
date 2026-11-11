const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("gio-import.h");
});
const policy = @import("policy.zig");
const catalog = @import("catalog.zig");
const mcp = @import("mcp.zig");
const wl = @import("wl.zig");
const trust = @import("trust.zig");
const a11y = @import("a11y.zig");

const EMPTY: [:0]const u8 = "";
const BRIDGE = "/usr/libexec/sinty-agent-bridge";
const NAME = "dev.sinty.Agent";
const PATH = "/dev/sinty/Agent";
const IFACE = "dev.sinty.Agent1";
const APP_IFACE = "dev.sinty.AppAgent1";
const CALL_MS = 120000;
const CONFIRM_US: i64 = 120 * 1000 * 1000;
const LINE_MAX = 16 * 1024 * 1024;
const DENIED = "org.freedesktop.DBus.Error.AccessDenied";

const XML =
    \\<node>
    \\  <interface name="dev.sinty.Agent1">
    \\    <method name="SetMode"><arg name="mode" type="s" direction="in"/></method>
    \\    <method name="GetStatus"><arg name="status" type="s" direction="out"/></method>
    \\    <method name="OpenGuestBridge"><arg name="socket" type="s" direction="out"/><arg name="bridge" type="s" direction="out"/></method>
    \\    <method name="OpenGrantedBridge"><arg name="token" type="s" direction="in"/><arg name="socket" type="s" direction="out"/><arg name="bridge" type="s" direction="out"/></method>
    \\    <method name="GrantSession"><arg name="token" type="s" direction="out"/></method>
    \\    <method name="RemoteGrant"><arg name="device" type="s" direction="in"/><arg name="token" type="s" direction="out"/></method>
    \\    <method name="Stop"/>
    \\    <method name="Resume"/>
    \\    <method name="Answer"><arg name="id" type="u" direction="in"/><arg name="allow" type="b" direction="in"/></method>
    \\    <method name="AllowSession"><arg name="id" type="u" direction="in"/></method>
    \\    <signal name="ConfirmRequested"><arg name="id" type="u"/><arg name="text" type="s"/></signal>
    \\    <signal name="ActionDone"><arg name="tool" type="s"/><arg name="outcome" type="s"/></signal>
    \\    <signal name="ConfirmClosed"><arg name="id" type="u"/></signal>
    \\    <signal name="RemoteChanged"><arg name="device" type="s"/></signal>
    \\    <signal name="IntentDone"><arg name="app" type="s"/><arg name="intent" type="s"/><arg name="args" type="s"/><arg name="result" type="s"/></signal>
    \\  </interface>
    \\</node>
;

const Answer = enum { none, allow, session, deny };

var bus: ?*c.GDBusConnection = null;
var lock: c.GMutex = undefined;
var changed: c.GCond = undefined;
var mode: policy.Mode = .ask;
var stopped = false;
var next_confirm: u32 = 1;
var waiting: u32 = 0;
var waiting_risk: policy.Risk = .read;
var answer: Answer = .none;
var guest_open = false;
var receipts_path: [:0]const u8 = "";

const GRANT_US: i64 = 15 * 60 * 1000 * 1000;

const OWNER_MAX = 255;

const Grant = struct {
    token: [32]u8,
    expires: i64,
    owner: [OWNER_MAX:0]u8 = .{0} ** OWNER_MAX,
    device: [OWNER_MAX:0]u8 = .{0} ** OWNER_MAX,
};

var grants: [16]?Grant = .{null} ** 16;

const Kind = enum { trusted, outsider, guest };

const Session = struct {
    tainted: bool = false,
    kind: Kind = .outsider,
    peer: []const u8 = "unknown",
    owner: [OWNER_MAX:0]u8 = .{0} ** OWNER_MAX,
    device: [OWNER_MAX:0]u8 = .{0} ** OWNER_MAX,
};

var remote_count: u32 = 0;
var remote_name: [OWNER_MAX:0]u8 = .{0} ** OWNER_MAX;

const HARMLESS = [_][]const u8{ "agent_status", "apps_list", "app_intents" };

fn harmless(name: []const u8) bool {
    for (HARMLESS) |h| {
        if (std.mem.eql(u8, h, name)) return true;
    }
    return false;
}

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

fn showArgs(a: std.mem.Allocator, args: std.json.Value) []const u8 {
    if (args != .object) return "";
    var out: std.ArrayList(u8) = .empty;
    var it = args.object.iterator();
    while (it.next()) |e| {
        const v = e.value_ptr.*;
        const shown = if (v == .string) v.string else std.json.Stringify.valueAlloc(a, v, .{}) catch "";
        out.print(a, "\n{s}: {s}", .{ e.key_ptr.*, shown }) catch return "";
    }
    return out.items;
}

fn confirm(a: std.mem.Allocator, who: []const u8, tool: []const u8, args: std.json.Value, risk: policy.Risk) Answer {
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    while (waiting != 0) c.g_cond_wait(&changed, &lock);
    const id = next_confirm;
    next_confirm += 1;
    waiting = id;
    waiting_risk = risk;
    answer = .none;
    const text = std.fmt.allocPrintSentinel(a, "{s}: {s}{s}", .{ who, tool, showArgs(a, args) }, 0) catch "";
    emit("ConfirmRequested", c.g_variant_new("(us)", id, text.ptr).?);
    const end = c.g_get_monotonic_time() + CONFIRM_US;
    while (answer == .none and !stopped) {
        if (c.g_cond_wait_until(&changed, &lock, end) == 0) break;
    }
    const r: Answer = if (stopped or answer == .none) .deny else answer;
    waiting = 0;
    emit("ConfirmClosed", c.g_variant_new("(u)", id).?);
    c.g_cond_broadcast(&changed);
    return r;
}

fn confirmOpen() bool {
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    return waiting != 0;
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

const Turn = struct { time: i64 = 0, user: []const u8 = "", answer: []const u8 = "" };
const Past = struct { id: []const u8, time: i64, first: []const u8, turns: usize };

fn conversationId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    return true;
}

fn mentions(turns: []const Turn, query: []const u8) bool {
    for (turns) |t| {
        if (std.ascii.indexOfIgnoreCase(t.user, query) != null or std.ascii.indexOfIgnoreCase(t.answer, query) != null) return true;
    }
    return false;
}

fn newerFirst(_: void, x: Past, y: Past) bool {
    return x.time > y.time;
}

fn conversations(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    const dir = std.fmt.allocPrintSentinel(a, "{s}/sinty-agent/conversations", .{std.mem.span(c.g_get_user_state_dir())}, 0) catch return fail("out of memory");
    if (str(args, "id")) |id| {
        if (!conversationId(id)) return fail("no such conversation");
        const p = std.fmt.allocPrintSentinel(a, "{s}/{s}.json", .{ dir, id }, 0) catch return fail("out of memory");
        var data: [*c]u8 = null;
        if (c.g_file_get_contents(p.ptr, &data, null, null) == 0) return fail("no such conversation");
        return .{ .text = std.mem.span(data) };
    }
    const query = str(args, "query");
    var found: std.ArrayList(Past) = .empty;
    if (c.g_dir_open(dir.ptr, 0, null)) |h| {
        defer c.g_dir_close(h);
        while (c.g_dir_read_name(h)) |raw| {
            const name = std.mem.span(raw);
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            const p = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0) catch continue;
            var data: [*c]u8 = null;
            if (c.g_file_get_contents(p.ptr, &data, null, null) == 0) continue;
            const v = std.json.parseFromSliceLeaky(struct { turns: []Turn }, a, std.mem.span(data), .{ .ignore_unknown_fields = true }) catch continue;
            if (v.turns.len == 0) continue;
            if (query) |q| if (!mentions(v.turns, q)) continue;
            const first = v.turns[0].user;
            found.append(a, .{ .id = name[0 .. name.len - 5], .time = v.turns[v.turns.len - 1].time, .first = first[0..@min(first.len, 160)], .turns = v.turns.len }) catch continue;
        }
    }
    std.mem.sort(Past, found.items, {}, newerFirst);
    const text = std.json.Stringify.valueAlloc(a, found.items[0..@min(found.items.len, 20)], .{}) catch return fail("out of memory");
    return .{ .text = text };
}

fn appOpen(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    const app = str(args, "app") orelse return fail("missing app");
    const file = std.fmt.allocPrintSentinel(a, "{s}.desktop", .{app}, 0) catch return fail("out of memory");
    const info = c.g_desktop_app_info_new(file.ptr) orelse return fail("application not found");
    defer c.g_object_unref(info);
    const before = wl.windowIdsOf(a, app);
    var err: [*c]c.GError = null;
    if (c.g_app_info_launch(@ptrCast(info), null, null, &err) == 0) {
        defer c.g_clear_error(&err);
        return fail(a.dupe(u8, std.mem.span(err.*.message)) catch "launch failed");
    }
    const id: ?u32 = wl.waitForNewWindow(a, app, before, if (before.len == 0) 8000 else 1500) orelse if (before.len != 0) before[0] else null;
    const window = id orelse return .{ .text = "launched, but no window of this application has appeared yet; check with windows_list before saying it is open" };
    const output = str(args, "output");
    var obj: std.json.ObjectMap = .empty;
    obj.put(a, "id", .{ .integer = window }) catch return fail("out of memory");
    obj.put(a, "action", .{ .string = if (output != null) "output" else "focus" }) catch return fail("out of memory");
    if (output) |o| obj.put(a, "output", .{ .string = o }) catch return fail("out of memory");
    return wl.windowSet(a, .{ .object = obj });
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
    const o = appCall(a, app, APP_IFACE, "Invoke", c.g_variant_new("(ss)", intent.ptr, shown.ptr), "(s)");
    if (o.failed or !unverified(a, o.text)) return o;
    const text = std.fmt.allocPrint(a, "NOT DONE: the application read the result back and the change is not there. Do not tell the user it worked. {s}", .{o.text}) catch return fail("out of memory");
    return .{ .text = text, .failed = true };
}

fn unverified(a: std.mem.Allocator, text: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch return false;
    if (parsed.value != .object) return false;
    const v = parsed.value.object.get("verified") orelse return false;
    return v == .bool and !v.bool;
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
    const device: []const u8 = if (remote_count > 0) std.mem.sliceTo(&remote_name, 0) else "";
    return std.json.Stringify.valueAlloc(a, .{ .mode = @tagName(mode), .stopped = stopped, .waiting = waiting, .risk = if (waiting != 0) @tagName(waiting_risk) else "", .remote = device }, .{}) catch "{}";
}

fn gerror(a: std.mem.Allocator, err: *[*c]c.GError) mcp.Outcome {
    defer c.g_clear_error(err);
    return fail(a.dupe(u8, std.mem.span(err.*.*.message)) catch "failed");
}

fn launchUri(uri: [*:0]const u8) mcp.Outcome {
    var err: [*c]c.GError = null;
    if (c.g_app_info_launch_default_for_uri(uri, null, &err) == 0) return gerror(std.heap.c_allocator, &err);
    return .{ .text = "opened" };
}

fn mailCompose(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    const to = c.g_uri_escape_string((str(args, "to") orelse EMPTY).ptr, "@,", 0);
    const subject = c.g_uri_escape_string((str(args, "subject") orelse EMPTY).ptr, null, 0);
    const body = c.g_uri_escape_string((str(args, "body") orelse EMPTY).ptr, null, 0);
    const uri = std.fmt.allocPrintSentinel(a, "mailto:{s}?subject={s}&body={s}", .{ std.mem.span(to), std.mem.span(subject), std.mem.span(body) }, 0) catch return fail("out of memory");
    return launchUri(uri.ptr);
}

fn openUri(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    const uri = str(args, "uri") orelse return fail("missing uri");
    const app = str(args, "app") orelse return launchUri(uri.ptr);
    const file = std.fmt.allocPrintSentinel(a, "{s}.desktop", .{app}, 0) catch return fail("out of memory");
    const info = c.g_desktop_app_info_new(file.ptr) orelse return fail("application not found");
    defer c.g_object_unref(info);
    if (c.g_app_info_supports_uris(@ptrCast(info)) == 0) return fail("this application does not open addresses");
    var uris = c.GList{ .data = @ptrCast(@constCast(uri.ptr)), .next = null, .prev = null };
    var err: [*c]c.GError = null;
    if (c.g_app_info_launch_uris(@ptrCast(info), &uris, null, &err) == 0) return gerror(a, &err);
    return .{ .text = "opened" };
}

fn notify(args: std.json.Value) mcp.Outcome {
    const title = str(args, "title") orelse return fail("missing title");
    const body = str(args, "body") orelse EMPTY;
    const actions = c.g_variant_builder_new(vt("as"));
    defer c.g_variant_builder_unref(actions);
    const hints = c.g_variant_builder_new(vt("a{sv}"));
    defer c.g_variant_builder_unref(hints);
    var err: [*c]c.GError = null;
    const r = c.g_dbus_connection_call_sync(bus, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", c.g_variant_new("(susssasa{sv}i)", "Sinty Agent", @as(c.guint32, 0), "", title.ptr, body.ptr, actions, hints, @as(c.gint32, -1)), null, c.G_DBUS_CALL_FLAGS_NONE, 5000, null, &err);
    if (r == null) return gerror(std.heap.c_allocator, &err);
    c.g_variant_unref(r);
    return .{ .text = "shown" };
}

fn findSchema(name: [:0]const u8) ?*c.GSettingsSchema {
    const source = c.g_settings_schema_source_get_default() orelse return null;
    return c.g_settings_schema_source_lookup(source, name.ptr, 1);
}

fn settingsGet(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    const name = str(args, "schema") orelse return fail("missing schema");
    const schema = findSchema(name) orelse return fail("no such schema");
    defer c.g_settings_schema_unref(schema);
    if (str(args, "key")) |key| {
        if (c.g_settings_schema_has_key(schema, key.ptr) == 0) return fail("no such key");
        const s = c.g_settings_new(name.ptr);
        defer c.g_object_unref(s);
        const v = c.g_settings_get_value(s, key.ptr);
        defer c.g_variant_unref(v);
        return .{ .text = a.dupe(u8, std.mem.span(c.g_variant_print(v, 0))) catch "" };
    }
    const keys = c.g_settings_schema_list_keys(schema);
    const joined = c.g_strjoinv(",", keys);
    return .{ .text = a.dupe(u8, std.mem.span(joined)) catch "" };
}

fn settingsSchemas(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    const source = c.g_settings_schema_source_get_default() orelse return fail("no settings on this system");
    var plain: [*c][*c]u8 = null;
    var moved: [*c][*c]u8 = null;
    c.g_settings_schema_source_list_schemas(source, 1, &plain, &moved);
    defer c.g_strfreev(plain);
    defer c.g_strfreev(moved);
    const query = str(args, "query");
    var names: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (plain[i] != null) : (i += 1) {
        const n = std.mem.span(plain[i]);
        if (query == null or std.mem.indexOf(u8, n, query.?) != null) names.append(a, n) catch {};
    }
    return .{ .text = std.json.Stringify.valueAlloc(a, names.items, .{}) catch "[]" };
}

fn descriptorDirs(a: std.mem.Allocator) []const [:0]const u8 {
    var dirs: std.ArrayList([:0]const u8) = .empty;
    const user = std.mem.span(c.g_get_user_data_dir());
    dirs.append(a, std.fmt.allocPrintSentinel(a, "{s}/singularity/app-settings", .{user}, 0) catch return dirs.items) catch {};
    const system = c.g_get_system_data_dirs();
    var i: usize = 0;
    while (system[i] != null) : (i += 1) {
        const s = std.fmt.allocPrintSentinel(a, "{s}/singularity/app-settings", .{std.mem.span(system[i])}, 0) catch continue;
        dirs.append(a, s) catch {};
    }
    return dirs.items;
}

fn currentValue(a: std.mem.Allocator, schema: []const u8, path: ?[]const u8, key: []const u8) ?[]const u8 {
    const sz = a.dupeZ(u8, schema) catch return null;
    const kz = a.dupeZ(u8, key) catch return null;
    const found = findSchema(sz) orelse return null;
    defer c.g_settings_schema_unref(found);
    if (c.g_settings_schema_has_key(found, kz.ptr) == 0) return null;
    const pz: ?[:0]u8 = if (path) |p| a.dupeZ(u8, p) catch null else null;
    const s = c.g_settings_new_full(found, null, if (pz) |p| p.ptr else null);
    defer c.g_object_unref(s);
    const v = c.g_settings_get_value(s, kz.ptr);
    defer c.g_variant_unref(v);
    return a.dupe(u8, std.mem.span(c.g_variant_print(v, 0))) catch null;
}

fn fileOf(path: [:0]const u8) ?[]const u8 {
    var raw: [*c]u8 = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents(path.ptr, &raw, &len, null) == 0) return null;
    return raw[0..len];
}

fn appSettings(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    const dirs = descriptorDirs(a);
    const app = str(args, "app") orelse {
        var names: std.ArrayList([]const u8) = .empty;
        for (dirs) |d| {
            const h = c.g_dir_open(d.ptr, 0, null) orelse continue;
            defer c.g_dir_close(h);
            while (c.g_dir_read_name(h)) |n| {
                const name = std.mem.span(n);
                if (std.mem.endsWith(u8, name, ".json")) names.append(a, a.dupe(u8, name[0 .. name.len - 5]) catch continue) catch {};
            }
        }
        return .{ .text = std.json.Stringify.valueAlloc(a, names.items, .{}) catch "[]" };
    };
    if (std.mem.indexOfScalar(u8, app, '/') != null) return fail("bad app id");
    for (dirs) |d| {
        const path = std.fmt.allocPrintSentinel(a, "{s}/{s}.json", .{ d, app }, 0) catch continue;
        const raw = fileOf(path) orelse continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return fail("broken descriptor");
        if (parsed != .object) return fail("broken descriptor");
        const items = parsed.object.get("settings") orelse return fail("no settings");
        if (items != .array) return fail("broken descriptor");
        const dflt = parsed.object.get("schema-id");
        for (items.array.items) |*it| {
            if (it.* != .object) continue;
            const key = it.object.get("key") orelse continue;
            if (key != .string) continue;
            const sv = it.object.get("schema-id") orelse dflt orelse continue;
            if (sv != .string) continue;
            const pv = it.object.get("path");
            const value = currentValue(a, sv.string, if (pv != null and pv.? == .string) pv.?.string else null, key.string) orelse continue;
            it.object.put(a, "value", .{ .string = value }) catch {};
            it.object.put(a, "schema", .{ .string = sv.string }) catch {};
        }
        return .{ .text = std.json.Stringify.valueAlloc(a, parsed, .{}) catch return fail("out of memory") };
    }
    return fail("this application has no settings page");
}

fn settingsSet(args: std.json.Value) mcp.Outcome {
    const name = str(args, "schema") orelse return fail("missing schema");
    const key = str(args, "key") orelse return fail("missing key");
    const raw = str(args, "value") orelse return fail("missing value");
    const schema = findSchema(name) orelse return fail("no such schema");
    defer c.g_settings_schema_unref(schema);
    if (c.g_settings_schema_has_key(schema, key.ptr) == 0) return fail("no such key");
    const k = c.g_settings_schema_get_key(schema, key.ptr);
    defer c.g_settings_schema_key_unref(k);
    var err: [*c]c.GError = null;
    const v = c.g_variant_parse(c.g_settings_schema_key_get_value_type(k), raw.ptr, null, null, &err);
    if (v == null) return gerror(std.heap.c_allocator, &err);
    const relocatable = str(args, "path");
    const s = c.g_settings_new_full(schema, null, if (relocatable) |p| p.ptr else null);
    defer c.g_object_unref(s);
    if (c.g_settings_set_value(s, key.ptr, v) == 0) return fail("this key cannot be written");
    c.g_settings_sync();
    return .{ .text = "changed" };
}

fn dbusCall(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    const which = str(args, "bus") orelse return fail("missing bus");
    const name = str(args, "name") orelse return fail("missing name");
    const path = str(args, "path") orelse return fail("missing path");
    const iface = str(args, "interface") orelse return fail("missing interface");
    const method = str(args, "method") orelse return fail("missing method");
    var err: [*c]c.GError = null;
    var params: ?*c.GVariant = null;
    if (str(args, "args")) |raw| {
        params = c.g_variant_parse(null, raw.ptr, null, null, &err);
        if (params == null) return gerror(a, &err);
    }
    const target = if (std.mem.eql(u8, which, "system")) c.g_bus_get_sync(c.G_BUS_TYPE_SYSTEM, null, &err) else bus;
    if (target == null) return gerror(a, &err);
    const r = c.g_dbus_connection_call_sync(target, name.ptr, path.ptr, iface.ptr, method.ptr, params, null, c.G_DBUS_CALL_FLAGS_NONE, 30000, null, &err);
    if (r == null) return gerror(a, &err);
    defer c.g_variant_unref(r);
    return .{ .text = a.dupe(u8, std.mem.span(c.g_variant_print(r, 1))) catch "" };
}

fn profilesCall(a: std.mem.Allocator, method: [*:0]const u8, params: ?*c.GVariant, reply: ?[*:0]const u8) mcp.Outcome {
    var err: [*c]c.GError = null;
    const r = c.g_dbus_connection_call_sync(bus, "dev.sinty.Profiles", "/dev/sinty/Profiles", "dev.sinty.Profiles1", method, params, if (reply) |t| vt(t) else null, c.G_DBUS_CALL_FLAGS_NONE, 15000, null, &err);
    if (r == null) return gerror(a, &err);
    defer c.g_variant_unref(r);
    if (reply == null) return .{ .text = "done" };
    const child = c.g_variant_get_child_value(r, 0);
    defer c.g_variant_unref(child);
    return .{ .text = a.dupe(u8, std.mem.span(c.g_variant_get_string(child, null))) catch "" };
}

fn profiles(a: std.mem.Allocator, name: []const u8, args: std.json.Value) mcp.Outcome {
    if (std.mem.eql(u8, name, "profiles_list")) {
        const list = profilesCall(a, "ListProfiles", null, "(s)");
        if (list.failed) return list;
        var err: [*c]c.GError = null;
        const r = c.g_dbus_connection_call_sync(bus, "dev.sinty.Profiles", "/dev/sinty/Profiles", "dev.sinty.Profiles1", "Status", null, vt("(a{sv})"), c.G_DBUS_CALL_FLAGS_NONE, 5000, null, &err);
        if (r == null) return gerror(a, &err);
        defer c.g_variant_unref(r);
        const text = std.fmt.allocPrint(a, "{{\"status\":\"{s}\",\"profiles\":{s}}}", .{ std.mem.span(c.g_variant_print(r, 0)), list.text }) catch return fail("out of memory");
        return .{ .text = text };
    }
    if (std.mem.eql(u8, name, "profile_activate")) {
        const id = str(args, "id") orelse return fail("missing id");
        return profilesCall(a, "ActivateFrom", c.g_variant_new("(ss)", id.ptr, "agent"), null);
    }
    if (std.mem.eql(u8, name, "profile_deactivate")) return profilesCall(a, "Deactivate", null, null);
    if (std.mem.eql(u8, name, "profile_save")) {
        const data = str(args, "profile") orelse return fail("missing profile");
        return profilesCall(a, "SaveProfile", c.g_variant_new("(s)", data.ptr), "(s)");
    }
    return fail("unknown profiles tool");
}

fn shellRun(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    const command = str(args, "command") orelse return fail("missing command");
    if (c.g_find_program_in_path("dsh") == null) return fail("dsh is not available on this system");
    const argv = [_:null]?[*:0]const u8{ "dsh", "-c", command.ptr };
    var out: [*c]u8 = null;
    var errs: [*c]u8 = null;
    var st: c_int = 1;
    var err: [*c]c.GError = null;
    if (c.g_spawn_sync(null, @ptrCast(@constCast(&argv)), null, c.G_SPAWN_SEARCH_PATH, null, null, &out, &errs, &st, &err) == 0) return gerror(a, &err);
    const text = std.fmt.allocPrint(a, "{s}{s}", .{ std.mem.span(out), std.mem.span(errs) }) catch return fail("out of memory");
    return .{ .text = text, .failed = c.g_spawn_check_wait_status(st, null) == 0 };
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
    if (std.mem.eql(u8, name, "mail_compose")) return mailCompose(a, args);
    if (std.mem.eql(u8, name, "open_uri")) return openUri(a, args);
    if (std.mem.eql(u8, name, "conversations")) return conversations(a, args);
    if (std.mem.eql(u8, name, "notify")) return notify(args);
    if (std.mem.startsWith(u8, name, "profile")) return profiles(a, name, args);
    if (std.mem.eql(u8, name, "ui_tree")) {
        const v = args.object.get("window") orelse return fail("missing window");
        if (v != .integer) return fail("missing window");
        const place = wl.placeOfWindow(v.integer) orelse return fail("no such window");
        return a11y.tree(a, place.pid, place.x, place.y);
    }
    if (confirmOpen() and (std.mem.eql(u8, name, "ui_act") or std.mem.eql(u8, name, "pointer") or std.mem.eql(u8, name, "keyboard")))
        return fail("a confirmation is open: only the user can answer it");
    if (std.mem.eql(u8, name, "ui_act")) {
        if (wl.consentBlocked()) return fail("a consent window is open: only the user can answer it");
        const ref = str(args, "ref") orelse return fail("missing ref");
        const action = str(args, "action") orelse return fail("missing action");
        const t = str(args, "text");
        return a11y.act(a, ref, action, if (t) |x| x else null);
    }
    if (std.mem.eql(u8, name, "settings_schemas")) return settingsSchemas(a, args);
    if (std.mem.eql(u8, name, "app_settings")) return appSettings(a, args);
    if (std.mem.eql(u8, name, "settings_get")) return settingsGet(a, args);
    if (std.mem.eql(u8, name, "settings_set")) return settingsSet(args);
    if (std.mem.eql(u8, name, "dbus_call")) return dbusCall(a, args);
    if (std.mem.eql(u8, name, "shell_run")) return shellRun(a, args);
    if (std.mem.eql(u8, name, "windows_list")) return wl.windows(a);
    if (std.mem.eql(u8, name, "window_set")) return wl.windowSet(a, args);
    if (std.mem.eql(u8, name, "outputs_list")) return wl.outputs(a);
    if (std.mem.eql(u8, name, "window_close")) return wl.windowClose(args);
    if (std.mem.eql(u8, name, "screen_capture")) return wl.capture(a, args);
    if (std.mem.eql(u8, name, "pointer")) return wl.pointer(args);
    if (std.mem.eql(u8, name, "keyboard")) return wl.keyboard(a, args);
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
    const verdict = if (session.kind == .trusted)
        policy.decide(mode, risk, session.tainted, stopped)
    else
        policy.decideOutsider(mode, risk, harmless(name), stopped);
    c.g_mutex_unlock(&lock);
    var label: []const u8 = @tagName(verdict);
    var o: mcp.Outcome = undefined;
    switch (verdict) {
        .refuse => o = fail("refused by the current mode"),
        .confirm => {
            const r = confirm(a, session.peer, name, args, risk);
            if (r == .session and session.kind == .outsider) session.kind = .trusted;
            if (r == .allow or r == .session) {
                label = "confirmed";
                o = run(a, name, args);
            } else {
                label = "denied";
                o = fail("the user did not allow this");
            }
        },
        .run => o = run(a, name, args),
    }
    if (!o.failed and (std.mem.eql(u8, name, "app_context") or std.mem.eql(u8, name, "conversations") or std.mem.eql(u8, name, "screen_capture") or std.mem.eql(u8, name, "windows_list") or std.mem.eql(u8, name, "ui_tree") or std.mem.eql(u8, name, "shell_run") or std.mem.eql(u8, name, "dbus_call") or (std.mem.eql(u8, name, "app_invoke") and risk == .read))) session.tainted = true;
    if (!o.failed and std.mem.eql(u8, name, "app_invoke")) {
        const clip = takeClipboard(a, o.text);
        if (clip.copy) |cp| shellCopy(a, cp);
        intentDone(a, session, args, clip.rest);
        o.text = withoutPrivate(a, o.text);
    }
    receipt(a, name, args, label, o);
    const tz = a.dupeZ(u8, name) catch return o;
    const lz = a.dupeZ(u8, label) catch return o;
    emit("ActionDone", c.g_variant_new("(ss)", tz.ptr, lz.ptr).?);
    return o;
}

pub const Clip = struct { text: []const u8, sensitive: bool, clear_after: u32 };

pub fn takeClipboard(a: std.mem.Allocator, text: []const u8) struct { rest: []const u8, copy: ?Clip } {
    var parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch return .{ .rest = text, .copy = null };
    if (parsed.value != .object) return .{ .rest = text, .copy = null };
    const priv = parsed.value.object.getPtr("private") orelse return .{ .rest = text, .copy = null };
    if (priv.* != .object) return .{ .rest = text, .copy = null };
    const clip = priv.object.get("clipboard") orelse return .{ .rest = text, .copy = null };
    _ = priv.object.orderedRemove("clipboard");
    const rest = std.json.Stringify.valueAlloc(a, parsed.value, .{}) catch "{}";
    if (clip != .object) return .{ .rest = rest, .copy = null };
    const t = clip.object.get("text") orelse return .{ .rest = rest, .copy = null };
    if (t != .string) return .{ .rest = rest, .copy = null };
    const sens = if (clip.object.get("sensitive")) |v| v == .bool and v.bool else false;
    const clear: u32 = if (clip.object.get("clear_after")) |v| (if (v == .integer and v.integer > 0 and v.integer <= 300) @intCast(v.integer) else 0) else 0;
    return .{ .rest = rest, .copy = .{ .text = t.string, .sensitive = sens, .clear_after = clear } };
}

fn shellCopy(a: std.mem.Allocator, clip: Clip) void {
    const tz = a.dupeZ(u8, clip.text) catch return;
    var err: [*c]c.GError = null;
    const r = c.g_dbus_connection_call_sync(bus, "dev.sinty.desktop", "/dev/sinty/Shell/AgentClipboard", "dev.sinty.AgentClipboard1", "Copy", c.g_variant_new("(sbu)", tz.ptr, @as(c.gboolean, if (clip.sensitive) 1 else 0), @as(c.guint32, clip.clear_after)), null, c.G_DBUS_CALL_FLAGS_NONE, 5000, null, &err);
    @memset(tz, 0);
    if (r == null) {
        c.g_clear_error(&err);
        return;
    }
    c.g_variant_unref(r);
}

pub fn withoutPrivate(a: std.mem.Allocator, text: []const u8) []const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch return text;
    if (parsed.value != .object or !parsed.value.object.contains("private")) return text;
    _ = parsed.value.object.orderedRemove("private");
    return std.json.Stringify.valueAlloc(a, parsed.value, .{}) catch "{}";
}

fn intentDone(a: std.mem.Allocator, session: *const Session, args: std.json.Value, result: []const u8) void {
    if (session.owner[0] == 0) return;
    const app = str(args, "app") orelse return;
    const intent = str(args, "intent") orelse return;
    const payload: std.json.Value = if (args.object.get("args")) |v| v else .{ .object = .empty };
    const raw = std.json.Stringify.valueAlloc(a, payload, .{}) catch return;
    const rz = a.dupeZ(u8, raw) catch return;
    const oz = a.dupeZ(u8, result) catch return;
    _ = c.g_dbus_connection_emit_signal(bus, &session.owner, PATH, IFACE, "IntentDone", c.g_variant_new("(ssss)", app.ptr, intent.ptr, rz.ptr, oz.ptr), null);
}

fn grant(owner: []const u8, device: []const u8) ?[32]u8 {
    var raw: [16]u8 = undefined;
    const fd = std.c.open("/dev/urandom", .{}, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    if (std.c.read(fd, &raw, raw.len) != raw.len) return null;
    const token = std.fmt.bytesToHex(raw, .lower);
    const now = c.g_get_monotonic_time();
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    var slot: usize = 0;
    var oldest: i64 = std.math.maxInt(i64);
    for (grants, 0..) |g, i| {
        const at = if (g) |live| (if (live.expires < now) std.math.minInt(i64) else live.expires) else std.math.minInt(i64);
        if (at < oldest) {
            oldest = at;
            slot = i;
        }
    }
    grants[slot] = .{ .token = token, .expires = now + GRANT_US };
    const n = @min(owner.len, OWNER_MAX);
    @memcpy(grants[slot].?.owner[0..n], owner[0..n]);
    const d = @min(device.len, OWNER_MAX);
    @memcpy(grants[slot].?.device[0..d], device[0..d]);
    return token;
}

fn redeem(line: []const u8) ?Grant {
    const prefix = "token ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const given = std.mem.trim(u8, line[prefix.len..], " \r");
    if (given.len != 32) return null;
    const now = c.g_get_monotonic_time();
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    for (grants) |g| {
        const live = g orelse continue;
        if (live.expires < now) continue;
        if (std.crypto.timing_safe.eql([32]u8, live.token, given[0..32].*)) return live;
    }
    return null;
}

fn remoteBegin(device: *const [OWNER_MAX:0]u8) void {
    c.g_mutex_lock(&lock);
    remote_count += 1;
    remote_name = device.*;
    c.g_mutex_unlock(&lock);
    emit("RemoteChanged", c.g_variant_new("(s)", device).?);
}

fn remoteEnd() void {
    c.g_mutex_lock(&lock);
    remote_count -|= 1;
    const left = remote_count;
    c.g_mutex_unlock(&lock);
    if (left == 0) emit("RemoteChanged", c.g_variant_new("(s)", "").?);
}

fn serve(fd: c_int, guest: bool) void {
    defer _ = std.c.close(fd);
    const gpa = std.heap.c_allocator;
    var session: Session = .{};
    const pid = trust.peerPid(fd);
    if (guest) {
        session.kind = .guest;
        session.peer = "dsh";
    } else {
        session.peer = trust.exeOf(gpa, pid);
        if (trust.trusted(gpa, pid)) session.kind = .trusted;
    }
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    defer if (session.device[0] != 0) remoteEnd();
    var first = true;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) return;
        pending.appendSlice(gpa, buf[0..@intCast(n)]) catch return;
        if (pending.items.len > LINE_MAX) return;
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |end| {
            if (first) {
                first = false;
                if (std.mem.startsWith(u8, pending.items, "token ")) {
                    if (redeem(pending.items[0..end])) |g| {
                        session.kind = .trusted;
                        session.owner = g.owner;
                        session.device = g.device;
                        if (g.device[0] != 0) {
                            session.peer = std.mem.sliceTo(&session.device, 0);
                            remoteBegin(&session.device);
                        }
                    }
                    pending.replaceRange(gpa, 0, end + 1, &.{}) catch return;
                    continue;
                }
            }
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

fn acceptLoop(listener: c_int, guest: bool) void {
    while (true) {
        const fd = std.c.accept(listener, null, null);
        if (fd < 0) continue;
        const t = std.Thread.spawn(.{}, serve, .{ fd, guest }) catch {
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

fn openGuestBridge(inv: ?*c.GDBusMethodInvocation) void {
    const a = std.heap.c_allocator;
    const dir = std.fmt.allocPrintSentinel(a, "{s}/artifacts/.sinty-agent", .{std.mem.span(c.g_get_home_dir())}, 0) catch return;
    const sock = std.fmt.allocPrintSentinel(a, "{s}/mcp.sock", .{dir}, 0) catch return;
    const bridge = std.fmt.allocPrintSentinel(a, "{s}/bridge", .{dir}, 0) catch return;
    if (c.g_mkdir_with_parents(dir.ptr, 0o700) != 0) {
        c.g_dbus_method_invocation_return_dbus_error(inv, "org.freedesktop.DBus.Error.Failed", "no folder shared with dsh");
        return;
    }
    const source = c.g_file_new_for_path(c.g_getenv("SINTY_AGENT_BRIDGE") orelse BRIDGE);
    const target = c.g_file_new_for_path(bridge.ptr);
    _ = c.g_file_copy(source, target, c.G_FILE_COPY_OVERWRITE, null, null, null, null);
    c.g_object_unref(source);
    c.g_object_unref(target);
    _ = c.chmod(bridge.ptr, 0o700);
    c.g_mutex_lock(&lock);
    const fresh = !guest_open;
    guest_open = true;
    c.g_mutex_unlock(&lock);
    if (fresh) {
        const t = std.Thread.spawn(.{}, acceptLoop, .{ listen(sock), true }) catch {
            c.g_dbus_method_invocation_return_dbus_error(inv, "org.freedesktop.DBus.Error.Failed", "cannot start the listener");
            return;
        };
        t.detach();
    }
    c.g_dbus_method_invocation_return_value(inv, c.g_variant_new("(ss)", sock.ptr, bridge.ptr));
}

fn callerTrusted(a: std.mem.Allocator, sender: [*c]const u8) bool {
    return trust.trusted(a, callerPid(sender));
}

fn callerRemote(a: std.mem.Allocator, sender: [*c]const u8) bool {
    return trust.remote(a, callerPid(sender));
}

fn callerPid(sender: [*c]const u8) i32 {
    const r = c.g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID", c.g_variant_new("(s)", sender), vt("(u)"), c.G_DBUS_CALL_FLAGS_NONE, 5000, null, null) orelse return 0;
    defer c.g_variant_unref(r);
    var pid: c.guint32 = 0;
    c.g_variant_get(r, "(u)", &pid);
    return @intCast(pid);
}

fn guestAsk(inv: ?*c.GDBusMethodInvocation) void {
    const who = "a program that wants to open the dsh bridge";
    const r = confirm(std.heap.c_allocator, who, "open_guest_bridge", .null, .irreversible);
    if (r == .allow or r == .session) {
        openGuestBridge(inv);
    } else {
        c.g_dbus_method_invocation_return_dbus_error(inv, DENIED, "the user did not allow this");
    }
}

fn onMethod(_: ?*c.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, _: [*c]const u8, method: [*c]const u8, params: ?*c.GVariant, inv: ?*c.GDBusMethodInvocation, _: c.gpointer) callconv(.c) void {
    const m = std.mem.span(method);
    if (std.mem.eql(u8, m, "GetStatus")) {
        const a = std.heap.c_allocator;
        const s = a.dupeZ(u8, status(a)) catch "{}";
        c.g_dbus_method_invocation_return_value(inv, c.g_variant_new("(s)", s.ptr));
        return;
    }
    var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch.deinit();
    const allowed = callerTrusted(scratch.allocator(), sender);
    if (std.mem.eql(u8, m, "OpenGrantedBridge")) {
        var given: [*c]const u8 = null;
        c.g_variant_get(params, "(&s)", &given);
        const line = std.fmt.allocPrint(scratch.allocator(), "token {s}", .{std.mem.span(given)}) catch "";
        if (allowed or redeem(line) != null) {
            openGuestBridge(inv);
        } else {
            c.g_dbus_method_invocation_return_dbus_error(inv, DENIED, "the token is not valid");
        }
        return;
    }
    if (std.mem.eql(u8, m, "OpenGuestBridge")) {
        if (allowed) {
            openGuestBridge(inv);
            return;
        }
        const t = std.Thread.spawn(.{}, guestAsk, .{inv}) catch {
            c.g_dbus_method_invocation_return_dbus_error(inv, DENIED, "cannot ask the user");
            return;
        };
        t.detach();
        return;
    }
    if (std.mem.eql(u8, m, "GrantSession")) {
        if (!allowed) {
            c.g_dbus_method_invocation_return_dbus_error(inv, DENIED, "only the desktop shell can do this");
            return;
        }
        const token = grant(std.mem.span(sender), "") orelse {
            c.g_dbus_method_invocation_return_dbus_error(inv, "org.freedesktop.DBus.Error.Failed", "no randomness");
            return;
        };
        const z: [33]u8 = token ++ [_]u8{0};
        c.g_dbus_method_invocation_return_value(inv, c.g_variant_new("(s)", &z));
        return;
    }
    const steering = std.mem.eql(u8, m, "Resume") or std.mem.eql(u8, m, "Answer") or std.mem.eql(u8, m, "AllowSession") or std.mem.eql(u8, m, "SetMode");
    const remote = !allowed and (steering or std.mem.eql(u8, m, "RemoteGrant")) and callerRemote(scratch.allocator(), sender);
    if (std.mem.eql(u8, m, "RemoteGrant")) {
        var device: [*c]const u8 = null;
        c.g_variant_get(params, "(&s)", &device);
        const name = std.mem.trim(u8, std.mem.span(device), " \t\r\n");
        if (!allowed and !remote) {
            c.g_dbus_method_invocation_return_dbus_error(inv, DENIED, "only the desktop or a paired device service can do this");
            return;
        }
        if (name.len == 0) {
            c.g_dbus_method_invocation_return_dbus_error(inv, "org.freedesktop.DBus.Error.InvalidArgs", "the device needs a name");
            return;
        }
        const token = grant(std.mem.span(sender), name) orelse {
            c.g_dbus_method_invocation_return_dbus_error(inv, "org.freedesktop.DBus.Error.Failed", "no randomness");
            return;
        };
        const z: [33]u8 = token ++ [_]u8{0};
        c.g_dbus_method_invocation_return_value(inv, c.g_variant_new("(s)", &z));
        return;
    }
    if (!allowed and !remote and steering and !std.mem.eql(u8, m, "SetMode")) {
        c.g_dbus_method_invocation_return_dbus_error(inv, DENIED, "only the desktop shell can do this");
        return;
    }
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    if (std.mem.eql(u8, m, "SetMode")) {
        var s: [*c]const u8 = null;
        c.g_variant_get(params, "(&s)", &s);
        const wanted = policy.Mode.parse(std.mem.span(s)) orelse {
            c.g_dbus_method_invocation_return_dbus_error(inv, "org.freedesktop.DBus.Error.InvalidArgs", "unknown mode");
            return;
        };
        if (policy.rank(wanted) > policy.rank(mode) and !allowed and !remote) {
            c.g_dbus_method_invocation_return_dbus_error(inv, DENIED, "only the desktop shell can raise the mode");
            return;
        }
        mode = wanted;
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
    } else if (std.mem.eql(u8, m, "AllowSession")) {
        var id: c.guint32 = 0;
        c.g_variant_get(params, "(u)", &id);
        if (id == waiting and id != 0) {
            answer = .session;
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

var config_path: [:0]const u8 = "";

fn loadMode() void {
    var data: [*c]u8 = null;
    if (c.g_file_get_contents(config_path.ptr, &data, null, null) == 0) return;
    defer c.g_free(data);
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const m = policy.fromConfig(arena.allocator(), std.mem.span(data)) orelse return;
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    mode = m;
}

fn onConfig(_: ?*c.GFileMonitor, _: ?*c.GFile, _: ?*c.GFile, event: c.GFileMonitorEvent, _: c.gpointer) callconv(.c) void {
    if (event == c.G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT or event == c.G_FILE_MONITOR_EVENT_CREATED) loadMode();
}

fn watchConfig(a: std.mem.Allocator) void {
    config_path = std.fmt.allocPrintSentinel(a, "{s}/sinty-agent/config.json", .{std.mem.span(c.g_get_user_config_dir())}, 0) catch return;
    loadMode();
    const file = c.g_file_new_for_path(config_path.ptr);
    const monitor = c.g_file_monitor_file(file, c.G_FILE_MONITOR_NONE, null, null) orelse return;
    _ = c.g_signal_connect_data(monitor, "changed", @ptrCast(&onConfig), null, null, 0);
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
    const t = std.Thread.spawn(.{}, acceptLoop, .{ listener, false }) catch fatal("cannot start the listener", .{});
    t.detach();

    watchConfig(a);
    _ = c.g_bus_own_name_on_connection(bus, NAME, c.G_BUS_NAME_OWNER_FLAGS_NONE, onBus, onLost, null, null);
    c.g_main_loop_run(c.g_main_loop_new(null, 0));
}

test "a granted token makes a session trusted and remembers who asked for it" {
    c.g_mutex_init(&lock);
    const token = grant(":1.42", "").?;
    var line: [38]u8 = undefined;
    @memcpy(line[0..6], "token ");
    @memcpy(line[6..], &token);
    const live = redeem(&line) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(":1.42", std.mem.sliceTo(&live.owner, 0));
    try std.testing.expectEqualStrings("", std.mem.sliceTo(&live.device, 0));
    line[37] ^= 1;
    try std.testing.expect(redeem(&line) == null);
    try std.testing.expect(redeem("token short") == null);
    try std.testing.expect(redeem("{\"jsonrpc\":\"2.0\"}") == null);
    for (&grants) |*g| g.* = null;
}

test "a remote grant carries the device name" {
    c.g_mutex_init(&lock);
    const token = grant(":1.7", "Pixel di Mirko").?;
    var line: [38]u8 = undefined;
    @memcpy(line[0..6], "token ");
    @memcpy(line[6..], &token);
    const live = redeem(&line) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Pixel di Mirko", std.mem.sliceTo(&live.device, 0));
    for (&grants) |*g| g.* = null;
}

test "showArgs prints one readable line per argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"app\":\"dev.sinty.files\",\"n\":2}", .{});
    try std.testing.expectEqualStrings("\napp: dev.sinty.files\nn: 2", showArgs(a, parsed));
    try std.testing.expectEqualStrings("", showArgs(a, .null));
}

test "a clipboard handed back by an intent reaches neither the model nor the card" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "{\"copied\":\"password\",\"private\":{\"clipboard\":{\"text\":\"hunter2\",\"sensitive\":true,\"clear_after\":30}}}";
    const clip = takeClipboard(a, raw);
    try std.testing.expect(clip.copy != null);
    try std.testing.expectEqualStrings("hunter2", clip.copy.?.text);
    try std.testing.expect(clip.copy.?.sensitive);
    try std.testing.expectEqual(@as(u32, 30), clip.copy.?.clear_after);
    try std.testing.expect(std.mem.indexOf(u8, clip.rest, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, withoutPrivate(a, clip.rest), "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, withoutPrivate(a, raw), "hunter2") == null);
    try std.testing.expect(takeClipboard(a, "{\"a\":1}").copy == null);
}

test "private intent fields reach the card but not the model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = withoutPrivate(a, "{\"private\":{\"token\":\"abc\"},\"to\":\"x@y\"}");
    try std.testing.expect(std.mem.indexOf(u8, out, "abc") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x@y") != null);
    try std.testing.expectEqualStrings("[1,2]", withoutPrivate(a, "[1,2]"));
    try std.testing.expectEqualStrings("not json", withoutPrivate(a, "not json"));
}
