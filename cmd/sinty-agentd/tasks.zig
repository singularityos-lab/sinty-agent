const std = @import("std");
const json = std.json;

pub const Trigger = union(enum) {
    every: u32,
    at: struct { hour: u8, minute: u8 },
    login,
    files: []const u8,
};

pub const Task = struct {
    id: []const u8,
    title: []const u8,
    prompt: []const u8,
    trigger: Trigger,
    enabled: bool = true,
};

fn field(o: json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    return true;
}

pub fn parseTrigger(o: json.ObjectMap) ?Trigger {
    if (o.get("every_minutes")) |v| {
        if (v == .integer and v.integer >= 5 and v.integer <= 7 * 24 * 60) return .{ .every = @intCast(v.integer) };
        return null;
    }
    if (field(o, "at")) |t| {
        if (t.len != 5 or t[2] != ':') return null;
        const h = std.fmt.parseInt(u8, t[0..2], 10) catch return null;
        const m = std.fmt.parseInt(u8, t[3..5], 10) catch return null;
        if (h > 23 or m > 59) return null;
        return .{ .at = .{ .hour = h, .minute = m } };
    }
    if (field(o, "event")) |e| {
        if (std.mem.eql(u8, e, "login")) return .login;
        if (std.mem.startsWith(u8, e, "files:")) {
            const dir = e[6..];
            if (dir.len == 0 or (dir[0] != '/' and dir[0] != '~')) return null;
            return .{ .files = dir };
        }
    }
    return null;
}

pub fn parseTask(v: json.Value) ?Task {
    if (v != .object) return null;
    const o = v.object;
    const id = field(o, "id") orelse return null;
    if (!validId(id)) return null;
    const prompt = field(o, "prompt") orelse return null;
    if (std.mem.trim(u8, prompt, " \t\r\n").len == 0) return null;
    const trigger = parseTrigger(o) orelse return null;
    const enabled = if (o.get("enabled")) |e| (e != .bool or e.bool) else true;
    return .{ .id = id, .title = field(o, "title") orelse id, .prompt = prompt, .trigger = trigger, .enabled = enabled };
}

pub fn parseAll(a: std.mem.Allocator, text: []const u8) []Task {
    var out: std.ArrayList(Task) = .empty;
    const v = json.parseFromSliceLeaky(json.Value, a, text, .{}) catch return out.items;
    const list = switch (v) {
        .array => |arr| arr.items,
        .object => |o| blk: {
            const t = o.get("tasks") orelse return out.items;
            if (t != .array) return out.items;
            break :blk t.array.items;
        },
        else => return out.items,
    };
    for (list) |item| {
        if (parseTask(item)) |t| out.append(a, t) catch {};
    }
    return out.items;
}

pub fn due(t: Task, now: i64, local_minute_of_day: u32, last: i64, started: i64) bool {
    if (!t.enabled) return false;
    return switch (t.trigger) {
        .every => |m| now - (if (last > 0) last else started) >= @as(i64, m) * 60,
        .at => |at| blk: {
            const target: u32 = @as(u32, at.hour) * 60 + at.minute;
            if (local_minute_of_day < target or local_minute_of_day > target + 30) break :blk false;
            break :blk now - last > 12 * 3600;
        },
        .login => last < started,
        .files => false,
    };
}

pub const Step = struct { text: []const u8, done: bool = false, result: []const u8 = "" };

pub const Plan = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8 = "active",
    steps: []Step,
};

pub fn parsePlans(a: std.mem.Allocator, text: []const u8) []Plan {
    var out: std.ArrayList(Plan) = .empty;
    const v = json.parseFromSliceLeaky([]Plan, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return out.items;
    for (v) |p| {
        if (validId(p.id)) out.append(a, p) catch {};
    }
    return out.items;
}

pub fn nextStep(p: Plan) ?usize {
    if (!std.mem.eql(u8, p.status, "active")) return null;
    for (p.steps, 0..) |s, i| {
        if (!s.done) return i;
    }
    return null;
}

pub fn expand(a: std.mem.Allocator, path: []const u8, home: []const u8) []const u8 {
    if (path.len == 0 or path[0] != '~') return path;
    const rest = std.mem.trimStart(u8, path[1..], "/");
    if (rest.len == 0) return home;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ home, rest }) catch path;
}

pub fn inHome(a: std.mem.Allocator, path: []const u8, home: []const u8) []const u8 {
    const full = expand(a, path, home);
    if (full.len > 0 and full[0] == '/') return full;
    const rest = if (std.mem.eql(u8, full, "home")) "" else if (std.mem.startsWith(u8, full, "home/")) full[5..] else full;
    if (rest.len == 0) return home;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ home, rest }) catch full;
}

test "a task needs an id, a prompt and a valid trigger" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = parseAll(a,
        \\[{"id":"mail","prompt":"Sort new mail","every_minutes":30},
        \\ {"id":"brief","prompt":"Morning brief","at":"08:15"},
        \\ {"id":"hello","prompt":"Say hi","event":"login","enabled":false},
        \\ {"id":"dl","prompt":"File new downloads","event":"files:~/Downloads"},
        \\ {"id":"bad id","prompt":"x","every_minutes":30},
        \\ {"id":"fast","prompt":"x","every_minutes":1},
        \\ {"id":"late","prompt":"x","at":"25:00"},
        \\ {"id":"empty","prompt":"  ","event":"login"}]
    );
    try std.testing.expectEqual(@as(usize, 4), list.len);
    try std.testing.expectEqual(@as(u32, 30), list[0].trigger.every);
    try std.testing.expectEqual(@as(u8, 8), list[1].trigger.at.hour);
    try std.testing.expect(!list[2].enabled);
    try std.testing.expectEqualStrings("~/Downloads", list[3].trigger.files);
}

test "due follows the trigger" {
    const every = Task{ .id = "a", .title = "a", .prompt = "p", .trigger = .{ .every = 30 } };
    try std.testing.expect(!due(every, 1000, 0, 0, 1000));
    try std.testing.expect(due(every, 1000 + 1800, 0, 0, 1000));
    try std.testing.expect(!due(every, 5000, 0, 4000, 1000));
    const at = Task{ .id = "b", .title = "b", .prompt = "p", .trigger = .{ .at = .{ .hour = 8, .minute = 15 } } };
    try std.testing.expect(due(at, 100000, 8 * 60 + 20, 0, 0));
    try std.testing.expect(!due(at, 100000, 8 * 60 + 20, 99000, 0));
    try std.testing.expect(!due(at, 100000, 7 * 60, 0, 0));
    const login = Task{ .id = "c", .title = "c", .prompt = "p", .trigger = .login };
    try std.testing.expect(due(login, 2000, 0, 500, 1000));
    try std.testing.expect(!due(login, 2000, 0, 1500, 1000));
    var off = login;
    off.enabled = false;
    try std.testing.expect(!due(off, 2000, 0, 0, 1000));
}

test "a folder name means a folder in the home" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/home/u/Inbox", inHome(a, "Inbox", "/home/u"));
    try std.testing.expectEqualStrings("/home/u/Inbox", inHome(a, "home/Inbox", "/home/u"));
    try std.testing.expectEqualStrings("/home/u/Inbox", inHome(a, "~/Inbox", "/home/u"));
    try std.testing.expectEqualStrings("/home/u/Inbox", inHome(a, "~Inbox", "/home/u"));
    try std.testing.expectEqualStrings("/home/u", inHome(a, "~", "/home/u"));
    try std.testing.expectEqualStrings("/home/u/Downloads", expand(a, "~/Downloads", "/home/u"));
    try std.testing.expectEqualStrings("/home/u", inHome(a, "home", "/home/u"));
    try std.testing.expectEqualStrings("/etc", inHome(a, "/etc", "/home/u"));
}

test "a plan resumes at its first open step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const plans = parsePlans(arena.allocator(),
        \\[{"id":"move","title":"Move photos","steps":[{"text":"list","done":true,"result":"40"},{"text":"copy"},{"text":"check"}]},
        \\ {"id":"old","title":"x","status":"done","steps":[{"text":"a"}]}]
    );
    try std.testing.expectEqual(@as(usize, 2), plans.len);
    try std.testing.expectEqual(@as(?usize, 1), nextStep(plans[0]));
    try std.testing.expectEqual(@as(?usize, null), nextStep(plans[1]));
}
