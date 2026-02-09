const std = @import("std");
const ast = @import("ast.zig");

pub const Generator = struct {
    output: *std.Io.Writer,
    indent: usize,

    pub fn init(output: *std.Io.Writer) Generator {
        return .{
            .output = output,
            .indent = 0,
        };
    }

    pub fn generateFile(self: *Generator, file: ast.TemplateFile) std.Io.Writer.Error!void {
        // Write user's header (imports, consts, etc.)
        if (file.header.len > 0) {
            try self.output.writeAll(file.header);
            try self.output.writeAll("\n\n");
        }

        for (file.templates) |template| {
            try self.generate(template);
            try self.output.writeAll("\n");
        }
    }

    pub fn generate(self: *Generator, template: ast.Template) std.Io.Writer.Error!void {
        // Write function signature
        if (template.is_public) {
            try self.output.writeAll("pub ");
        }
        try self.output.writeAll("fn ");
        try self.output.writeAll(template.name);
        try self.output.writeAll("(");
        try self.output.writeAll(template.params);
        if (template.params.len > 0) {
            try self.output.writeAll(", ");
        }
        try self.output.writeAll("writer: *std.Io.Writer) std.Io.Writer.Error!void {\n");

        self.indent += 1;

        // Generate body
        for (template.body) |node| {
            try self.generateNode(node);
        }

        self.indent -= 1;
        try self.output.writeAll("}\n");
    }

    fn generateNode(self: *Generator, node: ast.Node) std.Io.Writer.Error!void {
        switch (node) {
            .element => |elem| try self.generateElement(elem),
            .text => |text| try self.generateText(text),
            .expr => |expr| try self.generateExpr(expr),
            .if_stmt => |stmt| try self.generateIfStmt(stmt),
            .for_stmt => |stmt| try self.generateForStmt(stmt),
            .component_call => |call| try self.generateComponentCall(call),
        }
    }

    fn generateElement(self: *Generator, elem: ast.Element) std.Io.Writer.Error!void {
        // Check if we have any dynamic attributes
        var has_dynamic = false;
        for (elem.attributes) |attr| {
            if (attr.value == .dynamic) {
                has_dynamic = true;
                break;
            }
        }

        // Opening tag start
        try self.writeIndent();
        try self.output.writeAll("try writer.writeAll(\"<");
        try self.output.writeAll(elem.tag);

        if (!has_dynamic) {
            // Simple case: all static attributes, write in one string
            for (elem.attributes) |attr| {
                switch (attr.value) {
                    .static => |val| {
                        try self.output.writeAll(" ");
                        try self.output.writeAll(attr.name);
                        try self.output.writeAll("=\\\"");
                        try self.writeEscapedForZig(val);
                        try self.output.writeAll("\\\"");
                    },
                    .none => {
                        try self.output.writeAll(" ");
                        try self.output.writeAll(attr.name);
                    },
                    .dynamic => {},
                }
            }

            if (elem.self_closing) {
                try self.output.writeAll("/>\");\n");
                return;
            }
            try self.output.writeAll(">\");\n");
        } else {
            // Has dynamic attributes - need to interleave
            try self.output.writeAll("\");\n");

            for (elem.attributes) |attr| {
                switch (attr.value) {
                    .static => |val| {
                        try self.writeIndent();
                        try self.output.writeAll("try writer.writeAll(\" ");
                        try self.output.writeAll(attr.name);
                        try self.output.writeAll("=\\\"");
                        try self.writeEscapedForZig(val);
                        try self.output.writeAll("\\\"\");\n");
                    },
                    .none => {
                        try self.writeIndent();
                        try self.output.writeAll("try writer.writeAll(\" ");
                        try self.output.writeAll(attr.name);
                        try self.output.writeAll("\");\n");
                    },
                    .dynamic => |expr| {
                        try self.writeIndent();
                        try self.output.writeAll("try zt.writeAttr(writer, \"");
                        try self.output.writeAll(attr.name);
                        try self.output.writeAll("\", ");
                        try self.output.writeAll(expr);
                        try self.output.writeAll(");\n");
                    },
                }
            }

            // Close opening tag
            try self.writeIndent();
            if (elem.self_closing) {
                try self.output.writeAll("try writer.writeAll(\"/>\");\n");
                return;
            }
            try self.output.writeAll("try writer.writeAll(\">\");\n");
        }

        // Children
        for (elem.children) |child| {
            try self.generateNode(child);
        }

        // Closing tag
        try self.writeIndent();
        try self.output.writeAll("try writer.writeAll(\"</");
        try self.output.writeAll(elem.tag);
        try self.output.writeAll(">\");\n");
    }

    fn generateText(self: *Generator, text: ast.Text) std.Io.Writer.Error!void {
        if (text.content.len == 0) return;

        try self.writeIndent();
        try self.output.writeAll("try writer.writeAll(\"");
        try self.writeEscapedForZig(text.content);
        try self.output.writeAll("\");\n");
    }

    fn generateExpr(self: *Generator, expr: ast.Expr) std.Io.Writer.Error!void {
        switch (expr.content) {
            .zig_code => |code| {
                try self.writeIndent();
                if (expr.raw) {
                    try self.output.writeAll("try zt.writeRaw(writer, ");
                } else {
                    try self.output.writeAll("try zt.writeEscaped(writer, ");
                }
                try self.output.writeAll(code);
                try self.output.writeAll(");\n");
            },
            .if_expr => |if_expr| try self.generateIfExpr(if_expr, expr.raw),
            .for_expr => |for_expr| try self.generateForExpr(for_expr, expr.raw),
            .element => |elem| try self.generateElement(elem.*),
        }
    }

    fn generateIfExpr(self: *Generator, if_expr: ast.IfExpr, raw: bool) std.Io.Writer.Error!void {
        try self.writeIndent();
        try self.output.writeAll("if (");
        try self.output.writeAll(if_expr.condition);
        try self.output.writeAll(") {\n");

        self.indent += 1;
        try self.generateBranch(if_expr.then_branch, raw);
        self.indent -= 1;

        if (if_expr.else_branch) |else_branch| {
            try self.writeIndent();
            try self.output.writeAll("} else {\n");
            self.indent += 1;
            try self.generateBranch(else_branch, raw);
            self.indent -= 1;
        }

        try self.writeIndent();
        try self.output.writeAll("}\n");
    }

    fn generateForExpr(self: *Generator, for_expr: ast.ForExpr, raw: bool) std.Io.Writer.Error!void {
        try self.writeIndent();
        try self.output.writeAll("for (");
        try self.output.writeAll(for_expr.iterable);
        try self.output.writeAll(") |");
        try self.output.writeAll(for_expr.captures);
        try self.output.writeAll("| {\n");

        self.indent += 1;
        try self.generateBranch(for_expr.body, raw);
        self.indent -= 1;

        try self.writeIndent();
        try self.output.writeAll("}\n");
    }

    fn generateBranch(self: *Generator, branch: ast.Branch, raw: bool) std.Io.Writer.Error!void {
        switch (branch) {
            .element => |elem| try self.generateElement(elem.*),
            .component_call => |call| try self.generateComponentCall(call),
            .zig_code => |code| {
                try self.writeIndent();
                if (raw) {
                    try self.output.writeAll("try zt.writeRaw(writer, ");
                } else {
                    try self.output.writeAll("try zt.writeEscaped(writer, ");
                }
                try self.output.writeAll(code);
                try self.output.writeAll(");\n");
            },
        }
    }

    fn generateComponentCall(self: *Generator, call: ast.ComponentCall) std.Io.Writer.Error!void {
        try self.writeIndent();
        try self.output.writeAll("try ");
        try self.output.writeAll(call.name);
        try self.output.writeAll("(");
        if (call.args.len > 0) {
            try self.output.writeAll(call.args);
            try self.output.writeAll(", ");
        }
        try self.output.writeAll("writer);\n");
    }

    fn generateIfStmt(self: *Generator, stmt: ast.IfStatement) std.Io.Writer.Error!void {
        try self.writeIndent();
        try self.output.writeAll("if (");
        try self.output.writeAll(stmt.condition);
        try self.output.writeAll(") {\n");

        self.indent += 1;
        for (stmt.then_body) |node| {
            try self.generateNode(node);
        }
        self.indent -= 1;

        if (stmt.else_body) |else_body| {
            try self.writeIndent();
            try self.output.writeAll("} else {\n");
            self.indent += 1;
            for (else_body) |node| {
                try self.generateNode(node);
            }
            self.indent -= 1;
        }

        try self.writeIndent();
        try self.output.writeAll("}\n");
    }

    fn generateForStmt(self: *Generator, stmt: ast.ForStatement) std.Io.Writer.Error!void {
        try self.writeIndent();
        try self.output.writeAll("for (");
        try self.output.writeAll(stmt.iterable);
        try self.output.writeAll(") |");
        try self.output.writeAll(stmt.captures);
        try self.output.writeAll("| {\n");

        self.indent += 1;
        for (stmt.body) |node| {
            try self.generateNode(node);
        }
        self.indent -= 1;

        try self.writeIndent();
        try self.output.writeAll("}\n");
    }

    fn writeIndent(self: *Generator) std.Io.Writer.Error!void {
        for (0..self.indent) |_| {
            try self.output.writeAll("    ");
        }
    }

    fn writeEscapedForZig(self: *Generator, str: []const u8) std.Io.Writer.Error!void {
        for (str) |c| {
            switch (c) {
                '"' => try self.output.writeAll("\\\""),
                '\\' => try self.output.writeAll("\\\\"),
                '\n' => try self.output.writeAll("\\n"),
                '\r' => try self.output.writeAll("\\r"),
                '\t' => try self.output.writeAll("\\t"),
                else => try self.output.writeByte(c),
            }
        }
    }
};

// =========================================================================
// Tests
// =========================================================================

test "generate simple template" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

    const source =
        \\pub templ hello(name: []const u8) {
        \\    <div class="greeting">Hello</div>
        \\}
    ;

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, result, "pub fn hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<div class=\\\"greeting\\\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</div>") != null);
}

test "generate with expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

    const source =
        \\templ greet(name: []const u8) {
        \\    <span>{name}</span>
        \\}
    ;

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, result, "zt.writeEscaped(writer, name)") != null);
}

test "generate inline if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

    const source =
        \\templ test(show: bool) {
        \\    {if (show) <span>yes</span> else <span>no</span>}
        \\}
    ;

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, result, "if (show)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "} else {") != null);
}

test "generate for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

    const source =
        \\templ list(items: []const []const u8) {
        \\    <ul>
        \\        for (items) |item| {
        \\            <li>{item}</li>
        \\        }
        \\    </ul>
        \\}
    ;

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, result, "for (items) |item|") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<li>") != null);
}

test "generate component call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

    const source =
        \\templ Page(user: User) {
        \\    @Header()
        \\    @UserCard(user)
        \\}
    ;

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, result, "try Header(writer);") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try UserCard(user, writer);") != null);
}

test "generate dotted component call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

    const source =
        \\templ Page() {
        \\    @components.Header()
        \\    @ui.UserCard(user)
        \\}
    ;

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, result, "try components.Header(writer);") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try ui.UserCard(user, writer);") != null);
}

test "generate raw output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

    const source =
        \\templ test(html: []const u8) {
        \\    {html}
        \\    {!html}
        \\}
    ;

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, result, "zt.writeEscaped(writer, html)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "zt.writeRaw(writer, html)") != null);
}

test "generate inline for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

    const source =
        \\templ Tags(tags: []const []const u8) {
        \\    {for (tags) |tag| <span>{tag}</span>}
        \\}
    ;

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, result, "for (tags) |tag|") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<span>") != null);
}

test "generate inline for with index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

    const source =
        \\templ List(items: []const []const u8) {
        \\    {for (items, 0..) |item, idx| <li>{idx}: {item}</li>}
        \\}
    ;

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, result, "for (items, 0..) |item, idx|") != null);
}
