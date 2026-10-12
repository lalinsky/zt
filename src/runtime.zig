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

/// Same as `std.Io.Writer.writeAll`, but checks whether the bytes fit in the
/// buffer before entering the loop. `writeAll` only does that inside `write`,
/// in a loop over the remaining bytes, so the copy length is never constant
/// and every write turns into a `memcpy` call. Here, a call with a string
/// literal copies a fixed number of bytes, which compiles to a few moves.
pub fn writeAll(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    if (writer.end + bytes.len <= writer.buffer.len) {
        @branchHint(.likely);
        @memcpy(writer.buffer[writer.end..][0..bytes.len], bytes);
        writer.end += bytes.len;
        return;
    }
    return writer.writeAll(bytes);
}

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
/// If it has a `format` method, what that writes is escaped.
pub fn writeEscaped(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);

    // Check for formatHtml method - assumed to be pre-escaped/safe HTML
    if (comptime std.meta.hasMethod(T, "formatHtml")) {
        return value.formatHtml(writer);
    }

    if (comptime std.meta.hasMethod(T, "format")) {
        var escaping: EscapingWriter = .{ .underlying = writer };
        return value.format(&escaping.interface);
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
        .int => {
            // Digits and a sign never need escaping.
            try writeInt(writer, value);
        },
        .comptime_int => {
            try writer.printInt(value, 10, .lower, .{});
        },
        .float => {
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

/// Writes an integer in decimal. When the buffer has room for the longest
/// value of the type, the digits are written straight into it. `printInt`
/// formats into a temporary buffer and copies that out with `writeAll`,
/// which turns into a `memcpy` call for every number.
fn writeInt(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T).int;
    const U = if (info.bits <= 32) u32 else if (info.bits <= 64) u64 else if (info.bits <= 128) u128 else {
        return writer.printInt(value, 10, .lower, .{});
    };
    const negative = info.signedness == .signed and value < 0;
    const max_len = comptime countDigits(U, @abs(std.math.maxInt(T))) + @intFromBool(info.signedness == .signed);
    if (writer.buffer.len - writer.end < max_len) {
        return writer.printInt(value, 10, .lower, .{});
    }

    var a: U = @abs(value);
    const len = countDigits(U, a) + @intFromBool(negative);
    const dest = writer.buffer[writer.end..][0..len];
    if (negative) dest[0] = '-';
    var i = len;
    while (a >= 100) : (a /= 100) {
        i -= 2;
        dest[i..][0..2].* = std.fmt.digits2(@intCast(a % 100));
    }
    if (a < 10) {
        dest[i - 1] = '0' + @as(u8, @intCast(a));
    } else {
        dest[i - 2 ..][0..2].* = std.fmt.digits2(@intCast(a));
    }
    writer.end += len;
}

fn countDigits(comptime U: type, value: U) usize {
    var count: usize = 1;
    var limit: U = 10;
    while (value >= limit) {
        count += 1;
        limit = std.math.mul(U, limit, 10) catch break;
    }
    return count;
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

/// Returns a value whose `format` method calls `func` with `args` followed by
/// the writer, so a function that writes to a writer can be used in a template:
///
///     fn dateTime(ts: i64, w: *std.Io.Writer) std.Io.Writer.Error!void { ... }
///
///     <time>{zt.fmt(dateTime, .{post.created_at})}</time>
///
/// Like any other value, what it writes is escaped, unless written with `{!...}`.
pub fn fmt(comptime func: anytype, args: anytype) Fmt(func, @TypeOf(args)) {
    return .{ .args = args };
}

pub fn Fmt(comptime func: anytype, comptime Args: type) type {
    if (@typeInfo(Args) != .@"struct" or !@typeInfo(Args).@"struct".is_tuple) {
        @compileError("zt.fmt: expected the arguments as a tuple, like .{x}, found " ++ @typeName(Args));
    }
    return struct {
        args: Args,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const result = @call(.auto, func, self.args ++ .{writer});
            const R = @TypeOf(result);
            if (R == void) return;
            if (comptime isWriterErrorUnion(R)) return result;
            @compileError("zt.fmt: the function must return void or std.Io.Writer.Error!void, found " ++ @typeName(R));
        }
    };
}

fn isWriterErrorUnion(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .error_union => |info| info.payload == void and
            (info.error_set || std.Io.Writer.Error) == std.Io.Writer.Error,
        else => false,
    };
}

/// Writes an attribute, skipping it entirely if the value is null.
pub fn writeAttr(writer: *std.Io.Writer, comptime name: []const u8, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    const v = if (@typeInfo(T) == .optional) value orelse return else value;
    comptime checkAttrValueType(@TypeOf(v));

    try writeAll(writer, " " ++ name ++ "=\"");
    try writeEscaped(writer, v);
    try writeAll(writer, "\"");
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

const SchemeCheck = enum { allowed, rejected, open };

/// Checks the scheme of a URL made of `parts` written one after another.
/// The scheme ends at the first `:`. A `/`, `?` or `#` before it makes the
/// URL relative. Without any of them, the check stays open.
fn checkScheme(parts: []const []const u8) SchemeCheck {
    var scheme: [max_scheme_len]u8 = undefined;
    var len: usize = 0;
    for (parts) |part| {
        for (part) |c| {
            switch (c) {
                ':' => {
                    if (len > max_scheme_len) return .rejected;
                    for (allowed_schemes) |allowed| {
                        if (std.ascii.eqlIgnoreCase(scheme[0..len], allowed)) return .allowed;
                    }
                    return .rejected;
                },
                '/', '?', '#' => return .allowed,
                else => {
                    if (len < max_scheme_len) scheme[len] = c;
                    len += 1;
                },
            }
        }
    }
    return .open;
}

/// Like `checkScheme`, but a URL without a `:` is relative, so allowed.
fn isSchemeAllowed(parts: []const []const u8) bool {
    return checkScheme(parts) != .rejected;
}

/// Escapes what a `format` method writes as a URL part. Nothing is written
/// until the scheme check over `before` and the output so far is decided, so
/// a disallowed scheme can still be replaced with `invalid_url`.
const UrlPartWriter = struct {
    underlying: *std.Io.Writer,
    before: []const u8,
    check: SchemeCheck = .open,
    /// Output held back while the check is open.
    pending: [max_pending]u8 = undefined,
    pending_len: usize = 0,
    interface: std.Io.Writer = .{
        .vtable = &.{ .drain = drain },
        .buffer = &.{},
    },

    /// How much output can be held back. If it fills up before the check is
    /// decided, the URL is rejected.
    const max_pending = 1024;

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *UrlPartWriter = @fieldParentPtr("interface", w);
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.feed(bytes);
            total += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try self.feed(pattern);
            total += pattern.len;
        }
        return total;
    }

    fn feed(self: *UrlPartWriter, bytes: []const u8) std.Io.Writer.Error!void {
        switch (self.check) {
            .allowed => return writeEscapedString(self.underlying, bytes),
            .rejected => return,
            .open => {},
        }
        for (bytes, 0..) |c, i| {
            if (self.pending_len == max_pending) return self.decide(.rejected);
            self.pending[self.pending_len] = c;
            self.pending_len += 1;
            switch (c) {
                ':', '/', '?', '#' => {
                    try self.decide(checkScheme(&.{ self.before, self.pending[0..self.pending_len] }));
                    return self.feed(bytes[i + 1 ..]);
                },
                else => {},
            }
        }
    }

    /// Ends the output. If the check is still open, `after` decides it.
    fn finish(self: *UrlPartWriter, after: []const u8) std.Io.Writer.Error!void {
        if (self.check != .open) return;
        const check = checkScheme(&.{ self.before, self.pending[0..self.pending_len], after });
        try self.decide(if (check == .rejected) .rejected else .allowed);
    }

    fn decide(self: *UrlPartWriter, check: SchemeCheck) std.Io.Writer.Error!void {
        self.check = check;
        switch (check) {
            .allowed => {
                try self.underlying.writeAll(self.before);
                try writeEscapedString(self.underlying, self.pending[0..self.pending_len]);
            },
            .rejected => try self.underlying.writeAll(invalid_url),
            .open => unreachable,
        }
    }
};

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
/// String values and what `format` methods write are checked. Other values
/// (ints, enums) can't carry a scheme, and values with a `formatHtml` method
/// (like `Url`) are trusted. What a `format` method writes is held back until
/// the check is decided, and if that takes more than 1024 bytes, the URL is
/// rejected.
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
    if (comptime !std.meta.hasMethod(T, "formatHtml") and std.meta.hasMethod(T, "format")) {
        var url: UrlPartWriter = .{ .underlying = writer, .before = before };
        try value.format(&url.interface);
        return url.finish(after);
    }
    try writer.writeAll(before);
    try writeEscaped(writer, value);
}

/// Writes a URL attribute, skipping it entirely if the value is null.
/// A value with a disallowed scheme is replaced with `invalid_url`.
pub fn writeUrlAttr(writer: *std.Io.Writer, comptime name: []const u8, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    const v = if (@typeInfo(T) == .optional) value orelse return else value;
    comptime checkAttrValueType(@TypeOf(v));

    try writeAll(writer, " " ++ name ++ "=\"");
    try writeUrlPart(writer, "", v, "");
    try writeAll(writer, "\"");
}

/// Writes an HTML boolean attribute: the bare name when the value is true,
/// nothing when it is false or null.
pub fn writeBoolAttr(writer: *std.Io.Writer, comptime name: []const u8, value: anytype) std.Io.Writer.Error!void {
    const present: bool = switch (@TypeOf(value)) {
        bool => value,
        ?bool => value orelse false,
        else => @compileError("conditional attribute expects bool or ?bool, found " ++ @typeName(@TypeOf(value))),
    };
    if (!present) return;

    try writeAll(writer, " " ++ name);
}

/// Writes a value without escaping (for pre-escaped HTML).
/// If the value has a `formatHtml` or `format` method, it's called directly.
pub fn writeRaw(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);

    if (comptime std.meta.hasMethod(T, "formatHtml")) {
        return value.formatHtml(writer);
    }

    if (comptime std.meta.hasMethod(T, "format")) {
        return value.format(writer);
    }

    if (comptime isString(T)) {
        return writer.writeAll(if (@typeInfo(T) == .array) &value else value);
    }

    switch (@typeInfo(T)) {
        .optional => {
            if (value) |v| {
                try writeRaw(writer, v);
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
    try writeEscaped(&output.writer, " ");
    try writeEscaped(&output.writer, @as(i64, -1234567));
    try writeEscaped(&output.writer, " ");
    try writeEscaped(&output.writer, @as(u8, 255));
    try writeEscaped(&output.writer, " ");
    try writeEscaped(&output.writer, 100);
    try writeEscaped(&output.writer, " ");
    try writeEscaped(&output.writer, @as(f64, 1.5));
    try std.testing.expectEqualStrings("42 -1234567 255 100 1.5", output.writer.buffer[0..output.writer.end]);
}

test "writeInt writes every digit count, sign and limit" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    // Make sure the fast path runs.
    try output.ensureUnusedCapacity(64);

    const cases = .{
        .{ @as(u8, 0), "0" },
        .{ @as(u8, 9), "9" },
        .{ @as(u8, 10), "10" },
        .{ @as(u8, 99), "99" },
        .{ @as(u8, 100), "100" },
        .{ @as(u8, 255), "255" },
        .{ @as(i8, -128), "-128" },
        .{ @as(i8, -1), "-1" },
        .{ @as(u1, 1), "1" },
        .{ @as(i32, 1_000_000), "1000000" },
        .{ @as(u32, std.math.maxInt(u32)), "4294967295" },
        .{ @as(u64, std.math.maxInt(u64)), "18446744073709551615" },
        .{ @as(i64, std.math.minInt(i64)), "-9223372036854775808" },
        .{ @as(u128, std.math.maxInt(u128)), "340282366920938463463374607431768211455" },
        .{ @as(i128, std.math.minInt(i128)), "-170141183460469231731687303715884105728" },
        .{ @as(u256, 12345), "12345" },
    };
    inline for (cases) |case| {
        output.clearRetainingCapacity();
        try writeInt(&output.writer, case[0]);
        try std.testing.expectEqualStrings(case[1], output.written());
    }
}

test "writeInt falls back to printInt without room for the longest value" {
    var buf: [4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeInt(&writer, @as(u64, 42));
    try writeInt(&writer, @as(i32, -7));
    try std.testing.expectEqualStrings("42-7", writer.buffered());
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

const Formatted = struct {
    text: []const u8,

    pub fn format(self: Formatted, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.text);
    }
};

test "format is escaped" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeEscaped(&output.writer, Formatted{ .text = "<b>&</b>" });
    try writeEscaped(&output.writer, &Formatted{ .text = "\"" });
    const opt: ?Formatted = .{ .text = "<" };
    try writeEscaped(&output.writer, opt);
    try std.testing.expectEqualStrings("&lt;b&gt;&amp;&lt;/b&gt;&quot;&lt;", output.written());
}

test "format is written raw" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeRaw(&output.writer, Formatted{ .text = "<b>bold</b>" });
    try std.testing.expectEqualStrings("<b>bold</b>", output.written());
}

test "formatHtml takes precedence over format" {
    const Both = struct {
        pub fn format(_: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("<text>");
        }

        pub fn formatHtml(_: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("<html>");
        }
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeEscaped(&output.writer, Both{});
    try writeRaw(&output.writer, Both{});
    try std.testing.expectEqualStrings("<html><html>", output.written());
}

test "writeRaw with optionals and string literals" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const opt: ?Formatted = .{ .text = "<a>" };
    const missing: ?Formatted = null;
    try writeRaw(&output.writer, opt);
    try writeRaw(&output.writer, missing);
    try writeRaw(&output.writer, "<b>");
    try writeRaw(&output.writer, [_]u8{ '<', 'c', '>' });
    try std.testing.expectEqualStrings("<a><b><c>", output.written());
}

test "enum with format is written through it" {
    const Color = enum {
        red,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("<{t}>", .{self});
        }
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeEscaped(&output.writer, Color.red);
    try std.testing.expectEqualStrings("&lt;red&gt;", output.written());
}

fn testDate(year: u16, month: u8, day: u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{d}-{d:0>2}-{d:0>2}", .{ year, month, day });
}

fn testTag(name: []const u8, writer: *std.Io.Writer) void {
    writer.print("<{s}>", .{name}) catch {};
}

test "fmt calls the function with the writer" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    var day: u8 = 5;
    _ = &day;
    try writeEscaped(&output.writer, fmt(testDate, .{ 2026, 10, day }));
    try writeEscaped(&output.writer, fmt(testTag, .{"b"}));
    try writeRaw(&output.writer, fmt(testTag, .{"b"}));
    try std.testing.expectEqualStrings("2026-10-05&lt;b&gt;<b>", output.written());
}

test "fmt in an attribute" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeAttr(&output.writer, "title", fmt(testTag, .{"\"x\""}));
    try std.testing.expectEqualStrings(" title=\"&lt;&quot;x&quot;&gt;\"", output.written());
}

/// Writes its text in pieces of `chunk` bytes, to test output split across writes.
const Chunked = struct {
    text: []const u8,
    chunk: usize,

    pub fn format(self: Chunked, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var rest = self.text;
        while (rest.len > 0) {
            const n = @min(self.chunk, rest.len);
            try writer.writeAll(rest[0..n]);
            rest = rest[n..];
        }
    }
};

test "writeUrlPart checks the scheme of format output" {
    for ([_]usize{ 1, 3, 100 }) |chunk| {
        try expectUrlPart("https://example.com/?a=1&amp;b=2", "", Chunked{ .text = "https://example.com/?a=1&b=2", .chunk = chunk }, "");
        try expectUrlPart("/a:b", "", Chunked{ .text = "/a:b", .chunk = chunk }, "");
        try expectUrlPart(invalid_url, "", Chunked{ .text = "javascript:alert(1)", .chunk = chunk }, "");
        try expectUrlPart(invalid_url, "java", Chunked{ .text = "script:alert(1)", .chunk = chunk }, "");
        try expectUrlPart("htt&lt;b&gt;", "htt", Chunked{ .text = "<b>", .chunk = chunk }, "");
        // decided by `after`
        try expectUrlPart("https", "", Chunked{ .text = "https", .chunk = chunk }, "://host");
        try expectUrlPart(invalid_url, "", Chunked{ .text = "javascript", .chunk = chunk }, ":alert(1)");
        try expectUrlPart("page", "", Chunked{ .text = "page", .chunk = chunk }, "");
        try expectUrlPart("", "", Chunked{ .text = "", .chunk = chunk }, "/x");
    }
    try expectUrlPart(invalid_url, "", fmt(testTag, .{"x"}), ":y");
    try expectUrlPart("&lt;x&gt;", "", fmt(testTag, .{"x"}), "/y");
    try expectUrlAttr(" href=\"" ++ invalid_url ++ "\"", Formatted{ .text = "data:text/html,hi" });
    try expectUrlAttr(" href=\"/x\"", Formatted{ .text = "/x" });
    const opt: ?Formatted = .{ .text = "javascript:x" };
    try expectUrlAttr(" href=\"" ++ invalid_url ++ "\"", opt);
    try expectUrlAttr(" href=\"" ++ invalid_url ++ "\"", &Formatted{ .text = "javascript:x" });
}

const Padded = struct {
    slashes: usize,

    pub fn format(self: Padded, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s:>12}", .{"javascript"});
        try writer.splatByteAll('/', self.slashes);
    }
};

test "writeUrlPart checks splat and padded format output" {
    try expectUrlPart("  javascript///", "", Padded{ .slashes = 3 }, ":x");
    try expectUrlPart(invalid_url, "", Padded{ .slashes = 0 }, ":x");
}

test "writeUrlPart rejects format output too long to check" {
    const long: [UrlPartWriter.max_pending - 1]u8 = @splat('a');
    try expectUrlPart(long ++ "/", "", Formatted{ .text = long ++ "/" }, "");
    try expectUrlPart(invalid_url, "", Formatted{ .text = long ++ "a/" }, "");
}

test "writeAll copies into the buffer while it fits and drains otherwise" {
    const Counting = struct {
        writer: std.Io.Writer,
        drains: usize = 0,
        out: [64]u8 = undefined,
        out_len: usize = 0,

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *@This() = @fieldParentPtr("writer", w);
            std.debug.assert(data.len == 1 and splat == 1);
            self.drains += 1;
            for ([_][]const u8{ w.buffered(), data[0] }) |bytes| {
                @memcpy(self.out[self.out_len..][0..bytes.len], bytes);
                self.out_len += bytes.len;
            }
            w.end = 0;
            return data[0].len;
        }
    };

    var buf: [8]u8 = undefined;
    var counting: Counting = .{ .writer = .{ .vtable = &.{ .drain = Counting.drain }, .buffer = &buf } };
    const w = &counting.writer;

    try writeAll(w, "<td>");
    try writeAll(w, "");
    try std.testing.expectEqual(4, w.end);
    // Exactly filling the buffer does not drain.
    try writeAll(w, "1234");
    try std.testing.expectEqual(8, w.end);
    try std.testing.expectEqual(0, counting.drains);

    // One more byte does not fit, so it goes through drain.
    try writeAll(w, "x");
    try std.testing.expectEqual(1, counting.drains);
    try std.testing.expectEqual(0, w.end);
    try std.testing.expectEqualStrings("<td>1234x", counting.out[0..counting.out_len]);
}
