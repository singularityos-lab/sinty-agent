const std = @import("std");

pub const TEXT_EXT = [_][]const u8{
    ".txt", ".md",   ".csv",  ".tsv", ".json", ".xml", ".html", ".htm", ".rst", ".org", ".tex", ".log", ".ini", ".toml", ".yaml", ".yml",
    ".c",   ".h",    ".cpp",  ".rs",  ".zig",  ".go",  ".py",   ".js",  ".ts",  ".vala", ".java", ".sh", ".css", ".sql", ".ics", ".vcf",
    ".eml", ".srt",  ".conf",
};

pub fn isText(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    var buf: [16]u8 = undefined;
    const ext = name[dot..];
    if (ext.len > buf.len) return false;
    const low = std.ascii.lowerString(&buf, ext);
    for (TEXT_EXT) |e| {
        if (std.mem.eql(u8, e, low)) return true;
    }
    return false;
}

pub fn tokens(a: std.mem.Allocator, text: []const u8) [][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !isWord(text[i])) i += 1;
        const start = i;
        while (i < text.len and isWord(text[i])) i += 1;
        if (i - start < 2) continue;
        const w = a.alloc(u8, i - start) catch continue;
        for (text[start..i], 0..) |ch, k| w[k] = std.ascii.toLower(ch);
        out.append(a, stem(w)) catch {};
    }
    return out.items;
}

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch >= 0x80;
}

fn stem(w: []const u8) []const u8 {
    const ends = [_][]const u8{ "zioni", "zione", "mente", "ments", "ment", "ing", "ies", "es", "s", "i", "e", "a", "o" };
    for (ends) |e| {
        if (w.len > e.len + 3 and std.mem.endsWith(u8, w, e)) return w[0 .. w.len - e.len];
    }
    return w;
}

pub const Doc = struct {
    path: []const u8,
    name: []const u8,
    words: [][]const u8,
};

pub fn lexical(query: [][]const u8, doc: Doc, df: *const std.StringHashMapUnmanaged(u32), total: usize) f64 {
    if (query.len == 0) return 0;
    var score: f64 = 0;
    const len: f64 = @floatFromInt(@max(doc.words.len, 1));
    for (query) |q| {
        var tf: f64 = 0;
        for (doc.words) |w| {
            if (std.mem.eql(u8, w, q)) tf += 1;
        }
        var in_name = false;
        var name_buf: [512]u8 = undefined;
        const n = @min(doc.name.len, name_buf.len);
        const low = std.ascii.lowerString(name_buf[0..n], doc.name[0..n]);
        if (std.mem.indexOf(u8, low, q) != null) in_name = true;
        if (tf == 0 and !in_name) continue;
        const d: f64 = @floatFromInt(df.get(q) orelse 1);
        const idf = @log(1.0 + (@as(f64, @floatFromInt(total)) - d + 0.5) / (d + 0.5));
        const k = 1.2;
        const b = 0.75;
        const norm = tf * (k + 1) / (tf + k * (1 - b + b * len / 400.0));
        score += idf * norm + (if (in_name) idf * 1.5 else 0);
    }
    return score;
}

pub fn cosine(x: []const f32, y: []const f32) f64 {
    if (x.len != y.len or x.len == 0) return 0;
    var dot: f64 = 0;
    var nx: f64 = 0;
    var ny: f64 = 0;
    for (x, y) |p, q| {
        dot += p * q;
        nx += p * p;
        ny += q * q;
    }
    if (nx == 0 or ny == 0) return 0;
    return dot / (@sqrt(nx) * @sqrt(ny));
}

pub fn snippet(a: std.mem.Allocator, text: []const u8, query: [][]const u8) []const u8 {
    var best: usize = 0;
    var found = false;
    const lower = a.alloc(u8, text.len) catch return text[0..@min(text.len, 160)];
    _ = std.ascii.lowerString(lower, text);
    for (query) |q| {
        if (std.mem.indexOf(u8, lower, q)) |at| {
            best = at;
            found = true;
            break;
        }
    }
    const start = if (found and best > 60) best - 60 else 0;
    const end = @min(text.len, start + 200);
    var s = text[start..end];
    while (s.len > 0 and (s[0] & 0xC0) == 0x80) s = s[1..];
    while (s.len > 0 and (s[s.len - 1] & 0x80) != 0 and (s[s.len - 1] & 0xC0) != 0xC0) s = s[0 .. s.len - 1];
    if (s.len > 0 and (s[s.len - 1] & 0xC0) == 0xC0) s = s[0 .. s.len - 1];
    const out = a.dupe(u8, s) catch return "";
    for (out) |*ch| {
        if (ch.* == '\n' or ch.* == '\r' or ch.* == '\t') ch.* = ' ';
    }
    return out;
}

test "text files are recognised by extension" {
    try std.testing.expect(isText("Notes.MD"));
    try std.testing.expect(isText("bill.csv"));
    try std.testing.expect(!isText("photo.jpg"));
    try std.testing.expect(!isText("README"));
}

test "tokens fold case and endings so close words meet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = tokens(arena.allocator(), "Invoices, INVOICE and fatture: fattura!");
    try std.testing.expectEqualStrings("invoic", t[0]);
    try std.testing.expectEqualStrings("invoic", t[1]);
    try std.testing.expectEqualStrings(t[3], t[4]);
}

test "lexical ranking prefers the file about the query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d1 = Doc{ .path = "/a", .name = "trip.md", .words = tokens(a, "train tickets to rome and the hotel booking for the trip") };
    const d2 = Doc{ .path = "/b", .name = "electricity-bill.txt", .words = tokens(a, "electricity bill for october, amount due 84 euro") };
    var df: std.StringHashMapUnmanaged(u32) = .empty;
    for ([_]Doc{ d1, d2 }) |d| {
        for (d.words) |w| {
            const g = try df.getOrPut(a, w);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
    }
    const q = tokens(a, "electricity bills");
    try std.testing.expect(lexical(q, d2, &df, 2) > lexical(q, d1, &df, 2));
    try std.testing.expect(lexical(tokens(a, "trip"), d1, &df, 2) > 0);
}

test "cosine and snippet" {
    try std.testing.expectApproxEqAbs(@as(f64, 1), cosine(&.{ 1, 2 }, &.{ 2, 4 }), 1e-9);
    try std.testing.expectEqual(@as(f64, 0), cosine(&.{1}, &.{ 1, 2 }));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = snippet(a, "line one\nthe bill is here", tokens(a, "bill"));
    try std.testing.expect(std.mem.indexOf(u8, s, "bill") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, s, '\n') == null);
}
