# Helix

## 1. Language & Grammar Setup

Add the following to `~/.config/helix/languages.toml`:

```toml
[[language]]
name = "zt"
scope = "source.zt"
roots = ["build.zig", ".git"]
file-types = ["zt"]
comment-token = "//"
grammar = "zt"
indent = { tab-width = 4, unit = "    " }

[[grammar]]
name = "zt"
source = { git = "https://github.com/lalinsky/zt", rev = "main", subpath = "editor/tree-sitter-zt" }
```

## 2. Build Grammar

```sh
hx --grammar fetch
hx --grammar build
```

## 3. Copy Queries

From the root of this repository:

```sh
cp -r editor/helix/queries/zt ~/.config/helix/runtime/queries/zt
```
