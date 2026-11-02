const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("gio-import.h");
});
const mcp = @import("mcp.zig");

const ACC = "org.a11y.atspi.Accessible";
const ROOT = "/org/a11y/atspi/accessible/root";
const CALL_MS = 3000;
const NODE_MAX = 500;
const DEPTH_MAX = 24;
const COORD_WINDOW: u32 = 1;

fn fail(t: []const u8) mcp.Outcome {
    return .{ .text = t, .failed = true };
}

fn vt(s: [*:0]const u8) *const c.GVariantType {
    return @ptrCast(s);
}

fn connect() ?*c.GDBusConnection {
    const session = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse return null;
    const r = c.g_dbus_connection_call_sync(session, "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress", null, vt("(s)"), c.G_DBUS_CALL_FLAGS_NONE, CALL_MS, null, null) orelse return null;
    defer c.g_variant_unref(r);
    var addr: [*c]const u8 = null;
    c.g_variant_get(r, "(&s)", &addr);
    return c.g_dbus_connection_new_for_address_sync(addr, @intCast(c.G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | c.G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION), null, null, null);
}

fn callOn(conn: *c.GDBusConnection, name: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, method: [*:0]const u8, args: ?*c.GVariant, reply: [*:0]const u8) ?*c.GVariant {
    return c.g_dbus_connection_call_sync(conn, name, path, iface, method, args, vt(reply), c.G_DBUS_CALL_FLAGS_NONE, CALL_MS, null, null);
}

fn prop(conn: *c.GDBusConnection, name: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, key: [*:0]const u8) ?*c.GVariant {
    const r = callOn(conn, name, path, "org.freedesktop.DBus.Properties", "Get", c.g_variant_new("(ss)", iface, key), "(v)") orelse return null;
    defer c.g_variant_unref(r);
    var v: ?*c.GVariant = null;
    c.g_variant_get(r, "(v)", &v);
    return v;
}

const Node = struct {
    ref: []const u8,
    role: []const u8,
    name: []const u8,
    text: ?[]const u8 = null,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    actions: []const []const u8 = &.{},
    depth: u32,
};

fn hasIface(ifaces: [][*c]const u8, name: []const u8) bool {
    for (ifaces) |i| {
        if (std.mem.eql(u8, std.mem.span(i), name)) return true;
    }
    return false;
}

fn describe(a: std.mem.Allocator, conn: *c.GDBusConnection, name: [:0]const u8, path: [:0]const u8, origin: [2]i32, depth: u32, out: *std.ArrayList(Node)) void {
    if (out.items.len >= NODE_MAX or depth > DEPTH_MAX) return;
    var node = Node{ .ref = std.fmt.allocPrint(a, "{s}|{s}", .{ name, path }) catch return, .role = "", .name = "", .depth = depth };
    if (callOn(conn, name.ptr, path.ptr, ACC, "GetRoleName", null, "(s)")) |r| {
        defer c.g_variant_unref(r);
        var s: [*c]const u8 = null;
        c.g_variant_get(r, "(&s)", &s);
        node.role = a.dupe(u8, std.mem.span(s)) catch "";
    }
    if (prop(conn, name.ptr, path.ptr, ACC, "Name")) |v| {
        defer c.g_variant_unref(v);
        node.name = a.dupe(u8, std.mem.span(c.g_variant_get_string(v, null))) catch "";
    }
    var ifaces: std.ArrayList([*c]const u8) = .empty;
    const ir = callOn(conn, name.ptr, path.ptr, ACC, "GetInterfaces", null, "(as)");
    defer if (ir) |r| c.g_variant_unref(r);
    if (ir) |r| {
        const list = c.g_variant_get_child_value(r, 0);
        defer c.g_variant_unref(list);
        var i: usize = 0;
        const n = c.g_variant_n_children(list);
        while (i < n) : (i += 1) {
            const e = c.g_variant_get_child_value(list, i);
            ifaces.append(a, c.g_strdup(c.g_variant_get_string(e, null))) catch {};
            c.g_variant_unref(e);
        }
    }
    if (hasIface(ifaces.items, "org.a11y.atspi.Component")) {
        if (callOn(conn, name.ptr, path.ptr, "org.a11y.atspi.Component", "GetExtents", c.g_variant_new("(u)", COORD_WINDOW), "((iiii))")) |r| {
            defer c.g_variant_unref(r);
            c.g_variant_get(r, "((iiii))", &node.x, &node.y, &node.width, &node.height);
            node.x += origin[0];
            node.y += origin[1];
        }
    }
    if (hasIface(ifaces.items, "org.a11y.atspi.Text")) {
        if (callOn(conn, name.ptr, path.ptr, "org.a11y.atspi.Text", "GetText", c.g_variant_new("(ii)", @as(i32, 0), @as(i32, 2000)), "(s)")) |r| {
            defer c.g_variant_unref(r);
            var s: [*c]const u8 = null;
            c.g_variant_get(r, "(&s)", &s);
            if (s[0] != 0) node.text = a.dupe(u8, std.mem.span(s)) catch null;
        }
    }
    if (hasIface(ifaces.items, "org.a11y.atspi.Action")) {
        if (callOn(conn, name.ptr, path.ptr, "org.a11y.atspi.Action", "GetActions", null, "(a(sss))")) |r| {
            defer c.g_variant_unref(r);
            var names: std.ArrayList([]const u8) = .empty;
            const list = c.g_variant_get_child_value(r, 0);
            defer c.g_variant_unref(list);
            var i: usize = 0;
            const n = c.g_variant_n_children(list);
            while (i < n) : (i += 1) {
                const e = c.g_variant_get_child_value(list, i);
                defer c.g_variant_unref(e);
                const f = c.g_variant_get_child_value(e, 0);
                defer c.g_variant_unref(f);
                names.append(a, a.dupe(u8, std.mem.span(c.g_variant_get_string(f, null))) catch "") catch {};
            }
            node.actions = names.items;
        }
    }
    out.append(a, node) catch return;
    const kids = callOn(conn, name.ptr, path.ptr, ACC, "GetChildren", null, "(a(so))") orelse return;
    defer c.g_variant_unref(kids);
    const list = c.g_variant_get_child_value(kids, 0);
    defer c.g_variant_unref(list);
    var i: usize = 0;
    const n = c.g_variant_n_children(list);
    while (i < n) : (i += 1) {
        const e = c.g_variant_get_child_value(list, i);
        defer c.g_variant_unref(e);
        var kn: [*c]const u8 = null;
        var kp: [*c]const u8 = null;
        c.g_variant_get(e, "(&s&o)", &kn, &kp);
        const nz = a.dupeZ(u8, std.mem.span(kn)) catch return;
        const pz = a.dupeZ(u8, std.mem.span(kp)) catch return;
        describe(a, conn, nz, pz, origin, depth + 1, out);
    }
}

fn pidOf(conn: *c.GDBusConnection, name: [*c]const u8) i64 {
    const r = callOn(conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID", c.g_variant_new("(s)", name), "(u)") orelse return 0;
    defer c.g_variant_unref(r);
    var pid: u32 = 0;
    c.g_variant_get(r, "(u)", &pid);
    return pid;
}

pub fn tree(a: std.mem.Allocator, pid: i64, x: i32, y: i32) mcp.Outcome {
    const conn = connect() orelse return fail("the accessibility bus is not available");
    defer c.g_object_unref(conn);
    const kids = callOn(conn, "org.a11y.atspi.Registry", ROOT, ACC, "GetChildren", null, "(a(so))") orelse return fail("the accessibility registry does not answer");
    defer c.g_variant_unref(kids);
    const list = c.g_variant_get_child_value(kids, 0);
    defer c.g_variant_unref(list);
    var out: std.ArrayList(Node) = .empty;
    var i: usize = 0;
    const n = c.g_variant_n_children(list);
    while (i < n) : (i += 1) {
        const e = c.g_variant_get_child_value(list, i);
        defer c.g_variant_unref(e);
        var kn: [*c]const u8 = null;
        var kp: [*c]const u8 = null;
        c.g_variant_get(e, "(&s&o)", &kn, &kp);
        if (pidOf(conn, kn) != pid) continue;
        const nz = a.dupeZ(u8, std.mem.span(kn)) catch continue;
        const pz = a.dupeZ(u8, std.mem.span(kp)) catch continue;
        describe(a, conn, nz, pz, .{ x, y }, 0, &out);
    }
    if (out.items.len == 0) return fail("this window exposes no accessibility tree");
    return .{ .text = std.json.Stringify.valueAlloc(a, out.items, .{ .emit_null_optional_fields = false }) catch return fail("out of memory") };
}

pub fn act(a: std.mem.Allocator, ref: []const u8, action: []const u8, text: ?[]const u8) mcp.Outcome {
    const bar = std.mem.indexOfScalar(u8, ref, '|') orelse return fail("bad ref");
    const name = a.dupeZ(u8, ref[0..bar]) catch return fail("out of memory");
    const path = a.dupeZ(u8, ref[bar + 1 ..]) catch return fail("out of memory");
    if (c.g_variant_is_object_path(path.ptr) == 0 or c.g_dbus_is_unique_name(name.ptr) == 0) return fail("bad ref");
    const conn = connect() orelse return fail("the accessibility bus is not available");
    defer c.g_object_unref(conn);
    if (std.mem.eql(u8, action, "focus")) {
        const r = callOn(conn, name.ptr, path.ptr, "org.a11y.atspi.Component", "GrabFocus", null, "(b)") orelse return fail("this element cannot take focus");
        c.g_variant_unref(r);
        return .{ .text = "done" };
    }
    if (std.mem.eql(u8, action, "set_text")) {
        const t = a.dupeZ(u8, text orelse return fail("missing text")) catch return fail("out of memory");
        const r = callOn(conn, name.ptr, path.ptr, "org.a11y.atspi.EditableText", "SetTextContents", c.g_variant_new("(s)", t.ptr), "(b)") orelse return fail("this element is not editable");
        c.g_variant_unref(r);
        return .{ .text = "done" };
    }
    const list = callOn(conn, name.ptr, path.ptr, "org.a11y.atspi.Action", "GetActions", null, "(a(sss))") orelse return fail("this element has no actions");
    defer c.g_variant_unref(list);
    const items = c.g_variant_get_child_value(list, 0);
    defer c.g_variant_unref(items);
    var i: usize = 0;
    const n = c.g_variant_n_children(items);
    while (i < n) : (i += 1) {
        const e = c.g_variant_get_child_value(items, i);
        defer c.g_variant_unref(e);
        const f = c.g_variant_get_child_value(e, 0);
        defer c.g_variant_unref(f);
        if (std.mem.eql(u8, std.mem.span(c.g_variant_get_string(f, null)), action)) {
            const r = callOn(conn, name.ptr, path.ptr, "org.a11y.atspi.Action", "DoAction", c.g_variant_new("(i)", @as(i32, @intCast(i))), "(b)") orelse return fail("the action failed");
            c.g_variant_unref(r);
            return .{ .text = "done" };
        }
    }
    return fail("this element has no such action");
}
