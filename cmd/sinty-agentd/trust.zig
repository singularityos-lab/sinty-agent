const std = @import("std");
const options = @import("build_options");
const c = @cImport({
    @cInclude("sys/stat.h");
});

const SHELLS = [_][]const u8{
    "/usr/bin/singularity-desktop",
    "/usr/local/bin/singularity-desktop",
    "/opt/local/bin/singularity-desktop",
};

const TAINTING = [_][]const u8{ "LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT", "GTK_MODULES", "GTK_PATH", "GIO_EXTRA_MODULES", "GI_TYPELIB_PATH", "G_DEBUG" };

const Cred = extern struct { pid: i32, uid: u32, gid: u32 };

pub fn peerPid(fd: c_int) i32 {
    var cred: Cred = undefined;
    var len: std.c.socklen_t = @sizeOf(Cred);
    if (std.c.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.PEERCRED, @ptrCast(&cred), &len) != 0) return 0;
    return cred.pid;
}

pub fn exeOf(a: std.mem.Allocator, pid: i32) []const u8 {
    if (pid <= 0) return "unknown";
    const path = std.fmt.allocPrintSentinel(a, "/proc/{d}/exe", .{pid}, 0) catch return "unknown";
    const buf = a.alloc(u8, 4096) catch return "unknown";
    const n = std.c.readlink(path.ptr, buf.ptr, buf.len);
    if (n <= 0) return "unknown";
    return buf[0..@intCast(n)];
}

fn cleanEnv(a: std.mem.Allocator, pid: i32) bool {
    const path = std.fmt.allocPrintSentinel(a, "/proc/{d}/environ", .{pid}, 0) catch return false;
    const fd = std.c.open(path.ptr, .{}, @as(std.c.mode_t, 0));
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    const buf = a.alloc(u8, 1024 * 1024) catch return false;
    var used: usize = 0;
    while (used < buf.len) {
        const n = std.c.read(fd, buf[used..].ptr, buf.len - used);
        if (n < 0) return false;
        if (n == 0) break;
        used += @intCast(n);
    }
    return envIsClean(buf[0..used]);
}

pub fn envIsClean(env: []const u8) bool {
    var it = std.mem.splitScalar(u8, env, 0);
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        for (TAINTING) |t| {
            if (std.mem.eql(u8, kv[0..eq], t)) return false;
        }
    }
    return true;
}

fn rootOwned(a: std.mem.Allocator, exe: []const u8) bool {
    const z = a.dupeZ(u8, exe) catch return false;
    var st: c.struct_stat = undefined;
    if (c.stat(z.ptr, &st) != 0) return false;
    return st.st_uid == 0 and st.st_mode & 0o022 == 0;
}

pub fn trusted(a: std.mem.Allocator, pid: i32) bool {
    if (pid <= 0) return false;
    const exe = exeOf(a, pid);
    if (options.test_trust.len != 0) {
        var it = std.mem.splitScalar(u8, options.test_trust, ':');
        while (it.next()) |p| {
            if (std.mem.eql(u8, p, exe)) return true;
        }
    }
    for (SHELLS) |s| {
        if (std.mem.eql(u8, s, exe)) return rootOwned(a, exe) and cleanEnv(a, pid);
    }
    return false;
}

test "a preloaded library spoils the environment" {
    try std.testing.expect(!envIsClean("HOME=/x\x00LD_PRELOAD=/tmp/evil.so\x00"));
    try std.testing.expect(envIsClean("HOME=/x\x00LANG=it\x00"));
}

test "nobody is trusted without a live process" {
    try std.testing.expect(!trusted(std.testing.allocator, 0));
}
