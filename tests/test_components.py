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


def test_component_call_after_content(zt):
    """A component call is recognized after other content on the same line."""
    result = zt.run(
        '''
        templ Bar(n: u32) { <b>{n}</b> }
        pub templ run() {
            <td>@Bar(1)</td>
            <p>Hi @Bar(2) and @Bar (3)!</p>
        }
        ''',
        expected_ast='''
        (source_file
          (template
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
                  (tag_name)))))
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (component_call
                  (dotted_name)
                  (zig_expr_free))
                (close_tag
                  (tag_name)))
              (element
                (open_tag
                  (tag_name))
                (text)
                (component_call
                  (dotted_name)
                  (zig_expr_free))
                (text)
                (component_call
                  (dotted_name)
                  (zig_expr_free))
                (text)
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<td><b>1</b></td><p>Hi <b>2</b> and <b>3</b>!</p>'


def test_component_call_with_children_after_content(zt):
    result = zt.run(
        '''
        templ Card() { <div class="card">@children</div> }
        pub templ run() {
            <section>@Card() { <p>Hello</p> }</section>
        }
        ''',
        expected_ast='''
        (source_file
          (template
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
                      (attr_static_part))))
                (component_call
                  (dotted_name))
                (close_tag
                  (tag_name)))))
          (template
            (pub_keyword)
            (templ_keyword)
            (template_name
              (name))
            (template_body
              (element
                (open_tag
                  (tag_name))
                (component_call
                  (dotted_name)
                  (children_block
                    (element
                      (open_tag
                        (tag_name))
                      (text)
                      (close_tag
                        (tag_name)))))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<section><div class="card"><p>Hello</p></div></section>'


def test_builtin_after_content_is_text(zt):
    result = zt.run(
        'pub templ run() { <code>x = @tagName(e)</code> }',
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
                (text)
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<code>x = @tagName(e)</code>'


def test_builtin_in_inline_branch(zt):
    """A Zig builtin in an inline if branch is code, not a component call."""
    result = zt.run(
        '''
        pub templ run(r: anyerror![]const u8) {
            <p>{if (r) |v| v else |err| @errorName(err)}</p>
        }
        ''',
        args='.{error.Nope}',
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
                  (inline_if
                    (zig_expr_free)
                    (capture
                      (capture_content))
                    (zig_branch_expr)
                    (capture
                      (capture_content))
                    (zig_branch_expr)))
                (close_tag
                  (tag_name))))))
        ''',
    )
    assert result == '<p>Nope</p>'


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
