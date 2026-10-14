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

/// Attributes whose value is a URL. Dynamic values in them get a scheme check.
/// Follows Go's html/template, plus the htmx request attributes.
const url_attributes = std.StaticStringMapWithEql(void, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
    .{ "action", {} },
    .{ "archive", {} },
    .{ "background", {} },
    .{ "cite", {} },
    .{ "classid", {} },
    .{ "codebase", {} },
    .{ "data", {} },
    .{ "formaction", {} },
    .{ "href", {} },
    .{ "icon", {} },
    .{ "longdesc", {} },
    .{ "manifest", {} },
    .{ "poster", {} },
    .{ "profile", {} },
    .{ "src", {} },
    .{ "usemap", {} },
    .{ "xmlns", {} },
    .{ "hx-get", {} },
    .{ "hx-post", {} },
    .{ "hx-put", {} },
    .{ "hx-patch", {} },
    .{ "hx-delete", {} },
});

/// Attributes that look like URLs by name but aren't a single URL.
const non_url_attributes = std.StaticStringMapWithEql(void, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
    .{ "srcdoc", {} },
    .{ "srclang", {} },
    .{ "srcset", {} },
});

/// Whether an attribute holds a URL. Like Go's html/template, it looks through
/// `data-` and namespace prefixes (`data-href`, `xlink:href`), and treats
/// custom attributes with `src`, `uri` or `url` in the name as URLs.
fn isUrlAttribute(attr_name: []const u8) bool {
    var name = attr_name;
    if (std.ascii.startsWithIgnoreCase(name, "data-")) {
        name = name["data-".len..];
    } else if (std.mem.indexOfScalar(u8, name, ':')) |i| {
        if (std.ascii.eqlIgnoreCase(name[0..i], "xmlns")) return true;
        name = name[i + 1 ..];
    }
    if (url_attributes.has(name)) return true;
    if (non_url_attributes.has(name)) return false;
    return containsIgnoreCase(name, "src") or
        containsIgnoreCase(name, "uri") or
        containsIgnoreCase(name, "url");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

pub const Generator = struct {
    output: *std.Io.Writer,
    indent: usize,
    children_call_index: usize = 0,
    source_file: []const u8 = "",
    template_loc: ast.Location = .{},
    /// Whether a `zt.writeAll(_writer, "...` literal is open. Static output is
    /// appended to it, and the next line of other code closes it, so adjacent
    /// static pieces end up in a single write.
    static_open: bool = false,

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

        self.template_loc = template.loc;

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
        try self.output.writeAll("_writer: *std.Io.Writer) std.Io.Writer.Error!void {");
        try self.endParamsLine(template.params);

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
        try self.output.writeAll(") void {}");
        try self.endParamsLine(template.params);
        try self.output.writeAll("\n");

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
        try self.output.writeAll("pub fn render(args: Args, _writer: *std.Io.Writer) std.Io.Writer.Error!void {\n");
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
        try self.output.writeAll("_writer});\n");
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
        try self.output.writeAll("fn f(ptr: *const anyopaque, _writer: *std.Io.Writer) std.Io.Writer.Error!void {\n");
        self.indent += 1;
        try self.writeIndent();
        try self.output.writeAll("return render(@as(*const Args, @ptrCast(@alignCast(ptr))).*, _writer);\n");
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
        try self.output.writeAll("_writer: *std.Io.Writer) std.Io.Writer.Error!void {");
        try self.endParamsLine(params);
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
        try self.output.writeAll(") void {}");
        try self.endParamsLine(params);
        try self.output.writeAll("\n");

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

    /// End a line that contains user code with a comment pointing back to the
    /// template source. Zig prints the offending line in compile errors and
    /// stack traces, so the comment shows up right there.
    fn endLine(self: *Generator, loc: ast.Location) std.Io.Writer.Error!void {
        if (self.source_file.len > 0 and loc.line > 0) {
            try self.output.print(" // {s}:{d}:{d}", .{ self.source_file, loc.line, loc.column });
        }
        try self.output.writeAll("\n");
    }

    fn generateElement(self: *Generator, elem: ast.Element) std.Io.Writer.Error!void {
        try self.writeStatic("<");
        try self.writeStatic(elem.tag);

        for (elem.attributes) |attr| {
            switch (attr.value) {
                .static => |val| try self.writeStaticAttr(attr.name, val),
                .none => {
                    try self.writeStatic(" ");
                    try self.writeStatic(attr.name);
                },
                .dynamic => |expr| {
                    try self.writeIndent();
                    try self.output.writeAll(if (isUrlAttribute(attr.name))
                        "try zt.writeUrlAttr(_writer, \""
                    else
                        "try zt.writeAttr(_writer, \"");
                    try self.output.writeAll(attr.name);
                    try self.output.writeAll("\", ");
                    try self.output.writeAll(expr);
                    try self.output.writeAll(");");
                    try self.endLine(attr.loc);
                },
                .conditional => |expr| {
                    try self.writeIndent();
                    try self.output.writeAll("try zt.writeBoolAttr(_writer, \"");
                    try self.output.writeAll(attr.name);
                    try self.output.writeAll("\", ");
                    try self.output.writeAll(expr);
                    try self.output.writeAll(");");
                    try self.endLine(attr.loc);
                },
                .interpolated => |parts| {
                    try self.writeStatic(" ");
                    try self.writeStatic(attr.name);
                    try self.writeStatic("=\"");
                    if (isUrlAttribute(attr.name)) {
                        try self.generateUrlParts(parts, attr.loc);
                    } else {
                        try self.generateInterpolatedParts(parts, attr.loc);
                    }
                    try self.writeStatic("\"");
                },
            }
        }

        const is_void = void_elements.has(elem.tag);
        if (is_void) return self.writeStatic(">");
        if (elem.self_closing) return self.writeStatic("/>");
        try self.writeStatic(">");

        for (elem.children) |child| {
            try self.generateNode(child);
        }

        try self.writeStatic("</");
        try self.writeStatic(elem.tag);
        try self.writeStatic(">");
    }

    fn generateText(self: *Generator, text: ast.Text) std.Io.Writer.Error!void {
        try self.writeStatic(text.content);
    }

    fn generateDoctype(self: *Generator, doctype: ast.Doctype) std.Io.Writer.Error!void {
        try self.writeStatic("<!DOCTYPE ");
        try self.writeStatic(doctype.value);
        try self.writeStatic(">");
    }

    fn generateExpr(self: *Generator, expr: ast.Expr) std.Io.Writer.Error!void {
        switch (expr.content) {
            .zig_code => |code| try self.generateZigCode(code, expr.raw, expr.loc),
            .if_expr => |if_expr| try self.generateIfExpr(if_expr, expr.raw),
            .for_expr => |for_expr| try self.generateForExpr(for_expr, expr.raw, expr.loc),
            .switch_expr => |switch_expr| try self.generateSwitchExpr(switch_expr, expr.raw, expr.loc),
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
        try self.output.writeAll(" {");
        try self.endLine(if_expr.loc);

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
            try self.output.writeAll(" {");
            try self.endLine(if (if_expr.else_capture != null) if_expr.else_loc else .{});
            self.indent += 1;
            try self.generateBranch(else_branch, raw);
            self.indent -= 1;
        }

        try self.writeIndent();
        try self.output.writeAll("}\n");
    }

    fn generateForExpr(self: *Generator, for_expr: ast.ForExpr, raw: bool, loc: ast.Location) std.Io.Writer.Error!void {
        try self.writeIndent();
        try self.output.writeAll("for (");
        try self.output.writeAll(for_expr.iterable);
        try self.output.writeAll(") |");
        try self.output.writeAll(for_expr.captures);
        try self.output.writeAll("| {");
        try self.endLine(loc);

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
            .zig_code => |code| try self.generateZigCode(code.code, raw, code.loc),
        }
    }

    fn generateZigCode(self: *Generator, code: []const u8, raw: bool, loc: ast.Location) std.Io.Writer.Error!void {
        try self.writeIndent();
        if (raw) {
            try self.output.writeAll("try zt.writeRaw(_writer, ");
        } else {
            try self.output.writeAll("try zt.writeEscaped(_writer, ");
        }
        try self.output.writeAll(code);
        try self.output.writeAll(");");
        try self.endLine(loc);
    }

    fn generateComponentCall(self: *Generator, call: ast.ComponentCall) std.Io.Writer.Error!void {
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
        try self.output.writeAll("}, _writer);");
        try self.endLine(call.loc);
    }

    fn generateIfStmt(self: *Generator, stmt: ast.IfStatement) std.Io.Writer.Error!void {
        try self.writeIndent();
        try self.output.writeAll("if (");
        try self.output.writeAll(stmt.condition);
        try self.output.writeAll(")");
        if (stmt.capture) |cap| {
            try self.output.writeAll(" |");
            try self.output.writeAll(cap);
            try self.output.writeAll("|");
        }
        try self.output.writeAll(" {");
        try self.endLine(stmt.loc);

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
            try self.output.writeAll(" {");
            try self.endLine(if (stmt.else_capture != null) stmt.else_loc else .{});
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
        try self.output.writeAll(" {");
        try self.endLine(stmt.loc);

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
            try self.output.writeAll(" {");
            try self.endLine(if (stmt.else_capture != null) stmt.else_loc else .{});
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
        try self.output.writeAll("| {");
        try self.endLine(stmt.loc);

        self.indent += 1;
        for (stmt.body) |node| {
            try self.generateNode(node);
        }
        self.indent -= 1;

        try self.writeIndent();
        try self.output.writeAll("}\n");
    }

    fn generateSwitchStmt(self: *Generator, stmt: ast.SwitchStatement) std.Io.Writer.Error!void {
        try self.writeIndent();
        try self.output.writeAll("switch (");
        try self.output.writeAll(stmt.value);
        try self.output.writeAll(") {");
        try self.endLine(stmt.loc);

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
            try self.output.writeAll("{");
            try self.endLine(case.loc);

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

    fn generateSwitchExpr(self: *Generator, expr: ast.SwitchExpr, raw: bool, loc: ast.Location) std.Io.Writer.Error!void {
        try self.writeIndent();
        try self.output.writeAll("switch (");
        try self.output.writeAll(expr.value);
        try self.output.writeAll(") {");
        try self.endLine(loc);

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
            try self.output.writeAll("{");
            try self.endLine(case.loc);

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

    /// End a line containing the template parameters.
    fn endParamsLine(self: *Generator, params: []const ast.Parameter) std.Io.Writer.Error!void {
        try self.endLine(if (params.len > 0) self.template_loc else .{});
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

    fn generateInterpolatedParts(self: *Generator, parts: []const ast.Attribute.InterpolatedPart, loc: ast.Location) std.Io.Writer.Error!void {
        for (parts) |part| {
            switch (part) {
                .static => |val| try self.writeStatic(val),
                .dynamic => |expr| {
                    try self.writeIndent();
                    try self.output.writeAll("try zt.writeEscaped(_writer, ");
                    try self.output.writeAll(expr);
                    try self.output.writeAll(");");
                    try self.endLine(loc);
                },
            }
        }
    }

    /// Interpolated URL attribute value. Until the static text ends the scheme
    /// (`https://...`, `/users/...`), each dynamic part goes through
    /// zt.writeUrlPart, together with the static text around it. After that,
    /// parts are written as usual.
    fn generateUrlParts(self: *Generator, parts: []const ast.Attribute.InterpolatedPart, loc: ast.Location) std.Io.Writer.Error!void {
        var scheme_open = true;
        for (parts, 0..) |part, i| {
            switch (part) {
                .static => |val| {
                    if (std.mem.indexOfAny(u8, val, ":/?#") != null) scheme_open = false;
                    // Written by the writeUrlPart call that follows.
                    if (scheme_open and i + 1 < parts.len and parts[i + 1] == .dynamic) continue;
                    try self.writeStatic(val);
                },
                .dynamic => |expr| {
                    try self.writeIndent();
                    if (!scheme_open) {
                        try self.output.writeAll("try zt.writeEscaped(_writer, ");
                        try self.output.writeAll(expr);
                        try self.output.writeAll(");");
                        try self.endLine(loc);
                        continue;
                    }
                    try self.output.writeAll("try zt.writeUrlPart(_writer, \"");
                    if (i > 0 and parts[i - 1] == .static) try self.writeEscapedForZig(parts[i - 1].static);
                    try self.output.writeAll("\", ");
                    try self.output.writeAll(expr);
                    try self.output.writeAll(", \"");
                    if (i + 1 < parts.len and parts[i + 1] == .static) try self.writeEscapedForZig(parts[i + 1].static);
                    try self.output.writeAll("\");");
                    try self.endLine(loc);
                },
            }
        }
    }

    /// Starts a new line of generated code, closing the open static literal first.
    fn writeIndent(self: *Generator) std.Io.Writer.Error!void {
        if (self.static_open) {
            try self.output.writeAll("\");\n");
            self.static_open = false;
        }
        for (0..self.indent) |_| {
            try self.output.writeAll("    ");
        }
    }

    /// Writes static output, appending it to the open `zt.writeAll` literal.
    fn writeStatic(self: *Generator, str: []const u8) std.Io.Writer.Error!void {
        if (str.len == 0) return;
        if (!self.static_open) {
            try self.writeIndent();
            try self.output.writeAll("try zt.writeAll(_writer, \"");
            self.static_open = true;
        }
        try self.writeEscapedForZig(str);
    }

    /// Writes ` name="value"` as static output. A value containing `"` came from
    /// a single-quoted attribute and can't contain `'`, so it keeps single quotes.
    fn writeStaticAttr(self: *Generator, name: []const u8, value: []const u8) std.Io.Writer.Error!void {
        const quote = if (std.mem.indexOfScalar(u8, value, '"') != null) "'" else "\"";
        try self.writeStatic(" ");
        try self.writeStatic(name);
        try self.writeStatic("=");
        try self.writeStatic(quote);
        try self.writeStatic(value);
        try self.writeStatic(quote);
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
    try std.testing.expect(std.mem.indexOf(u8, result, "zt.writeEscaped(_writer, name)") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.renderComponent(Header, .{}, _writer);") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.renderComponent(UserCard, .{user}, _writer);") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.renderComponent(components.Header, .{}, _writer);") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.renderComponent(ui.UserCard, .{user}, _writer);") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result, "zt.writeEscaped(_writer, html)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "zt.writeRaw(_writer, html)") != null);
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

test "generate merges adjacent static output into one write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

    const source =
        \\templ test(items: []const []const u8) {
        \\    <!DOCTYPE html>
        \\    <html>
        \\        <body class="main">
        \\            <h1>Items</h1>
        \\            <ul>
        \\                for (items) |item| {
        \\                    <li class={item}><b>{item}</b></li>
        \\                }
        \\            </ul>
        \\        </body>
        \\    </html>
        \\}
    ;

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeAll(_writer, \"<!DOCTYPE html><html><body class=\\\"main\\\"><h1>Items</h1><ul>\");\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeAll(_writer, \"<li\");\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeAll(_writer, \"><b>\");\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeAll(_writer, \"</b></li>\");\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeAll(_writer, \"</ul></body></html>\");\n") != null);
    try std.testing.expectEqual(5, std.mem.count(u8, result, "zt.writeAll("));
}

test "generate source location comments on user code lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

    const source =
        \\templ test(items: []const Item) {
        \\    <ul class="list">
        \\        for (items) |item| {
        \\            <li id={item.id}>{item.name}</li>
        \\        }
        \\    </ul>
        \\}
    ;

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    gen.source_file = "test.zt";
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, result, "std.Io.Writer.Error!void { // test.zt:1:11\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "for (items) |item| { // test.zt:3:9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeAttr(_writer, \"id\", item.id); // test.zt:4:17\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeEscaped(_writer, item.name); // test.zt:4:30\n") != null);
    // Static markup we generate ourselves is not annotated
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeAll(_writer, \"<ul class=\\\"list\\\">\");\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeAll(_writer, \"</li>\");\n") != null);
}

test "generate source locations for inline if branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

    const source =
        \\templ test(a: anyerror!u32, b: ?u32) {
        \\    <p>{if (a) |x| x
        \\        else |err| errText(err)}</p>
        \\    <p>{if (b == null) "none" else if (b) |y| y else "?"}</p>
        \\}
    ;

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    gen.source_file = "test.zt";
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, result, "if (a) |x| { // test.zt:2:9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeEscaped(_writer, x); // test.zt:2:20\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "} else |err| { // test.zt:3:9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeEscaped(_writer, errText(err)); // test.zt:3:20\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "if (b == null) { // test.zt:4:9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "if (b) |y| { // test.zt:4:36\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeEscaped(_writer, y); // test.zt:4:47\n") != null);
}

test "generate URL checks only where a dynamic part can set the scheme" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");

    const source =
        \\templ test(u: User) {
        \\    <a href={u.website} title={u.name} data-url={u.feed}></a>
        \\    <a href="/users/{u.id}"></a>
        \\    <a href="https://{u.host}/"></a>
        \\    <a href="{u.base}/x/{u.id}"></a>
        \\    <img src="a{u.x}b{u.y}c" />
        \\}
    ;

    var p = parser.Parser.init(arena.allocator(), source);
    const template = try p.parseTemplate();

    var output: std.Io.Writer.Allocating = .init(arena.allocator());
    var gen = Generator.init(&output.writer);
    try gen.generate(template);

    const result = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeUrlAttr(_writer, \"href\", u.website);\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeAttr(_writer, \"title\", u.name);\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeUrlAttr(_writer, \"data-url\", u.feed);\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeAll(_writer, \"></a><a href=\\\"/users/\");\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeAll(_writer, \"\\\"></a><a href=\\\"https://\");\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeUrlPart(_writer, \"\", u.base, \"/x/\");\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeUrlPart(_writer, \"a\", u.x, \"b\");\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeUrlPart(_writer, \"b\", u.y, \"c\");\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "try zt.writeAll(_writer, \"c\\\">\");\n") != null);
    try std.testing.expectEqual(3, std.mem.count(u8, result, "writeUrlPart"));
}

test "detect URL attributes" {
    for ([_][]const u8{ "href", "HREF", "src", "action", "formaction", "xlink:href", "svg:href", "xmlns:foo", "data-href", "data-image-url", "imgsrc", "hx-get", "data-hx-post" }) |name| {
        try std.testing.expect(isUrlAttribute(name));
    }
    for ([_][]const u8{ "class", "title", "srcset", "srcdoc", "srclang", "data-id", "alt" }) |name| {
        try std.testing.expect(!isUrlAttribute(name));
    }
}
