# Inline control flow

def test_inline_if(zt):
    result = zt.run(
        'pub templ run(x: bool) { {if (x) <b>yes</b>} }',
        args='.{true}',
    )
    assert result == '<b>yes</b>'


def test_inline_if_false(zt):
    result = zt.run(
        'pub templ run(x: bool) { {if (x) <b>yes</b>} }',
        args='.{false}',
    )
    assert result == ''


def test_inline_if_else(zt):
    result = zt.run(
        'pub templ run(x: bool) { {if (x) <b>yes</b> else <i>no</i>} }',
        args='.{false}',
    )
    assert result == '<i>no</i>'


def test_inline_if_zig_expr(zt):
    result = zt.run(
        'pub templ run(x: bool) { {if (x) "yes" else "no"} }',
        args='.{true}',
    )
    assert result == 'yes'


def test_inline_if_capture(zt):
    """Inline if with optional capture."""
    result = zt.run(
        'pub templ run(x: ?[]const u8) { {if (x) |val| <b>{val}</b>} }',
        args='.{"hi"}',
    )
    assert result == '<b>hi</b>'


def test_inline_if_capture_null(zt):
    """Inline if with optional capture, null case."""
    result = zt.run(
        'pub templ run(x: ?[]const u8) { {if (x) |val| <b>{val}</b>} }',
        args='.{null}',
    )
    assert result == ''


def test_inline_if_capture_else(zt):
    """Inline if with optional capture and else."""
    result = zt.run(
        'pub templ run(x: ?[]const u8) { {if (x) |val| <b>{val}</b> else <i>none</i>} }',
        args='.{"test"}',
    )
    assert result == '<b>test</b>'


def test_inline_if_capture_else_null(zt):
    """Inline if with optional capture and else, null case."""
    result = zt.run(
        'pub templ run(x: ?[]const u8) { {if (x) |val| <b>{val}</b> else <i>none</i>} }',
        args='.{null}',
    )
    assert result == '<i>none</i>'


def test_inline_if_capture_zig_expr(zt):
    """Inline if with optional capture returning Zig expression."""
    result = zt.run(
        'pub templ run(x: ?[]const u8) { {if (x) |val| val else "default"} }',
        args='.{"value"}',
    )
    assert result == 'value'


def test_inline_if_else_error_capture(zt):
    """Inline if with error union capture on both branches."""
    result = zt.run(
        '''
const Error = error{Fail};

fn mayFail(fail: bool) Error![]const u8 {
    if (fail) return error.Fail;
    return "success";
}

pub templ run(fail: bool) {
    {if (mayFail(fail)) |val| <b>{val}</b> else |_| <i>error</i>}
}
''',
        args='.{false}',
    )
    assert result == '<b>success</b>'


def test_inline_if_else_error_capture_error_case(zt):
    """Inline if with error union capture, error case."""
    result = zt.run(
        '''
const Error = error{Fail};

fn mayFail(fail: bool) Error![]const u8 {
    if (fail) return error.Fail;
    return "success";
}

pub templ run(fail: bool) {
    {if (mayFail(fail)) |val| <b>{val}</b> else |_| <i>error</i>}
}
''',
        args='.{true}',
    )
    assert result == '<i>error</i>'


def test_inline_for(zt):
    result = zt.run(
        'pub templ run(items: []const []const u8) { {for (items) |x| <i>{x}</i>} }',
        args='.{&[_][]const u8{"a", "b"}}',
    )
    assert result == '<i>a</i><i>b</i>'


def test_inline_for_zig_expr(zt):
    result = zt.run(
        'pub templ run(items: []const i32) { {for (items) |x| x * 2} }',
        args='.{&[_]i32{1, 2, 3}}',
    )
    assert result == '246'


# Block-level control flow

def test_block_if(zt):
    result = zt.run(
        '''pub templ run(x: bool) {
            if (x) { <b>yes</b> }
        }''',
        args='.{true}',
    )
    assert result == '<b>yes</b>'


def test_block_if_else(zt):
    result = zt.run(
        '''pub templ run(x: bool) {
            if (x) { <b>yes</b> } else { <i>no</i> }
        }''',
        args='.{false}',
    )
    assert result == '<i>no</i>'


def test_block_else_if(zt):
    result = zt.run(
        '''pub templ run(x: i32) {
            if (x == 1) { <span>one</span> }
            else if (x == 2) { <span>two</span> }
            else { <span>other</span> }
        }''',
        args='.{2}',
    )
    assert result == '<span>two</span>'


def test_block_if_capture(zt):
    """Block-level if with optional capture."""
    result = zt.run(
        '''pub templ run(x: ?[]const u8) {
            if (x) |val| {
                <span>{val}</span>
            }
        }''',
        args='.{"hello"}',
    )
    assert result == '<span>hello</span>'


def test_block_if_capture_null(zt):
    """Block-level if with optional capture, null case."""
    result = zt.run(
        '''pub templ run(x: ?[]const u8) {
            if (x) |val| {
                <span>{val}</span>
            }
        }''',
        args='.{null}',
    )
    assert result == ''


def test_block_if_capture_else(zt):
    """Block-level if with optional capture and else branch."""
    result = zt.run(
        '''pub templ run(x: ?[]const u8) {
            if (x) |val| {
                <span>{val}</span>
            } else {
                <span>none</span>
            }
        }''',
        args='.{"world"}',
    )
    assert result == '<span>world</span>'


def test_block_if_capture_else_null(zt):
    """Block-level if with optional capture and else branch, null case."""
    result = zt.run(
        '''pub templ run(x: ?[]const u8) {
            if (x) |val| {
                <span>{val}</span>
            } else {
                <span>none</span>
            }
        }''',
        args='.{null}',
    )
    assert result == '<span>none</span>'


def test_block_if_else_error_capture(zt):
    """Block-level if with error union capture on else branch."""
    result = zt.run(
        '''
const Error = error{Fail};

fn mayFail(fail: bool) Error![]const u8 {
    if (fail) return error.Fail;
    return "success";
}

pub templ run(fail: bool) {
    if (mayFail(fail)) |val| {
        <b>{val}</b>
    } else |_| {
        <i>error</i>
    }
}
''',
        args='.{false}',
    )
    assert result == '<b>success</b>'


def test_block_if_else_error_capture_error_case(zt):
    """Block-level if with error union capture, error case."""
    result = zt.run(
        '''
const Error = error{Fail};

fn mayFail(fail: bool) Error![]const u8 {
    if (fail) return error.Fail;
    return "success";
}

pub templ run(fail: bool) {
    if (mayFail(fail)) |val| {
        <b>{val}</b>
    } else |_| {
        <i>error</i>
    }
}
''',
        args='.{true}',
    )
    assert result == '<i>error</i>'


def test_consecutive_if_and_for(zt):
    """Two block-level constructs in sequence (issue #1)."""
    result = zt.run(
        '''pub templ run(items: []const []const u8) {
            if (items.len == 0) {
                <p>No items</p>
            }
            for (items) |item| {
                <article>
                    <header>{item}</header>
                </article>
            }
        }''',
        args='.{&[_][]const u8{"a", "b"}}',
    )
    assert result == '<article><header>a</header></article><article><header>b</header></article>'


def test_consecutive_if_and_for_empty(zt):
    """Two block-level constructs in sequence, empty case (issue #1)."""
    result = zt.run(
        '''pub templ run(items: []const []const u8) {
            if (items.len == 0) {
                <p>No items</p>
            }
            for (items) |item| {
                <article>
                    <header>{item}</header>
                </article>
            }
        }''',
        args='.{&[_][]const u8{}}',
    )
    assert result == '<p>No items</p>'


def test_consecutive_ifs(zt):
    """Two consecutive if blocks (issue #1)."""
    result = zt.run(
        '''pub templ run(a: bool, b: bool) {
            if (a) {
                <p>A</p>
            }
            if (b) {
                <p>B</p>
            }
        }''',
        args='.{true, true}',
    )
    assert result == '<p>A</p><p>B</p>'


def test_consecutive_fors(zt):
    """Two consecutive for blocks (issue #1)."""
    result = zt.run(
        '''pub templ run(a: []const []const u8, b: []const []const u8) {
            for (a) |x| {
                <p>{x}</p>
            }
            for (b) |y| {
                <span>{y}</span>
            }
        }''',
        args='.{&[_][]const u8{"a", "b"}, &[_][]const u8{"c", "d"}}',
    )
    assert result == '<p>a</p><p>b</p><span>c</span><span>d</span>'


def test_block_for(zt):
    result = zt.run(
        '''pub templ run(items: []const []const u8) {
            <ul>
                for (items) |x| { <li>{x}</li> }
            </ul>
        }''',
        args='.{&[_][]const u8{"a", "b"}}',
    )
    assert result == '<ul><li>a</li><li>b</li></ul>'


def test_block_for_index(zt):
    result = zt.run(
        '''pub templ run(items: []const []const u8) {
            for (items, 0..) |x, i| { <span>{i}:{x}</span> }
        }''',
        args='.{&[_][]const u8{"a", "b"}}',
    )
    assert result == '<span>0:a</span><span>1:b</span>'


def test_inline_for_index(zt):
    """Inline for loop with index."""
    result = zt.run(
        'pub templ run(items: []const []const u8) { {for (items, 0..) |x, i| <span>{i}:{x}</span>} }',
        args='.{&[_][]const u8{"a", "b"}}',
    )
    assert result == '<span>0:a</span><span>1:b</span>'


def test_for_empty(zt):
    """For loop over empty slice produces no output."""
    result = zt.run(
        '''pub templ run(items: []const []const u8) {
            <ul>
                for (items) |x| { <li>{x}</li> }
            </ul>
        }''',
        args='.{&[_][]const u8{}}',
    )
    assert result == '<ul></ul>'


def test_nested_for(zt):
    """Nested for loops."""
    result = zt.run(
        '''pub templ run(rows: []const []const i32) {
            <table>
                for (rows) |row| {
                    <tr>
                        for (row) |cell| {
                            <td>{cell}</td>
                        }
                    </tr>
                }
            </table>
        }''',
        args='.{&[_][]const i32{&[_]i32{1, 2}, &[_]i32{3, 4}}}',
    )
    assert result == '<table><tr><td>1</td><td>2</td></tr><tr><td>3</td><td>4</td></tr></table>'


def test_directly_nested_for(zt):
    """For loop directly inside another for loop without intermediate elements."""
    result = zt.run(
        '''pub templ run(rows: []const []const i32) {
            for (rows) |row| {
                for (row) |cell| {
                    <span>{cell}</span>
                }
            }
        }''',
        args='.{&[_][]const i32{&[_]i32{1, 2}, &[_]i32{3, 4}}}',
    )
    assert result == '<span>1</span><span>2</span><span>3</span><span>4</span>'


# Switch

def test_switch_basic(zt):
    result = zt.run(
        '''const Status = enum { active, pending, inactive };

        pub templ run(s: Status) {
            switch (s) {
                .active => { <span>Active</span> },
                .pending => { <span>Pending</span> },
                .inactive => { <span>Inactive</span> },
            }
        }''',
        args='.{.active}',
    )
    assert result == '<span>Active</span>'


def test_switch_else(zt):
    result = zt.run(
        '''const Status = enum { active, pending, inactive };

        pub templ run(s: Status) {
            switch (s) {
                .active => { <span>Active</span> },
                else => { <span>Other</span> },
            }
        }''',
        args='.{.inactive}',
    )
    assert result == '<span>Other</span>'


def test_switch_non_block_case(zt):
    result = zt.run(
        '''const Status = enum { active, pending, inactive };

        pub templ run(s: Status) {
            switch (s) {
                .active => <span>Active</span>,
                .pending => <span>Pending</span>,
                else => <span>Other</span>,
            }
        }''',
        args='.{.pending}',
    )
    assert result == '<span>Pending</span>'


def test_switch_capture(zt):
    result = zt.run(
        '''const Value = union(enum) { num: i32, text: []const u8 };

        pub templ run(v: Value) {
            switch (v) {
                .num => |n| { <span>{n}</span> },
                .text => |t| { <span>{t}</span> },
            }
        }''',
        args='.{.{ .num = 42 }}',
    )
    assert result == '<span>42</span>'


def test_switch_capture_text(zt):
    result = zt.run(
        '''const Value = union(enum) { num: i32, text: []const u8 };

        pub templ run(v: Value) {
            switch (v) {
                .num => |n| { <span>{n}</span> },
                .text => |t| { <span>{t}</span> },
            }
        }''',
        args='.{.{ .text = "hello" }}',
    )
    assert result == '<span>hello</span>'


def test_inline_switch(zt):
    result = zt.run(
        '''const Role = enum { admin, user, guest };

        pub templ run(r: Role) {
            {switch (r) { .admin => <b>Admin</b>, .user => <i>User</i>, else => <span>Guest</span> }}
        }''',
        args='.{.user}',
    )
    assert result == '<i>User</i>'


def test_inline_switch_else(zt):
    result = zt.run(
        '''const Role = enum { admin, user, guest };

        pub templ run(r: Role) {
            {switch (r) { .admin => <b>Admin</b>, else => <span>Other</span> }}
        }''',
        args='.{.guest}',
    )
    assert result == '<span>Other</span>'


def test_inline_switch_zig_expr(zt):
    result = zt.run(
        '''const Status = enum { active, pending, inactive };

        pub templ run(s: Status) {
            {switch (s) { .active => "Active", .pending => "Pending", else => "Other" }}
        }''',
        args='.{.active}',
    )
    assert result == 'Active'


def test_switch_capture_zig_expr(zt):
    result = zt.run(
        '''const Value = union(enum) { num: i32, text: []const u8 };

        pub templ run(v: Value) {
            {switch (v) { .num => |n| n * 2, .text => |t| t.len }}
        }''',
        args='.{.{ .num = 21 }}',
    )
    assert result == '42'


def test_inline_switch_func_call(zt):
    """Switch branch with function call containing commas."""
    result = zt.run(
        '''const Status = enum { active, pending };

        fn add(a: i32, b: i32) i32 { return a + b; }

        pub templ run(s: Status) {
            {switch (s) { .active => add(20, 22), .pending => add(1, 2) }}
        }''',
        args='.{.active}',
    )
    assert result == '42'


def test_text_then_switch_then_text(zt):
    """Regression test for https://github.com/lalinsky/zt/issues/17

    Text followed by switch statement should not consume the switch keyword as text.
    """
    result = zt.run(
        '''const Visibility = enum { private, public };

        pub templ run(v: Visibility) {
            <h1>
                test text
                {
                    switch (v) {
                        .private => {
                            <img src="/static/img/lock.svg" />
                        },
                        .public => {
                            <img src="/static/img/public.svg" />
                        },
                    }
                }
                more text
            </h1>
        }''',
        args='.{.private}',
    )
    assert '<h1>' in result
    assert 'test text' in result
    assert '<img src="/static/img/lock.svg">' in result
    assert 'more text' in result
    assert '</h1>' in result
    # Make sure switch is NOT treated as text
    assert 'switch' not in result


def test_inline_switch_with_block_branches(zt):
    """Inline switch with { } blocks containing HTML in branches, sandwiched by text on separate lines."""
    result = zt.run(
        '''const Visibility = enum { private, public };

        pub templ run(v: Visibility) {
            <h1>
                before
                {switch (v) { .private => { <img src="/lock.svg" /> }, .public => { <img src="/public.svg" /> } }}
                after
            </h1>
        }''',
        args='.{.public}',
    )
    assert 'before' in result
    assert '<img src="/public.svg">' in result
    assert 'after' in result
    assert 'switch' not in result


def test_issue17_comment_case1(zt):
    """Test case from issue #17 comment - multiline with newline after {"""
    result = zt.run(
        '''const Visibility = enum { private, public };

        pub templ run(v: Visibility) {
            <h1>
                test text

                {
                    switch (v) {
                        .private => {
                            <img src="/static/img/lock.svg" />
                        },
                        .public => {
                            <img src="/static/img/public.svg" />
                        },
                    }
                }
            </h1>
        }''',
        args='.{.private}',
    )
    assert 'test text' in result
    assert '<img src="/static/img/lock.svg">' in result
    assert 'switch' not in result


def test_issue17_comment_case2(zt):
    """Test case from issue #17 comment - space after { with multiline switch"""
    result = zt.run(
        '''const Visibility = enum { private, public };

        pub templ run(v: Visibility) {
            <h1>
                test text

                { switch (v) {
                    .private => {
                        <img src="/static/img/lock.svg" />
                    },
                    .public => {
                        <img src="/static/img/public.svg" />
                    },
                } }
            </h1>
        }''',
        args='.{.public}',
    )
    assert 'test text' in result
    assert '<img src="/static/img/public.svg">' in result
    assert 'switch' not in result


def test_issue17_comment_if_block(zt):
    """Test case from issue #17 comment - if with block containing HTML after text"""
    result = zt.run(
        '''pub templ run(number_of_portions: ?u32) {
            <h2>
                test text

                {
                    if (number_of_portions) |n| {
                        <p>Portions: {n}</p>
                    }
                }
            </h2>
        }''',
        args='.{4}',
    )
    assert 'test text' in result
    assert '<p>Portions: 4</p>' in result
    assert 'if' not in result


def test_issue17_comment_for_block(zt):
    """Test for loop with block containing HTML after text"""
    result = zt.run(
        '''pub templ run(items: []const []const u8) {
            <ul>
                header text

                {
                    for (items) |item| {
                        <li>{item}</li>
                    }
                }
            </ul>
        }''',
        args='.{&.{"apple", "banana"}}',
    )
    assert 'header text' in result
    assert '<li>apple</li>' in result
    assert '<li>banana</li>' in result
    assert 'for' not in result
