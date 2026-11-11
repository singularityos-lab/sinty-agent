const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("gio-import.h");
});

const NAME = "dev.sinty.Agent";
const PATH = "/dev/sinty/Agent";
const IFACE = "dev.sinty.Agent1";

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("sinty-agent: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usage() noreturn {
    fatal("usage: sinty-agent mcp | status | mode plan|ask|auto|autopilot | stop | resume | grant | allow ID | deny ID", .{});
}

fn pump(from: c_int, to: c_int) void {
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = std.c.read(from, &buf, buf.len);
        if (n <= 0) std.process.exit(0);
        var off: usize = 0;
        const len: usize = @intCast(n);
        while (off < len) {
            const w = std.c.write(to, buf[off..].ptr, len - off);
            if (w <= 0) std.process.exit(1);
            off += @intCast(w);
        }
    }
}

fn bridge() noreturn {
    const a = std.heap.c_allocator;
    const sock = std.fmt.allocPrintSentinel(a, "{s}/sinty-agent/mcp.sock", .{std.mem.span(c.g_get_user_runtime_dir())}, 0) catch fatal("out of memory", .{});
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (sock.len >= addr.sun_path.len) fatal("socket path too long", .{});
    @memcpy(addr.sun_path[0..sock.len], sock);
    var fd: c_int = -1;
    var tries: u32 = 0;
    while (tries < 50) : (tries += 1) {
        fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0) break;
        _ = std.c.close(fd);
        fd = -1;
        if (tries == 0) start();
        c.g_usleep(100 * 1000);
    }
    if (fd < 0) fatal("sinty-agentd is not running", .{});
    if (!sendToken(fd)) fatal("sinty-agentd closed the connection", .{});
    const t = std.Thread.spawn(.{}, pump, .{ fd, 1 }) catch fatal("cannot start", .{});
    t.detach();
    pump(0, fd);
    std.process.exit(0);
}

fn bus() *c.GDBusConnection {
    return c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse fatal("no session bus", .{});
}

fn start() void {
    const r = c.g_dbus_connection_call_sync(bus(), "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "StartServiceByName", c.g_variant_new("(su)", NAME, @as(c.guint32, 0)), null, c.G_DBUS_CALL_FLAGS_NONE, 5000, null, null);
    if (r != null) c.g_variant_unref(r);
}

fn call(method: [*:0]const u8, params: ?*c.GVariant) ?*c.GVariant {
    var err: [*c]c.GError = null;
    const r = c.g_dbus_connection_call_sync(bus(), NAME, PATH, IFACE, method, params, null, c.G_DBUS_CALL_FLAGS_NONE, 5000, null, &err);
    if (r == null) fatal("{s}", .{std.mem.span(err.*.message)});
    return r;
}

pub fn main(init: std.process.Init.Minimal) void {
    if (std.c.getuid() == 0 or std.c.geteuid() == 0) fatal("Sinty AI never runs as root", .{});
    var it = init.args.iterate();
    _ = it.next();
    const cmd = it.next() orelse usage();
    if (std.mem.eql(u8, cmd, "mcp")) bridge();
    if (std.mem.eql(u8, cmd, "status")) {
        const r = call("GetStatus", null);
        var s: [*c]const u8 = null;
        c.g_variant_get(r, "(&s)", &s);
        std.debug.print("{s}\n", .{std.mem.span(s)});
    } else if (std.mem.eql(u8, cmd, "stop")) {
        _ = call("Stop", null);
    } else if (std.mem.eql(u8, cmd, "resume")) {
        _ = call("Resume", null);
    } else if (std.mem.eql(u8, cmd, "grant")) {
        const r = call("GrantSession", null);
        var s: [*c]const u8 = null;
        c.g_variant_get(r, "(&s)", &s);
        std.debug.print("{s}\n", .{std.mem.span(s)});
    } else if (std.mem.eql(u8, cmd, "allow-session")) {
        const raw = it.next() orelse usage();
        const id = std.fmt.parseInt(u32, raw, 10) catch usage();
        _ = call("AllowSession", c.g_variant_new("(u)", id));
    } else if (std.mem.eql(u8, cmd, "mode")) {
        const m = it.next() orelse usage();
        _ = call("SetMode", c.g_variant_new("(s)", m.ptr));
    } else if (std.mem.eql(u8, cmd, "allow") or std.mem.eql(u8, cmd, "deny")) {
        const raw = it.next() orelse usage();
        const id = std.fmt.parseInt(u32, raw, 10) catch usage();
        const allow: c.gboolean = if (std.mem.eql(u8, cmd, "allow")) 1 else 0;
        _ = call("Answer", c.g_variant_new("(ub)", id, allow));
    } else usage();
}

fn sendToken(fd: c_int) bool {
    const token = std.mem.span(c.g_getenv("SINTY_AGENT_TOKEN") orelse return true);
    if (token.len == 0) return true;
    var line: [80]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "token {s}\n", .{token}) catch return true;
    var off: usize = 0;
    while (off < text.len) {
        const n = std.c.write(fd, text[off..].ptr, text.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}
