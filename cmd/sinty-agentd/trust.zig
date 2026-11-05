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

const REMOTES = [_][]const u8{
    "/usr/libexec/singularity-nearby",
    "/usr/local/libexec/singularity-nearby",
    "/opt/local/libexec/singularity-nearby",
};

const COMPAT_ROOT = "/compat/linux";

const TAINTING = [_][]const u8{ "LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT", "GTK_MODULES", "GTK_PATH", "GIO_EXTRA_MODULES", "GI_TYPELIB_PATH", "G_DEBUG" };

const PATH_LISTS = [_][]const u8{ "LD_LIBRARY_PATH", "GI_TYPELIB_PATH" };

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

fn systemPaths(value: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ':');
    while (it.next()) |p| {
        if (!std.mem.startsWith(u8, p, "/usr/") and !std.mem.startsWith(u8, p, "/opt/local/")) return false;
        if (std.mem.indexOf(u8, p, "..") != null) return false;
    }
    return true;
}

pub fn envIsClean(env: []const u8) bool {
    var it = std.mem.splitScalar(u8, env, 0);
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        for (TAINTING) |t| {
            if (!std.mem.eql(u8, kv[0..eq], t)) continue;
            for (PATH_LISTS) |l| {
                if (std.mem.eql(u8, t, l) and systemPaths(kv[eq + 1 ..])) break;
            } else return false;
        }
    }
    return true;
}

pub fn canonical(exe: []const u8) []const u8 {
    if (std.mem.startsWith(u8, exe, COMPAT_ROOT ++ "/")) return exe[COMPAT_ROOT.len..];
    return exe;
}

fn isSameRootOwnedFile(a: std.mem.Allocator, pid: i32, exe: []const u8) bool {
    const z = a.dupeZ(u8, exe) catch return false;
    const link = std.fmt.allocPrintSentinel(a, "/proc/{d}/exe", .{pid}, 0) catch return false;
    var want: c.struct_stat = undefined;
    var got: c.struct_stat = undefined;
    if (c.stat(z.ptr, &want) != 0) return false;
    const safe = want.st_uid == 0 and want.st_mode & 0o022 == 0;
    if (c.stat(link.ptr, &got) != 0) return false;
    if (want.st_dev != got.st_dev or want.st_ino != got.st_ino) return false;
    return safe;
}

fn listed(a: std.mem.Allocator, pid: i32, programs: []const []const u8, extra: []const u8) bool {
    if (pid <= 0) return false;
    const exe = canonical(exeOf(a, pid));
    if (extra.len != 0) {
        var it = std.mem.splitScalar(u8, extra, ':');
        while (it.next()) |p| {
            if (std.mem.eql(u8, p, exe)) return true;
        }
    }
    for (programs) |s| {
        if (std.mem.eql(u8, s, exe)) return isSameRootOwnedFile(a, pid, exe) and cleanEnv(a, pid);
    }
    return false;
}

pub fn trusted(a: std.mem.Allocator, pid: i32) bool {
    return listed(a, pid, &SHELLS, options.test_trust);
}

pub fn remote(a: std.mem.Allocator, pid: i32) bool {
    return listed(a, pid, &REMOTES, options.test_remote);
}

test "a preloaded library spoils the environment" {
    try std.testing.expect(!envIsClean("HOME=/x\x00LD_PRELOAD=/tmp/evil.so\x00"));
    try std.testing.expect(envIsClean("HOME=/x\x00LANG=it\x00"));
}

test "system library paths do not spoil the environment" {
    try std.testing.expect(envIsClean("LD_LIBRARY_PATH=/usr/lib:/usr/lib\x00GI_TYPELIB_PATH=/usr/lib/girepository-1.0\x00"));
    try std.testing.expect(!envIsClean("LD_LIBRARY_PATH=/usr/lib:/tmp/evil\x00"));
    try std.testing.expect(!envIsClean("LD_LIBRARY_PATH=/usr/lib:\x00"));
    try std.testing.expect(!envIsClean("LD_LIBRARY_PATH=/usr/../tmp\x00"));
    try std.testing.expect(!envIsClean("GI_TYPELIB_PATH=/home/x\x00"));
}

test "nobody is trusted without a live process" {
    try std.testing.expect(!trusted(std.testing.allocator, 0));
    try std.testing.expect(!remote(std.testing.allocator, 0));
}

test "canonical removes only the compat root" {
    try std.testing.expectEqualStrings("/usr/bin/x", canonical("/compat/linux/usr/bin/x"));
    try std.testing.expectEqualStrings("/usr/bin/x", canonical("/usr/bin/x"));
    try std.testing.expectEqualStrings("/compat/linuxevil/x", canonical("/compat/linuxevil/x"));
}
