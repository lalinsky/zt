/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

module.exports = grammar({
  name: "zt",

  externals: ($) => [
    $._zig_code,        // opaque top-level Zig code (imports, fn defs, consts)
    $.zig_expr,         // balanced expression; blocks if/for/switch (for _expr_content)
    $.zig_expr_free,    // balanced expression; unconstrained (attributes, conditions)
    $.zig_branch_expr,  // balanced expression; blocks keywords AND <, @, { (for _branch)
    $.raw_text,         // raw content of <style> and <script> elements
  ],

  extras: ($) => [/[ \t\r\n]/],

  conflicts: ($) => [
    [$.component_call],
    [$.switch_case, $.branch_block],
  ],

  rules: {
    // -------------------------------------------------------------------------
    // Top-level: interleaved Zig code and template declarations
    // -------------------------------------------------------------------------

    source_file: ($) => repeat(choice($.zig_code, $.template)),

    zig_code: ($) => $._zig_code,

    // -------------------------------------------------------------------------
    // Template declaration: [pub] templ Name(params) { body }
    // -------------------------------------------------------------------------

    template: ($) =>
      seq(
        optional($.pub_keyword),
        $.templ_keyword,
        $.template_name,
        "(",
        optional($.parameter_list),
        ")",
        $.template_body
      ),

    pub_keyword: (_) => "pub",
    templ_keyword: (_) => "templ",
    template_name: ($) => $.name,

    parameter_list: ($) => seq($.parameter, repeat(seq(",", $.parameter))),

    parameter: ($) =>
      seq(field("name", $.name), ":", field("type", $.type_expr)),

    // Type expression: everything up to the next comma or closing paren.
    // These are always simple Zig types, not arbitrary expressions.
    type_expr: (_) => token(/[^,)]+/),

    // -------------------------------------------------------------------------
    // Template body
    // -------------------------------------------------------------------------

    template_body: ($) => seq("{", repeat($._node), "}"),

    _node: ($) =>
      choice(
        $.style_element,
        $.script_element,
        $.element,
        $.doctype,
        $.html_comment,
        $.expr_block,
        $.component_call,
        $.block_if,
        $.block_for,
        $.block_switch,
        $.text
      ),

    // -------------------------------------------------------------------------
    // HTML elements
    // -------------------------------------------------------------------------

    style_element: ($) =>
      seq("<", "style", repeat($.attribute), ">", optional($.raw_text), "</", "style", ">"),

    script_element: ($) =>
      seq("<", "script", repeat($.attribute), ">", optional($.raw_text), "</", "script", ">"),

    element: ($) =>
      choice(
        seq($.open_tag, repeat($._node), $.close_tag),
        $.self_closing_tag
      ),

    open_tag: ($) => seq("<", $.tag_name, repeat($.attribute), ">"),

    close_tag: ($) => seq("</", $.tag_name, ">"),

    self_closing_tag: ($) => seq("<", $.tag_name, repeat($.attribute), "/>"),

    tag_name: (_) => /[A-Za-z][A-Za-z0-9\-_:]*/,

    doctype: (_) => /<!DOCTYPE\s+[^>]+>/i,

    html_comment: (_) => /<!--[\s\S]*?-->/,

    // -------------------------------------------------------------------------
    // Attributes
    // -------------------------------------------------------------------------

    attribute: ($) =>
      choice(
        $.dynamic_attribute,
        $.quoted_attribute,
        $.boolean_attribute
      ),

    boolean_attribute: ($) => $.attribute_name,

    quoted_attribute: ($) =>
      seq(
        $.attribute_name,
        "=",
        choice(
          seq('"', repeat(choice($.attr_static_part, $.attr_interpolation)), '"'),
          seq("'", repeat(choice($.attr_static_part_sq, $.attr_interpolation)), "'")
        )
      ),

    dynamic_attribute: ($) =>
      seq($.attribute_name, "=", "{", $.zig_expr_free, "}"),

    attribute_name: (_) => /[@A-Za-z_][A-Za-z0-9\-_:.@]*/,

    attr_static_part: (_) => /[^{}"]+/,
    attr_static_part_sq: (_) => /[^{}']+/,
    attr_interpolation: ($) => seq("{", $.zig_expr_free, "}"),

    // -------------------------------------------------------------------------
    // Expression blocks  { expr }  or  {! expr }
    // -------------------------------------------------------------------------

    expr_block: ($) =>
      seq("{", optional($.raw_marker), $._expr_content, "}"),

    raw_marker: (_) => "!",

    _expr_content: ($) =>
      choice(
        $.inline_if,
        $.inline_for,
        $.inline_switch,
        $.element,
        $.zig_expr
      ),

    // -------------------------------------------------------------------------
    // Component calls: @Name(args) or @Name(args) { children }
    // -------------------------------------------------------------------------

    component_call: ($) =>
      seq(
        "@",
        $.dotted_name,
        optional(seq("(", optional($.zig_expr_free), ")")),
        optional($.children_block)
      ),

    dotted_name: (_) => /[A-Za-z_][A-Za-z0-9_.:]*/,

    children_block: ($) => seq("{", repeat($._node), "}"),

    // -------------------------------------------------------------------------
    // Block-level control flow
    // -------------------------------------------------------------------------

    block_if: ($) =>
      seq(
        "if",
        "(", $.zig_expr_free, ")",
        optional($.capture),
        "{", repeat($._node), "}",
        optional($.else_clause)
      ),

    else_clause: ($) =>
      seq(
        "else",
        optional($.capture),
        choice(
          seq("{", repeat($._node), "}"),
          $.block_if
        )
      ),

    block_for: ($) =>
      seq(
        "for",
        "(", $.for_args, ")",
        $.capture,
        "{", repeat($._node), "}"
      ),

    block_switch: ($) =>
      seq(
        "switch",
        "(", $.zig_expr_free, ")",
        "{",
        repeat(seq($.switch_case, optional(","))),
        "}"
      ),

    switch_case: ($) =>
      seq(
        $.switch_pattern,
        optional($.capture),
        "=>",
        optional($.capture),
        choice(
          seq("{", repeat($._node), "}"),
          $._branch
        )
      ),

    switch_pattern: (_) => token(prec(-1, /[^|={},\n]+/)),

    // -------------------------------------------------------------------------
    // Inline control flow (inside { })
    // -------------------------------------------------------------------------

    inline_if: ($) =>
      seq(
        "if",
        "(", $.zig_expr_free, ")",
        optional($.capture),
        $._branch,
        optional(seq("else", optional($.capture), $._branch))
      ),

    inline_for: ($) =>
      seq(
        "for",
        "(", $.for_args, ")",
        $.capture,
        $._branch
      ),

    inline_switch: ($) =>
      seq(
        "switch",
        "(", $.zig_expr_free, ")",
        "{",
        repeat(seq($.switch_branch, optional(","))),
        "}"
      ),

    switch_branch: ($) =>
      seq(
        $.switch_pattern,
        optional($.capture),
        "=>",
        optional($.capture),
        $._branch
      ),

    _branch: ($) =>
      choice(
        $.element,
        $.component_call,
        $.branch_block,
        $.zig_branch_expr
      ),

    branch_block: ($) => seq("{", repeat($._node), "}"),

    // for_args: one or more comma-separated Zig expressions (for multi-object loops)
    for_args: ($) =>
      seq($.zig_expr_free, repeat(seq(",", $.zig_expr_free))),

    // -------------------------------------------------------------------------
    // Captures: |val| or |val, idx|
    // -------------------------------------------------------------------------

    capture: ($) => seq("|", $.capture_content, "|"),

    capture_content: (_) => /[^|]+/,

    // -------------------------------------------------------------------------
    // Text content between tags
    // -------------------------------------------------------------------------

    // Must start with a non-special character and not be a keyword followed by (
    // prec(-1) means any more specific rule wins.
    text: (_) => token(prec(-1, /[^<>{}\s@][^<>{}]*/)),

    name: (_) => /[A-Za-z_][A-Za-z0-9_]*/,
  },
});
