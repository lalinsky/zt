const std = @import("std");

/// A file containing one or more templates
pub const TemplateFile = struct {
    /// Zig code before the first template (imports, consts, etc.)
    header: []const u8,
    templates: []const Template,
};

pub const Template = struct {
    name: []const u8,
    params: []const u8, // Raw Zig parameter list
    is_public: bool,
    body: []const Node,
};

pub const Node = union(enum) {
    element: Element,
    text: Text,
    expr: Expr,
    if_stmt: IfStatement,
    for_stmt: ForStatement,
    component_call: ComponentCall,
};

pub const Element = struct {
    tag: []const u8,
    attributes: []const Attribute,
    children: []const Node,
    self_closing: bool,
};

pub const Attribute = struct {
    name: []const u8,
    value: Value,

    pub const Value = union(enum) {
        static: []const u8, // class="foo"
        dynamic: []const u8, // class={expr}
        none, // boolean attribute like `disabled`
    };
};

pub const Text = struct {
    content: []const u8,
};

/// Expression block: { ... } or raw: {! ... }
pub const Expr = struct {
    content: Content,
    raw: bool = false, // {!expr} for unescaped output

    pub const Content = union(enum) {
        zig_code: []const u8,
        if_expr: IfExpr,
        for_expr: ForExpr,
        element: *Element,
    };
};

/// Inline if: {if (cond) <span>yes</span> else <span>no</span>}
pub const IfExpr = struct {
    condition: []const u8,
    then_branch: Branch,
    else_branch: ?Branch,
};

/// Inline for: {for (items) |item| <li>{item}</li>}
pub const ForExpr = struct {
    iterable: []const u8,
    captures: []const u8,
    body: Branch,
};

/// Branch in inline if/for - element, component call, or zig code
pub const Branch = union(enum) {
    element: *Element,
    component_call: ComponentCall,
    zig_code: []const u8,
};

/// Component call: @Name(args)
pub const ComponentCall = struct {
    name: []const u8,
    args: []const u8,
};

/// Block-level: if (cond) { ... } else { ... }
pub const IfStatement = struct {
    condition: []const u8,
    then_body: []const Node,
    else_body: ?[]const Node,
};

/// Block-level: for (iter) |capture| { ... }
pub const ForStatement = struct {
    iterable: []const u8,
    captures: []const u8,
    body: []const Node,
};

pub const Location = struct {
    line: usize,
    column: usize,
};
