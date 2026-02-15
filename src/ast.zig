const std = @import("std");

/// A file containing one or more templates
pub const TemplateFile = struct {
    /// Zig code before the first template (imports, consts, etc.)
    header: []const u8,
    templates: []const Template,
};

pub const Parameter = struct {
    name: []const u8,
    type_str: []const u8,
};

pub const Template = struct {
    name: []const u8,
    params: []const Parameter,
    is_public: bool,
    body: []const Node,
};

pub const Node = union(enum) {
    element: Element,
    text: Text,
    expr: Expr,
    if_stmt: IfStatement,
    for_stmt: ForStatement,
    switch_stmt: SwitchStatement,
    component_call: ComponentCall,
};

pub const Element = struct {
    tag: []const u8,
    attributes: []const Attribute,
    children: []const Node,
    self_closing: bool,
    loc: Location = .{},
    end_loc: Location = .{},
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
    loc: Location = .{},

    pub const Content = union(enum) {
        zig_code: []const u8,
        if_expr: IfExpr,
        for_expr: ForExpr,
        switch_expr: SwitchExpr,
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

/// Component call: @Name(args) or @Name(args) { children }
pub const ComponentCall = struct {
    name: []const u8,
    args: []const u8,
    children: []const Node = &.{},
    loc: Location = .{},
};

/// Block-level: if (cond) { ... } else { ... }
pub const IfStatement = struct {
    condition: []const u8,
    then_body: []const Node,
    else_body: ?[]const Node,
    loc: Location = .{},
};

/// Block-level: for (iter) |capture| { ... }
pub const ForStatement = struct {
    iterable: []const u8,
    captures: []const u8,
    body: []const Node,
    loc: Location = .{},
};

/// Block-level: switch (expr) { .case => { ... }, ... }
pub const SwitchStatement = struct {
    value: []const u8,
    cases: []const SwitchCase,
    loc: Location = .{},
};

/// A single switch case
pub const SwitchCase = struct {
    pattern: []const u8, // ".active", "else", ".foo, .bar", etc.
    capture: ?[]const u8, // |val| capture if present
    body: Body,

    pub const Body = union(enum) {
        nodes: []const Node, // { ... } block with multiple nodes
        branch: Branch, // single element/component/zig_code
    };
};

/// Inline switch expression
pub const SwitchExpr = struct {
    value: []const u8,
    cases: []const SwitchBranch,
};

/// A single inline switch branch
pub const SwitchBranch = struct {
    pattern: []const u8,
    capture: ?[]const u8,
    body: Branch,
};

pub const Location = struct {
    line: usize = 0,
    column: usize = 0,
};
