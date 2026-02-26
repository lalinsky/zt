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
