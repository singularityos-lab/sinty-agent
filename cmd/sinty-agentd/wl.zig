const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("wl-import.h");
});
const mcp = @import("mcp.zig");

const gpa = std.heap.c_allocator;
const IMAGE_MAX = 1568;
const WAIT_STEP_US = 10000;
const WAIT_STEPS = 500;

const STATE_MAXIMIZED = 0;
const STATE_MINIMIZED = 1;
const STATE_ACTIVATED = 2;
const STATE_FULLSCREEN = 3;

const BTN_LEFT = 0x110;
const BTN_RIGHT = 0x111;
const BTN_MIDDLE = 0x112;

const MOD_SHIFT = 1;
const MOD_CTRL = 4;
const MOD_ALT = 8;
const MOD_SUPER = 64;

const Win = struct {
    id: u32,
    h: ?*c.zwlr_foreign_toplevel_handle_v1,
    title: []u8 = &.{},
    app: []u8 = &.{},
    maximized: bool = false,
    minimized: bool = false,
    activated: bool = false,
    fullscreen: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    ht: i32 = 0,
    output: []u8 = &.{},
    pid: i32 = 0,
};

const Out = struct {
    o: ?*c.wl_output,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    name: []u8 = &.{},
};

const Frame = struct {
    format: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    stride: u32 = 0,
    invert: bool = false,
    have: bool = false,
    ready: bool = false,
    failed: bool = false,
};

var lock: c.GMutex = std.mem.zeroes(c.GMutex);
var started = false;
var dead = false;
var display: ?*c.wl_display = null;
var seat: ?*c.wl_seat = null;
var shm: ?*c.wl_shm = null;
var mgr: ?*c.zwlr_foreign_toplevel_manager_v1 = null;
var tiling: ?*c.zsingularity_tiling_manager_v1 = null;
var preview: ?*c.zsingularity_preview_manager_v1 = null;
var process: ?*c.zsingularity_process_manager_v1 = null;
var vptrMgr: ?*c.zwlr_virtual_pointer_manager_v1 = null;
var vkbdMgr: ?*c.zwp_virtual_keyboard_manager_v1 = null;
var copyMgr: ?*c.zwlr_screencopy_manager_v1 = null;
var xdgMgr: ?*c.zxdg_output_manager_v1 = null;
var vptr: ?*c.zwlr_virtual_pointer_v1 = null;
var wins: std.ArrayList(*Win) = .empty;
var outs: std.ArrayList(*Out) = .empty;
var nextId: u32 = 1;

fn fail(t: []const u8) mcp.Outcome {
    return .{ .text = t, .failed = true };
}

fn dup(s: [*c]const u8) []u8 {
    if (s == null) return &.{};
    return gpa.dupe(u8, std.mem.span(s)) catch &.{};
}

fn winOf(h: ?*anyopaque) ?*Win {
    for (wins.items) |w| {
        if (@as(?*anyopaque, @ptrCast(w.h)) == h) return w;
    }
    return null;
}

fn onHandle(_: ?*const anyopaque, target: ?*anyopaque, op: u32, _: [*c]const c.wl_message, args: [*c]c.wl_argument) callconv(.c) c_int {
    const w = winOf(target) orelse return 0;
    switch (op) {
        0 => {
            gpa.free(w.title);
            w.title = dup(args[0].s);
        },
        1 => {
            gpa.free(w.app);
            w.app = dup(args[0].s);
        },
        4 => {
            w.maximized = false;
            w.minimized = false;
            w.activated = false;
            w.fullscreen = false;
            const arr = args[0].a;
            const n = arr.*.size / 4;
            const v: [*c]const u32 = @ptrCast(@alignCast(arr.*.data));
            for (0..n) |i| switch (v[i]) {
                STATE_MAXIMIZED => w.maximized = true,
                STATE_MINIMIZED => w.minimized = true,
                STATE_ACTIVATED => w.activated = true,
                STATE_FULLSCREEN => w.fullscreen = true,
                else => {},
            };
        },
        6 => {
            for (wins.items, 0..) |x, i| {
                if (x == w) {
                    _ = wins.swapRemove(i);
                    break;
                }
            }
            c.zwlr_foreign_toplevel_handle_v1_destroy(w.h);
            gpa.free(w.title);
            gpa.free(w.app);
            gpa.free(w.output);
            gpa.destroy(w);
        },
        else => {},
    }
    return 0;
}

fn onManager(_: ?*const anyopaque, _: ?*anyopaque, op: u32, _: [*c]const c.wl_message, args: [*c]c.wl_argument) callconv(.c) c_int {
    if (op != 0) return 0;
    const w = gpa.create(Win) catch return 0;
    w.* = .{ .id = nextId, .h = @ptrCast(args[0].o) };
    nextId += 1;
    wins.append(gpa, w) catch return 0;
    _ = c.wl_proxy_add_dispatcher(@ptrCast(w.h), onHandle, null, null);
    return 0;
}

fn onTiling(_: ?*const anyopaque, _: ?*anyopaque, op: u32, _: [*c]const c.wl_message, args: [*c]c.wl_argument) callconv(.c) c_int {
    if (op != 0) return 0;
    const w = winOf(args[0].o) orelse return 0;
    w.x = args[1].i;
    w.y = args[2].i;
    w.w = args[3].i;
    w.ht = args[4].i;
    gpa.free(w.output);
    w.output = dup(args[7].s);
    return 0;
}

fn onProcess(_: ?*const anyopaque, _: ?*anyopaque, op: u32, _: [*c]const c.wl_message, args: [*c]c.wl_argument) callconv(.c) c_int {
    if (op != 0) return 0;
    const w = winOf(args[0].o) orelse return 0;
    w.pid = args[1].i;
    return 0;
}

fn onXdg(_: ?*const anyopaque, _: ?*anyopaque, op: u32, _: [*c]const c.wl_message, _: [*c]c.wl_argument) callconv(.c) c_int {
    _ = op;
    return 0;
}

fn onXdgOut(data: ?*const anyopaque, _: ?*anyopaque, op: u32, _: [*c]const c.wl_message, args: [*c]c.wl_argument) callconv(.c) c_int {
    const o: *Out = @ptrCast(@alignCast(@constCast(data.?)));
    switch (op) {
        0 => {
            o.x = args[0].i;
            o.y = args[1].i;
        },
        1 => {
            o.w = args[0].i;
            o.h = args[1].i;
        },
        3 => {
            gpa.free(o.name);
            o.name = dup(args[0].s);
        },
        else => {},
    }
    return 0;
}

fn onFramePreview(data: ?*const anyopaque, _: ?*anyopaque, op: u32, _: [*c]const c.wl_message, args: [*c]c.wl_argument) callconv(.c) c_int {
    const f: *Frame = @ptrCast(@alignCast(@constCast(data.?)));
    switch (op) {
        0 => {
            f.format = args[0].u;
            f.w = args[1].u;
            f.h = args[2].u;
            f.stride = args[3].u;
            f.have = true;
        },
        1 => f.invert = args[0].u & 1 != 0,
        2 => f.ready = true,
        3 => f.failed = true,
        else => {},
    }
    return 0;
}

fn usableFormat(fmt: u32) bool {
    return fmt == c.WL_SHM_FORMAT_XRGB8888 or fmt == c.WL_SHM_FORMAT_ARGB8888 or redFirst(fmt);
}

fn redFirst(fmt: u32) bool {
    return fmt == c.WL_SHM_FORMAT_XBGR8888 or fmt == c.WL_SHM_FORMAT_ABGR8888;
}

fn onFrameCopy(data: ?*const anyopaque, _: ?*anyopaque, op: u32, _: [*c]const c.wl_message, args: [*c]c.wl_argument) callconv(.c) c_int {
    const f: *Frame = @ptrCast(@alignCast(@constCast(data.?)));
    switch (op) {
        0 => {
            const fmt = args[0].u;
            if (!f.have or (!usableFormat(f.format) and usableFormat(fmt))) {
                f.format = fmt;
                f.w = args[1].u;
                f.h = args[2].u;
                f.stride = args[3].u;
                f.have = true;
            }
        },
        1 => f.invert = args[0].u & 1 != 0,
        2 => f.ready = true,
        3 => f.failed = true,
        else => {},
    }
    return 0;
}

fn bind(reg: ?*c.wl_registry, id: u32, iface: *const c.wl_interface, have: u32, want: u32) ?*anyopaque {
    return c.wl_registry_bind(reg, id, iface, @min(have, want));
}

fn onRegistry(_: ?*const anyopaque, target: ?*anyopaque, op: u32, _: [*c]const c.wl_message, args: [*c]c.wl_argument) callconv(.c) c_int {
    if (op != 0) return 0;
    const reg: ?*c.wl_registry = @ptrCast(target);
    const id = args[0].u;
    const name = std.mem.span(args[1].s);
    const ver = args[2].u;
    const is = struct {
        fn f(n: []const u8, i: *const c.wl_interface) bool {
            return std.mem.eql(u8, n, std.mem.span(i.name));
        }
    }.f;
    if (is(name, &c.wl_seat_interface)) {
        if (seat == null) seat = @ptrCast(bind(reg, id, &c.wl_seat_interface, ver, 1));
    } else if (is(name, &c.wl_shm_interface)) {
        shm = @ptrCast(bind(reg, id, &c.wl_shm_interface, ver, 1));
    } else if (is(name, &c.wl_output_interface)) {
        const o = gpa.create(Out) catch return 0;
        o.* = .{ .o = @ptrCast(bind(reg, id, &c.wl_output_interface, ver, 3)) };
        outs.append(gpa, o) catch return 0;
    } else if (is(name, &c.zwlr_foreign_toplevel_manager_v1_interface)) {
        mgr = @ptrCast(bind(reg, id, &c.zwlr_foreign_toplevel_manager_v1_interface, ver, 3));
        _ = c.wl_proxy_add_dispatcher(@ptrCast(mgr), onManager, null, null);
    } else if (is(name, &c.zsingularity_tiling_manager_v1_interface)) {
        tiling = @ptrCast(bind(reg, id, &c.zsingularity_tiling_manager_v1_interface, ver, 4));
        _ = c.wl_proxy_add_dispatcher(@ptrCast(tiling), onTiling, null, null);
    } else if (is(name, &c.zsingularity_preview_manager_v1_interface)) {
        preview = @ptrCast(bind(reg, id, &c.zsingularity_preview_manager_v1_interface, ver, 1));
    } else if (is(name, &c.zsingularity_process_manager_v1_interface)) {
        process = @ptrCast(bind(reg, id, &c.zsingularity_process_manager_v1_interface, ver, 1));
        _ = c.wl_proxy_add_dispatcher(@ptrCast(process), onProcess, null, null);
    } else if (is(name, &c.zwlr_virtual_pointer_manager_v1_interface)) {
        vptrMgr = @ptrCast(bind(reg, id, &c.zwlr_virtual_pointer_manager_v1_interface, ver, 1));
    } else if (is(name, &c.zwp_virtual_keyboard_manager_v1_interface)) {
        vkbdMgr = @ptrCast(bind(reg, id, &c.zwp_virtual_keyboard_manager_v1_interface, ver, 1));
    } else if (is(name, &c.zwlr_screencopy_manager_v1_interface)) {
        copyMgr = @ptrCast(bind(reg, id, &c.zwlr_screencopy_manager_v1_interface, ver, 1));
    } else if (is(name, &c.zxdg_output_manager_v1_interface)) {
        xdgMgr = @ptrCast(bind(reg, id, &c.zxdg_output_manager_v1_interface, ver, 3));
    }
    return 0;
}

fn pump() void {
    while (true) {
        c.g_mutex_lock(&lock);
        const d = display.?;
        _ = c.wl_display_dispatch_pending(d);
        _ = c.wl_display_flush(d);
        c.g_mutex_unlock(&lock);
        var p = c.struct_pollfd{ .fd = c.wl_display_get_fd(d), .events = c.POLLIN, .revents = 0 };
        if (c.poll(&p, 1, 500) <= 0) continue;
        c.g_mutex_lock(&lock);
        if (c.wl_display_prepare_read(d) == 0) {
            var q = c.struct_pollfd{ .fd = c.wl_display_get_fd(d), .events = c.POLLIN, .revents = 0 };
            if (c.poll(&q, 1, 0) > 0) {
                if (c.wl_display_read_events(d) < 0) dead = true;
            } else c.wl_display_cancel_read(d);
        }
        c.g_mutex_unlock(&lock);
        if (dead) return;
    }
}

fn connect() bool {
    if (display != null and !dead) return true;
    if (dead) return false;
    display = c.wl_display_connect(null);
    if (display == null) return false;
    const reg = c.wl_display_get_registry(display);
    _ = c.wl_proxy_add_dispatcher(@ptrCast(reg), onRegistry, null, null);
    _ = c.wl_display_roundtrip(display);
    for (outs.items) |o| {
        if (xdgMgr == null) break;
        const x = c.zxdg_output_manager_v1_get_xdg_output(xdgMgr, o.o);
        _ = c.wl_proxy_add_dispatcher(@ptrCast(x), onXdgOut, o, null);
    }
    _ = c.wl_display_roundtrip(display);
    _ = c.wl_display_roundtrip(display);
    const t = std.Thread.spawn(.{}, pump, .{}) catch return false;
    t.detach();
    return true;
}

fn enter() bool {
    c.g_mutex_lock(&lock);
    if (connect()) return true;
    c.g_mutex_unlock(&lock);
    return false;
}

fn leave() void {
    _ = c.wl_display_flush(display);
    c.g_mutex_unlock(&lock);
}

const NO_COMPOSITOR = "the compositor cannot be reached";

fn refresh() void {
    _ = c.wl_display_roundtrip(display);
    for (wins.items) |w| {
        if (tiling != null) c.zsingularity_tiling_manager_v1_get_geometry(tiling, w.h);
        if (process != null) c.zsingularity_process_manager_v1_get_pid(process, w.h);
    }
    _ = c.wl_display_roundtrip(display);
}

fn byId(id: i64) ?*Win {
    for (wins.items) |w| {
        if (w.id == id) return w;
    }
    return null;
}

fn winJson(w: *Win) struct { id: u32, app_id: []const u8, title: []const u8, pid: i32, x: i32, y: i32, width: i32, height: i32, output: []const u8, focused: bool, maximized: bool, minimized: bool, fullscreen: bool } {
    return .{ .id = w.id, .app_id = w.app, .title = w.title, .pid = w.pid, .x = w.x, .y = w.y, .width = w.w, .height = w.ht, .output = w.output, .focused = w.activated, .maximized = w.maximized, .minimized = w.minimized, .fullscreen = w.fullscreen };
}

pub fn windows(a: std.mem.Allocator) mcp.Outcome {
    if (!enter()) return fail(NO_COMPOSITOR);
    defer leave();
    refresh();
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch return fail("out of memory");
    for (wins.items, 0..) |w, i| {
        if (i != 0) out.append(a, ',') catch {};
        const s = std.json.Stringify.valueAlloc(a, winJson(w), .{}) catch return fail("out of memory");
        out.appendSlice(a, s) catch {};
    }
    out.append(a, ']') catch {};
    return .{ .text = out.items };
}

fn int(args: std.json.Value, key: []const u8) ?i64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn text(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

const SNAPS = [_][]const u8{ "none", "left", "right", "top", "bottom", "top_left", "top_right", "bottom_left", "bottom_right", "maximize" };

pub fn windowSet(args: std.json.Value) mcp.Outcome {
    const id = int(args, "id") orelse return fail("missing id");
    const action = text(args, "action") orelse return fail("missing action");
    if (!enter()) return fail(NO_COMPOSITOR);
    defer leave();
    _ = c.wl_display_roundtrip(display);
    const w = byId(id) orelse return fail("no such window");
    const eq = std.mem.eql;
    if (eq(u8, action, "focus")) {
        c.zwlr_foreign_toplevel_handle_v1_activate(w.h, seat);
    } else if (eq(u8, action, "minimize")) {
        c.zwlr_foreign_toplevel_handle_v1_minimize(w.h);
    } else if (eq(u8, action, "unminimize")) {
        c.zwlr_foreign_toplevel_handle_v1_unset_minimize(w.h);
    } else if (eq(u8, action, "maximize")) {
        c.zwlr_foreign_toplevel_handle_v1_maximize(w.h);
    } else if (eq(u8, action, "unmaximize")) {
        c.zwlr_foreign_toplevel_handle_v1_unset_maximize(w.h);
    } else if (eq(u8, action, "fullscreen")) {
        c.zwlr_foreign_toplevel_handle_v1_set_fullscreen(w.h, null);
    } else if (eq(u8, action, "unfullscreen")) {
        c.zwlr_foreign_toplevel_handle_v1_unset_fullscreen(w.h);
    } else if (eq(u8, action, "move_resize")) {
        if (tiling == null) return fail("the compositor does not allow this");
        const x = int(args, "x") orelse return fail("missing x");
        const y = int(args, "y") orelse return fail("missing y");
        const wd = int(args, "width") orelse return fail("missing width");
        const ht = int(args, "height") orelse return fail("missing height");
        if (wd <= 0 or ht <= 0) return fail("bad size");
        c.zsingularity_tiling_manager_v1_set_geometry(tiling, w.h, @intCast(x), @intCast(y), @intCast(wd), @intCast(ht));
    } else if (eq(u8, action, "snap")) {
        if (tiling == null) return fail("the compositor does not allow this");
        const dir = text(args, "direction") orelse return fail("missing direction");
        for (SNAPS, 0..) |s, i| {
            if (eq(u8, s, dir)) {
                c.zsingularity_tiling_manager_v1_snap_view(tiling, w.h, @intCast(i));
                break;
            }
        } else return fail("unknown direction");
    } else if (eq(u8, action, "workspace")) {
        if (tiling == null) return fail("the compositor does not allow this");
        const n = int(args, "workspace") orelse return fail("missing workspace");
        if (n < 0) return fail("bad workspace");
        c.zsingularity_tiling_manager_v1_move_to_workspace(tiling, w.h, @intCast(n));
    } else return fail("unknown action");
    _ = c.wl_display_roundtrip(display);
    return .{ .text = "done" };
}

pub const WindowPlace = struct { pid: i64, x: i32, y: i32 };

pub fn placeOfWindow(id: i64) ?WindowPlace {
    if (!enter()) return null;
    defer leave();
    refresh();
    const w = byId(id) orelse return null;
    if (w.pid <= 0) return null;
    return .{ .pid = w.pid, .x = w.x, .y = w.y };
}

pub fn consentBlocked() bool {
    if (!enter()) return false;
    defer leave();
    return consentOpen();
}

pub fn windowClose(args: std.json.Value) mcp.Outcome {
    const id = int(args, "id") orelse return fail("missing id");
    if (!enter()) return fail(NO_COMPOSITOR);
    defer leave();
    _ = c.wl_display_roundtrip(display);
    const w = byId(id) orelse return fail("no such window");
    c.zwlr_foreign_toplevel_handle_v1_close(w.h);
    _ = c.wl_display_roundtrip(display);
    return .{ .text = "asked the window to close" };
}

fn layout() struct { x: i32, y: i32, w: u32, h: u32 } {
    var x0: i32 = std.math.maxInt(i32);
    var y0: i32 = std.math.maxInt(i32);
    var x1: i32 = std.math.minInt(i32);
    var y1: i32 = std.math.minInt(i32);
    for (outs.items) |o| {
        x0 = @min(x0, o.x);
        y0 = @min(y0, o.y);
        x1 = @max(x1, o.x + o.w);
        y1 = @max(y1, o.y + o.h);
    }
    if (x1 <= x0 or y1 <= y0) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    return .{ .x = x0, .y = y0, .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
}

fn now() u32 {
    return @truncate(@as(u64, @intCast(@divTrunc(c.g_get_monotonic_time(), 1000))));
}

fn moveTo(x: i64, y: i64) ?[]const u8 {
    const l = layout();
    if (l.w == 0) return "no output is known";
    const dx = x - l.x;
    const dy = y - l.y;
    if (dx < 0 or dy < 0 or dx >= l.w or dy >= l.h) return "the point is outside every screen";
    c.zwlr_virtual_pointer_v1_motion_absolute(vptr, now(), @intCast(dx), @intCast(dy), l.w, l.h);
    c.zwlr_virtual_pointer_v1_frame(vptr);
    return null;
}

fn press(button: u32, down: bool) void {
    c.zwlr_virtual_pointer_v1_button(vptr, now(), button, if (down) 1 else 0);
    c.zwlr_virtual_pointer_v1_frame(vptr);
}

fn settle() void {
    _ = c.wl_display_roundtrip(display);
    c.g_usleep(WAIT_STEP_US * 3);
}

const CONSENT = [_][]const u8{ "dev.sinty.portal.consent", "dev.sinty.screencast.chooser", "dev.sinty.polkit", "zenity" };
const CONSENT_OPEN = "a consent window is open: only the user can answer it";

fn consentOpen() bool {
    _ = c.wl_display_roundtrip(display);
    for (wins.items) |w| {
        for (CONSENT) |id| {
            if (std.mem.eql(u8, w.app, id)) return true;
        }
    }
    return false;
}

pub fn pointer(args: std.json.Value) mcp.Outcome {
    const action = text(args, "action") orelse return fail("missing action");
    if (!enter()) return fail(NO_COMPOSITOR);
    defer leave();
    if (consentOpen()) return fail(CONSENT_OPEN);
    if (vptrMgr == null) return fail("the compositor does not allow this");
    if (vptr == null) vptr = c.zwlr_virtual_pointer_manager_v1_create_virtual_pointer(vptrMgr, seat);
    refresh();
    var ox: i64 = 0;
    var oy: i64 = 0;
    if (int(args, "window")) |id| {
        const w = byId(id) orelse return fail("no such window");
        c.zwlr_foreign_toplevel_handle_v1_activate(w.h, seat);
        settle();
        refresh();
        ox = w.x;
        oy = w.y;
    }
    const x = (int(args, "x") orelse return fail("missing x")) + ox;
    const y = (int(args, "y") orelse return fail("missing y")) + oy;
    if (moveTo(x, y)) |e| return fail(e);
    settle();
    const eq = std.mem.eql;
    if (eq(u8, action, "move")) {
        return .{ .text = "done" };
    } else if (eq(u8, action, "click") or eq(u8, action, "double_click") or eq(u8, action, "right_click") or eq(u8, action, "middle_click")) {
        const b: u32 = if (eq(u8, action, "right_click")) BTN_RIGHT else if (eq(u8, action, "middle_click")) BTN_MIDDLE else BTN_LEFT;
        const times: u32 = if (eq(u8, action, "double_click")) 2 else 1;
        for (0..times) |_| {
            press(b, true);
            settle();
            press(b, false);
            settle();
        }
    } else if (eq(u8, action, "scroll")) {
        const n = int(args, "amount") orelse return fail("missing amount");
        const axis: u32 = if (eq(u8, text(args, "axis") orelse "vertical", "horizontal")) 1 else 0;
        c.zwlr_virtual_pointer_v1_axis_source(vptr, 0);
        c.zwlr_virtual_pointer_v1_axis_discrete(vptr, now(), axis, c.wl_fixed_from_int(@intCast(n * 15)), @intCast(n));
        c.zwlr_virtual_pointer_v1_frame(vptr);
    } else if (eq(u8, action, "drag")) {
        const tx = (int(args, "to_x") orelse return fail("missing to_x")) + ox;
        const ty = (int(args, "to_y") orelse return fail("missing to_y")) + oy;
        press(BTN_LEFT, true);
        settle();
        const steps: i64 = 8;
        var i: i64 = 1;
        while (i <= steps) : (i += 1) {
            if (moveTo(x + @divTrunc((tx - x) * i, steps), y + @divTrunc((ty - y) * i, steps))) |e| {
                press(BTN_LEFT, false);
                return fail(e);
            }
            settle();
        }
        press(BTN_LEFT, false);
    } else return fail("unknown action");
    settle();
    return .{ .text = "done" };
}

fn memfd(size: usize) c_int {
    const fd = c.memfd_create("sinty-agent", 0);
    if (fd < 0) return -1;
    if (c.ftruncate(fd, @intCast(size)) != 0) {
        _ = c.close(fd);
        return -1;
    }
    return fd;
}

const KEY_NAMES = [_][2][]const u8{
    .{ "enter", "Return" }, .{ "return", "Return" }, .{ "tab", "Tab" },        .{ "esc", "Escape" },     .{ "escape", "Escape" },
    .{ "space", "space" },  .{ "backspace", "BackSpace" }, .{ "delete", "Delete" }, .{ "home", "Home" },   .{ "end", "End" },
    .{ "up", "Up" },        .{ "down", "Down" },     .{ "left", "Left" },      .{ "right", "Right" },    .{ "pageup", "Prior" },
    .{ "pagedown", "Next" }, .{ "insert", "Insert" },
};

fn symOf(a: std.mem.Allocator, cp: u21) []const u8 {
    if (cp == '\n') return "Return";
    if (cp == '\t') return "Tab";
    return std.fmt.allocPrint(a, "U{X:0>4}", .{@as(u32, cp)}) catch "space";
}

fn keymapFor(a: std.mem.Allocator, syms: []const []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.print(a, "xkb_keymap {{\nxkb_keycodes \"s\" {{\nminimum = 8;\nmaximum = {d};\n", .{syms.len + 9});
    for (syms, 0..) |_, i| try o.print(a, "<K{d}> = {d};\n", .{ i, i + 9 });
    try o.appendSlice(a, "};\nxkb_types \"s\" { include \"complete\" };\nxkb_compatibility \"s\" { include \"complete\" };\nxkb_symbols \"s\" {\n");
    for (syms, 0..) |s, i| try o.print(a, "key <K{d}> {{ [ {s} ] }};\n", .{ i, s });
    try o.appendSlice(a, "};\n};\n");
    try o.append(a, 0);
    return o.items;
}

fn sendKeymap(kb: ?*c.zwp_virtual_keyboard_v1, map: []const u8) bool {
    const fd = memfd(map.len);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    const p = c.mmap(null, map.len, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
    if (p == c.MAP_FAILED) return false;
    @memcpy(@as([*]u8, @ptrCast(p))[0..map.len], map);
    _ = c.munmap(p, map.len);
    c.zwp_virtual_keyboard_v1_keymap(kb, 1, fd, @intCast(map.len));
    return true;
}

fn tap(kb: ?*c.zwp_virtual_keyboard_v1, key: u32) void {
    c.zwp_virtual_keyboard_v1_key(kb, now(), key, 1);
    c.zwp_virtual_keyboard_v1_key(kb, now(), key, 0);
    _ = c.wl_display_flush(display);
    c.g_usleep(WAIT_STEP_US);
}

pub fn keyboard(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    const typed = text(args, "text");
    const keys = text(args, "keys");
    if ((typed == null) == (keys == null)) return fail("give either text or keys");
    if (!enter()) return fail(NO_COMPOSITOR);
    defer leave();
    if (consentOpen()) return fail(CONSENT_OPEN);
    if (vkbdMgr == null) return fail("the compositor does not allow this");
    if (int(args, "window")) |id| {
        _ = c.wl_display_roundtrip(display);
        const w = byId(id) orelse return fail("no such window");
        c.zwlr_foreign_toplevel_handle_v1_activate(w.h, seat);
        settle();
    }
    var syms: std.ArrayList([]const u8) = .empty;
    var seq: std.ArrayList(u32) = .empty;
    var mods: u32 = 0;
    if (typed) |t| {
        const view = std.unicode.Utf8View.init(t) catch return fail("text is not valid UTF-8");
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            const s = symOf(a, cp);
            var at: ?usize = null;
            for (syms.items, 0..) |x, i| {
                if (std.mem.eql(u8, x, s)) at = i;
            }
            if (at == null) {
                syms.append(a, s) catch return fail("out of memory");
                at = syms.items.len - 1;
            }
            seq.append(a, @intCast(at.? + 1)) catch return fail("out of memory");
        }
    } else {
        var parts = std.mem.splitScalar(u8, keys.?, '+');
        while (parts.next()) |raw| {
            const low = std.ascii.allocLowerString(a, raw) catch return fail("out of memory");
            const eq = std.mem.eql;
            if (eq(u8, low, "ctrl") or eq(u8, low, "control")) {
                mods |= MOD_CTRL;
            } else if (eq(u8, low, "shift")) {
                mods |= MOD_SHIFT;
            } else if (eq(u8, low, "alt")) {
                mods |= MOD_ALT;
            } else if (eq(u8, low, "super") or eq(u8, low, "meta")) {
                mods |= MOD_SUPER;
            } else {
                var sym: ?[]const u8 = null;
                for (KEY_NAMES) |n| {
                    if (eq(u8, n[0], low)) sym = n[1];
                }
                if (sym == null and low.len >= 2 and low[0] == 'f' and std.ascii.isDigit(low[1])) {
                    sym = std.fmt.allocPrint(a, "F{s}", .{low[1..]}) catch null;
                }
                if (sym == null) {
                    const v = std.unicode.Utf8View.init(low) catch return fail("bad key");
                    var i = v.iterator();
                    const cp = i.nextCodepoint() orelse return fail("bad key");
                    if (i.nextCodepoint() != null) return fail("unknown key name");
                    sym = symOf(a, cp);
                }
                syms.append(a, sym.?) catch return fail("out of memory");
                seq.append(a, @intCast(syms.items.len)) catch return fail("out of memory");
            }
        }
        if (seq.items.len == 0) return fail("no key to press");
    }
    if (seq.items.len == 0) return .{ .text = "done" };
    const map = keymapFor(a, syms.items) catch return fail("out of memory");
    const kb = c.zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(vkbdMgr, seat);
    defer c.zwp_virtual_keyboard_v1_destroy(kb);
    if (!sendKeymap(kb, map)) return fail("cannot prepare the keyboard");
    settle();
    if (mods != 0) c.zwp_virtual_keyboard_v1_modifiers(kb, mods, 0, 0, 0);
    for (seq.items) |k| tap(kb, k);
    if (mods != 0) c.zwp_virtual_keyboard_v1_modifiers(kb, 0, 0, 0, 0);
    settle();
    return .{ .text = "done" };
}

const Shot = struct { data: []u8, f: Frame };

fn waitFrame(f: *Frame, want: enum { have, end }) void {
    var i: usize = 0;
    while (i < WAIT_STEPS) : (i += 1) {
        _ = c.wl_display_roundtrip(display);
        if (f.failed) return;
        if (want == .have and f.have) return;
        if (want == .end and f.ready) return;
        c.g_usleep(WAIT_STEP_US);
    }
}

fn allocFrame(f: *Frame, fd: *c_int, map: *[*]u8) ?*c.wl_buffer {
    const size = @as(usize, f.stride) * f.h;
    fd.* = memfd(size);
    if (fd.* < 0) return null;
    const p = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd.*, 0);
    if (p == c.MAP_FAILED) return null;
    map.* = @ptrCast(p);
    const pool = c.wl_shm_create_pool(shm, fd.*, @intCast(size));
    defer c.wl_shm_pool_destroy(pool);
    return c.wl_shm_pool_create_buffer(pool, 0, @intCast(f.w), @intCast(f.h), @intCast(f.stride), f.format);
}

fn chunk(a: std.mem.Allocator, o: *std.ArrayList(u8), tag: []const u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try o.appendSlice(a, &len);
    try o.appendSlice(a, tag);
    try o.appendSlice(a, data);
    var crc = c.crc32(0, tag.ptr, @intCast(tag.len));
    crc = c.crc32(crc, data.ptr, @intCast(data.len));
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, @truncate(crc), .big);
    try o.appendSlice(a, &sum);
}

fn toPng(a: std.mem.Allocator, map: [*]const u8, f: Frame, scale: *f64) ?[]u8 {
    const swap = redFirst(f.format);
    const big = @max(f.w, f.h);
    const step: usize = if (big > IMAGE_MAX) (big + IMAGE_MAX - 1) / IMAGE_MAX else 1;
    scale.* = 1.0 / @as(f64, @floatFromInt(step));
    const nw: usize = f.w / step;
    const nh: usize = f.h / step;
    if (nw == 0 or nh == 0) return null;
    const raw = a.alloc(u8, (nw * 3 + 1) * nh) catch return null;
    var at: usize = 0;
    for (0..nh) |y| {
        raw[at] = 0;
        at += 1;
        for (0..nw) |x| {
            var sum = [3]u32{ 0, 0, 0 };
            for (0..step) |dy| {
                const sy = y * step + dy;
                const row = map + (if (f.invert) f.h - 1 - sy else sy) * f.stride;
                for (0..step) |dx| {
                    const px = row + (x * step + dx) * 4;
                    sum[0] += if (swap) px[0] else px[2];
                    sum[1] += px[1];
                    sum[2] += if (swap) px[2] else px[0];
                }
            }
            const n: u32 = @intCast(step * step);
            for (sum) |v| {
                raw[at] = @intCast(v / n);
                at += 1;
            }
        }
    }
    var zlen = c.compressBound(@intCast(raw.len));
    const z = a.alloc(u8, zlen) catch return null;
    if (c.compress2(z.ptr, &zlen, raw.ptr, @intCast(raw.len), 6) != c.Z_OK) return null;
    var o: std.ArrayList(u8) = .empty;
    o.appendSlice(a, "\x89PNG\r\n\x1a\n") catch return null;
    var hdr: [13]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(nw), .big);
    std.mem.writeInt(u32, hdr[4..8], @intCast(nh), .big);
    hdr[8] = 8;
    hdr[9] = 2;
    hdr[10] = 0;
    hdr[11] = 0;
    hdr[12] = 0;
    chunk(a, &o, "IHDR", &hdr) catch return null;
    chunk(a, &o, "IDAT", z[0..zlen]) catch return null;
    chunk(a, &o, "IEND", "") catch return null;
    const enc = std.base64.standard.Encoder;
    const b64 = a.alloc(u8, enc.calcSize(o.items.len)) catch return null;
    _ = enc.encode(b64, o.items);
    return b64;
}

pub fn capture(a: std.mem.Allocator, args: std.json.Value) mcp.Outcome {
    if (!enter()) return fail(NO_COMPOSITOR);
    defer leave();
    if (shm == null) return fail("the compositor does not allow this");
    refresh();
    var f: Frame = .{};
    var ox: i32 = 0;
    var oy: i32 = 0;
    var lw: i32 = 0;
    var previewF: ?*c.zsingularity_preview_frame_v1 = null;
    var copyF: ?*c.zwlr_screencopy_frame_v1 = null;
    if (int(args, "window")) |id| {
        if (preview == null) return fail("the compositor does not allow this");
        const w = byId(id) orelse return fail("no such window");
        ox = w.x;
        oy = w.y;
        lw = w.w;
        previewF = c.zsingularity_preview_manager_v1_capture_toplevel(preview, w.h, 0);
        _ = c.wl_proxy_add_dispatcher(@ptrCast(previewF), onFramePreview, &f, null);
    } else {
        if (copyMgr == null or outs.items.len == 0) return fail("the compositor does not allow this");
        var o = outs.items[0];
        if (text(args, "output")) |n| {
            for (outs.items) |x| {
                if (std.mem.eql(u8, x.name, n)) o = x;
            }
            if (!std.mem.eql(u8, o.name, n)) return fail("no such output");
        }
        ox = o.x;
        oy = o.y;
        lw = o.w;
        copyF = c.zwlr_screencopy_manager_v1_capture_output(copyMgr, 0, o.o);
        _ = c.wl_proxy_add_dispatcher(@ptrCast(copyF), onFrameCopy, &f, null);
    }
    defer if (previewF != null) c.zsingularity_preview_frame_v1_destroy(previewF);
    defer if (copyF != null) c.zwlr_screencopy_frame_v1_destroy(copyF);
    waitFrame(&f, .have);
    if (!f.have or f.failed) return fail("the capture failed");
    if (!usableFormat(f.format)) return fail("unsupported pixel format");
    var fd: c_int = -1;
    var map: [*]u8 = undefined;
    const buffer = allocFrame(&f, &fd, &map) orelse return fail("cannot allocate the capture");
    const size = @as(usize, f.stride) * f.h;
    defer {
        c.wl_buffer_destroy(buffer);
        _ = c.munmap(map, size);
        _ = c.close(fd);
    }
    if (previewF != null) c.zsingularity_preview_frame_v1_copy(previewF, buffer) else c.zwlr_screencopy_frame_v1_copy(copyF, buffer);
    waitFrame(&f, .end);
    if (!f.ready) return fail("the capture failed");
    var imgScale: f64 = 1;
    const png = toPng(a, map, f, &imgScale) orelse return fail("cannot encode the capture");
    const px = if (lw > 0) @as(f64, @floatFromInt(lw)) / (@as(f64, @floatFromInt(f.w)) * imgScale) else 1 / imgScale;
    const meta = std.fmt.allocPrint(a, "{{\"origin_x\":{d},\"origin_y\":{d},\"points_per_image_pixel\":{d:.4},\"note\":\"screen point = origin + image pixel * points_per_image_pixel\"}}", .{ ox, oy, px }) catch return fail("out of memory");
    return .{ .text = meta, .image = png };
}
