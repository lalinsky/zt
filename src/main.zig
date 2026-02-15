const std = @import("std");
const zt = @import("zt.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: zt-compile <file.zt>...\n", .{});
        std.process.exit(1);
    }

    for (args[1..]) |input_path| {
        try compileTemplate(allocator, input_path);
    }
}

fn compileTemplate(allocator: std.mem.Allocator, input_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Read source
    const source = std.fs.cwd().readFileAlloc(alloc, input_path, 10 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading '{s}': {}\n", .{ input_path, err });
        return error.ReadFailed;
    };

    // Parse
    var parser = zt.Parser.init(alloc, source);
    const file = parser.parseFile() catch |err| {
        if (parser.err) |e| {
            std.debug.print("{s}:{d}:{d}: {s}\n", .{ input_path, e.line, e.col, e.msg });
        } else {
            std.debug.print("{s}: parse error: {}\n", .{ input_path, err });
        }
        return error.ParseFailed;
    };

    // Generate
    var output: std.Io.Writer.Allocating = .init(alloc);
    try output.writer.writeAll("// Auto-generated from ");
    try output.writer.writeAll(std.fs.path.basename(input_path));
    try output.writer.writeAll(" - do not edit\n");
    try output.writer.writeAll("const std = @import(\"std\");\n");
    try output.writer.writeAll("const zt = @import(\"zt\");\n\n");

    var gen = zt.Generator.init(&output.writer);
    gen.source_file = std.fs.path.basename(input_path);
    gen.generateFile(file) catch |err| {
        std.debug.print("Error generating code: {}\n", .{err});
        return error.GenerateFailed;
    };

    const generated = output.writer.buffer[0..output.writer.end];

    // Write output: foo.zt -> foo.zig
    const output_path = try replaceExtension(alloc, input_path, ".zig");
    std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = generated }) catch |err| {
        std.debug.print("Error writing '{s}': {}\n", .{ output_path, err });
        return error.WriteFailed;
    };
    std.debug.print("Wrote {s}\n", .{output_path});
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
