def test_static_text(zt):
    result = zt.run('pub templ run() { <p>Hello</p> }')
    assert result == '<p>Hello</p>'


def test_expression(zt):
    result = zt.run(
        'pub templ run(name: []const u8) { <p>{name}</p> }',
        args='.{"World"}',
    )
    assert result == '<p>World</p>'


def test_expression_escaped(zt):
    result = zt.run(
        'pub templ run(s: []const u8) { <p>{s}</p> }',
        args='.{"<script>"}',
    )
    assert result == '<p>&lt;script&gt;</p>'


def test_expression_raw(zt):
    result = zt.run(
        'pub templ run(s: []const u8) { <p>{!s}</p> }',
        args='.{"<b>bold</b>"}',
    )
    assert result == '<p><b>bold</b></p>'


def test_self_closing(zt):
    result = zt.run('pub templ run() { <br/><input type="text" /> }')
    assert result == '<br/><input type="text"/>'


def test_boolean_attr(zt):
    result = zt.run('pub templ run() { <input disabled checked /> }')
    assert result == '<input disabled checked/>'


def test_dynamic_attr(zt):
    result = zt.run(
        'pub templ run(cls: []const u8) { <div class={cls}></div> }',
        args='.{"foo"}',
    )
    assert result == '<div class="foo"></div>'


def test_optional_attr_present(zt):
    result = zt.run(
        'pub templ run(x: ?[]const u8) { <div class={x}></div> }',
        args='.{"bar"}',
    )
    assert result == '<div class="bar"></div>'


def test_optional_attr_null(zt):
    result = zt.run(
        'pub templ run(x: ?[]const u8) { <div class={x}></div> }',
        args='.{null}',
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
''', args='.{21}')
    assert result == '<span>42</span>'


def test_std_function_call(zt):
    result = zt.run('''
const std2 = @import("std");

pub templ run(s: []const u8) {
    <span>{std2.mem.trim(u8, s, " ")}</span>
}
''', args='.{"  hi  "}')
    assert result == '<span>hi</span>'
