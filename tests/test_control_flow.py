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


def test_inline_for(zt):
    result = zt.run(
        'pub templ run(items: []const []const u8) { {for (items) |x| <i>{x}</i>} }',
        args='.{&[_][]const u8{"a", "b"}}',
    )
    assert result == '<i>a</i><i>b</i>'


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
