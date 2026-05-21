def test_static_text(zt):
    result = zt.run('pub templ run() { <p>Hello</p> }')
    assert result == '<p>Hello</p>'


def test_expression(zt):
    result = zt.run(
        'pub templ run(name: []const u8) { <p>{name}</p> }',
        args='.{"World"}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<p>World</p>'


def test_expression_escaped(zt):
    result = zt.run(
        'pub templ run(s: []const u8) { <p>{s}</p> }',
        args='.{"<script>"}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<p>&lt;script&gt;</p>'


def test_expression_raw(zt):
    result = zt.run(
        'pub templ run(s: []const u8) { <p>{!s}</p> }',
        args='.{"<b>bold</b>"}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (raw_marker)
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<p><b>bold</b></p>'


def test_self_closing(zt):
    # Void elements output without trailing slash (HTML5 compliant)
    result = zt.run(
        'pub templ run() { <br/><input type="text" /> }',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (element
                (self_closing_tag
                  (tag_name)))
              (element
                (self_closing_tag
                  (tag_name)
                  (attribute
                    (quoted_attribute
                      (attribute_name)
                      (attr_static_part))))))))
        ''',
    )
    assert result == '<br><input type="text">'


def test_boolean_attr(zt):
    # Void elements output without trailing slash (HTML5 compliant)
    result = zt.run(
        'pub templ run() { <input disabled checked /> }',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (element
                (self_closing_tag
                  (tag_name)
                  (attribute
                    (boolean_attribute
                      (attribute_name)))
                  (attribute
                    (boolean_attribute
                      (attribute_name))))))))
        ''',
    )
    assert result == '<input disabled checked>'


def test_dynamic_attr(zt):
    result = zt.run(
        'pub templ run(cls: []const u8) { <div class={cls}></div> }',
        args='.{"foo"}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (dynamic_attribute
                      (attribute_name)
                      (zig_expr_free))))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<div class="foo"></div>'


def test_optional_attr_present(zt):
    result = zt.run(
        'pub templ run(x: ?[]const u8) { <div class={x}></div> }',
        args='.{"bar"}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (dynamic_attribute
                      (attribute_name)
                      (zig_expr_free))))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<div class="bar"></div>'


def test_optional_attr_null(zt):
    result = zt.run(
        'pub templ run(x: ?[]const u8) { <div class={x}></div> }',
        args='.{null}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (dynamic_attribute
                      (attribute_name)
                      (zig_expr_free))))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<div></div>'


def test_zig_function_call(zt):
    result = zt.run('''
fn double(x: i32) i32 {
    return x * 2;
}

pub templ run(x: i32) {
    <span>{double(x)}</span>
}
''', args='.{21}', expected_ast='''
        (source_file
          (zig_code)
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<span>42</span>'


def test_std_function_call(zt):
    result = zt.run('''
const std2 = @import("std");

pub templ run(s: []const u8) {
    <span>{std2.mem.trim(u8, s, " ")}</span>
}
''', args='.{"  hi  "}', expected_ast='''
        (source_file
          (zig_code)
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<span>hi</span>'


# Control flow in attributes

def test_attr_if_else(zt):
    result = zt.run(
        'pub templ run(x: bool) { <div class={if (x) "active" else "inactive"}></div> }',
        args='.{true}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (dynamic_attribute
                      (attribute_name)
                      (zig_expr_free))))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<div class="active"></div>'


def test_attr_if_else_false(zt):
    result = zt.run(
        'pub templ run(x: bool) { <div class={if (x) "active" else "inactive"}></div> }',
        args='.{false}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (dynamic_attribute
                      (attribute_name)
                      (zig_expr_free))))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<div class="inactive"></div>'


def test_attr_switch(zt):
    result = zt.run(
        '''const Status = enum { active, pending, inactive };

        pub templ run(s: Status) {
            <div class={switch (s) { .active => "green", .pending => "yellow", else => "gray" }}></div>
        }''',
        args='.{.pending}',
        expected_ast='''
        (source_file
          (zig_code)
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (dynamic_attribute
                      (attribute_name)
                      (zig_expr_free))))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<div class="yellow"></div>'


# Nested braces in expressions

def test_expr_array_access(zt):
    result = zt.run(
        'pub templ run(arr: []const u8) { <span>{arr[0]}</span> }',
        args='.{"hello"}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<span>104</span>'  # 'h' = 104


def test_expr_struct_literal(zt):
    result = zt.run('''
fn getX(s: struct { x: i32 }) i32 {
    return s.x;
}

pub templ run() {
    <span>{getX(.{ .x = 42 })}</span>
}
''', expected_ast='''
        (source_file
          (zig_code)
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<span>42</span>'


def test_expr_nested_struct_literal(zt):
    result = zt.run('''
fn getInnerX(s: struct { inner: struct { x: i32 } }) i32 {
    return s.inner.x;
}

pub templ run() {
    <span>{getInnerX(.{ .inner = .{ .x = 99 } })}</span>
}
''', expected_ast='''
        (source_file
          (zig_code)
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<span>99</span>'


def test_attr_nested_braces(zt):
    result = zt.run('''
fn getClass(opts: struct { primary: bool }) []const u8 {
    return if (opts.primary) "btn-primary" else "btn";
}

pub templ run() {
    <div class={getClass(.{ .primary = true })}></div>
}
''', expected_ast='''
        (source_file
          (zig_code)
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (dynamic_attribute
                      (attribute_name)
                      (zig_expr_free))))
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<div class="btn-primary"></div>'


def test_expr_string_with_braces(zt):
    result = zt.run(
        'pub templ run() { <span>{"{"}</span><span>{"}"}</span> }',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name)))
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<span>{</span><span>}</span>'


def test_expr_chained_field_access(zt):
    result = zt.run('''
const Inner = struct { value: i32 };
const Outer = struct { inner: Inner };

pub templ run(o: Outer) {
    <span>{o.inner.value}</span>
}
''', args='.{.{ .inner = .{ .value = 42 } }}', expected_ast='''
        (source_file
          (zig_code)
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<span>42</span>'


def test_expr_multiple_args(zt):
    result = zt.run('''
fn add(a: i32, b: i32, c: i32) i32 {
    return a + b + c;
}

pub templ run() {
    <span>{add(1, 2, 3)}</span>
}
''', expected_ast='''
        (source_file
          (zig_code)
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<span>6</span>'


def test_expr_arithmetic(zt):
    result = zt.run(
        'pub templ run(x: i32) { <span>{x * 2 + 10}</span> }',
        args='.{16}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<span>42</span>'


def test_expr_comparison(zt):
    result = zt.run(
        'pub templ run(x: i32) { <span>{x > 10}</span> }',
        args='.{42}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<span>true</span>'


def test_expr_slice(zt):
    result = zt.run(
        'pub templ run(s: []const u8) { <span>{s[0..5]}</span> }',
        args='.{"hello world"}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<span>hello</span>'


def test_expr_orelse(zt):
    result = zt.run(
        'pub templ run(x: ?[]const u8) { <span>{x orelse "default"}</span> }',
        args='.{null}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<span>default</span>'


def test_expr_orelse_present(zt):
    result = zt.run(
        'pub templ run(x: ?[]const u8) { <span>{x orelse "default"}</span> }',
        args='.{"value"}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<span>value</span>'


def test_expr_optional_unwrap(zt):
    result = zt.run(
        'pub templ run(x: ?i32) { <span>{x.?}</span> }',
        args='.{42}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<span>42</span>'


def test_expr_builtin(zt):
    result = zt.run(
        'pub templ run(x: i32) { <span>{@abs(x)}</span> }',
        args='.{-42}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<span>42</span>'


def test_expr_parenthesized(zt):
    result = zt.run(
        'pub templ run(x: i32) { <span>{(x + 1) * 2}</span> }',
        args='.{20}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<span>42</span>'


def test_expr_number_literal(zt):
    result = zt.run(
        'pub templ run() { <span>{42}</span> }',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<span>42</span>'


def test_expr_string_literal(zt):
    result = zt.run(
        'pub templ run() { <span>{"hello"}</span> }',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<span>hello</span>'


def test_expr_bool_literal(zt):
    result = zt.run(
        'pub templ run() { <span>{true}</span><span>{false}</span> }',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name)))
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<span>true</span><span>false</span>'


def test_expr_interspersed_with_text(zt):
    result = zt.run(
        'pub templ run(a: i32, b: i32) { <span>{a} + {b} = {a + b}</span> }',
        args='.{2, 3}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr))
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (text)
                (expr_block
                  (zig_expr))
                (text)
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<span>2 + 3 = 5</span>'


def test_expr_multiline(zt):
    result = zt.run('''
pub templ run(x: i32) {
    <span>{
        x * 2
    }</span>
}
''', args='.{21}', expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<span>42</span>'


def test_expr_adjacent(zt):
    result = zt.run(
        'pub templ run(a: []const u8, b: []const u8) { <span>{a}{b}</span> }',
        args='.{"hello", "world"}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr))
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (expr_block
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<span>helloworld</span>'


def test_expr_with_trailing_text(zt):
    """Regression test for https://github.com/lalinsky/zt/issues/4"""
    result = zt.run(
        'pub templ run(title: []const u8) { <header>{title} | test</header> }',
        args='.{"Ramen"}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (text)
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<header>Ramen | test</header>'


def test_doctype(zt):
    """Regression test for https://github.com/lalinsky/zt/issues/8"""
    result = zt.run(
        'pub templ run() { <!DOCTYPE html><html></html> }',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (doctype)
              (element
                (open_tag
                  (tag_name))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<!DOCTYPE html><html></html>'


def test_doctype_with_whitespace(zt):
    """DOCTYPE followed by content with whitespace"""
    result = zt.run('''pub templ run() {
    <!DOCTYPE html>
    <html lang="en"></html>
}''', expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (doctype)
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (quoted_attribute
                      (attribute_name)
                      (attr_static_part))))
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<!DOCTYPE html><html lang="en"></html>'


def test_literal_text_content(zt):
    """Literal text inside elements without braces"""
    result = zt.run('''pub templ run() {
    <foo>
      hello world
    </foo>
}''', expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (text)
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<foo>\n      hello world\n    </foo>'


def test_attr_string_interpolation(zt):
    """Regression test for https://github.com/lalinsky/zt/issues/10"""
    result = zt.run('''
const Recipe = struct { id: i32, slug: []const u8 };

pub templ run(recipe: Recipe) {
    <a href="/recipe/{recipe.id}/{recipe.slug}">Link</a>
}
''', args='.{.{ .id = 123, .slug = "pizza" }}', expected_ast='''
        (source_file
          (zig_code)
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (quoted_attribute
                      (attribute_name)
                      (attr_static_part)
                      (attr_interpolation
                        (zig_expr_free))
                      (attr_static_part)
                      (attr_interpolation
                        (zig_expr_free)))))
                (text)
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<a href="/recipe/123/pizza">Link</a>'


def test_attr_interpolation_arithmetic(zt):
    """Test arithmetic expression in interpolated attribute"""
    result = zt.run(
        'pub templ run(x: i32) { <div data-value="result: {x + 1}"></div> }',
        args='.{41}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (quoted_attribute
                      (attribute_name)
                      (attr_static_part)
                      (attr_interpolation
                        (zig_expr_free)))))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<div data-value="result: 42"></div>'


def test_attr_interpolation_if(zt):
    """Test if expression in interpolated attribute"""
    result = zt.run(
        'pub templ run(active: bool) { <div class="btn {if (active) "active" else "inactive"}"></div> }',
        args='.{true}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (quoted_attribute
                      (attribute_name)
                      (attr_static_part)
                      (attr_interpolation
                        (zig_expr_free)))))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<div class="btn active"></div>'


def test_attr_interpolation_switch(zt):
    """Test switch expression in interpolated attribute"""
    result = zt.run('''
const Status = enum { ok, err };

pub templ run(s: Status) {
    <div class="status-{switch (s) { .ok => "success", .err => "error" }}"></div>
}
''', args='.{.ok}', expected_ast='''
        (source_file
          (zig_code)
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (quoted_attribute
                      (attribute_name)
                      (attr_static_part)
                      (attr_interpolation
                        (zig_expr_free)))))
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<div class="status-success"></div>'


def test_issue4_case1(zt):
    """Test from issue #4 comment - inline"""
    result = zt.run('''
const Recipe = struct { title: []const u8 };

pub templ run(recipe: Recipe) {
    <header>
        {recipe.title} | test
    </header>
}
''', args='.{.{ .title = "Ramen" }}', expected_ast='''
        (source_file
          (zig_code)
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (text)
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<header>Ramen | test\n    </header>'


def test_issue4_case2(zt):
    """Test from issue #4 comment - multiline"""
    result = zt.run('''
const Recipe = struct { title: []const u8 };

pub templ run(recipe: Recipe) {
    <header>
        {recipe.title}
        | test
    </header>
}
''', args='.{.{ .title = "Ramen" }}', expected_ast='''
        (source_file
          (zig_code)
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (expr_block
                  (zig_expr))
                (text)
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<header>Ramen\n        | test\n    </header>'


def test_void_function_no_output(zt):
    """Test that void-returning functions don't print 'void' - issue #11"""
    result = zt.run('''
fn writeDate(writer: *@import("std").Io.Writer) void {
    writer.writeAll("2022-05-06") catch return;
}

pub templ run() {
    <p>Created {!writeDate(writer)}</p>
}
''', expected_ast='''
        (source_file
          (zig_code)
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (text)
                (expr_block
                  (raw_marker)
                  (zig_expr))
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<p>Created 2022-05-06</p>'


def test_multiline_html_attributes(zt):
    """Test that HTML tags with attributes on multiple lines compile - issue #14"""
    result = zt.run('''
pub templ run() {
    <button type="button"
            data-action="delete"
            data-confirm="Are you sure?"
            class="secondary-button">
        Delete
    </button>
}
''', expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (quoted_attribute
                      (attribute_name)
                      (attr_static_part)))
                  (attribute
                    (quoted_attribute
                      (attribute_name)
                      (attr_static_part)))
                  (attribute
                    (quoted_attribute
                      (attribute_name)
                      (attr_static_part)))
                  (attribute
                    (quoted_attribute
                      (attribute_name)
                      (attr_static_part))))
                (text)
                (close_tag
                  (tag_name))))))
        ''')
    assert result == '<button type="button" data-action="delete" data-confirm="Are you sure?" class="secondary-button">\n        Delete\n    </button>'


# Attribute value escaping

def test_attr_escape_double_quote(zt):
    """Double quotes in dynamic attribute values must be escaped."""
    result = zt.run(
        r'pub templ run(s: []const u8) { <div title={s}></div> }',
        args=r'.{"say \"hello\""}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (dynamic_attribute
                      (attribute_name)
                      (zig_expr_free))))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<div title="say &quot;hello&quot;"></div>'


def test_attr_escape_single_quote(zt):
    """Single quotes in dynamic attribute values must be escaped."""
    result = zt.run(
        'pub templ run(s: []const u8) { <div title={s}></div> }',
        args=".{\"it's fine\"}",
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (dynamic_attribute
                      (attribute_name)
                      (zig_expr_free))))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<div title="it&#x27;s fine"></div>'


def test_attr_escape_angle_brackets(zt):
    """Angle brackets in dynamic attribute values must be escaped."""
    result = zt.run(
        'pub templ run(s: []const u8) { <div title={s}></div> }',
        args='.{"<script>"}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (dynamic_attribute
                      (attribute_name)
                      (zig_expr_free))))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<div title="&lt;script&gt;"></div>'


def test_attr_escape_ampersand(zt):
    """Ampersands in dynamic attribute values must be escaped."""
    result = zt.run(
        'pub templ run(s: []const u8) { <div title={s}></div> }',
        args='.{"a&b"}',
        expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (parameter_list
              (parameter
                name: (name)
                type: (type_expr)))
            (template_body
              (element
                (open_tag
                  (tag_name)
                  (attribute
                    (dynamic_attribute
                      (attribute_name)
                      (zig_expr_free))))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<div title="a&amp;b"></div>'


# Style elements


def test_style_element_static(zt):
    """Static CSS inside style element should pass through unchanged."""
    result = zt.run('''
pub templ run() {
    <style>
        .foo { color: red; }
    </style>
}
''', expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (style_element
                (raw_text)))))
        ''')
    assert '<style>' in result
    assert '.foo { color: red; }' in result
    assert '</style>' in result


def test_script_element_static(zt):
    """Static JS inside script element should pass through unchanged."""
    result = zt.run('''
pub templ run() {
    <script>
        if (x) { console.log("hello"); }
    </script>
}
''', expected_ast='''
        (source_file
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (script_element
                (raw_text)))))
        ''')
    assert '<script>' in result
    assert 'if (x) { console.log("hello"); }' in result
    assert '</script>' in result
