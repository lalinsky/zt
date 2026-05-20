; Keywords — capture names match tree-sitter-zig for visual consistency
(pub_keyword) @keyword.modifier
(templ_keyword) @keyword.function
"if" @keyword.conditional
"else" @keyword.conditional
"for" @keyword.repeat
"switch" @keyword.conditional

; Template declaration
(template (template_name) @function)
(parameter name: (name) @variable.parameter)
(parameter type: (type_expr) @type)

; Captures (loop/optional variables)
(capture (capture_content) @variable)

; HTML structure
(open_tag (tag_name) @tag)
(close_tag (tag_name) @tag)
(self_closing_tag (tag_name) @tag)
"<" @punctuation.bracket
">" @punctuation.bracket
"</" @punctuation.bracket
"/>" @punctuation.bracket
(doctype) @tag
(html_comment) @comment

; Attributes
(attribute_name) @tag.attribute
(attr_static_part) @string
(attr_static_part_sq) @string

; Component calls  @Name(...)
"@" @punctuation.special
(component_call (dotted_name) @function.call)

; Raw output marker {! ... }
(raw_marker) @operator

; Switch patterns
(switch_pattern) @constant

; Punctuation
"{" @punctuation.bracket
"}" @punctuation.bracket
"(" @punctuation.bracket
")" @punctuation.bracket
"|" @punctuation.bracket
"=>" @operator
"," @punctuation.delimiter
":" @punctuation.delimiter

; Text content between tags
(text) @string.special

; Zig embedded content — highlighted via injection where possible,
; @embedded gives a baseline style for the rest
(zig_code) @embedded
(zig_expr) @embedded
(zig_expr_free) @embedded
(zig_branch_expr) @embedded
