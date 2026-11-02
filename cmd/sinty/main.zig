const std = @import("std");
const provider = @import("provider.zig");
const c = provider.c;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("sinty: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usage() noreturn {
    fatal("usage: sinty ask [--provider NAME] [--model NAME] [--endpoint URL] TEXT\n       sinty key PROVIDER (reads the key from standard input)\nproviders: {s}", .{"claude-code codex claude-api ollama"});
}

fn storeKey(p: []const u8) void {
    var buf: [4096]u8 = undefined;
    const n = std.c.read(0, &buf, buf.len);
    if (n <= 0) fatal("no key on standard input", .{});
    const key = std.mem.trim(u8, buf[0..@intCast(n)], " \r\n");
    provider.saveKey(std.heap.c_allocator, p, key) catch fatal("the keyring refused the key", .{});
}

pub fn main(init: std.process.Init.Minimal) void {
    const a = std.heap.c_allocator;
    var it = init.args.iterate();
    _ = it.next();
    const cmd = it.next() orelse usage();
    if (std.mem.eql(u8, cmd, "key")) {
        storeKey(it.next() orelse usage());
        return;
    }
    if (!std.mem.eql(u8, cmd, "ask")) usage();
    var cfg = provider.Config.load(a);
    var words: std.ArrayList(u8) = .empty;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--provider")) {
            cfg.provider = it.next() orelse usage();
        } else if (std.mem.eql(u8, arg, "--model")) {
            cfg.model = it.next() orelse usage();
        } else if (std.mem.eql(u8, arg, "--endpoint")) {
            cfg.endpoint = it.next() orelse usage();
        } else {
            if (words.items.len > 0) words.append(a, ' ') catch fatal("out of memory", .{});
            words.appendSlice(a, arg) catch fatal("out of memory", .{});
        }
    }
    if (words.items.len == 0) usage();
    const text = provider.run(a, cfg, words.items) catch |e| fatal("{s}", .{provider.describe(e)});
    if (text.len > 0) {
        _ = std.c.write(1, text.ptr, text.len);
        _ = std.c.write(1, "\n", 1);
    }
}
