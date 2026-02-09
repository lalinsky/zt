const std = @import("std");
const zt = @import("zt.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: zt-compile <file.zt> [output.zig]\n", .{});
        std.process.exit(1);
    }

    const input_path = args[1];
    const output_path = if (args.len > 2) args[2] else null;

    // Read source
    const source = std.fs.cwd().readFileAlloc(allocator, input_path, 10 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading '{s}': {}\n", .{ input_path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    // Parse
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = zt.Parser.init(arena.allocator(), source);
    const file = parser.parseFile() catch |err| {
        if (parser.err) |e| {
            std.debug.print("{s}:{d}:{d}: {s}\n", .{ input_path, e.line, e.col, e.msg });
        } else {
            std.debug.print("{s}: parse error: {}\n", .{ input_path, err });
        }
        std.process.exit(1);
    };

    // Generate
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    output.writer.writeAll("// Auto-generated from ") catch unreachable;
    output.writer.writeAll(std.fs.path.basename(input_path)) catch unreachable;
    output.writer.writeAll(" - do not edit\n") catch unreachable;
    output.writer.writeAll("const std = @import(\"std\");\n") catch unreachable;
    output.writer.writeAll("const zt = @import(\"zt\");\n\n") catch unreachable;

    var gen = zt.Generator.init(&output.writer);
    gen.generateFile(file) catch |err| {
        std.debug.print("Error generating code: {}\n", .{err});
        std.process.exit(1);
    };

    const generated = output.writer.buffer[0..output.writer.end];

    // Write output
    if (output_path) |path| {
        std.fs.cwd().writeFile(.{ .sub_path = path, .data = generated }) catch |err| {
            std.debug.print("Error writing '{s}': {}\n", .{ path, err });
            std.process.exit(1);
        };
        std.debug.print("Wrote {s}\n", .{path});
    } else {
        std.fs.File.stdout().writeAll(generated) catch {};
    }
}
