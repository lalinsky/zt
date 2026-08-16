const std = @import("std");
const zt = @import("zt.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 3 or args.len % 2 != 1) {
        std.debug.print("Usage: zt-compile <input.zt> <output.zig> ...\n", .{});
        std.process.exit(1);
    }

    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        try compileTemplate(init.gpa, init.io, args[i], args[i + 1]);
    }
}

fn compileTemplate(allocator: std.mem.Allocator, io: std.Io, input_path: []const u8, output_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Read source
    const source = std.Io.Dir.cwd().readFileAlloc(io, input_path, alloc, .limited(10 * 1024 * 1024)) catch |err| {
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

    const raw = output.writer.buffer[0..output.writer.end];

    // Run the result through zig's own formatter so the file we write is
    // `zig fmt` clean. On a parse error we write the unformatted source
    // anyway: the compiler's diagnostics on the real file beat anything we
    // could say here, and the file has to exist for it to point at.
    const generated = formatZig(alloc, raw) catch |err| blk: {
        std.debug.print("{s}: warning: generated code did not format ({}), writing as-is\n", .{ output_path, err });
        break :blk raw;
    };

    // Write output
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = generated }) catch |err| {
        std.debug.print("Error writing '{s}': {}\n", .{ output_path, err });
        return error.WriteFailed;
    };
}

fn formatZig(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    const source_z = try allocator.dupeZ(u8, source);
    var tree = try std.zig.Ast.parse(allocator, source_z, .zig);
    if (tree.errors.len > 0) return error.InvalidZig;
    return tree.renderAlloc(allocator);
}
