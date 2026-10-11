const std = @import("std");

// Compiler for the template language
pub const ast = @import("ast.zig");
pub const Parser = @import("parser.zig").Parser;
pub const Generator = @import("codegen.zig").Generator;

// Runtime types and functions for generated code
pub const Component = @import("runtime.zig").Component;
pub const writeEscaped = @import("runtime.zig").writeEscaped;
pub const writeRaw = @import("runtime.zig").writeRaw;
pub const writeAttr = @import("runtime.zig").writeAttr;
pub const writeBoolAttr = @import("runtime.zig").writeBoolAttr;
pub const writeUrlAttr = @import("runtime.zig").writeUrlAttr;
pub const writeUrlPart = @import("runtime.zig").writeUrlPart;
pub const isSafeUrl = @import("runtime.zig").isSafeUrl;
pub const Url = @import("runtime.zig").Url;
pub const invalid_url = @import("runtime.zig").invalid_url;
pub const renderComponent = @import("runtime.zig").renderComponent;

test {
    std.testing.refAllDecls(@This());
}
