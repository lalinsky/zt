; Inject Zig highlighting into top-level Zig code blocks (complete declarations)
((zig_code) @injection.content
  (#set! injection.language "zig"))

; Expression nodes are Zig fragments — inject best-effort; the Zig parser may
; not fully parse them as they are not complete source files.
((zig_expr) @injection.content
  (#set! injection.language "zig"))

((zig_expr_free) @injection.content
  (#set! injection.language "zig"))

((zig_branch_expr) @injection.content
  (#set! injection.language "zig"))
