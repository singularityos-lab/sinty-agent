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
