const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Expose zt module for dependents
    _ = b.addModule("zt", .{
        .root_source_file = b.path("src/zt.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/zt.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

// =============================================================================
// Build helpers for dependents
// =============================================================================

/// Compile .zt template files to .zig files.
/// Generated files are placed next to the source files (hello.zt → hello.zig).
/// Returns a step that must complete before compilation.
pub fn addTemplates(
    b: *std.Build,
    template_paths: []const []const u8,
) *std.Build.Step {
    const gen_step = b.allocator.create(TemplateGenStep) catch @panic("OOM");
    gen_step.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = "zt-compile",
            .owner = b,
            .makeFn = TemplateGenStep.make,
        }),
        .template_paths = b.allocator.dupe([]const u8, template_paths) catch @panic("OOM"),
    };
    return &gen_step.step;
}

/// Custom build step that generates Zig code from .zt template files
pub const TemplateGenStep = struct {
    step: std.Build.Step,
    template_paths: []const []const u8,

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *TemplateGenStep = @fieldParentPtr("step", step);
        const b = step.owner;

        const zt = @import("src/zt.zig");

        for (self.template_paths) |template_path| {
            // Read source
            const source = std.fs.cwd().readFileAlloc(b.allocator, template_path, 10 * 1024 * 1024) catch |err| {
                return step.fail("Failed to read template '{s}': {}", .{ template_path, err });
            };
            defer b.allocator.free(source);

            // Parse
            var arena = std.heap.ArenaAllocator.init(b.allocator);
            defer arena.deinit();

            var parser = zt.Parser.init(arena.allocator(), source);
            const file = parser.parseFile() catch |err| {
                return step.fail("Failed to parse template '{s}': {}", .{ template_path, err });
            };

            // Generate
            var output: std.Io.Writer.Allocating = .init(b.allocator);
            defer output.deinit();

            output.writer.writeAll("// Auto-generated from ") catch |err| {
                return step.fail("Generation error: {}", .{err});
            };
            output.writer.writeAll(std.fs.path.basename(template_path)) catch |err| {
                return step.fail("Generation error: {}", .{err});
            };
            output.writer.writeAll(" - do not edit\n") catch |err| {
                return step.fail("Generation error: {}", .{err});
            };
            output.writer.writeAll("const std = @import(\"std\");\n") catch |err| {
                return step.fail("Generation error: {}", .{err});
            };
            output.writer.writeAll("const zt = @import(\"zt\");\n\n") catch |err| {
                return step.fail("Generation error: {}", .{err});
            };

            var gen = zt.Generator.init(&output.writer);
            gen.generateFile(file) catch |err| {
                return step.fail("Failed to generate code for '{s}': {}", .{ template_path, err });
            };

            // Write output next to source: foo.zt → foo.zig
            const output_path = replaceExtension(b.allocator, template_path, ".zig") catch @panic("OOM");
            const generated_content = output.writer.buffer[0..output.writer.end];

            std.fs.cwd().writeFile(.{
                .sub_path = output_path,
                .data = generated_content,
            }) catch |err| {
                return step.fail("Failed to write '{s}': {}", .{ output_path, err });
            };
        }
    }

    fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, new_ext: []const u8) ![]const u8 {
        const stem = std.fs.path.stem(path);
        const dir = std.fs.path.dirname(path) orelse "";
        if (dir.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ dir, stem, new_ext });
        } else {
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, new_ext });
        }
    }
};
