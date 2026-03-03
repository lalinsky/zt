const std = @import("std");
const ast = @import("ast.zig");

/// HTML raw text elements whose content is not parsed for expressions.
/// https://html.spec.whatwg.org/multipage/syntax.html#raw-text-elements
const raw_text_elements = std.StaticStringMap(void).initComptime(.{
    .{ "script", {} },
    .{ "style", {} },
});

pub const ParseError = struct {
    line: usize,
    col: usize,
    msg: []const u8,
};

pub const Parser = struct {
    source: []const u8,
    pos: usize,
    line: usize,
    col: usize,
    allocator: std.mem.Allocator,
    err: ?ParseError = null,

    pub const Error = error{ OutOfMemory, ParseError };

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
            .allocator = allocator,
        };
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        self.err = .{
            .line = self.line,
            .col = self.col,
            .msg = std.fmt.allocPrint(self.allocator, fmt, args) catch "error",
        };
        return error.ParseError;
    }

    // =========================================================================
    // Core utilities
    // =========================================================================

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    fn peekAhead(self: *Parser, offset: usize) ?u8 {
        const idx = self.pos + offset;
        if (idx >= self.source.len) return null;
        return self.source[idx];
    }

    fn advance(self: *Parser) ?u8 {
        if (self.pos >= self.source.len) return null;
        const c = self.source[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return c;
    }

    fn match(self: *Parser, expected: []const u8) bool {
        if (self.pos + expected.len > self.source.len) return false;
        if (std.mem.eql(u8, self.source[self.pos..][0..expected.len], expected)) {
            for (expected) |c| {
                if (c == '\n') {
                    self.line += 1;
                    self.col = 1;
                } else {
                    self.col += 1;
                }
            }
            self.pos += expected.len;
            return true;
        }
        return false;
    }

    fn check(self: *Parser, expected: []const u8) bool {
        if (self.pos + expected.len > self.source.len) return false;
        return std.mem.eql(u8, self.source[self.pos..][0..expected.len], expected);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                _ = self.advance();
            } else {
                break;
            }
        }
    }

    fn skipSpaces(self: *Parser) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t') {
                _ = self.advance();
            } else {
                break;
            }
        }
    }

    fn location(self: *Parser) ast.Location {
        return .{ .line = self.line, .column = self.col };
    }

    // =========================================================================
    // Template parsing: pub templ name(params) { body }
    // =========================================================================

    /// Parse a file containing one or more templates and Zig code
    pub fn parseFile(self: *Parser) Error!ast.TemplateFile {
        var zig_code_parts: std.ArrayList([]const u8) = .empty;
        var templates: std.ArrayList(ast.Template) = .empty;

        while (self.peek() != null) {
            self.skipWhitespace();
            if (self.peek() == null) break;

            // Check if we're at a template start
            if (self.isAtTemplate()) {
                const template = try self.parseTemplate();
                try templates.append(self.allocator, template);
            } else {
                // Parse Zig code until next template or EOF
                const zig_start = self.pos;
                while (self.peek() != null) {
                    self.skipToNextLine();
                    self.skipWhitespace();
                    if (self.isAtTemplate()) break;
                }
                const zig_code = std.mem.trim(u8, self.source[zig_start..self.pos], " \t\n\r");
                if (zig_code.len > 0) {
                    try zig_code_parts.append(self.allocator, zig_code);
                }
            }
        }

        // Join all Zig code parts with newlines
        const header = if (zig_code_parts.items.len == 0)
            ""
        else if (zig_code_parts.items.len == 1)
            zig_code_parts.items[0]
        else
            try std.mem.join(self.allocator, "\n\n", zig_code_parts.items);

        return .{ .header = header, .templates = templates.items };
    }

    fn isAtTemplate(self: *Parser) bool {
        if (self.check("templ ")) return true;
        if (self.check("pub ")) {
            // Look ahead past "pub " to check for "templ"
            const saved_pos = self.pos;
            const saved_line = self.line;
            const saved_col = self.col;
            _ = self.match("pub ");
            self.skipWhitespace();
            const is_templ = self.check("templ ");
            self.pos = saved_pos;
            self.line = saved_line;
            self.col = saved_col;
            return is_templ;
        }
        return false;
    }

    fn skipToNextLine(self: *Parser) void {
        while (self.peek()) |c| {
            _ = self.advance();
            if (c == '\n') break;
        }
    }

    pub fn parseTemplate(self: *Parser) Error!ast.Template {
        self.skipWhitespace();

        const is_public = self.match("pub ");
        if (is_public) self.skipWhitespace();

        if (!self.match("templ ")) {
            return self.fail("expected 'templ' keyword", .{});
        }
        self.skipWhitespace();

        const name = try self.parseIdentifier();
        self.skipWhitespace();

        if (!self.match("(")) return self.fail("expected '(' after template name", .{});
        const params = try self.parseParameters();
        if (!self.match(")")) return self.fail("expected ')' after template parameters", .{});

        self.skipWhitespace();
        const body = try self.parseBracedNodes();

        return .{
            .name = name,
            .params = params,
            .is_public = is_public,
            .body = body,
        };
    }

    fn parseIdentifier(self: *Parser) Error![]const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                _ = self.advance();
            } else {
                break;
            }
        }
        if (self.pos == start) return self.fail("expected identifier", .{});
        return self.source[start..self.pos];
    }

    /// Parse template parameters: "name: Type, other: OtherType" -> []Parameter
    fn parseParameters(self: *Parser) Error![]const ast.Parameter {
        var params: std.ArrayList(ast.Parameter) = .empty;

        while (true) {
            self.skipWhitespace();
            if (self.peek() == @as(u8, ')')) break;

            // Parse parameter name
            const name = try self.parseIdentifier();
            self.skipWhitespace();

            // Expect colon
            if (!self.match(":")) return self.fail("expected ':' after parameter name", .{});
            self.skipWhitespace();

            // Parse type (with brace depth tracking for complex types)
            const type_start = self.pos;
            var depth: usize = 0;
            while (self.peek()) |c| {
                if (c == '(' or c == '[' or c == '{') {
                    depth += 1;
                    _ = self.advance();
                } else if (c == ')' or c == ']' or c == '}') {
                    if (depth == 0) break;
                    depth -= 1;
                    _ = self.advance();
                } else if (c == ',' and depth == 0) {
                    break;
                } else {
                    _ = self.advance();
                }
            }
            const type_str = std.mem.trim(u8, self.source[type_start..self.pos], " \t\n\r");

            try params.append(self.allocator, .{ .name = name, .type_str = type_str });

            self.skipWhitespace();
            if (!self.match(",")) break;
        }

        return params.items;
    }

    // =========================================================================
    // Common parsing helpers
    // =========================================================================

    /// Parse `(code)` - parens with balanced Zig code inside
    fn parseParenExpr(self: *Parser) Error![]const u8 {
        if (!self.match("(")) return self.fail("expected '('", .{});
        const code = try self.parseZigCodeBalanced(1);
        if (!self.match(")")) return self.fail("expected ')'", .{});
        return code;
    }

    /// Parse `|captures|` - pipe-delimited captures
    fn parseCaptures(self: *Parser) Error![]const u8 {
        if (!self.match("|")) return self.fail("expected '|'", .{});
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == '|') break;
            _ = self.advance();
        }
        const captures = self.source[start..self.pos];
        if (!self.match("|")) return self.fail("expected '|'", .{});
        return captures;
    }

    /// Parse `{ nodes }` - braced block of nodes
    fn parseBracedNodes(self: *Parser) Error![]const ast.Node {
        if (!self.match("{")) return self.fail("expected '{{'", .{});
        const nodes = try self.parseNodes(true); // at_block_start = true
        self.skipWhitespace();
        if (!self.match("}")) return self.fail("expected '}}'", .{});
        return nodes;
    }

    // =========================================================================
    // Node parsing - the main recursive descent
    // =========================================================================

    fn parseNodes(self: *Parser, block_level: bool) Error![]const ast.Node {
        var nodes: std.ArrayList(ast.Node) = .empty;

        while (true) {
            if (self.peek() == null or self.peek() == '}' or self.check("</")) break;

            if (try self.parseNode(block_level)) |node| {
                try nodes.append(self.allocator, node);
            } else {
                break;
            }
        }

        return nodes.items;
    }

    fn parseNode(self: *Parser, at_block_start: bool) Error!?ast.Node {
        // Save position before skipping whitespace
        const saved_pos = self.pos;
        const saved_line = self.line;
        const saved_col = self.col;

        self.skipWhitespace();

        // Block constructs allowed at block start OR if we crossed a newline
        const allow_block_constructs = at_block_start or (self.line > saved_line);

        const c = self.peek() orelse return null;
        if (c == '}') return null;

        if (c == '<') {
            if (self.check("</")) return null;
            if (self.check("<!--")) {
                try self.skipComment();
                return self.parseNode(at_block_start);
            }
            if (self.checkDoctypeInsensitive()) {
                return .{ .doctype = try self.parseDoctype() };
            }
            return .{ .element = try self.parseElement() };
        }
        if (c == '{') return .{ .expr = try self.parseExprBlock() };

        // Block-level constructs only allowed at block start or after newline
        if (allow_block_constructs) {
            if (c == '@') return .{ .component_call = try self.parseComponentCall() };
            if (self.check("for ")) return .{ .for_stmt = try self.parseForStatement() };
            if (self.check("if ")) return .{ .if_stmt = try self.parseIfStatement() };
            if (self.check("switch ")) return .{ .switch_stmt = try self.parseSwitchStatement() };
        }

        // Fallback to text - restore position to include whitespace
        self.pos = saved_pos;
        self.line = saved_line;
        self.col = saved_col;

        return .{ .text = try self.parseText() };
    }

    // =========================================================================
    // Element parsing: <tag attr="val">children</tag> or <tag />
    // =========================================================================

    fn parseElement(self: *Parser) Error!ast.Element {
        const loc = self.location();
        if (!self.match("<")) return self.fail("expected '<'", .{});

        const tag = try self.parseTagName();
        const attributes = try self.parseAttributes();

        self.skipSpaces();

        // Self-closing: <tag />
        if (self.match("/>")) {
            return .{
                .tag = tag,
                .attributes = attributes,
                .children = &[_]ast.Node{},
                .self_closing = true,
                .loc = loc,
            };
        }

        // Opening tag: <tag>
        if (!self.match(">")) return self.fail("expected '>' to close opening tag", .{});

        // Raw text elements (style, script) - content is not parsed for expressions
        const children = if (raw_text_elements.has(tag))
            try self.parseRawTextContent(tag)
        else
            // Parse children (not at block start, but newlines enable block constructs)
            try self.parseNodes(false);

        // Closing tag: </tag>
        self.skipWhitespace();
        const end_loc = self.location();
        if (!self.match("</")) return self.fail("expected closing tag '</{s}>'", .{tag});
        const closing_tag = try self.parseTagName();
        if (!std.mem.eql(u8, tag, closing_tag)) return self.fail("mismatched closing tag: expected '</{s}>', found '</{s}>'", .{ tag, closing_tag });
        self.skipSpaces();
        if (!self.match(">")) return self.fail("expected '>' to close tag", .{});

        return .{
            .tag = tag,
            .attributes = attributes,
            .children = children,
            .self_closing = false,
            .loc = loc,
            .end_loc = end_loc,
        };
    }

    /// Parse raw text content until the closing tag (for style, script elements).
    /// Returns content as a single Text node, or empty if content is whitespace-only.
    fn parseRawTextContent(self: *Parser, tag: []const u8) Error![]const ast.Node {
        const start = self.pos;

        // Find the closing tag
        while (self.pos < self.source.len) {
            if (self.check("</")) {
                // Check if this is actually our closing tag
                const saved_pos = self.pos;
                const saved_line = self.line;
                const saved_col = self.col;

                _ = self.match("</");
                const closing_start = self.pos;
                while (self.peek()) |c| {
                    if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':') {
                        _ = self.advance();
                    } else break;
                }
                const closing_tag = self.source[closing_start..self.pos];

                if (std.ascii.eqlIgnoreCase(closing_tag, tag)) {
                    // Found the closing tag - restore position to before </
                    self.pos = saved_pos;
                    self.line = saved_line;
                    self.col = saved_col;
                    break;
                }

                // Not our closing tag, restore and continue
                self.pos = saved_pos;
                self.line = saved_line;
                self.col = saved_col;
            }
            _ = self.advance();
        }

        const content = self.source[start..self.pos];

        // Return empty children if content is empty/whitespace-only
        if (std.mem.trim(u8, content, " \t\n\r").len == 0) {
            return &[_]ast.Node{};
        }

        // Return single text node with raw content
        const text_node = try self.allocator.create(ast.Node);
        text_node.* = .{ .text = .{ .content = content } };
        const nodes = try self.allocator.alloc(ast.Node, 1);
        nodes[0] = text_node.*;
        return nodes;
    }

    fn parseTagName(self: *Parser) Error![]const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':') {
                _ = self.advance();
            } else {
                break;
            }
        }
        if (self.pos == start) return self.fail("expected tag name", .{});
        return self.source[start..self.pos];
    }

    fn parseAttributes(self: *Parser) Error![]const ast.Attribute {
        var attrs: std.ArrayList(ast.Attribute) = .empty;

        while (true) {
            self.skipWhitespace();
            const c = self.peek() orelse break;
            if (c == '>' or c == '/') break;

            const attr = try self.parseAttribute();
            try attrs.append(self.allocator, attr);
        }

        return attrs.items;
    }

    fn parseAttribute(self: *Parser) Error!ast.Attribute {
        const name = try self.parseAttributeName();
        self.skipSpaces();

        // Boolean attribute (no value)
        if (self.peek() != @as(u8, '=')) {
            return .{ .name = name, .value = .none };
        }

        _ = self.match("=");
        self.skipSpaces();

        const c = self.peek() orelse return self.fail("expected attribute value after '='", .{});

        // Dynamic attribute: attr={expr}
        if (c == '{') {
            _ = self.advance(); // consume {
            const expr = try self.parseZigCodeBalanced(0);
            if (!self.match("}")) return self.fail("expected '}}' to close dynamic attribute", .{});
            return .{ .name = name, .value = .{ .dynamic = expr } };
        }

        // Quoted attribute: attr="value" or attr='value'
        // May contain interpolations: attr="prefix{expr}suffix"
        if (c == '"' or c == '\'') {
            const quote = self.advance().?;
            const value = try self.parseQuotedAttrValue(quote);
            _ = self.advance(); // consume closing quote
            return .{ .name = name, .value = value };
        }

        return self.fail("expected '\"', \"'\", or '{{' for attribute value", .{});
    }

    /// Parse a quoted attribute value, which may contain interpolations like "prefix{expr}suffix"
    fn parseQuotedAttrValue(self: *Parser, quote: u8) Error!ast.Attribute.Value {
        const start = self.pos;

        // First pass: check if there are any interpolations
        var has_interpolation = false;
        var scan_pos = self.pos;
        while (scan_pos < self.source.len) {
            const ch = self.source[scan_pos];
            if (ch == quote) break;
            if (ch == '{') {
                has_interpolation = true;
                break;
            }
            scan_pos += 1;
        }

        // Simple case: no interpolations, return static value
        if (!has_interpolation) {
            while (self.peek()) |ch| {
                if (ch == quote) break;
                _ = self.advance();
            }
            return .{ .static = self.source[start..self.pos] };
        }

        // Complex case: parse interpolated parts
        var parts: std.ArrayList(ast.Attribute.InterpolatedPart) = .empty;
        var text_start = self.pos;

        while (self.peek()) |ch| {
            if (ch == quote) break;

            if (ch == '{') {
                // Save any preceding static text
                if (self.pos > text_start) {
                    try parts.append(self.allocator, .{ .static = self.source[text_start..self.pos] });
                }

                // Parse the dynamic expression
                _ = self.advance(); // consume {
                const expr = try self.parseZigCodeBalanced(0);
                if (!self.match("}")) return self.fail("expected '}}' to close interpolation", .{});
                try parts.append(self.allocator, .{ .dynamic = expr });

                text_start = self.pos;
            } else {
                _ = self.advance();
            }
        }

        // Save any trailing static text
        if (self.pos > text_start) {
            try parts.append(self.allocator, .{ .static = self.source[text_start..self.pos] });
        }

        return .{ .interpolated = parts.items };
    }

    fn parseAttributeName(self: *Parser) Error![]const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':' or c == '@') {
                _ = self.advance();
            } else {
                break;
            }
        }
        if (self.pos == start) return self.fail("expected attribute name", .{});
        return self.source[start..self.pos];
    }

    // =========================================================================
    // Expression block: { ... }
    // =========================================================================

    fn parseExprBlock(self: *Parser) Error!ast.Expr {
        const loc = self.location();
        if (!self.match("{")) return self.fail("expected '{{'", .{});

        // Check for raw output: {!expr}
        const is_raw = self.match("!");

        self.skipWhitespace();

        const content = try self.parseExprContent();

        self.skipWhitespace();
        if (!self.match("}")) return self.fail("expected '}}' to close expression", .{});

        return .{ .content = content, .raw = is_raw, .loc = loc };
    }

    fn parseExprContent(self: *Parser) Error!ast.Expr.Content {
        // Check for inline if: if (cond) branch else branch
        if (self.check("if ") or self.check("if(")) {
            return .{ .if_expr = try self.parseIfExpr() };
        }

        // Check for inline for: for (iter) |cap| branch
        if (self.check("for ") or self.check("for(")) {
            return .{ .for_expr = try self.parseForExpr() };
        }

        // Check for inline switch: switch (expr) ...
        if (self.check("switch ") or self.check("switch(")) {
            return .{ .switch_expr = try self.parseSwitchExpr() };
        }

        // Check for inline element: <tag>...</tag>
        if (self.peek() == @as(u8, '<') and !self.check("</")) {
            const elem = try self.allocator.create(ast.Element);
            elem.* = try self.parseElement();
            return .{ .element = elem };
        }

        // Plain Zig code
        return .{ .zig_code = try self.parseZigCodeBalanced(0) };
    }

    // =========================================================================
    // Inline if: if (cond) branch else branch
    // =========================================================================

    fn parseIfExpr(self: *Parser) Error!ast.IfExpr {
        _ = self.match("if");
        self.skipWhitespace();
        const condition = try self.parseParenExpr();
        self.skipWhitespace();

        // Optional capture: |val|
        const capture: ?[]const u8 = if (self.peek() == @as(u8, '|'))
            try self.parseCaptures()
        else
            null;

        self.skipWhitespace();
        const then_branch = try self.parseBranch();
        self.skipWhitespace();

        var else_capture: ?[]const u8 = null;
        const else_branch: ?ast.Branch = if (self.match("else")) blk: {
            self.skipWhitespace();
            // Optional else capture: else |err|
            if (self.peek() == @as(u8, '|')) {
                else_capture = try self.parseCaptures();
                self.skipWhitespace();
            }
            break :blk try self.parseBranch();
        } else null;

        return .{ .condition = condition, .capture = capture, .then_branch = then_branch, .else_capture = else_capture, .else_branch = else_branch };
    }

    fn parseBranch(self: *Parser) Error!ast.Branch {
        const c = self.peek() orelse return self.fail("unexpected end of file in branch", .{});

        // Block with template nodes: { ... }
        if (c == '{') {
            return .{ .nodes = try self.parseBracedNodes() };
        }

        // Element branch: <tag>...</tag>
        if (c == '<' and !self.check("</")) {
            const elem = try self.allocator.create(ast.Element);
            elem.* = try self.parseElement();
            return .{ .element = elem };
        }

        // Component call branch: @Name(args)
        if (c == '@') {
            return .{ .component_call = try self.parseComponentCall() };
        }

        // Nested if: if (cond) branch else branch
        if (self.check("if ") or self.check("if(")) {
            const if_expr = try self.allocator.create(ast.IfExpr);
            if_expr.* = try self.parseIfExpr();
            return .{ .if_expr = if_expr };
        }

        // Zig code branch (until else or })
        return .{ .zig_code = try self.parseZigCodeUntilBranchEnd(false) };
    }

    fn parseSwitchBranchBody(self: *Parser) Error!ast.Branch {
        const c = self.peek() orelse return self.fail("unexpected end of file in branch", .{});

        // Block with template nodes: { ... }
        if (c == '{') {
            return .{ .nodes = try self.parseBracedNodes() };
        }

        // Element branch: <tag>...</tag>
        if (c == '<' and !self.check("</")) {
            const elem = try self.allocator.create(ast.Element);
            elem.* = try self.parseElement();
            return .{ .element = elem };
        }

        // Component call branch: @Name(args)
        if (c == '@') {
            return .{ .component_call = try self.parseComponentCall() };
        }

        // Zig code branch (until comma or } for switch)
        return .{ .zig_code = try self.parseZigCodeUntilBranchEnd(true) };
    }

    // =========================================================================
    // Component call: @Name(args)
    // =========================================================================

    fn parseComponentCall(self: *Parser) Error!ast.ComponentCall {
        const loc = self.location();
        if (!self.match("@")) return self.fail("expected '@' for component call", .{});

        const name = try self.parseDottedIdentifier();
        self.skipSpaces();

        // Args are optional (e.g. @children has no parens)
        var args: []const u8 = "";
        if (self.match("(")) {
            args = try self.parseZigCodeBalanced(1);
            if (!self.match(")")) return self.fail("expected ')' after component arguments", .{});
        }

        // Optional children block: @Name(args) { ... }
        // Only skip spaces (not newlines) for lookahead - preserve newlines for block detection
        self.skipSpaces();
        var children: []const ast.Node = &.{};
        if (self.match("{")) {
            children = try self.parseNodes(true); // at_block_start = true
            self.skipWhitespace();
            if (!self.match("}")) return self.fail("expected '}}' to close component children block", .{});
        }

        return .{
            .name = name,
            .args = args,
            .children = children,
            .loc = loc,
        };
    }

    /// Parse identifier with optional dots: foo, foo.bar, foo.bar.baz
    fn parseDottedIdentifier(self: *Parser) Error![]const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') {
                _ = self.advance();
            } else {
                break;
            }
        }
        if (self.pos == start) return self.fail("expected component name", .{});
        return self.source[start..self.pos];
    }

    // =========================================================================
    // Inline for: for (iter) |cap| branch
    // =========================================================================

    fn parseForExpr(self: *Parser) Error!ast.ForExpr {
        _ = self.match("for");
        self.skipWhitespace();
        const iterable = try self.parseParenExpr();
        self.skipWhitespace();
        const captures = try self.parseCaptures();
        self.skipWhitespace();
        const body = try self.parseBranch();

        return .{ .iterable = iterable, .captures = captures, .body = body };
    }

    // =========================================================================
    // Block-level if: if (cond) { ... } else { ... }
    // =========================================================================

    fn parseIfStatement(self: *Parser) Error!ast.IfStatement {
        const loc = self.location();
        _ = self.match("if");
        self.skipSpaces();

        const condition = try self.parseParenExpr();
        self.skipSpaces();

        // Optional capture: |val|
        const capture: ?[]const u8 = if (self.peek() == @as(u8, '|'))
            try self.parseCaptures()
        else
            null;

        self.skipWhitespace();
        const then_body = try self.parseBracedNodes();

        const pos_after_then = self.pos;
        self.skipWhitespace();

        var else_capture: ?[]const u8 = null;
        const else_body: ?[]const ast.Node = if (self.match("else")) blk: {
            self.skipWhitespace();
            // Optional else capture: else |err|
            if (self.peek() == @as(u8, '|')) {
                else_capture = try self.parseCaptures();
                self.skipWhitespace();
            }
            if (self.check("if ") or self.check("if(")) {
                const nested_if = try self.parseIfStatement();
                const nodes = try self.allocator.alloc(ast.Node, 1);
                nodes[0] = .{ .if_stmt = nested_if };
                break :blk nodes;
            }
            break :blk try self.parseBracedNodes();
        } else blk: {
            self.pos = pos_after_then;
            break :blk null;
        };

        return .{ .condition = condition, .capture = capture, .then_body = then_body, .else_capture = else_capture, .else_body = else_body, .loc = loc };
    }

    // =========================================================================
    // Block-level for: for (iter) |cap| { ... }
    // =========================================================================

    fn parseForStatement(self: *Parser) Error!ast.ForStatement {
        const loc = self.location();
        _ = self.match("for");
        self.skipSpaces();

        const iterable = try self.parseParenExpr();
        self.skipSpaces();
        const captures = try self.parseCaptures();
        self.skipWhitespace();
        const body = try self.parseBracedNodes();

        return .{ .iterable = iterable, .captures = captures, .body = body, .loc = loc };
    }

    // =========================================================================
    // Block-level switch: switch (expr) { .case => { ... }, ... }
    // =========================================================================

    fn parseSwitchStatement(self: *Parser) Error!ast.SwitchStatement {
        const loc = self.location();
        _ = self.match("switch");
        self.skipSpaces();

        const value = try self.parseParenExpr();
        self.skipWhitespace();

        if (!self.match("{")) return self.fail("expected '{{' to start switch body", .{});
        var cases: std.ArrayList(ast.SwitchCase) = .empty;

        while (true) {
            self.skipWhitespace();
            if (self.peek() == @as(u8, '}')) break;
            try cases.append(self.allocator, try self.parseSwitchCase());
            self.skipWhitespace();
            _ = self.match(",");
        }

        if (!self.match("}")) return self.fail("expected '}}' to close switch body", .{});
        return .{ .value = value, .cases = cases.items, .loc = loc };
    }

    fn parseSwitchCase(self: *Parser) Error!ast.SwitchCase {
        const pattern = try self.parseSwitchPattern();
        self.skipSpaces();
        if (!self.match("=>")) return self.fail("expected '=>' after switch pattern", .{});
        self.skipSpaces();

        const capture: ?[]const u8 = if (self.peek() == @as(u8, '|'))
            try self.parseCaptures()
        else
            null;

        self.skipWhitespace();
        const body: ast.SwitchCase.Body = if (self.peek() == @as(u8, '{'))
            .{ .nodes = try self.parseBracedNodes() }
        else
            .{ .branch = try self.parseBranch() };

        return .{ .pattern = pattern, .capture = capture, .body = body };
    }

    fn parseSwitchPattern(self: *Parser) Error![]const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            // Pattern ends at | (capture) or = (arrow)
            if (c == '|') break;
            if (c == '=' and self.peekAhead(1) == @as(u8, '>')) break;
            if (c == '{' or c == '}') break;
            _ = self.advance();
        }
        const pattern = std.mem.trim(u8, self.source[start..self.pos], " \t\n\r");
        if (pattern.len == 0) return self.fail("expected switch pattern", .{});
        return pattern;
    }

    // =========================================================================
    // Inline switch: switch (expr) { .case => branch, ... }
    // =========================================================================

    fn parseSwitchExpr(self: *Parser) Error!ast.SwitchExpr {
        _ = self.match("switch");
        self.skipWhitespace();
        const value = try self.parseParenExpr();
        self.skipWhitespace();

        if (!self.match("{")) return self.fail("expected '{{' after switch expression", .{});

        var cases: std.ArrayList(ast.SwitchBranch) = .empty;
        while (true) {
            self.skipWhitespace();
            if (self.peek() == @as(u8, '}')) break;
            try cases.append(self.allocator, try self.parseSwitchBranch());
            self.skipWhitespace();
            if (!self.match(",")) break;
        }

        self.skipWhitespace();
        if (!self.match("}")) return self.fail("expected '}}' to close switch", .{});

        return .{ .value = value, .cases = cases.items };
    }

    fn parseSwitchBranch(self: *Parser) Error!ast.SwitchBranch {
        const pattern = try self.parseSwitchPattern();
        self.skipWhitespace();
        if (!self.match("=>")) return self.fail("expected '=>' after switch pattern", .{});
        self.skipWhitespace();

        const capture: ?[]const u8 = if (self.peek() == @as(u8, '|'))
            try self.parseCaptures()
        else
            null;

        self.skipWhitespace();
        return .{ .pattern = pattern, .capture = capture, .body = try self.parseSwitchBranchBody() };
    }

    // =========================================================================
    // Zig code parsing - balance braces, respect strings
    // =========================================================================

    /// Parse Zig code, balancing braces. Starts with `depth` open parens/braces.
    fn parseZigCodeBalanced(self: *Parser, initial_depth: usize) Error![]const u8 {
        const start = self.pos;
        var paren_depth: usize = initial_depth;
        var brace_depth: usize = 0;

        while (self.peek()) |c| {
            // Handle string literals
            if (c == '"') {
                self.skipQuoted('"');
                continue;
            }

            // Handle char literals
            if (c == '\'') {
                self.skipQuoted('\'');
                continue;
            }

            // Track parens
            if (c == '(') {
                paren_depth += 1;
                _ = self.advance();
                continue;
            }
            if (c == ')') {
                if (paren_depth == 0) break;
                paren_depth -= 1;
                if (paren_depth == 0 and initial_depth > 0) break;
                _ = self.advance();
                continue;
            }

            // Track braces
            if (c == '{') {
                brace_depth += 1;
                _ = self.advance();
                continue;
            }
            if (c == '}') {
                if (brace_depth == 0) break;
                brace_depth -= 1;
                _ = self.advance();
                continue;
            }

            _ = self.advance();
        }

        return std.mem.trim(u8, self.source[start..self.pos], " \t\n\r");
    }

    /// Parse Zig code until we hit `else` or `}` at depth 0.
    /// If stop_at_comma is true, also stop at `,` at depth 0 (for switch branches).
    fn parseZigCodeUntilBranchEnd(self: *Parser, stop_at_comma: bool) Error![]const u8 {
        const start = self.pos;
        var brace_depth: usize = 0;
        var paren_depth: usize = 0;

        while (self.peek()) |c| {
            // Handle strings
            if (c == '"') {
                self.skipQuoted('"');
                continue;
            }

            // Handle char literals
            if (c == '\'') {
                self.skipQuoted('\'');
                continue;
            }

            // Check for `else` keyword at depth 0
            if (brace_depth == 0 and paren_depth == 0 and self.check("else")) {
                break;
            }

            // Stop at comma for switch branches
            if (stop_at_comma and brace_depth == 0 and paren_depth == 0 and c == ',') {
                break;
            }

            // Track depth
            if (c == '(') paren_depth += 1;
            if (c == ')') paren_depth -|= 1;
            if (c == '{') brace_depth += 1;
            if (c == '}') {
                if (brace_depth == 0) break;
                brace_depth -= 1;
            }

            _ = self.advance();
        }

        return std.mem.trim(u8, self.source[start..self.pos], " \t\n\r");
    }

    fn skipQuoted(self: *Parser, quote: u8) void {
        _ = self.advance(); // opening quote
        while (self.peek()) |c| {
            if (c == '\\') {
                _ = self.advance();
                _ = self.advance();
            } else if (c == quote) {
                _ = self.advance();
                break;
            } else {
                _ = self.advance();
            }
        }
    }

    // =========================================================================
    // Text and comments
    // =========================================================================

    fn parseText(self: *Parser) Error!ast.Text {
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == '<' or c == '{' or c == '}') break;
            _ = self.advance();
        }
        return .{ .content = self.source[start..self.pos] };
    }

    fn skipComment(self: *Parser) Error!void {
        if (self.match("<!--")) {
            while (!self.check("-->")) {
                if (self.advance() == null) return self.fail("unexpected end of file in comment", .{});
            }
            _ = self.match("-->");
        }
    }

    fn checkDoctypeInsensitive(self: *Parser) bool {
        const prefix = "<!DOCTYPE";
        if (self.pos + prefix.len > self.source.len) return false;
        const slice = self.source[self.pos .. self.pos + prefix.len];
        return std.ascii.eqlIgnoreCase(slice, prefix);
    }

    fn parseDoctype(self: *Parser) Error!ast.Doctype {
        // Skip "<!DOCTYPE" (case insensitive)
        self.pos += 9;
        self.col += 9;

        self.skipSpaces();

        // Parse the doctype value (e.g., "html")
        const start = self.pos;
        while (self.peek()) |ch| {
            if (ch == '>' or std.ascii.isWhitespace(ch)) break;
            _ = self.advance();
        }
        const value = self.source[start..self.pos];

        self.skipSpaces();

        if (!self.match(">")) return self.fail("expected '>' to close DOCTYPE", .{});

        return .{ .value = value };
    }
};

// =========================================================================
// Tests
// =========================================================================

test "parse simple template" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\pub templ hello(name: []const u8) {
        \\    <div class="greeting">
        \\        Hello, {name}!
        \\    </div>
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    try std.testing.expectEqualStrings("hello", template.name);
    try std.testing.expect(template.is_public);
    try std.testing.expectEqual(@as(usize, 1), template.body.len);
}

test "parse inline if with elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test(show: bool) {
        \\    {if (show) <span>visible</span> else <span>hidden</span>}
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    try std.testing.expectEqual(@as(usize, 1), template.body.len);
    const expr = template.body[0].expr;
    try std.testing.expect(expr.content == .if_expr);

    const if_expr = expr.content.if_expr;
    try std.testing.expectEqualStrings("show", if_expr.condition);

    // Then branch is an element
    try std.testing.expect(if_expr.then_branch == .element);
    try std.testing.expectEqualStrings("span", if_expr.then_branch.element.tag);

    // Else branch exists and is an element
    try std.testing.expect(if_expr.else_branch != null);
    try std.testing.expect(if_expr.else_branch.? == .element);
    try std.testing.expectEqualStrings("span", if_expr.else_branch.?.element.tag);
}

test "parse inline if with zig code branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test(value: ?[]const u8) {
        \\    {if (value) |v| v else "default"}
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const if_expr = template.body[0].expr.content.if_expr;
    try std.testing.expectEqualStrings("value", if_expr.condition);

    // Capture is parsed
    try std.testing.expectEqualStrings("v", if_expr.capture.?);

    // Then branch is zig code (the captured variable)
    try std.testing.expect(if_expr.then_branch == .zig_code);
    try std.testing.expectEqualStrings("v", if_expr.then_branch.zig_code);

    // Else branch is zig code
    try std.testing.expect(if_expr.else_branch.? == .zig_code);
    try std.testing.expectEqualStrings("\"default\"", if_expr.else_branch.?.zig_code);
}

test "parse inline if without else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test(show: bool) {
        \\    {if (show) <span>visible</span>}
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const if_expr = template.body[0].expr.content.if_expr;
    try std.testing.expect(if_expr.then_branch == .element);
    try std.testing.expect(if_expr.else_branch == null);
}

test "parse inline else if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test(x: i32) {
        \\    {if (x == 1) <span>one</span> else if (x == 2) <span>two</span> else <span>other</span>}
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    // First if: x == 1
    const if_expr = template.body[0].expr.content.if_expr;
    try std.testing.expectEqualStrings("x == 1", if_expr.condition);
    try std.testing.expect(if_expr.then_branch == .element);
    try std.testing.expectEqualStrings("span", if_expr.then_branch.element.tag);

    // Else branch is a nested if
    try std.testing.expect(if_expr.else_branch != null);
    try std.testing.expect(if_expr.else_branch.? == .if_expr);

    // Nested if: x == 2
    const nested = if_expr.else_branch.?.if_expr;
    try std.testing.expectEqualStrings("x == 2", nested.condition);
    try std.testing.expect(nested.then_branch == .element);
    try std.testing.expectEqualStrings("span", nested.then_branch.element.tag);

    // Final else
    try std.testing.expect(nested.else_branch != null);
    try std.testing.expect(nested.else_branch.? == .element);
    try std.testing.expectEqualStrings("span", nested.else_branch.?.element.tag);
}

test "parse inline for with element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test(items: []const []const u8) {
        \\    {for (items) |item| <li>{item}</li>}
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    try std.testing.expectEqual(@as(usize, 1), template.body.len);
    const expr = template.body[0].expr;
    try std.testing.expect(expr.content == .for_expr);

    const for_expr = expr.content.for_expr;
    try std.testing.expectEqualStrings("items", for_expr.iterable);
    try std.testing.expectEqualStrings("item", for_expr.captures);
    try std.testing.expect(for_expr.body == .element);
    try std.testing.expectEqualStrings("li", for_expr.body.element.tag);
}

test "parse inline for with index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test(items: []const []const u8) {
        \\    {for (items, 0..) |item, idx| <li>{idx}: {item}</li>}
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const for_expr = template.body[0].expr.content.for_expr;
    try std.testing.expectEqualStrings("items, 0..", for_expr.iterable);
    try std.testing.expectEqualStrings("item, idx", for_expr.captures);
}

test "parse block for statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ list(items: []const []const u8) {
        \\    <ul>
        \\        for (items) |item| {
        \\            <li>{item}</li>
        \\        }
        \\    </ul>
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    try std.testing.expectEqual(@as(usize, 1), template.body.len);
    const ul = template.body[0].element;
    try std.testing.expectEqualStrings("ul", ul.tag);

    // ul contains a for statement
    try std.testing.expectEqual(@as(usize, 1), ul.children.len);
    try std.testing.expect(ul.children[0] == .for_stmt);

    const for_stmt = ul.children[0].for_stmt;
    try std.testing.expectEqualStrings("items", for_stmt.iterable);
    try std.testing.expectEqualStrings("item", for_stmt.captures);
    try std.testing.expectEqual(@as(usize, 1), for_stmt.body.len);
}

test "parse block if statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test(show: bool) {
        \\    if (show) {
        \\        <div>shown</div>
        \\    } else {
        \\        <span>hidden</span>
        \\    }
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    try std.testing.expectEqual(@as(usize, 1), template.body.len);
    try std.testing.expect(template.body[0] == .if_stmt);

    const if_stmt = template.body[0].if_stmt;
    try std.testing.expectEqualStrings("show", if_stmt.condition);
    try std.testing.expectEqual(@as(usize, 1), if_stmt.then_body.len);
    try std.testing.expect(if_stmt.else_body != null);
    try std.testing.expectEqual(@as(usize, 1), if_stmt.else_body.?.len);
}

test "parse else if chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test(x: i32) {
        \\    if (x == 1) {
        \\        <span>one</span>
        \\    } else if (x == 2) {
        \\        <span>two</span>
        \\    } else {
        \\        <span>other</span>
        \\    }
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const if_stmt = template.body[0].if_stmt;
    try std.testing.expectEqualStrings("x == 1", if_stmt.condition);

    // else body contains a single if_stmt (the else-if)
    try std.testing.expect(if_stmt.else_body != null);
    try std.testing.expectEqual(@as(usize, 1), if_stmt.else_body.?.len);
    try std.testing.expect(if_stmt.else_body.?[0] == .if_stmt);

    const else_if = if_stmt.else_body.?[0].if_stmt;
    try std.testing.expectEqualStrings("x == 2", else_if.condition);
    try std.testing.expect(else_if.else_body != null);
}

test "parse nested inline expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test(user: User) {
        \\    <div>
        \\        {if (user.admin) <span class="badge">{user.role}</span>}
        \\    </div>
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const div = template.body[0].element;
    const if_expr = div.children[0].expr.content.if_expr;
    const span = if_expr.then_branch.element;

    try std.testing.expectEqualStrings("span", span.tag);
    try std.testing.expectEqual(@as(usize, 1), span.attributes.len);
    try std.testing.expectEqualStrings("class", span.attributes[0].name);

    // span has a child expression
    try std.testing.expectEqual(@as(usize, 1), span.children.len);
    try std.testing.expect(span.children[0] == .expr);
}

test "parse self-closing element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test() {
        \\    <div>
        \\        <br/>
        \\        <input type="text" />
        \\        <img src="foo.png"/>
        \\    </div>
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const div = template.body[0].element;
    try std.testing.expectEqual(@as(usize, 3), div.children.len);

    const br = div.children[0].element;
    try std.testing.expectEqualStrings("br", br.tag);
    try std.testing.expect(br.self_closing);
    try std.testing.expectEqual(@as(usize, 0), br.children.len);

    const input = div.children[1].element;
    try std.testing.expectEqualStrings("input", input.tag);
    try std.testing.expect(input.self_closing);

    const img = div.children[2].element;
    try std.testing.expectEqualStrings("img", img.tag);
    try std.testing.expect(img.self_closing);
}

test "parse single-quoted attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test() {
        \\    <div class='foo' data-value='bar "baz"'></div>
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const div = template.body[0].element;
    try std.testing.expectEqual(@as(usize, 2), div.attributes.len);

    try std.testing.expectEqualStrings("class", div.attributes[0].name);
    try std.testing.expectEqualStrings("foo", div.attributes[0].value.static);

    try std.testing.expectEqualStrings("data-value", div.attributes[1].name);
    try std.testing.expectEqualStrings("bar \"baz\"", div.attributes[1].value.static);
}

test "parse dynamic attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test(cls: []const u8, url: []const u8) {
        \\    <div class={cls} data-url={url}></div>
        \\    <a href={buildUrl(base, path)}></a>
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const div = template.body[0].element;
    try std.testing.expectEqual(@as(usize, 2), div.attributes.len);

    try std.testing.expectEqualStrings("class", div.attributes[0].name);
    try std.testing.expect(div.attributes[0].value == .dynamic);
    try std.testing.expectEqualStrings("cls", div.attributes[0].value.dynamic);

    try std.testing.expectEqualStrings("data-url", div.attributes[1].name);
    try std.testing.expectEqualStrings("url", div.attributes[1].value.dynamic);

    const a = template.body[1].element;
    try std.testing.expectEqualStrings("href", a.attributes[0].name);
    try std.testing.expectEqualStrings("buildUrl(base, path)", a.attributes[0].value.dynamic);
}

test "parse boolean attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test() {
        \\    <input type="checkbox" checked disabled readonly />
        \\    <button disabled></button>
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const input = template.body[0].element;
    try std.testing.expectEqual(@as(usize, 4), input.attributes.len);

    try std.testing.expectEqualStrings("type", input.attributes[0].name);
    try std.testing.expect(input.attributes[0].value == .static);

    try std.testing.expectEqualStrings("checked", input.attributes[1].name);
    try std.testing.expect(input.attributes[1].value == .none);

    try std.testing.expectEqualStrings("disabled", input.attributes[2].name);
    try std.testing.expect(input.attributes[2].value == .none);

    try std.testing.expectEqualStrings("readonly", input.attributes[3].name);
    try std.testing.expect(input.attributes[3].value == .none);

    const button = template.body[1].element;
    try std.testing.expectEqualStrings("disabled", button.attributes[0].name);
    try std.testing.expect(button.attributes[0].value == .none);
}

test "parse zig code with nested braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test(opts: Options) {
        \\    <div class={getClass(.{ .primary = true, .large = opts.large })}></div>
        \\    {formatStruct(.{ .name = "test", .value = 42 })}
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const div = template.body[0].element;
    const class_attr = div.attributes[0];
    try std.testing.expectEqualStrings("class", class_attr.name);
    try std.testing.expectEqualStrings("getClass(.{ .primary = true, .large = opts.large })", class_attr.value.dynamic);

    const expr = template.body[1].expr;
    try std.testing.expect(expr.content == .zig_code);
    try std.testing.expectEqualStrings("formatStruct(.{ .name = \"test\", .value = 42 })", expr.content.zig_code);
}

test "parse zig code with strings containing braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test() {
        \\    {"{"}
        \\    {"}"}
        \\    {"{ nested }"}
        \\    {fmt("{s}: {d}", .{name, value})}
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    try std.testing.expectEqual(@as(usize, 4), template.body.len);

    try std.testing.expectEqualStrings("\"{\"", template.body[0].expr.content.zig_code);
    try std.testing.expectEqualStrings("\"}\"", template.body[1].expr.content.zig_code);
    try std.testing.expectEqualStrings("\"{ nested }\"", template.body[2].expr.content.zig_code);
    try std.testing.expectEqualStrings("fmt(\"{s}: {d}\", .{name, value})", template.body[3].expr.content.zig_code);
}

test "parse component call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ Page(user: User) {
        \\    <div>
        \\        @Header()
        \\        @UserCard(user)
        \\        @Footer()
        \\    </div>
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const div = template.body[0].element;
    try std.testing.expectEqual(@as(usize, 3), div.children.len);

    const header = div.children[0].component_call;
    try std.testing.expectEqualStrings("Header", header.name);
    try std.testing.expectEqualStrings("", header.args);

    const user_card = div.children[1].component_call;
    try std.testing.expectEqualStrings("UserCard", user_card.name);
    try std.testing.expectEqualStrings("user", user_card.args);

    const footer = div.children[2].component_call;
    try std.testing.expectEqualStrings("Footer", footer.name);
    try std.testing.expectEqualStrings("", footer.args);
}

test "parse component call in for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ PostList(posts: []const Post) {
        \\    for (posts) |post| {
        \\        @PostCard(post)
        \\    }
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const for_stmt = template.body[0].for_stmt;
    try std.testing.expectEqual(@as(usize, 1), for_stmt.body.len);

    const call = for_stmt.body[0].component_call;
    try std.testing.expectEqualStrings("PostCard", call.name);
    try std.testing.expectEqualStrings("post", call.args);
}

test "parse inline if with component calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ Badge(user: User) {
        \\    {if (user.admin) @AdminBadge(user) else @UserBadge(user)}
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const if_expr = template.body[0].expr.content.if_expr;
    try std.testing.expectEqualStrings("user.admin", if_expr.condition);

    try std.testing.expect(if_expr.then_branch == .component_call);
    try std.testing.expectEqualStrings("AdminBadge", if_expr.then_branch.component_call.name);

    try std.testing.expect(if_expr.else_branch.? == .component_call);
    try std.testing.expectEqualStrings("UserBadge", if_expr.else_branch.?.component_call.name);
}

test "parse file with interleaved zig functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\const std = @import("std");
        \\
        \\pub fn helper(x: i32) i32 {
        \\    return x * 2;
        \\}
        \\
        \\pub templ First() {
        \\    <div>first</div>
        \\}
        \\
        \\fn privateHelper() void {}
        \\
        \\pub templ Second() {
        \\    <div>second</div>
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const file = try parser.parseFile();

    // Should have 2 templates
    try std.testing.expectEqual(@as(usize, 2), file.templates.len);
    try std.testing.expectEqualStrings("First", file.templates[0].name);
    try std.testing.expectEqualStrings("Second", file.templates[1].name);

    // Header should contain all Zig code
    try std.testing.expect(std.mem.indexOf(u8, file.header, "const std = @import") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.header, "pub fn helper") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.header, "fn privateHelper") != null);
}

test "parse dotted component call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ Page() {
        \\    @components.Header()
        \\    @ui.cards.UserCard(user)
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const header = template.body[0].component_call;
    try std.testing.expectEqualStrings("components.Header", header.name);
    try std.testing.expectEqualStrings("", header.args);

    const user_card = template.body[1].component_call;
    try std.testing.expectEqualStrings("ui.cards.UserCard", user_card.name);
    try std.testing.expectEqualStrings("user", user_card.args);
}

test "parse block switch statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ Status(status: Status) {
        \\    switch (status) {
        \\        .active => {
        \\            <span class="green">Active</span>
        \\        },
        \\        .pending => {
        \\            <span class="yellow">Pending</span>
        \\        },
        \\        else => {
        \\            <span>Unknown</span>
        \\        },
        \\    }
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    try std.testing.expectEqual(@as(usize, 1), template.body.len);
    const switch_stmt = template.body[0].switch_stmt;
    try std.testing.expectEqualStrings("status", switch_stmt.value);
    try std.testing.expectEqual(@as(usize, 3), switch_stmt.cases.len);

    try std.testing.expectEqualStrings(".active", switch_stmt.cases[0].pattern);
    try std.testing.expectEqualStrings(".pending", switch_stmt.cases[1].pattern);
    try std.testing.expectEqualStrings("else", switch_stmt.cases[2].pattern);
}

test "parse switch with capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ Value(val: Value) {
        \\    switch (val) {
        \\        .int => |n| {
        \\            <span>{n}</span>
        \\        },
        \\        .string => |s| {
        \\            <span>{s}</span>
        \\        },
        \\    }
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const switch_stmt = template.body[0].switch_stmt;
    try std.testing.expectEqualStrings("n", switch_stmt.cases[0].capture.?);
    try std.testing.expectEqualStrings("s", switch_stmt.cases[1].capture.?);
}

test "parse switch with mixed block and non-block cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ Status(status: Status) {
        \\    switch (status) {
        \\        .active => <span>Active</span>,
        \\        .pending => {
        \\            <span>Pending</span>
        \\            <span>Please wait</span>
        \\        },
        \\        else => @Unknown(),
        \\    }
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const switch_stmt = template.body[0].switch_stmt;
    try std.testing.expectEqual(@as(usize, 3), switch_stmt.cases.len);

    // First case: single element (branch)
    try std.testing.expect(switch_stmt.cases[0].body == .branch);
    try std.testing.expect(switch_stmt.cases[0].body.branch == .element);

    // Second case: block with nodes
    try std.testing.expect(switch_stmt.cases[1].body == .nodes);
    try std.testing.expectEqual(@as(usize, 2), switch_stmt.cases[1].body.nodes.len);

    // Third case: component call (branch)
    try std.testing.expect(switch_stmt.cases[2].body == .branch);
    try std.testing.expect(switch_stmt.cases[2].body.branch == .component_call);
}

test "parse inline switch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ Badge(role: Role) {
        \\    {switch (role) { .admin => <span>Admin</span>, .user => <span>User</span>, else => <span>Guest</span> }}
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const switch_expr = template.body[0].expr.content.switch_expr;
    try std.testing.expectEqualStrings("role", switch_expr.value);
    try std.testing.expectEqual(@as(usize, 3), switch_expr.cases.len);

    try std.testing.expectEqualStrings(".admin", switch_expr.cases[0].pattern);
    try std.testing.expect(switch_expr.cases[0].body == .element);
}

test "parse raw expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test(html: []const u8) {
        \\    <div>{!html}</div>
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const div = template.body[0].element;
    const expr = div.children[0].expr;
    try std.testing.expect(expr.raw);
    try std.testing.expectEqualStrings("html", expr.content.zig_code);
}

test "parse escaped vs raw" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test(text: []const u8) {
        \\    {text}
        \\    {!text}
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    const escaped = template.body[0].expr;
    try std.testing.expect(!escaped.raw);

    const raw = template.body[1].expr;
    try std.testing.expect(raw.raw);
}

test "parse doctype" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test() {
        \\    <!DOCTYPE html>
        \\    <html></html>
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    try std.testing.expectEqual(@as(usize, 2), template.body.len);
    try std.testing.expect(template.body[0] == .doctype);
    try std.testing.expectEqualStrings("html", template.body[0].doctype.value);
    try std.testing.expect(template.body[1] == .element);
}

test "parse doctype case insensitive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test() {
        \\    <!doctype html>
        \\    <html></html>
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    try std.testing.expectEqual(@as(usize, 2), template.body.len);
    try std.testing.expect(template.body[0] == .doctype);
    try std.testing.expectEqualStrings("html", template.body[0].doctype.value);
}

test "parse multiline html attributes - issue #14" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\templ test() {
        \\    <button type="button"
        \\            data-action="delete"
        \\            class="btn">
        \\        Delete
        \\    </button>
        \\}
    ;

    var parser = Parser.init(arena.allocator(), source);
    const template = try parser.parseTemplate();

    try std.testing.expectEqual(@as(usize, 1), template.body.len);
    const element = template.body[0].element;
    try std.testing.expectEqualStrings("button", element.tag);
    try std.testing.expectEqual(@as(usize, 3), element.attributes.len);
    try std.testing.expectEqualStrings("type", element.attributes[0].name);
    try std.testing.expectEqualStrings("data-action", element.attributes[1].name);
    try std.testing.expectEqualStrings("class", element.attributes[2].name);
}
