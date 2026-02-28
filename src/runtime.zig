const std = @import("std");

/// A writer that escapes HTML special characters as it writes.
pub const EscapingWriter = struct {
    underlying: *std.Io.Writer,
    interface: std.Io.Writer = .{
        .vtable = &vtable,
        .buffer = &.{}, // unbuffered - writes go directly to underlying
    },

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
    };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *EscapingWriter = @fieldParentPtr("interface", w);
        var total: usize = 0;

        // Write all slices except the last
        for (data[0 .. data.len - 1]) |bytes| {
            try writeEscapedString(self.underlying, bytes);
            total += bytes.len;
        }

        // Handle the last slice with splat (repeat count)
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try writeEscapedString(self.underlying, pattern);
            total += pattern.len;
        }

        return total;
    }
};

/// A type-erased renderable component.
pub const Component = struct {
    ptr: *const anyopaque,
    renderFn: *const fn (*const anyopaque, *std.Io.Writer) std.Io.Writer.Error!void,

    pub fn render(self: Component, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.renderFn(self.ptr, writer);
    }
};

/// Renders a component call target. Accepts either a template struct type
/// (dispatches to Type.render(args, writer)) or a zt.Component value
/// (dispatches to value.render(writer), ignoring args).
pub inline fn renderComponent(target: anytype, args: anytype, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (@TypeOf(target) == type) {
        return target.render(args, writer);
    } else if (@TypeOf(target) == Component) {
        return target.render(writer);
    } else {
        @compileError("expected a template type or zt.Component");
    }
}

/// Writes a value to the writer, escaping HTML special characters.
/// If the value has a `formatHtml` method, it's called directly (assumed safe).
pub fn writeEscaped(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);

    // Check for formatHtml method - assumed to be pre-escaped/safe HTML
    if (comptime std.meta.hasMethod(T, "formatHtml")) {
        return value.formatHtml(writer);
    }

    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                // []const u8 or []u8 - write as escaped string
                try writeEscapedString(writer, value);
                return;
            }
            if (ptr.size == .one) {
                // Check for *const [N]u8 or *const [N:0]u8 (string literals)
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array and child_info.array.child == u8) {
                    try writeEscapedString(writer, value);
                    return;
                }
            }
            // Other pointer - try to format
            try writeFormatted(writer, value);
        },
        .array => |arr| {
            // [N]u8 array
            if (arr.child == u8) {
                try writeEscapedString(writer, &value);
                return;
            }
            try writeFormatted(writer, value);
        },
        .int, .float => {
            try writeFormatted(writer, value);
        },
        .optional => {
            if (value) |v| {
                try writeEscaped(writer, v);
            }
        },
        .@"enum" => {
            try writeEscapedString(writer, @tagName(value));
        },
        .bool => {
            try writer.writeAll(if (value) "true" else "false");
        },
        .void => {
            // Do nothing for void return values
        },
        else => {
            try writeFormatted(writer, value);
        },
    }
}

fn writeEscapedString(writer: *std.Io.Writer, str: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0;
    for (str, 0..) |c, i| {
        const escape: ?[]const u8 = switch (c) {
            '<' => "&lt;",
            '>' => "&gt;",
            '&' => "&amp;",
            '"' => "&quot;",
            '\'' => "&#x27;",
            else => null,
        };
        if (escape) |esc| {
            if (i > start) {
                try writer.writeAll(str[start..i]);
            }
            try writer.writeAll(esc);
            start = i + 1;
        }
    }
    if (start < str.len) {
        try writer.writeAll(str[start..]);
    }
}

fn writeFormatted(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    var escaping: EscapingWriter = .{ .underlying = writer };
    try escaping.interface.print("{any}", .{value});
}

/// Writes an attribute, skipping it entirely if the value is null.
pub fn writeAttr(writer: *std.Io.Writer, name: []const u8, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    const v = if (@typeInfo(T) == .optional) value orelse return else value;

    try writer.writeAll(" ");
    try writer.writeAll(name);
    try writer.writeAll("=\"");
    try writeEscaped(writer, v);
    try writer.writeAll("\"");
}

/// Writes a value without escaping (for pre-escaped HTML).
pub fn writeRaw(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try writer.writeAll(value);
                return;
            }
        },
        .void => {
            // Do nothing for void return values
        },
        else => {
            try writer.print("{}", .{value});
        },
    }
}

// =========================================================================
// Tests
// =========================================================================

test "escape html entities" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeEscaped(&output.writer, "<script>alert('xss')</script>");
    try std.testing.expectEqualStrings(
        "&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;",
        output.writer.buffer[0..output.writer.end],
    );
}

test "escape preserves normal text" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeEscaped(&output.writer, "Hello, World!");
    try std.testing.expectEqualStrings(
        "Hello, World!",
        output.writer.buffer[0..output.writer.end],
    );
}

test "escape numbers" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeEscaped(&output.writer, @as(i32, 42));
    try std.testing.expectEqualStrings("42", output.writer.buffer[0..output.writer.end]);
}

test "escape optional" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const maybe: ?[]const u8 = "hello";
    try writeEscaped(&output.writer, maybe);
    try std.testing.expectEqualStrings("hello", output.writer.buffer[0..output.writer.end]);
}

test "escape null optional" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const maybe: ?[]const u8 = null;
    try writeEscaped(&output.writer, maybe);
    try std.testing.expectEqualStrings("", output.writer.buffer[0..output.writer.end]);
}

test "writeAttr with value" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeAttr(&output.writer, "class", "active");
    try std.testing.expectEqualStrings(" class=\"active\"", output.writer.buffer[0..output.writer.end]);
}

test "writeAttr with optional value" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const maybe: ?[]const u8 = "active";
    try writeAttr(&output.writer, "class", maybe);
    try std.testing.expectEqualStrings(" class=\"active\"", output.writer.buffer[0..output.writer.end]);
}

test "writeAttr with null skips attribute" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const maybe: ?[]const u8 = null;
    try writeAttr(&output.writer, "class", maybe);
    try std.testing.expectEqualStrings("", output.writer.buffer[0..output.writer.end]);
}

test "formatHtml is written raw" {
    const Html = struct {
        content: []const u8,

        pub fn formatHtml(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(self.content);
        }
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const html = Html{ .content = "<b>bold</b>" };
    try writeEscaped(&output.writer, html);
    try std.testing.expectEqualStrings("<b>bold</b>", output.writer.buffer[0..output.writer.end]);
}

test "formatHtml works with pointer" {
    const Html = struct {
        content: []const u8,

        pub fn formatHtml(self: *const @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(self.content);
        }
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const html = Html{ .content = "<i>italic</i>" };
    try writeEscaped(&output.writer, &html);
    try std.testing.expectEqualStrings("<i>italic</i>", output.writer.buffer[0..output.writer.end]);
}

test "escape large array" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    // Array that formats to >256 bytes (would have failed with old fixed buffer)
    const large = comptime blk: {
        var arr: [1000]u32 = undefined;
        for (0..1000) |i| arr[i] = @intCast(i);
        break :blk arr;
    };
    try writeEscaped(&output.writer, large);

    // Verify output is non-empty and contains expected content
    const result = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(result.len > 256);
    try std.testing.expect(std.mem.startsWith(u8, result, "{ 0, 1, 2, 3,"));
    try std.testing.expect(std.mem.endsWith(u8, result, "997, 998, 999 }"));
}
