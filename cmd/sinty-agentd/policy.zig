const std = @import("std");

pub const Mode = enum {
    plan,
    ask,
    auto,
    autopilot,

    pub fn parse(s: []const u8) ?Mode {
        return std.meta.stringToEnum(Mode, s);
    }
};

pub fn fromConfig(a: std.mem.Allocator, text: []const u8) ?Mode {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return null;
    if (v != .object) return null;
    const f = v.object.get("mode") orelse return null;
    if (f != .string) return null;
    const m = Mode.parse(f.string) orelse return null;
    return if (m == .autopilot) .auto else m;
}

pub const Risk = enum {
    read,
    undoable,
    irreversible,

    pub fn parse(s: []const u8) Risk {
        return std.meta.stringToEnum(Risk, s) orelse .irreversible;
    }
};

pub const Verdict = enum { run, confirm, refuse };

pub fn decide(mode: Mode, risk: Risk, tainted: bool, stopped: bool) Verdict {
    if (stopped) return .refuse;
    return switch (mode) {
        .plan => if (risk == .read) .run else .refuse,
        .ask => if (risk == .irreversible) .confirm else .run,
        .auto => if (risk == .irreversible and tainted) .confirm else .run,
        .autopilot => .run,
    };
}

pub fn decideOutsider(mode: Mode, risk: Risk, harmless: bool, stopped: bool) Verdict {
    if (stopped) return .refuse;
    if (harmless) return .run;
    if (mode == .plan and risk != .read) return .refuse;
    return .confirm;
}

pub fn rank(m: Mode) u8 {
    return @intFromEnum(m);
}

test "an outsider gets no mode for free" {
    try std.testing.expectEqual(Verdict.confirm, decideOutsider(.autopilot, .irreversible, false, false));
    try std.testing.expectEqual(Verdict.confirm, decideOutsider(.autopilot, .read, false, false));
    try std.testing.expectEqual(Verdict.run, decideOutsider(.autopilot, .read, true, false));
    try std.testing.expectEqual(Verdict.refuse, decideOutsider(.plan, .undoable, false, false));
    try std.testing.expectEqual(Verdict.refuse, decideOutsider(.autopilot, .read, true, true));
}

test "stop refuses everything" {
    try std.testing.expectEqual(Verdict.refuse, decide(.autopilot, .read, false, true));
}

test "plan only reads" {
    try std.testing.expectEqual(Verdict.run, decide(.plan, .read, true, false));
    try std.testing.expectEqual(Verdict.refuse, decide(.plan, .undoable, false, false));
}

test "ask confirms what cannot be undone" {
    try std.testing.expectEqual(Verdict.run, decide(.ask, .undoable, true, false));
    try std.testing.expectEqual(Verdict.confirm, decide(.ask, .irreversible, false, false));
}

test "auto confirms only after reading outside content" {
    try std.testing.expectEqual(Verdict.run, decide(.auto, .irreversible, false, false));
    try std.testing.expectEqual(Verdict.confirm, decide(.auto, .irreversible, true, false));
}

test "autopilot never asks" {
    try std.testing.expectEqual(Verdict.run, decide(.autopilot, .irreversible, true, false));
}

test "an unknown risk counts as irreversible" {
    try std.testing.expectEqual(Risk.irreversible, Risk.parse("whatever"));
}

test "a mode in the configuration never reaches autopilot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(?Mode, .plan), fromConfig(a, "{\"mode\":\"plan\"}"));
    try std.testing.expectEqual(@as(?Mode, .auto), fromConfig(a, "{\"mode\":\"auto\"}"));
    try std.testing.expectEqual(@as(?Mode, .auto), fromConfig(a, "{\"mode\":\"autopilot\"}"));
    try std.testing.expectEqual(@as(?Mode, null), fromConfig(a, "{\"provider\":\"local\"}"));
    try std.testing.expectEqual(@as(?Mode, null), fromConfig(a, "{\"mode\":\"root\"}"));
    try std.testing.expectEqual(@as(?Mode, null), fromConfig(a, "not json"));
}
