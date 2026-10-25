# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] - 2026-10-25

### Changed

- Rendering is faster. Integers are written straight into the writer's buffer ([#37], [#41]),
  adjacent static output is merged into one write with a fast path for short writes ([#38], [#40]),
  escaping scans a vector at a time ([#42]) and short strings are escaped inline ([#44]),
  and the generated writing helpers mark the writer `noalias` ([#45]).

### Fixed

- A compile error inside an inline `{if ...}` branch or `else` capture now points at that
  branch instead of the expression's opening `{` ([#52]).

## [0.2.0] - 2026-10-11

### Breaking changes

- Dynamic values in URL attributes (`href`, `src`, `action`, `hx-get`, ...) are now checked for a safe scheme.
  Values that aren't relative URLs and don't use `http`, `https`, `mailto`, `tel`, `ftp` or `ftps` are replaced
  with `about:invalid#ZtFailedSanitizationURL`. Wrap trusted URLs in `zt.Url` to skip the check. ([#33])
- Values with a `format` method are now written through it, instead of as a struct dump. ([#34])

### Added

- `zt.fmt(func, .{args})` lets a template use a function that writes to a writer. ([#34])
- `zt.Url`, `zt.isSafeUrl` and `zt.invalid_url` for working with URL sanitization. ([#33])
- `{!...}` accepts optionals, string literals, and values with `format` or `formatHtml` methods. ([#34])

### Changed

- Compile errors in generated code point back to the `.zt` source: lines with user code end with a
  `// file.zt:line:col` comment, which Zig shows next to the error. ([#32])
- The generated file keeps the line numbers of the Zig code at the top of the template. ([#32])
- A template parameter can now be called `writer`. ([#34])

### Security

- Fixed XSS through `javascript:` and other dangerous URLs in dynamic URL attributes, which were only
  HTML-escaped. ([#33])

## [0.1.0] - 2026-10-09

Initial release.

[Unreleased]: https://github.com/lalinsky/zt/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/lalinsky/zt/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/lalinsky/zt/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/lalinsky/zt/releases/tag/v0.1.0
[#32]: https://github.com/lalinsky/zt/pull/32
[#33]: https://github.com/lalinsky/zt/pull/33
[#34]: https://github.com/lalinsky/zt/pull/34
[#37]: https://github.com/lalinsky/zt/pull/37
[#38]: https://github.com/lalinsky/zt/pull/38
[#40]: https://github.com/lalinsky/zt/pull/40
[#41]: https://github.com/lalinsky/zt/pull/41
[#42]: https://github.com/lalinsky/zt/pull/42
[#44]: https://github.com/lalinsky/zt/pull/44
[#45]: https://github.com/lalinsky/zt/pull/45
[#52]: https://github.com/lalinsky/zt/pull/52
