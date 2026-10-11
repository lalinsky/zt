INVALID = 'about:invalid#ZtFailedSanitizationURL'


def generated(zt):
    return (zt.workdir / "src/tpl.zig").read_text()


def test_dynamic_href_allowed(zt):
    result = zt.run(
        'pub templ run(url: []const u8) { <a href={url}>x</a> }',
        args='.{"https://example.com/?a=1&b=2"}',
    )
    assert result == '<a href="https://example.com/?a=1&amp;b=2">x</a>'


def test_dynamic_href_relative(zt):
    result = zt.run(
        'pub templ run(url: []const u8) { <a href={url}>x</a> }',
        args='.{"/a:b"}',
    )
    assert result == '<a href="/a:b">x</a>'


def test_dynamic_href_javascript(zt):
    result = zt.run(
        'pub templ run(url: []const u8) { <a href={url}>x</a> }',
        args='.{"JaVaScRiPt:alert(1)"}',
    )
    assert result == f'<a href="{INVALID}">x</a>'


def test_dynamic_src_data(zt):
    result = zt.run(
        'pub templ run(url: []const u8) { <img src={url} /> }',
        args='.{"data:text/html,hi"}',
    )
    assert result == f'<img src="{INVALID}">'


def test_dynamic_hx_get(zt):
    result = zt.run(
        'pub templ run(url: []const u8) { <button hx-get={url}>x</button> }',
        args='.{"javascript:alert(1)"}',
    )
    assert result == f'<button hx-get="{INVALID}">x</button>'


def test_dynamic_href_null_omitted(zt):
    result = zt.run(
        'pub templ run(url: ?[]const u8) { <a href={url}>x</a> }',
        args='.{null}',
    )
    assert result == '<a>x</a>'


def test_dynamic_href_trusted_url(zt):
    result = zt.run(
        'pub templ run(url: []const u8) { <a href={zt.Url{ .value = url }}>x</a> }',
        args='.{"javascript:go(\\"x\\")"}',
    )
    assert result == '<a href="javascript:go(&quot;x&quot;)">x</a>'


def test_dynamic_non_url_attr_unchecked(zt):
    result = zt.run(
        'pub templ run(v: []const u8) { <div title={v}></div> }',
        args='.{"javascript:alert(1)"}',
    )
    assert result == '<div title="javascript:alert(1)"></div>'
    assert 'zt.writeAttr(writer, "title", v)' in generated(zt)


def test_interpolated_relative_prefix_unchecked(zt):
    result = zt.run(
        'pub templ run(id: []const u8) { <a href="/users/{id}">x</a> }',
        args='.{"javascript:alert(1)"}',
    )
    assert result == '<a href="/users/javascript:alert(1)">x</a>'
    assert 'writeUrlPart' not in generated(zt)


def test_interpolated_scheme_prefix_unchecked(zt):
    result = zt.run(
        'pub templ run(host: []const u8) { <a href="https://{host}/">x</a> }',
        args='.{"example.com"}',
    )
    assert result == '<a href="https://example.com/">x</a>'
    assert 'writeUrlPart' not in generated(zt)


def test_interpolated_base_checked_allowed(zt):
    result = zt.run(
        'pub templ run(base: []const u8, id: u32) { <a href="{base}/x/{id}">x</a> }',
        args='.{"https://example.com", 7}',
    )
    assert result == '<a href="https://example.com/x/7">x</a>'
    assert 'writeUrlPart' in generated(zt)


def test_interpolated_base_checked_rejected(zt):
    result = zt.run(
        'pub templ run(base: []const u8, id: u32) { <a href="{base}/x/{id}">x</a> }',
        args='.{"javascript:alert(1)//", 7}',
    )
    assert result == f'<a href="{INVALID}/x/7">x</a>'


def test_interpolated_scheme_in_tail_rejected(zt):
    result = zt.run(
        'pub templ run(proto: []const u8) { <a href="{proto}://example.com">x</a> }',
        args='.{"javascript"}',
    )
    assert result == f'<a href="{INVALID}://example.com">x</a>'


def test_interpolated_scheme_split_across_values_rejected(zt):
    result = zt.run(
        'pub templ run(a: []const u8, b: []const u8) { <a href="{a}{b}">x</a> }',
        args='.{"java", "script:alert(1)"}',
    )
    assert result == f'<a href="java{INVALID}">x</a>'


def test_interpolated_static_prefix_checked(zt):
    result = zt.run(
        'pub templ run(rest: []const u8) { <a href="java{rest}">x</a> }',
        args='.{"script:alert(1)"}',
    )
    assert result == f'<a href="{INVALID}">x</a>'


def test_interpolated_relative_parts(zt):
    result = zt.run(
        'pub templ run(slug: []const u8, id: u32) { <a href="{slug}-{id}">x</a> }',
        args='.{"post", 7}',
    )
    assert result == '<a href="post-7">x</a>'


def test_data_url_attr_checked(zt):
    result = zt.run(
        'pub templ run(url: []const u8) { <div data-url={url}></div> }',
        args='.{"javascript:alert(1)"}',
    )
    assert result == f'<div data-url="{INVALID}"></div>'


def test_xlink_href_checked(zt):
    result = zt.run(
        'pub templ run(url: []const u8) { <use xlink:href={url}></use> }',
        args='.{"javascript:alert(1)"}',
    )
    assert result == f'<use xlink:href="{INVALID}"></use>'
