const std = @import("std");

pub const Kind = enum { setting, profile, ctrl_z, instruction };

pub const Change = struct {
    id: u32,
    time: i64,
    tool: []const u8,
    app: []const u8 = "",
    summary: []const u8,
    kind: Kind,
    undo: []const u8,
    schema: []const u8 = "",
    path: []const u8 = "",
    key: []const u8 = "",
    undone: bool = false,
};

const MAX = 64;

pub const Journal = struct {
    gpa: std.mem.Allocator,
    items: [MAX]?Change = .{null} ** MAX,
    next: u32 = 1,

    fn dupe(self: *Journal, s: []const u8) []const u8 {
        return self.gpa.dupe(u8, s) catch "";
    }

    fn release(self: *Journal, ch: Change) void {
        for ([_][]const u8{ ch.tool, ch.app, ch.summary, ch.undo, ch.schema, ch.path, ch.key }) |s| {
            if (s.len != 0) self.gpa.free(s);
        }
    }

    pub fn add(self: *Journal, ch: Change) u32 {
        const id = self.next;
        self.next += 1;
        const slot = &self.items[id % MAX];
        if (slot.*) |old| self.release(old);
        slot.* = .{
            .id = id,
            .time = ch.time,
            .tool = self.dupe(ch.tool),
            .app = self.dupe(ch.app),
            .summary = self.dupe(ch.summary),
            .kind = ch.kind,
            .undo = self.dupe(ch.undo),
            .schema = self.dupe(ch.schema),
            .path = self.dupe(ch.path),
            .key = self.dupe(ch.key),
        };
        return id;
    }

    pub fn get(self: *Journal, id: u32) ?*Change {
        const slot = &self.items[id % MAX];
        if (slot.*) |*ch| {
            if (ch.id == id) return ch;
        }
        return null;
    }

    pub fn last(self: *Journal) ?*Change {
        var id = self.next;
        while (id > 1 and self.next - id < MAX) {
            id -= 1;
            if (self.get(id)) |ch| {
                if (!ch.undone) return ch;
            }
        }
        return null;
    }

    pub fn listJson(self: *Journal, a: std.mem.Allocator) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        out.append(a, '[') catch return "[]";
        var id = self.next;
        var first = true;
        while (id > 1 and self.next - id < MAX) {
            id -= 1;
            const ch = self.get(id) orelse continue;
            const item = std.json.Stringify.valueAlloc(a, .{
                .id = ch.id,
                .time = ch.time,
                .tool = ch.tool,
                .app = ch.app,
                .summary = ch.summary,
                .undo = ch.undo,
                .undone = ch.undone,
            }, .{}) catch continue;
            if (!first) out.append(a, ',') catch {};
            first = false;
            out.appendSlice(a, item) catch {};
        }
        out.append(a, ']') catch {};
        return out.items;
    }
};

pub fn undoOf(a: std.mem.Allocator, result: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, result, .{}) catch return null;
    if (v != .object) return null;
    const u = v.object.get("undo") orelse return null;
    if (u != .string) return null;
    const t = std.mem.trim(u8, u.string, " \t\r\n");
    if (t.len == 0 or std.ascii.startsWithIgnoreCase(t, "nothing to undo")) return null;
    return t;
}

pub fn kindOf(undo: []const u8) Kind {
    if (std.ascii.eqlIgnoreCase(undo, "ctrl+z")) return .ctrl_z;
    return .instruction;
}

pub fn undoAction(a: std.mem.Allocator, actions: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, actions, .{}) catch return null;
    const list = switch (v) {
        .array => |arr| arr.items,
        .object => |o| blk: {
            const inner = o.get("actions") orelse return null;
            if (inner != .array) return null;
            break :blk inner.array.items;
        },
        else => return null,
    };
    var best: ?[]const u8 = null;
    for (list) |it| {
        const name = switch (it) {
            .string => |s| s,
            .object => |o| blk: {
                const n = o.get("name") orelse continue;
                if (n != .string) continue;
                if (o.get("enabled")) |e| if (e == .bool and !e.bool) continue;
                break :blk n.string;
            },
            else => continue,
        };
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse continue;
        if (!std.mem.eql(u8, name[dot + 1 ..], "undo")) continue;
        if (best == null or std.mem.startsWith(u8, name, "win.")) best = name;
    }
    return best;
}

test "the journal hands back the newest change still to undo" {
    var j = Journal{ .gpa = std.testing.allocator };
    defer for (j.items) |it| if (it) |ch| j.release(ch);
    const a = j.add(.{ .id = 0, .time = 1, .tool = "settings_set", .summary = "dark", .kind = .setting, .undo = "'light'", .schema = "s", .key = "k" });
    const b = j.add(.{ .id = 0, .time = 2, .tool = "app_invoke", .app = "dev.sinty.Maps", .summary = "maps_move", .kind = .instruction, .undo = "maps_move with lat 1" });
    try std.testing.expectEqual(b, j.last().?.id);
    j.get(b).?.undone = true;
    try std.testing.expectEqual(a, j.last().?.id);
    j.get(a).?.undone = true;
    try std.testing.expect(j.last() == null);
}

test "the ring forgets what falls out of it" {
    var j = Journal{ .gpa = std.testing.allocator };
    defer for (j.items) |it| if (it) |ch| j.release(ch);
    const first = j.add(.{ .id = 0, .time = 0, .tool = "t", .summary = "s", .kind = .instruction, .undo = "u" });
    var i: usize = 0;
    while (i < MAX) : (i += 1) _ = j.add(.{ .id = 0, .time = 0, .tool = "t", .summary = "s", .kind = .instruction, .undo = "u" });
    try std.testing.expect(j.get(first) == null);
}

test "undo text comes from the intent result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("maps_move with lat 1", undoOf(a, "{\"undo\":\"maps_move with lat 1\"}").?);
    try std.testing.expect(undoOf(a, "{\"undo\":\"nothing to undo\"}") == null);
    try std.testing.expect(undoOf(a, "plain") == null);
    try std.testing.expectEqual(Kind.ctrl_z, kindOf("Ctrl+Z"));
}

test "the undo action prefers the window one and skips disabled ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("win.undo", undoAction(a, "[{\"name\":\"app.undo\"},{\"name\":\"win.undo\"}]").?);
    try std.testing.expect(undoAction(a, "[{\"name\":\"win.undo\",\"enabled\":false}]") == null);
    try std.testing.expectEqualStrings("doc.undo", undoAction(a, "{\"actions\":[{\"name\":\"doc.undo\"}]}").?);
}
