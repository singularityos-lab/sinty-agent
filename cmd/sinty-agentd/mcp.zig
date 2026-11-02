const std = @import("std");
const catalog = @import("catalog.zig");

pub const Outcome = struct {
    text: []const u8,
    failed: bool = false,
    image: ?[]const u8 = null,
};

pub const Host = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, a: std.mem.Allocator, tool: []const u8, args: std.json.Value) Outcome,
};

const VERSION = "2025-06-18";

fn reply(a: std.mem.Allocator, id: std.json.Value, result: []const u8) ![]u8 {
    const i = try std.json.Stringify.valueAlloc(a, id, .{});
    return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ i, result });
}

fn failure(a: std.mem.Allocator, id: std.json.Value, code: i32, message: []const u8) ![]u8 {
    const i = try std.json.Stringify.valueAlloc(a, id, .{});
    return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ i, code, message });
}

pub fn handle(a: std.mem.Allocator, line: []const u8, host: Host) !?[]u8 {
    const req = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch
        return try failure(a, .null, -32700, "parse error");
    if (req != .object) return try failure(a, .null, -32600, "invalid request");
    const method = req.object.get("method") orelse return null;
    if (method != .string) return try failure(a, .null, -32600, "invalid request");
    const id = req.object.get("id") orelse return null;
    const params = req.object.get("params");

    if (std.mem.eql(u8, method.string, "initialize")) {
        var version: []const u8 = VERSION;
        if (params) |p| if (p == .object) if (p.object.get("protocolVersion")) |v| if (v == .string) {
            version = v.string;
        };
        const r = try std.fmt.allocPrint(a, "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"sinty-agent\",\"version\":\"0.1.0\"}}}}", .{version});
        return try reply(a, id, r);
    }
    if (std.mem.eql(u8, method.string, "ping")) return try reply(a, id, "{}");
    if (std.mem.eql(u8, method.string, "tools/list")) return try reply(a, id, try catalog.listJson(a));
    if (std.mem.eql(u8, method.string, "tools/call")) {
        if (params == null or params.? != .object) return try failure(a, id, -32602, "missing params");
        const name = params.?.object.get("name") orelse return try failure(a, id, -32602, "missing name");
        if (name != .string or catalog.find(name.string) == null) return try failure(a, id, -32602, "unknown tool");
        const args = params.?.object.get("arguments") orelse std.json.Value{ .object = .empty };
        const o = host.call(host.ctx, a, name.string, args);
        const text = try std.json.Stringify.valueAlloc(a, o.text, .{});
        const img = if (o.image) |b| try std.fmt.allocPrint(a, ",{{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"{s}\"}}", .{b}) else "";
        return try reply(a, id, try std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}{s}],\"isError\":{}}}", .{ text, img, o.failed }));
    }
    return try failure(a, id, -32601, "method not found");
}

fn echo(_: *anyopaque, _: std.mem.Allocator, tool: []const u8, _: std.json.Value) Outcome {
    return .{ .text = tool };
}

fn run(a: std.mem.Allocator, line: []const u8) !?[]u8 {
    var x: u8 = 0;
    return handle(a, line, .{ .ctx = &x, .call = echo });
}

test "initialize answers the version of the client" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = (try run(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\"}}")).?;
    try std.testing.expect(std.mem.indexOf(u8, r, "2024-11-05") != null);
}

test "notifications get no answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try run(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")) == null);
}

test "a tool outside the catalog is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = (try run(arena.allocator(), "{\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"rm\"}}")).?;
    try std.testing.expect(std.mem.indexOf(u8, r, "unknown tool") != null);
}

test "a known tool reaches the host" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = (try run(arena.allocator(), "{\"id\":\"x\",\"method\":\"tools/call\",\"params\":{\"name\":\"app_open\",\"arguments\":{\"app\":\"a\"}}}")).?;
    try std.testing.expect(std.mem.indexOf(u8, r, "\"id\":\"x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "app_open") != null);
}

test "garbage is a parse error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = (try run(arena.allocator(), "{nope")).?;
    try std.testing.expect(std.mem.indexOf(u8, r, "-32700") != null);
}
