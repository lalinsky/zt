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
source = { path = "/home/lukas/projects/zt/editor/tree-sitter-zt" }
```

## 2. Build Grammar

```sh
hx --grammar fetch
hx --grammar build
```

## 3. Link Queries

```sh
mkdir -p ~/.config/helix/runtime/queries
ln -s /home/lukas/projects/zt/editor/tree-sitter-zt/queries ~/.config/helix/runtime/queries/zt
```
