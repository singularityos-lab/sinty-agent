const std = @import("std");

const sockaddr_un = extern struct {
    family: u16,
    path: [108]u8,
};

extern "c" fn socket(c_int, c_int, c_int) c_int;
extern "c" fn connect(c_int, *const anyopaque, u32) c_int;

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

pub fn main(init: std.process.Init.Minimal) void {
    var it = init.args.iterate();
    _ = it.next();
    const path = it.next() orelse std.process.exit(2);
    var addr: sockaddr_un = .{ .family = 1, .path = std.mem.zeroes([108]u8) };
    if (path.len >= addr.path.len) std.process.exit(2);
    @memcpy(addr.path[0..path.len], path);
    const fd = socket(1, 1, 0);
    if (fd < 0 or connect(fd, &addr, @sizeOf(sockaddr_un)) != 0) std.process.exit(1);
    const t = std.Thread.spawn(.{}, pump, .{ fd, 1 }) catch std.process.exit(1);
    t.detach();
    pump(0, fd);
}
