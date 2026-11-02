const std = @import("std");

const PROTOCOLS = [_][]const u8{
    "wlr-foreign-toplevel-management-unstable-v1",
    "singularity-tiling-unstable-v1",
    "singularity-preview-unstable-v1",
    "singularity-process-unstable-v1",
    "virtual-keyboard-unstable-v1",
    "wlr-virtual-pointer-unstable-v1",
    "wlr-screencopy-unstable-v1",
    "xdg-output-unstable-v1",
};

fn protocols(b: *std.Build, mod: *std.Build.Module) void {
    mod.linkSystemLibrary("wayland-client", .{});
    mod.linkSystemLibrary("z", .{});
    for (PROTOCOLS) |p| {
        const xml = b.path(b.fmt("protocols/{s}.xml", .{p}));
        const h = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        h.addFileArg(xml);
        const header = h.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{p}));
        mod.addIncludePath(header.dirname());
        const src = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        src.addFileArg(xml);
        mod.addCSourceFile(.{ .file = src.addOutputFileArg(b.fmt("{s}.c", .{p})), .flags = &.{} });
    }
}

fn exe(b: *std.Build, name: []const u8, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path("cmd/sinty-agentd"));
    mod.linkSystemLibrary("gio-2.0", .{});
    mod.linkSystemLibrary("gio-unix-2.0", .{});
    if (std.mem.eql(u8, name, "sinty-agentd")) {
        protocols(b, mod);
        const o = b.addOptions();
        o.addOption([]const u8, "test_trust", b.option([]const u8, "test-trust", "extra trusted programs, for tests only") orelse "");
        mod.addOptions("build_options", o);
    }
    b.installArtifact(b.addExecutable(.{ .name = name, .root_module = mod }));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    exe(b, "sinty-agentd", "cmd/sinty-agentd/main.zig", target, optimize);
    exe(b, "sinty-agent", "cmd/sinty-agent/main.zig", target, optimize);

    const sinty = b.createModule(.{ .root_source_file = b.path("cmd/sinty/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    sinty.addIncludePath(b.path("cmd/sinty"));
    sinty.linkSystemLibrary("gio-2.0", .{});
    sinty.linkSystemLibrary("libsoup-3.0", .{});
    sinty.linkSystemLibrary("libsecret-1", .{});
    b.installArtifact(b.addExecutable(.{ .name = "sinty", .root_module = sinty }));

    const bridge = b.createModule(.{
        .root_source_file = b.path("cmd/sinty-agent-bridge/main.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = target.result.cpu.arch, .os_tag = .linux, .abi = .musl }),
        .optimize = .ReleaseSmall,
        .link_libc = true,
    });
    b.installArtifact(b.addExecutable(.{ .name = "sinty-agent-bridge", .root_module = bridge, .linkage = .static }));
    b.installFile("data/dev.sinty.Agent.service", "share/dbus-1/services/dev.sinty.Agent.service");

    const test_step = b.step("test", "run tests");
    for ([_][]const u8{ "cmd/sinty-agentd/policy.zig", "cmd/sinty-agentd/mcp.zig", "cmd/sinty-agentd/catalog.zig" }) |root| {
        const mod = b.createModule(.{ .root_source_file = b.path(root), .target = target, .optimize = optimize });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }
}
