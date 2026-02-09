pub const ast = @import("ast.zig");
pub const Parser = @import("parser.zig").Parser;
pub const Generator = @import("codegen.zig").Generator;

// Runtime functions for generated code
pub const writeEscaped = @import("runtime.zig").writeEscaped;
pub const writeRaw = @import("runtime.zig").writeRaw;
pub const writeAttr = @import("runtime.zig").writeAttr;


test {
    _ = @import("parser.zig");
    _ = @import("codegen.zig");
    _ = @import("runtime.zig");
}
