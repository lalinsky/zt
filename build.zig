const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Expose zt module for dependents
    const lib = b.addModule("zt", .{
        .root_source_file = b.path("src/zt.zig"),
        .target = target,
        .optimize = optimize,
    });

    // CLI tool
    const exe = b.addExecutable(.{
        .name = "zt-compile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zt-compile");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_filter = b.option([]const u8, "test-filter", "Filter for test names");
    const tests = b.addTest(.{
        .root_module = lib,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        .filters = if (test_filter) |f| &.{f} else &.{},
    });

    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

// =============================================================================
// Build helpers for dependents
// =============================================================================

/// Compile .zt template files to .zig files.
/// Generated files are placed next to the source files (hello.zt → hello.zig).
/// Returns a step that must complete before compilation.
///
/// Usage:
/// ```zig
/// const zt_dep = b.dependency("zt", .{});
/// const templates = zt.addTemplates(b, zt_dep, &.{
///     b.path("src/templates/pages.zt"),
/// });
/// exe.step.dependOn(templates);
/// ```
pub fn addTemplates(
    b: *std.Build,
    zt_dep: *std.Build.Dependency,
    template_paths: []const std.Build.LazyPath,
) *std.Build.Step {
    const zt_exe = zt_dep.artifact("zt-compile");
    const usf = b.addUpdateSourceFiles();

    for (template_paths) |template_path| {
        const run = b.addRunArtifact(zt_exe);
        run.addFileArg(template_path);
        run.addFileInput(template_path); // Explicit input dependency
        const basename = getBasename(template_path);
        const output = run.addOutputFileArg(replaceExtension(b, basename, ".zig"));
        const output_sub_path = replaceExtension(b, getSubPath(template_path), ".zig");
        usf.addCopyFileToSource(output, output_sub_path);
    }

    return &usf.step;
}

fn getSubPath(path: std.Build.LazyPath) []const u8 {
    return switch (path) {
        .src_path => |p| p.sub_path,
        else => @panic("unsupported path type"),
    };
}

fn getBasename(path: std.Build.LazyPath) []const u8 {
    return std.fs.path.basename(getSubPath(path));
}

fn replaceExtension(b: *std.Build, path: []const u8, new_ext: []const u8) []const u8 {
    const stem = path[0 .. path.len - std.fs.path.extension(path).len];
    return std.mem.concat(b.allocator, u8, &.{ stem, new_ext }) catch @panic("OOM");
}
