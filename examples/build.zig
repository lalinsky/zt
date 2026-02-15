const std = @import("std");
const zt = @import("zt");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get zt dependency
    const zt_dep = b.dependency("zt", .{
        .target = target,
        .optimize = optimize,
    });

    // Compile templates (generates .zig next to .zt files)
    const templates_step = zt.addTemplates(b, zt_dep, &.{
        b.path("src/templates/hello.zt"),
    });

    // Create root module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("zt", zt_dep.module("zt"));

    // Build executable
    const exe = b.addExecutable(.{
        .name = "zt-example",
        .root_module = root_module,
    });

    // Ensure templates are compiled before building
    exe.step.dependOn(templates_step);

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
