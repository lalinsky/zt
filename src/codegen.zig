const std = @import("std");
const ast = @import("ast.zig");

/// HTML void elements that cannot have children and must not have a closing tag.
/// https://html.spec.whatwg.org/multipage/syntax.html#void-elements
const void_elements = std.StaticStringMap(void).initComptime(.{
    .{ "area", {} },
    .{ "base", {} },
    .{ "br", {} },
    .{ "col", {} },
    .{ "embed", {} },
    .{ "hr", {} },
    .{ "img", {} },
    .{ "input", {} },
    .{ "link", {} },
    .{ "meta", {} },
    .{ "source", {} },
    .{ "track", {} },
    .{ "wbr", {} },
});

pub const Generator = struct {
    output: *std.Io.Writer,
    indent: usize,
    children_call_index: usize = 0,
    source_file: []const u8 = "",
    last_emitted_line: usize = 0,

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
        const has_children_param = bodyUsesChildren(template.body);
        const num_children_calls = countChildrenCalls(template.body);

        // Phase 1: Generate inner structs for component calls with children
        if (num_children_calls > 0) {
            self.children_call_index = 0;
            try self.generateInnerStructs(template.name, template.params, template.body);
        }

        // Phase 2: Generate the main struct
        if (template.is_public) {
            try self.output.writeAll("pub ");
        }
        try self.output.writeAll("const ");
        try self.output.writeAll(template.name);
        try self.output.writeAll(" = struct {\n");

        self.indent += 1;

        // _render: the actual implementation
        try self.writeIndent();
        try self.output.writeAll("fn _render(");
        try self.writeParams(template.params);
        // Implicit children param if template uses @children
        if (has_children_param) {
            if (template.params.len > 0) try self.output.writeAll(", ");
            try self.output.writeAll("children: zt.Component");
        }
        // Hidden params for component calls with children
        for (0..num_children_calls) |i| {
            if (template.params.len > 0 or has_children_param or i > 0) try self.output.writeAll(", ");
            try self.writeChildrenParamName(i);
            try self.output.writeAll(": zt.Component");
        }
        if (template.params.len > 0 or has_children_param or num_children_calls > 0) {
            try self.output.writeAll(", ");
        }
        try self.output.writeAll("writer: *std.Io.Writer) std.Io.Writer.Error!void {\n");

        self.indent += 1;
        if (template.params.len > 0) try self.writeParamDiscards(template.params);
        self.children_call_index = 0;
        for (template.body) |node| {
            try self.generateNode(node);
        }
        self.indent -= 1;

        try self.writeIndent();
        try self.output.writeAll("}\n\n");

        // _signature: captures template param types (+ children if used)
        try self.writeIndent();
        try self.output.writeAll("fn _signature(");
        try self.writeAnonymizedParams(template.params);
        if (has_children_param) {
            if (template.params.len > 0) try self.output.writeAll(", ");
            try self.output.writeAll("_: zt.Component");
        }
        try self.output.writeAll(") void {}\n\n");

        // Args, render, bind
        try self.writeArgsRenderBind(template.name, num_children_calls);

        self.indent -= 1;
        try self.output.writeAll("};\n");
    }

    /// Generate the Args type, render function, and bind function.
    fn writeArgsRenderBind(self: *Generator, template_name: []const u8, num_children_calls: usize) std.Io.Writer.Error!void {
        // Args
        try self.writeIndent();
        try self.output.writeAll("pub const Args = std.meta.ArgsTuple(@TypeOf(_signature));\n\n");

        // render
        try self.writeIndent();
        try self.output.writeAll("pub fn render(args: Args, writer: *std.Io.Writer) std.Io.Writer.Error!void {\n");
        self.indent += 1;
        // Bind inner structs
        for (0..num_children_calls) |i| {
            try self.writeIndent();
            try self.output.writeAll("const ");
            try self.writeChildrenParamName(i);
            try self.output.writeAll(" = ");
            try self.output.writeAll(template_name);
            try self.writeChildrenStructSuffix(i);
            try self.output.writeAll(".bind(&args);\n");
        }
        try self.writeIndent();
        try self.output.writeAll("return @call(.always_inline, _render, args ++ .{");
        for (0..num_children_calls) |i| {
            try self.writeChildrenParamName(i);
            try self.output.writeAll(", ");
        }
        try self.output.writeAll("writer});\n");
        self.indent -= 1;
        try self.writeIndent();
        try self.output.writeAll("}\n\n");

        // bind
        try self.writeIndent();
        try self.output.writeAll("pub fn bind(args: *const Args) zt.Component {\n");
        self.indent += 1;
        try self.writeIndent();
        try self.output.writeAll("return .{\n");
        self.indent += 1;
        try self.writeIndent();
        try self.output.writeAll(".ptr = @ptrCast(args),\n");
        try self.writeIndent();
        try self.output.writeAll(".renderFn = struct {\n");
        self.indent += 1;
        try self.writeIndent();
        try self.output.writeAll("fn f(ptr: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void {\n");
        self.indent += 1;
        try self.writeIndent();
        try self.output.writeAll("return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, writer);\n");
        self.indent -= 1;
        try self.writeIndent();
        try self.output.writeAll("}\n");
        self.indent -= 1;
        try self.writeIndent();
        try self.output.writeAll("}.f,\n");
        self.indent -= 1;
        try self.writeIndent();
        try self.output.writeAll("};\n");
        self.indent -= 1;
        try self.writeIndent();
        try self.output.writeAll("}\n");
    }

    /// Generate inner structs for all component calls with children in the body.
    fn generateInnerStructs(self: *Generator, parent_name: []const u8, params: []const ast.Parameter, nodes: []const ast.Node) std.Io.Writer.Error!void {
        for (nodes) |node| {
            switch (node) {
                .component_call => |call| {
                    if (call.children.len > 0) {
                        try self.generateOneInnerStruct(parent_name, params, call.children);
                    }
                },
                .element => |elem| try self.generateInnerStructs(parent_name, params, elem.children),
                .if_stmt => |stmt| {
                    try self.generateInnerStructs(parent_name, params, stmt.then_body);
                    if (stmt.else_body) |eb| try self.generateInnerStructs(parent_name, params, eb);
                },
                .for_stmt => |stmt| try self.generateInnerStructs(parent_name, params, stmt.body),
                .switch_stmt => |stmt| {
                    for (stmt.cases) |case| switch (case.body) {
                        .nodes => |case_nodes| try self.generateInnerStructs(parent_name, params, case_nodes),
                        .branch => {},
                    };
                },
                else => {},
            }
        }
    }

    /// Generate a single inner struct for a children block.
    fn generateOneInnerStruct(self: *Generator, parent_name: []const u8, params: []const ast.Parameter, body: []const ast.Node) std.Io.Writer.Error!void {
        const index = self.children_call_index;
        self.children_call_index += 1;

        // Build this inner struct's name for recursive use
        var name_buf: [256]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}__children_{d}", .{ parent_name, index }) catch "??";

        // Recursively handle nested children calls
        const num_children_calls = countChildrenCalls(body);
        if (num_children_calls > 0) {
            const saved_index = self.children_call_index;
            self.children_call_index = 0;
            try self.generateInnerStructs(name, params, body);
            self.children_call_index = saved_index;
        }

        try self.output.writeAll("const ");
        try self.output.writeAll(name);
        try self.output.writeAll(" = struct {\n");

        self.indent += 1;

        // _render
        try self.writeIndent();
        try self.output.writeAll("fn _render(");
        try self.writeParams(params);
        // Hidden params for nested children calls
        for (0..num_children_calls) |i| {
            try self.output.writeAll(", ");
            try self.writeChildrenParamName(i);
            try self.output.writeAll(": zt.Component");
        }
        if (params.len > 0 or num_children_calls > 0) try self.output.writeAll(", ");
        try self.output.writeAll("writer: *std.Io.Writer) std.Io.Writer.Error!void {\n");
        self.indent += 1;
        if (params.len > 0) try self.writeParamDiscards(params);
        const saved_index = self.children_call_index;
        self.children_call_index = 0;
        for (body) |node| {
            try self.generateNode(node);
        }
        self.children_call_index = saved_index;
        self.indent -= 1;
        try self.writeIndent();
        try self.output.writeAll("}\n\n");

        // _signature
        try self.writeIndent();
        try self.output.writeAll("fn _signature(");
        try self.writeAnonymizedParams(params);
        try self.output.writeAll(") void {}\n\n");

        // Args, render, bind
        try self.writeArgsRenderBind(name, num_children_calls);

        self.indent -= 1;
        try self.output.writeAll("};\n\n");
    }

    fn generateNode(self: *Generator, node: ast.Node) std.Io.Writer.Error!void {
        switch (node) {
            .element => |elem| try self.generateElement(elem),
            .text => |text| try self.generateText(text),
            .expr => |expr| try self.generateExpr(expr),
            .if_stmt => |stmt| try self.generateIfStmt(stmt),
            .for_stmt => |stmt| try self.generateForStmt(stmt),
            .switch_stmt => |stmt| try self.generateSwitchStmt(stmt),
            .component_call => |call| try self.generateComponentCall(call),
            .doctype => |doctype| try self.generateDoctype(doctype),
        }
    }

    fn writeSourceLoc(self: *Generator, loc: ast.Location) std.Io.Writer.Error!void {
        if (self.source_file.len == 0 or loc.line == 0) return;
        if (loc.line == self.last_emitted_line) return;
        self.last_emitted_line = loc.line;
        try self.writeIndent();
        try self.output.print("// {s}:{d}\n", .{ self.source_file, loc.line });
    }

    fn generateElement(self: *Generator, elem: ast.Element) std.Io.Writer.Error!void {
        try self.writeSourceLoc(elem.loc);
        // Check if we have any dynamic attributes
        var has_dynamic = false;
        for (elem.attributes) |attr| {
            if (attr.value == .dynamic or attr.value == .interpolated) {
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
                    .dynamic, .interpolated => {},
                }
            }

            const is_void = void_elements.has(elem.tag);
            if (is_void or elem.self_closing) {
                if (is_void) {
                    try self.output.writeAll(">\");\n");
                } else {
                    try self.output.writeAll("/>\");\n");
                }
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
                    .interpolated => |parts| {
                        try self.writeIndent();
                        try self.output.writeAll("try writer.writeAll(\" ");
                        try self.output.writeAll(attr.name);
                        try self.output.writeAll("=\\\"\");\n");
                        for (parts) |part| {
                            switch (part) {
                                .static => |val| {
                                    try self.writeIndent();
                                    try self.output.writeAll("try writer.writeAll(\"");
                                    try self.writeEscapedForZig(val);
                                    try self.output.writeAll("\");\n");
                                },
                                .dynamic => |expr| {
                                    try self.writeIndent();
                                    try self.output.writeAll("try zt.writeEscaped(writer, ");
                                    try self.output.writeAll(expr);
                                    try self.output.writeAll(");\n");
                                },
                            }
                        }
                        try self.writeIndent();
                        try self.output.writeAll("try writer.writeAll(\"\\\"\");\n");
                    },
                }
            }

            // Close opening tag
            try self.writeIndent();
            const is_void = void_elements.has(elem.tag);
            if (is_void or elem.self_closing) {
                if (is_void) {
                    try self.output.writeAll("try writer.writeAll(\">\");\n");
                } else {
                    try self.output.writeAll("try writer.writeAll(\"/>\");\n");
                }
                return;
            }
            try self.output.writeAll("try writer.writeAll(\">\");\n");
        }

        // Children
        for (elem.children) |child| {
            try self.generateNode(child);
        }

        // Closing tag
        try self.writeSourceLoc(elem.end_loc);
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

    fn generateDoctype(self: *Generator, doctype: ast.Doctype) std.Io.Writer.Error!void {
        try self.writeIndent();
        try self.output.writeAll("try writer.writeAll(\"<!DOCTYPE ");
        try self.output.writeAll(doctype.value);
        try self.output.writeAll(">\");\n");
    }

    fn generateExpr(self: *Generator, expr: ast.Expr) std.Io.Writer.Error!void {
        try self.writeSourceLoc(expr.loc);
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
            .switch_expr => |switch_expr| try self.generateSwitchExpr(switch_expr, expr.raw),
            .element => |elem| try self.generateElement(elem.*),
        }
    }

    fn generateIfExpr(self: *Generator, if_expr: ast.IfExpr, raw: bool) std.Io.Writer.Error!void {
        try self.writeIndent();
        try self.output.writeAll("if (");
        try self.output.writeAll(if_expr.condition);
        try self.output.writeAll(")");
        if (if_expr.capture) |cap| {
            try self.output.writeAll(" |");
            try self.output.writeAll(cap);
            try self.output.writeAll("|");
        }
        try self.output.writeAll(" {\n");

        self.indent += 1;
        try self.generateBranch(if_expr.then_branch, raw);
        self.indent -= 1;

        if (if_expr.else_branch) |else_branch| {
            try self.writeIndent();
            try self.output.writeAll("} else");
            if (if_expr.else_capture) |cap| {
                try self.output.writeAll(" |");
                try self.output.writeAll(cap);
                try self.output.writeAll("|");
            }
            try self.output.writeAll(" {\n");
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
            .if_expr => |if_expr| try self.generateIfExpr(if_expr.*, raw),
            .nodes => |nodes| {
                for (nodes) |node| {
                    try self.generateNode(node);
                }
            },
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
        try self.writeSourceLoc(call.loc);
        try self.writeIndent();
        try self.output.writeAll("try zt.renderComponent(");
        try self.output.writeAll(call.name);
        try self.output.writeAll(", .{");
        if (call.args.len > 0) {
            try self.output.writeAll(call.args);
        }
        // Pass the bound children component if this call has children
        if (call.children.len > 0) {
            if (call.args.len > 0) try self.output.writeAll(", ");
            try self.writeChildrenParamName(self.children_call_index);
            self.children_call_index += 1;
        }
        try self.output.writeAll("}, writer);\n");
    }

    fn generateIfStmt(self: *Generator, stmt: ast.IfStatement) std.Io.Writer.Error!void {
        try self.writeSourceLoc(stmt.loc);
        try self.writeIndent();
        try self.output.writeAll("if (");
        try self.output.writeAll(stmt.condition);
        try self.output.writeAll(")");
        if (stmt.capture) |cap| {
            try self.output.writeAll(" |");
            try self.output.writeAll(cap);
            try self.output.writeAll("|");
        }
        try self.output.writeAll(" {\n");

        self.indent += 1;
        for (stmt.then_body) |node| {
            try self.generateNode(node);
        }
        self.indent -= 1;

        if (stmt.else_body) |else_body| {
            // Check for else-if chain: single if_stmt node (only if no else capture)
            if (stmt.else_capture == null and else_body.len == 1 and else_body[0] == .if_stmt) {
                try self.writeIndent();
                try self.output.writeAll("} else ");
                try self.generateIfStmtInline(else_body[0].if_stmt);
                return;
            }
            try self.writeIndent();
            try self.output.writeAll("} else");
            if (stmt.else_capture) |cap| {
                try self.output.writeAll(" |");
                try self.output.writeAll(cap);
                try self.output.writeAll("|");
            }
            try self.output.writeAll(" {\n");
            self.indent += 1;
            for (else_body) |node| {
                try self.generateNode(node);
            }
            self.indent -= 1;
        }

        try self.writeIndent();
        try self.output.writeAll("}\n");
    }

    /// Generate if statement without leading indent (for else-if chains)
    fn generateIfStmtInline(self: *Generator, stmt: ast.IfStatement) std.Io.Writer.Error!void {
        try self.output.writeAll("if (");
        try self.output.writeAll(stmt.condition);
        try self.output.writeAll(")");
        if (stmt.capture) |cap| {
            try self.output.writeAll(" |");
            try self.output.writeAll(cap);
            try self.output.writeAll("|");
        }
        try self.output.writeAll(" {\n");

        self.indent += 1;
        for (stmt.then_body) |node| {
            try self.generateNode(node);
        }
        self.indent -= 1;

        if (stmt.else_body) |else_body| {
            if (stmt.else_capture == null and else_body.len == 1 and else_body[0] == .if_stmt) {
                try self.writeIndent();
                try self.output.writeAll("} else ");
                try self.generateIfStmtInline(else_body[0].if_stmt);
                return;
            }
            try self.writeIndent();
            try self.output.writeAll("} else");
            if (stmt.else_capture) |cap| {
                try self.output.writeAll(" |");
                try self.output.writeAll(cap);
                try self.output.writeAll("|");
            }
            try self.output.writeAll(" {\n");
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
        try self.writeSourceLoc(stmt.loc);
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

    fn generateSwitchStmt(self: *Generator, stmt: ast.SwitchStatement) std.Io.Writer.Error!void {
        try self.writeSourceLoc(stmt.loc);
        try self.writeIndent();
        try self.output.writeAll("switch (");
        try self.output.writeAll(stmt.value);
        try self.output.writeAll(") {\n");

        self.indent += 1;
        for (stmt.cases) |case| {
            try self.writeIndent();
            try self.output.writeAll(case.pattern);
            try self.output.writeAll(" => ");
            if (case.capture) |cap| {
                try self.output.writeAll("|");
                try self.output.writeAll(cap);
                try self.output.writeAll("| ");
            }
            try self.output.writeAll("{\n");

            self.indent += 1;
            switch (case.body) {
                .nodes => |nodes| {
                    for (nodes) |node| {
                        try self.generateNode(node);
                    }
                },
                .branch => |branch| try self.generateBranch(branch, false),
            }
            self.indent -= 1;

            try self.writeIndent();
            try self.output.writeAll("},\n");
        }
        self.indent -= 1;

        try self.writeIndent();
        try self.output.writeAll("}\n");
    }

    fn generateSwitchExpr(self: *Generator, expr: ast.SwitchExpr, raw: bool) std.Io.Writer.Error!void {
        try self.writeIndent();
        try self.output.writeAll("switch (");
        try self.output.writeAll(expr.value);
        try self.output.writeAll(") {\n");

        self.indent += 1;
        for (expr.cases) |case| {
            try self.writeIndent();
            try self.output.writeAll(case.pattern);
            try self.output.writeAll(" => ");
            if (case.capture) |cap| {
                try self.output.writeAll("|");
                try self.output.writeAll(cap);
                try self.output.writeAll("| ");
            }
            try self.output.writeAll("{\n");

            self.indent += 1;
            try self.generateBranch(case.body, raw);
            self.indent -= 1;

            try self.writeIndent();
            try self.output.writeAll("},\n");
        }
        self.indent -= 1;

        try self.writeIndent();
        try self.output.writeAll("}\n");
    }

    fn writeChildrenParamName(self: *Generator, index: usize) std.Io.Writer.Error!void {
        try self.output.print("__children_{d}", .{index});
    }

    fn writeChildrenStructSuffix(self: *Generator, index: usize) std.Io.Writer.Error!void {
        try self.output.print("__children_{d}", .{index});
    }

    /// Check if a body uses @children (needs implicit children param).
    fn bodyUsesChildren(nodes: []const ast.Node) bool {
        for (nodes) |node| {
            switch (node) {
                .component_call => |call| {
                    if (std.mem.eql(u8, call.name, "children")) return true;
                },
                .element => |elem| {
                    if (bodyUsesChildren(elem.children)) return true;
                },
                .if_stmt => |stmt| {
                    if (bodyUsesChildren(stmt.then_body)) return true;
                    if (stmt.else_body) |eb| {
                        if (bodyUsesChildren(eb)) return true;
                    }
                },
                .for_stmt => |stmt| {
                    if (bodyUsesChildren(stmt.body)) return true;
                },
                .switch_stmt => |stmt| {
                    for (stmt.cases) |case| switch (case.body) {
                        .nodes => |case_nodes| {
                            if (bodyUsesChildren(case_nodes)) return true;
                        },
                        .branch => |branch| switch (branch) {
                            .component_call => |cc| {
                                if (std.mem.eql(u8, cc.name, "children")) return true;
                            },
                            else => {},
                        },
                    };
                },
                else => {},
            }
        }
        return false;
    }

    /// Count component calls with children blocks in a body tree.
    fn countChildrenCalls(nodes: []const ast.Node) usize {
        var count: usize = 0;
        for (nodes) |node| {
            switch (node) {
                .component_call => |call| {
                    if (call.children.len > 0) count += 1;
                },
                .element => |elem| count += countChildrenCalls(elem.children),
                .if_stmt => |stmt| {
                    count += countChildrenCalls(stmt.then_body);
                    if (stmt.else_body) |eb| count += countChildrenCalls(eb);
                },
                .for_stmt => |stmt| count += countChildrenCalls(stmt.body),
                .switch_stmt => |stmt| {
                    for (stmt.cases) |case| switch (case.body) {
                        .nodes => |case_nodes| count += countChildrenCalls(case_nodes),
                        .branch => {},
                    };
                },
                else => {},
            }
        }
        return count;
    }

    /// Write `_ = &name;` for each param to suppress unused parameter errors.
    fn writeParamDiscards(self: *Generator, params: []const ast.Parameter) std.Io.Writer.Error!void {
        for (params) |p| {
            try self.writeIndent();
            try self.output.writeAll("_ = &");
            try self.output.writeAll(p.name);
            try self.output.writeAll(";\n");
        }
    }

    /// Writes params with names replaced by `_`, e.g. "name: []const u8, age: u32" -> "_: []const u8, _: u32"
    fn writeAnonymizedParams(self: *Generator, params: []const ast.Parameter) std.Io.Writer.Error!void {
        for (params, 0..) |p, i| {
            if (i > 0) try self.output.writeAll(", ");
            try self.output.writeAll("_: ");
            try self.output.writeAll(p.type_str);
        }
    }

    /// Writes full parameter list: "name: Type, other: OtherType"
    fn writeParams(self: *Generator, params: []const ast.Parameter) std.Io.Writer.Error!void {
        for (params, 0..) |p, i| {
            if (i > 0) try self.output.writeAll(", ");
            try self.output.writeAll(p.name);
            try self.output.writeAll(": ");
            try self.output.writeAll(p.type_str);
        }
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
    try std.testing.expect(std.mem.indexOf(u8, result, "pub const hello") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.renderComponent(Header, .{}, writer);") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.renderComponent(UserCard, .{user}, writer);") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.renderComponent(components.Header, .{}, writer);") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.renderComponent(ui.UserCard, .{user}, writer);") != null);
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

test "generate switch statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

    const source =
        \\templ Status(status: Status) {
        \\    switch (status) {
        \\        .active => {
        \\            <span>Active</span>
        \\        },
        \\        .pending => |val| {
        \\            <span>{val}</span>
        \\        },
        \\    }
        \\}
    ;

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, result, "switch (status)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, ".active =>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, ".pending => |val|") != null);
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

test "generate else if chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

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

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    // Should generate "} else if (" not "} else {\n    if ("
    try std.testing.expect(std.mem.indexOf(u8, result, "} else if (x == 2)") != null);
}

test "generate void elements without closing slash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

    const source =
        \\templ test() {
        \\    <head>
        \\        <meta name="viewport"/>
        \\    </head>
        \\    <br/>
        \\}
    ;

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    // Void elements should output > not />
    try std.testing.expect(std.mem.indexOf(u8, result, "<meta name=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<br>") != null);
    // Should NOT have /> for void elements
    try std.testing.expect(std.mem.indexOf(u8, result, "<br/>") == null);
    // Should NOT have closing tags for void elements
    try std.testing.expect(std.mem.indexOf(u8, result, "</meta>") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</br>") == null);
    // But regular elements should still have closing tags
    try std.testing.expect(std.mem.indexOf(u8, result, "</head>") != null);
}
