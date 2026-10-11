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

fn checkAttrValueType(comptime T: type) void {
    if (T == bool) {
        // `checked="false"` would still mean checked in HTML.
        @compileError("bool attribute value: use `attr?={expr}` for an HTML boolean attribute, " ++
            "or pass a string for attributes that take \"true\"/\"false\"");
    }
}

/// Writes an attribute, skipping it entirely if the value is null.
pub fn writeAttr(writer: *std.Io.Writer, name: []const u8, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    const v = if (@typeInfo(T) == .optional) value orelse return else value;
    comptime checkAttrValueType(@TypeOf(v));

    try writer.writeAll(" ");
    try writer.writeAll(name);
    try writer.writeAll("=\"");
    try writeEscaped(writer, v);
    try writer.writeAll("\"");
}

/// Written in place of a URL value whose scheme is not allowed. Anything
/// written after it ends up in the fragment, so it stays harmless.
pub const invalid_url = "about:invalid#ZtFailedSanitizationURL";

const allowed_schemes = [_][]const u8{ "http", "https", "mailto", "tel", "ftp", "ftps" };
const max_scheme_len = 6;

/// A trusted URL that skips the scheme check in URL attributes.
/// It is still HTML-escaped, wherever it is written.
pub const Url = struct {
    value: []const u8,

    pub fn formatHtml(self: Url, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writeEscapedString(writer, self.value);
    }
};

/// Checks the scheme of a URL made of `parts` written one after another.
/// The scheme ends at the first `:`. A `/`, `?` or `#` before it, or no `:`
/// at all, makes the URL relative.
fn isSchemeAllowed(parts: []const []const u8) bool {
    var scheme: [max_scheme_len]u8 = undefined;
    var len: usize = 0;
    for (parts) |part| {
        for (part) |c| {
            switch (c) {
                ':' => {
                    if (len > max_scheme_len) return false;
                    for (allowed_schemes) |allowed| {
                        if (std.ascii.eqlIgnoreCase(scheme[0..len], allowed)) return true;
                    }
                    return false;
                },
                '/', '?', '#' => return true,
                else => {
                    if (len < max_scheme_len) scheme[len] = c;
                    len += 1;
                },
            }
        }
    }
    return true;
}

/// Returns true if `url` is relative or uses an allowed scheme
/// (http, https, mailto, tel, ftp, ftps).
pub fn isSafeUrl(url: []const u8) bool {
    return isSchemeAllowed(&.{url});
}

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => ptr.child == u8,
            .one => @typeInfo(ptr.child) == .array and @typeInfo(ptr.child).array.child == u8,
            else => false,
        },
        .array => |arr| arr.child == u8,
        else => false,
    };
}

/// Writes a dynamic part of a URL attribute value that comes before the scheme
/// is known, together with the static text `before` it. The scheme check also
/// sees the static text `after` it, which the caller writes. Anything before
/// `before` must not contain `:`, `/`, `?` or `#`.
///
/// If `before`, `value` and `after` make up a disallowed scheme, writes
/// `invalid_url` instead of `before` and `value`. Each such part is checked on
/// its own: when an earlier part leaves the scheme open, a later one can only
/// end it with a scheme of its own, and that gets checked.
///
/// Only string values are checked. Other values (ints, enums) can't carry a
/// scheme, and values with a `formatHtml` method (like `Url`) are trusted.
pub fn writeUrlPart(
    writer: *std.Io.Writer,
    comptime before: []const u8,
    value: anytype,
    comptime after: []const u8,
) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    if (@typeInfo(T) == .optional) {
        if (value) |v| return writeUrlPart(writer, before, v, after);
        return writeUrlPart(writer, before, "", after);
    }

    if (comptime isString(T)) {
        const str: []const u8 = if (@typeInfo(T) == .array) &value else value;
        if (!isSchemeAllowed(&.{ before, str, after })) {
            return writer.writeAll(invalid_url);
        }
    }
    try writer.writeAll(before);
    try writeEscaped(writer, value);
}

/// Writes a URL attribute, skipping it entirely if the value is null.
/// A value with a disallowed scheme is replaced with `invalid_url`.
pub fn writeUrlAttr(writer: *std.Io.Writer, name: []const u8, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    const v = if (@typeInfo(T) == .optional) value orelse return else value;
    comptime checkAttrValueType(@TypeOf(v));

    try writer.writeAll(" ");
    try writer.writeAll(name);
    try writer.writeAll("=\"");
    try writeUrlPart(writer, "", v, "");
    try writer.writeAll("\"");
}

/// Writes an HTML boolean attribute: the bare name when the value is true,
/// nothing when it is false or null.
pub fn writeBoolAttr(writer: *std.Io.Writer, name: []const u8, value: anytype) std.Io.Writer.Error!void {
    const present: bool = switch (@TypeOf(value)) {
        bool => value,
        ?bool => value orelse false,
        else => @compileError("conditional attribute expects bool or ?bool, found " ++ @typeName(@TypeOf(value))),
    };
    if (!present) return;

    try writer.writeAll(" ");
    try writer.writeAll(name);
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

test "writeBoolAttr with true writes bare attribute" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeBoolAttr(&output.writer, "checked", true);
    try std.testing.expectEqualStrings(" checked", output.writer.buffer[0..output.writer.end]);
}

test "writeBoolAttr with false skips attribute" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeBoolAttr(&output.writer, "checked", false);
    try std.testing.expectEqualStrings("", output.writer.buffer[0..output.writer.end]);
}

test "writeBoolAttr with optional bool" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const yes: ?bool = true;
    const no: ?bool = false;
    const missing: ?bool = null;
    try writeBoolAttr(&output.writer, "a", yes);
    try writeBoolAttr(&output.writer, "b", no);
    try writeBoolAttr(&output.writer, "c", missing);
    try std.testing.expectEqualStrings(" a", output.writer.buffer[0..output.writer.end]);
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

test "isSafeUrl allows listed schemes in any case" {
    for ([_][]const u8{
        "http://example.com",
        "https://example.com/a?b=c",
        "mailto:user@example.com",
        "tel:+123456",
        "ftp://example.com",
        "ftps://example.com",
        "HTTPS://example.com",
        "HtTp://example.com",
        "MailTo:user@example.com",
    }) |url| {
        try std.testing.expect(isSafeUrl(url));
    }
}

test "isSafeUrl allows relative URLs" {
    for ([_][]const u8{ "/x", "x", "?q=1", "#frag", "//host", "/a:b", "a/b:c", "?q=a:b", "#a:b", "" }) |url| {
        try std.testing.expect(isSafeUrl(url));
    }
}

test "isSafeUrl rejects other schemes" {
    for ([_][]const u8{
        "javascript:alert(1)",
        "JaVaScRiPt:alert(1)",
        " javascript:alert(1)",
        "java\tscript:alert(1)",
        "data:text/html,<script>alert(1)</script>",
        "vbscript:msgbox(1)",
        "httpss://example.com",
        ":foo",
    }) |url| {
        try std.testing.expect(!isSafeUrl(url));
    }
}

fn expectUrlAttr(expected: []const u8, value: anytype) !void {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeUrlAttr(&output.writer, "href", value);
    try std.testing.expectEqualStrings(expected, output.writer.buffer[0..output.writer.end]);
}

test "writeUrlAttr writes allowed URLs escaped" {
    try expectUrlAttr(" href=\"https://example.com/?a=1&amp;b=2\"", "https://example.com/?a=1&b=2");
    try expectUrlAttr(" href=\"/users/&quot;x&quot;\"", "/users/\"x\"");
    try expectUrlAttr(" href=\"\"", "");
}

test "writeUrlAttr replaces disallowed URLs" {
    try expectUrlAttr(" href=\"" ++ invalid_url ++ "\"", "javascript:alert(1)");
    try expectUrlAttr(" href=\"" ++ invalid_url ++ "\"", "JaVaScRiPt:alert(1)");
    try expectUrlAttr(" href=\"" ++ invalid_url ++ "\"", " javascript:alert(1)");
    try expectUrlAttr(" href=\"" ++ invalid_url ++ "\"", "java\tscript:alert(1)");
    try expectUrlAttr(" href=\"" ++ invalid_url ++ "\"", "data:text/html,hi");
    try expectUrlAttr(" href=\"" ++ invalid_url ++ "\"", "vbscript:msgbox(1)");
}

test "writeUrlAttr with optional value" {
    const present: ?[]const u8 = "/home";
    const missing: ?[]const u8 = null;
    const bad: ?[]const u8 = "javascript:alert(1)";
    try expectUrlAttr(" href=\"/home\"", present);
    try expectUrlAttr("", missing);
    try expectUrlAttr(" href=\"" ++ invalid_url ++ "\"", bad);
}

test "writeUrlAttr skips the check for non-string values" {
    const Kind = enum { home, about };
    try expectUrlAttr(" href=\"42\"", @as(i32, 42));
    try expectUrlAttr(" href=\"about\"", Kind.about);
}

test "writeUrlAttr with Url skips the check but escapes" {
    try expectUrlAttr(" href=\"javascript:alert(&quot;x&quot;)\"", Url{ .value = "javascript:alert(\"x\")" });
    const ptr = &Url{ .value = "data:x" };
    try expectUrlAttr(" href=\"data:x\"", ptr);
    const opt: ?Url = .{ .value = "data:x" };
    try expectUrlAttr(" href=\"data:x\"", opt);
}

test "Url is escaped outside URL attributes" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeEscaped(&output.writer, Url{ .value = "<a&b>" });
    try std.testing.expectEqualStrings("&lt;a&amp;b&gt;", output.writer.buffer[0..output.writer.end]);
}

fn expectUrlPart(expected: []const u8, comptime before: []const u8, value: anytype, comptime after: []const u8) !void {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeUrlPart(&output.writer, before, value, after);
    try std.testing.expectEqualStrings(expected, output.writer.buffer[0..output.writer.end]);
}

test "writeUrlPart checks the scheme across before, value and after" {
    // "{base}/x"
    try expectUrlPart("https://example.com", "", "https://example.com", "/x");
    try expectUrlPart("", "", "", "/x");
    try expectUrlPart(invalid_url, "", "javascript:alert(1)", "/x");
    // "{proto}://host"
    try expectUrlPart("https", "", "https", "://host");
    try expectUrlPart(invalid_url, "", "javascript", ":alert(1)");
    // "java{rest}"
    try expectUrlPart(invalid_url, "java", "script:alert(1)", "");
    try expectUrlPart("htt&lt;b&gt;", "htt", "<b>", "");
    // "{a}{b}": the second part is checked on its own
    try expectUrlPart("java", "", "java", "");
    try expectUrlPart(invalid_url, "", "script:alert(1)", "");
    try expectUrlPart(invalid_url, "", ":alert(1)", "");
    try expectUrlPart(invalid_url, "", "", ":alert(1)");
    // optional
    const missing: ?[]const u8 = null;
    try expectUrlPart("", "", missing, "/x");
}

test "writeUrlPart skips the check for non-string values" {
    const Proto = enum { ws, wss };
    try expectUrlPart("wss", "", Proto.wss, "://host");
    try expectUrlPart("item1", "item", @as(u32, 1), "");
    try expectUrlPart("1", "", @as(u32, 1), ":x");
}
