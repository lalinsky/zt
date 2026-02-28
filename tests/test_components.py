def test_component_call(zt):
    result = zt.run('''
        templ inner(x: []const u8) { <b>{x}</b> }
        pub templ run() { @inner("hi") }
    ''')
    assert result == '<b>hi</b>'


def test_component_call_in_loop(zt):
    result = zt.run('''
        templ item(x: []const u8) { <li>{x}</li> }
        pub templ run(items: []const []const u8) {
            for (items) |x| { @item(x) }
        }
    ''', args='.{&[_][]const u8{"a", "b"}}')
    assert result == '<li>a</li><li>b</li>'


def test_inline_for_with_component(zt):
    """Inline for loop with component call as body."""
    result = zt.run('''
        templ Item(x: []const u8) { <li>{x}</li> }
        pub templ run(items: []const []const u8) {
            <ul>{for (items) |x| @Item(x)}</ul>
        }
    ''', args='.{&[_][]const u8{"a", "b"}}')
    assert result == '<ul><li>a</li><li>b</li></ul>'


def test_component_with_children(zt):
    result = zt.run('''
        templ wrapper() {
            <div>
                @children
            </div>
        }
        pub templ run() {
            @wrapper() {
                <span>inside</span>
            }
        }
    ''')
    assert result == '<div><span>inside</span></div>'


def test_at_symbol_inline_is_text(zt):
    """@ inline (without newline) should be literal text."""
    result = zt.run('pub templ run() { <div>@test</div> }')
    assert result == '<div>@test</div>'


def test_at_in_email(zt):
    """@ in the middle of text should be literal."""
    result = zt.run('pub templ run() { <span>email@example.com</span> }')
    assert result == '<span>email@example.com</span>'


def test_nested_children(zt):
    result = zt.run('''
        templ outer(tag: []const u8) {
            <div data-tag={tag}>
                @children
            </div>
        }
        templ inner(tag: []const u8) {
            <span data-tag={tag}>
                @children
            </span>
        }
        pub templ run(x: []const u8) {
            @outer("a") {
                @inner("b") { {x} }
            }
        }
    ''', args='.{"hello"}')
    assert result == '<div data-tag="a"><span data-tag="b">hello</span></div>'
