const std = @import("std");
const provider = @import("provider.zig");
const memory = @import("memory.zig");
const acp = @import("acp.zig");
const c = provider.c;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("sinty: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usage() noreturn {
    fatal("usage: sinty ask [--provider NAME] [--model NAME] [--endpoint URL] [--conversation ID] TEXT\n       sinty check [--provider NAME] [--model NAME] [--endpoint URL]\n       sinty key PROVIDER (reads the key from standard input)\n       sinty acp (an Agent Client Protocol agent on standard input and output)\nproviders: {s}", .{"local claude-code codex claude-api ollama"});
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
    if (std.mem.eql(u8, cmd, "acp")) {
        acp.serve(a, provider.Config.load(a));
        return;
    }
    const checking = std.mem.eql(u8, cmd, "check");
    if (!checking and !std.mem.eql(u8, cmd, "ask")) usage();
    var cfg = provider.Config.load(a);
    const configured = cfg.provider;
    var model_given = false;
    var endpoint_given = false;
    var words: std.ArrayList(u8) = .empty;
    var conversation: []const u8 = "";
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--provider")) {
            cfg.provider = it.next() orelse usage();
        } else if (std.mem.eql(u8, arg, "--model")) {
            cfg.model = it.next() orelse usage();
            model_given = true;
        } else if (std.mem.eql(u8, arg, "--endpoint")) {
            cfg.endpoint = it.next() orelse usage();
            endpoint_given = true;
        } else if (std.mem.eql(u8, arg, "--conversation")) {
            conversation = it.next() orelse usage();
            if (!memory.valid(conversation)) usage();
        } else {
            if (words.items.len > 0) words.append(a, ' ') catch fatal("out of memory", .{});
            words.appendSlice(a, arg) catch fatal("out of memory", .{});
        }
    }
    if (!model_given and !std.mem.eql(u8, cfg.provider, configured)) {
        cfg.model = "";
        if (!endpoint_given) cfg.endpoint = "";
    }
    if (checking) {
        if (words.items.len > 0) usage();
        cfg.tools = false;
        const reply = provider.run(a, cfg, "Reply with the single word ready.") catch |e| fatal("{s}", .{provider.describe(e)});
        const trimmed = std.mem.trim(u8, reply, " \r\n\t");
        if (trimmed.len == 0) fatal("the model sent an empty answer", .{});
        _ = std.c.write(1, trimmed.ptr, trimmed.len);
        _ = std.c.write(1, "\n", 1);
        return;
    }
    if (words.items.len == 0) usage();
    const turns = if (conversation.len > 0) memory.load(a, conversation) else &.{};
    const full = memory.prompt(a, turns, provider.windows(a), words.items) catch fatal("out of memory", .{});
    const text = provider.run(a, cfg, full) catch |e| fatal("{s}", .{provider.describe(e)});
    if (conversation.len > 0) memory.save(a, conversation, turns, words.items, text);
    if (text.len > 0) {
        _ = std.c.write(1, text.ptr, text.len);
        _ = std.c.write(1, "\n", 1);
    }
}
