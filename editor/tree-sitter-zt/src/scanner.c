#include "tree_sitter/parser.h"
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Order must match externals[] in grammar.js
typedef enum {
    ZIG_CODE,
    ZIG_EXPR,         // _expr_content: won't consume if/for/switch keywords
    ZIG_EXPR_FREE,    // attributes, conditions: unconstrained
    ZIG_BRANCH_EXPR,  // _branch positions: like ZIG_EXPR + rejects <, @, { as first char
    RAW_TEXT,         // raw content of <style> and <script> elements
    TEXT,             // text between tags, stops before inline component calls
    ELSE_KEYWORD,     // "else", only to know when it is valid
    OPEN_PAREN,       // "(", only to know when component arguments can follow
} TokenType;

void *tree_sitter_zt_external_scanner_create(void) { return NULL; }
void tree_sitter_zt_external_scanner_destroy(void *p) { (void)p; }
unsigned tree_sitter_zt_external_scanner_serialize(void *p, char *buf) { (void)p; (void)buf; return 0; }
void tree_sitter_zt_external_scanner_deserialize(void *p, const char *buf, unsigned n) { (void)p; (void)buf; (void)n; }

static void skip_ws(TSLexer *l) { l->advance(l, true); }
static void consume(TSLexer *l) { l->advance(l, false); }

static bool is_space(int32_t c) { return c == ' ' || c == '\t'; }
static bool is_newline(int32_t c) { return c == '\n' || c == '\r'; }
static bool is_ident(int32_t c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

// Advance through str speculatively. Returns true if matched.
// On false return from the calling scan_* function, position resets.
static bool match_str(TSLexer *l, const char *s) {
    for (int i = 0; s[i]; i++) {
        if (l->lookahead != (unsigned char)s[i]) return false;
        l->advance(l, false);
    }
    return true;
}

// Check if at "templ" or "pub templ" — for zig_code to yield to template declarations.
static bool at_template_decl(TSLexer *l) {
    while (is_space(l->lookahead)) l->advance(l, false);
    if (l->lookahead == 'p') {
        if (!match_str(l, "pub")) return false;
        if (!is_space(l->lookahead)) return false;
        while (is_space(l->lookahead)) l->advance(l, false);
    }
    if (!match_str(l, "templ")) return false;
    int32_t c = l->lookahead;
    return is_space(c) || is_newline(c) || c == 0;
}

// Check if at a template control-flow keyword ("if", "for", "switch") followed by ( or space.
// Returns false if not — but may have advanced a few chars speculatively.
static bool at_control_flow_keyword(TSLexer *l) {
    int32_t c = l->lookahead;
    if (c == 'i') {
        l->advance(l, false);
        if (l->lookahead != 'f') return false;
        l->advance(l, false);
        c = l->lookahead;
        return c == '(' || is_space(c) || is_newline(c);
    }
    if (c == 'f') {
        l->advance(l, false);
        if (l->lookahead != 'o') return false;
        l->advance(l, false);
        if (l->lookahead != 'r') return false;
        l->advance(l, false);
        c = l->lookahead;
        return c == '(' || is_space(c) || is_newline(c);
    }
    if (c == 's') {
        l->advance(l, false);
        if (l->lookahead != 'w') return false;
        l->advance(l, false);
        if (l->lookahead != 'i') return false;
        l->advance(l, false);
        if (l->lookahead != 't') return false;
        l->advance(l, false);
        if (l->lookahead != 'c') return false;
        l->advance(l, false);
        if (l->lookahead != 'h') return false;
        l->advance(l, false);
        c = l->lookahead;
        return c == '(' || is_space(c) || is_newline(c);
    }
    return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Zig builtins: an @name in this list is Zig code, not a component call.
// Union of std.zig.BuiltinFn.list in Zig 0.16 and 0.17, sorted for bsearch.
// ─────────────────────────────────────────────────────────────────────────────
static const char *const builtins[] = {
    "Enum",
    "EnumLiteral",
    "FieldType",
    "Fn",
    "Frame",
    "Int",
    "Pointer",
    "SpirvType",
    "Struct",
    "This",
    "Tuple",
    "TypeOf",
    "Union",
    "Vector",
    "abs",
    "addWithOverflow",
    "addrSpaceCast",
    "alignCast",
    "alignOf",
    "as",
    "atomicLoad",
    "atomicRmw",
    "atomicStore",
    "backingInt",
    "bitCast",
    "bitOffsetOf",
    "bitReverse",
    "bitSizeOf",
    "branchHint",
    "breakpoint",
    "byteSwap",
    "cDefine",
    "cImport",
    "cInclude",
    "cUndef",
    "cVaArg",
    "cVaCopy",
    "cVaEnd",
    "cVaStart",
    "call",
    "ceil",
    "clz",
    "cmpxchgStrong",
    "cmpxchgWeak",
    "compileError",
    "compileLog",
    "constCast",
    "cos",
    "ctz",
    "disableInstrumentation",
    "disableIntrinsics",
    "divCeil",
    "divExact",
    "divFloor",
    "divTrunc",
    "embedFile",
    "enumFromInt",
    "errorCast",
    "errorFromInt",
    "errorName",
    "errorReturnTrace",
    "exp",
    "exp2",
    "export",
    "extern",
    "field",
    "fieldParentPtr",
    "floatCast",
    "floatFromInt",
    "floor",
    "frame",
    "frameAddress",
    "fromBackingInt",
    "hasDecl",
    "hasField",
    "import",
    "inComptime",
    "intCast",
    "intFromBool",
    "intFromEnum",
    "intFromError",
    "intFromFloat",
    "intFromPtr",
    "log",
    "log10",
    "log2",
    "max",
    "memcpy",
    "memmove",
    "memset",
    "min",
    "mod",
    "mulAdd",
    "mulWithOverflow",
    "offsetOf",
    "panic",
    "popCount",
    "prefetch",
    "ptrCast",
    "ptrFromInt",
    "reduce",
    "rem",
    "returnAddress",
    "round",
    "select",
    "setEvalBranchQuota",
    "setFloatMode",
    "setRuntimeSafety",
    "shlExact",
    "shlWithOverflow",
    "shrExact",
    "shuffle",
    "sin",
    "sizeOf",
    "splat",
    "sqrt",
    "src",
    "subWithOverflow",
    "tagName",
    "tan",
    "trap",
    "trunc",
    "truncate",
    "typeInfo",
    "typeName",
    "unionInit",
    "volatileCast",
    "wasmMemoryGrow",
    "wasmMemorySize",
    "workGroupId",
    "workGroupSize",
    "workItemId",
};

static int compare_name(const void *key, const void *elem) {
    return strcmp((const char *)key, *(const char *const *)elem);
}

static bool is_builtin(const char *name) {
    return bsearch(name, builtins, sizeof(builtins) / sizeof(builtins[0]), sizeof(builtins[0]), compare_name) != NULL;
}

// Consume an @name (the lexer is at '@') and copy the name without the '@'
// into buf. Dots are included, like in @ui.Button. Names that don't fit
// are truncated, which is fine since no builtin is that long.
static void scan_at_name(TSLexer *l, char *buf, size_t size) {
    size_t len = 0;
    consume(l); // '@'
    while (is_ident(l->lookahead) || l->lookahead == '.') {
        if (len + 1 < size) buf[len++] = (char)l->lookahead;
        consume(l);
    }
    buf[len] = 0;
}

typedef enum {
    AT_TEXT,       // not a call: an email address, a builtin like @tagName(x), ...
    AT_CALL,       // @Name(args) or @children, a call anywhere in content
    AT_PLAIN_NAME, // @name without arguments, a call only at the start of a node
} AtKind;

// Classify the @name at the lexer position, like checkInlineComponentCall in
// src/parser.zig. Consumes the name and any spaces after it.
static AtKind scan_at(TSLexer *l) {
    char name[64];
    scan_at_name(l, name, sizeof(name));
    if (!((name[0] >= 'a' && name[0] <= 'z') || (name[0] >= 'A' && name[0] <= 'Z') || name[0] == '_')) return AT_TEXT;
    if (is_builtin(name)) return AT_TEXT;
    if (strcmp(name, "children") == 0) return AT_CALL;
    while (is_space(l->lookahead)) consume(l);
    if (l->lookahead == '(') return AT_CALL;
    return AT_PLAIN_NAME;
}

// ─────────────────────────────────────────────────────────────────────────────
// TEXT: text between tags, up to '<', '{' or '}'
//
// Like parseText in src/parser.zig, text stops before a component call
// (@Name(args) or @children), but not before an email address or a builtin.
// At the start of text, it yields to control-flow keywords and to a component
// call. An @name without arguments is a call when it follows whitespace, as
// at the start of a line or a block, and text when it is glued to the
// preceding tag (<div>@test</div>) or text.
// ─────────────────────────────────────────────────────────────────────────────
static bool is_text_end(int32_t c) { return c == '<' || c == '{' || c == '}'; }

static bool scan_text(TSLexer *l, bool else_valid, bool paren_valid) {
    bool skipped_ws = false;
    bool skipped_newline = false;
    while (is_space(l->lookahead) || is_newline(l->lookahead)) {
        if (is_newline(l->lookahead)) skipped_newline = true;
        skip_ws(l);
        skipped_ws = true;
    }

    // Right after a component name, arguments on the same line belong to the call
    if (paren_valid && !skipped_newline && l->lookahead == '(') return false;

    if (l->eof(l) || is_text_end(l->lookahead)) return false;

    if (l->lookahead == '@') {
        AtKind kind = scan_at(l);
        if (kind == AT_CALL) return false;
        if (kind == AT_PLAIN_NAME && skipped_ws) return false;
    } else {
        if (at_control_flow_keyword(l)) return false;
        if (else_valid && match_str(l, "else") && !is_ident(l->lookahead)) return false;
    }

    for (;;) {
        if (l->eof(l) || is_text_end(l->lookahead)) break;
        if (l->lookahead == '@') {
            l->mark_end(l); // tentative end before '@'
            if (scan_at(l) == AT_CALL) {
                l->result_symbol = TEXT;
                return true;
            }
            continue;
        }
        consume(l);
    }

    l->mark_end(l);
    l->result_symbol = TEXT;
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// ZIG_CODE: consume lines of Zig code until a template declaration
// ─────────────────────────────────────────────────────────────────────────────
static bool scan_zig_code(TSLexer *l) {
    while (is_space(l->lookahead) || is_newline(l->lookahead)) skip_ws(l);

    if (l->eof(l)) return false;
    if (at_template_decl(l)) return false; // resets on false return

    bool has_content = false;
    for (;;) {
        while (!is_newline(l->lookahead) && !l->eof(l)) {
            consume(l);
            has_content = true;
        }
        while (is_newline(l->lookahead)) consume(l);

        l->mark_end(l); // tentative end after this line

        // Peek at leading whitespace of next line
        while (is_space(l->lookahead)) l->advance(l, false);

        if (l->eof(l) || at_template_decl(l)) break;
        // Not a template — continue consuming. The peeked whitespace will be
        // included in the token when mark_end is updated at end of next line.
    }

    if (!has_content) return false;
    l->result_symbol = ZIG_CODE;
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// ZIG_EXPR / ZIG_EXPR_FREE / ZIG_BRANCH_EXPR: consume a balanced Zig expression
//
// Stops at depth-0: ')', '}', '|', ','
// Also stops at depth-0 "else" keyword (scans ahead speculatively)
//
// block_keywords=true  → also stops before "if"/"for"/"switch" at depth 0
// branch_mode=true     → also returns false if first char is '<', '@', or '{'
//                         so element/component_call/branch_block win in _branch
// ─────────────────────────────────────────────────────────────────────────────
static void consume_string(TSLexer *l, int32_t quote) {
    consume(l); // opening quote
    while (!l->eof(l)) {
        int32_t c = l->lookahead;
        if (c == '\\') { consume(l); consume(l); }
        else if (c == quote) { consume(l); break; }
        else consume(l);
    }
}

// yield_excl: return false when first char is '!' so raw_marker ("!") can win in expr_block
static bool scan_zig_expr(TSLexer *l, bool block_keywords, bool branch_mode, bool yield_excl, TokenType result) {
    while (is_space(l->lookahead) || is_newline(l->lookahead)) skip_ws(l);

    if (l->eof(l)) return false;

    int32_t first = l->lookahead;

    // In _branch context, yield to element (<), component_call (@), branch_block ({),
    // but a builtin like @errorName(err) is Zig code
    if (branch_mode && (first == '<' || first == '{')) return false;
    if (branch_mode && first == '@') {
        char name[64];
        scan_at_name(l, name, sizeof(name));
        if (!is_builtin(name)) return false;
    }

    // In _expr_content, yield to raw_marker ("!") so {!expr} is parsed correctly
    if (yield_excl && first == '!') return false;

    // In _expr_content context, yield to inline control-flow keywords.
    // at_control_flow_keyword may speculatively consume 1-2 chars; if it returns
    // false for a variable like `s`, `i`, `f`, those chars are part of the token.
    if (block_keywords && at_control_flow_keyword(l)) return false;

    int paren = 0, brace = 0, bracket = 0;
    // If at_control_flow_keyword consumed chars speculatively and returned false,
    // we've already advanced past the first char — mark it as real content.
    bool has = (block_keywords && (first == 'i' || first == 'f' || first == 's')) || first == '@';

    for (;;) {
        int32_t c = l->lookahead;
        if (l->eof(l)) break;

        if (paren == 0 && brace == 0 && bracket == 0) {
            if (c == ')' || c == '}' || c == '|' || c == ',') break;

            // In branch positions, speculatively check for "else" keyword at depth 0.
            // Not needed for ZIG_EXPR/_FREE: those contexts never have a template
            // `else` clause following the expression, and stopping at `else` would
            // wrongly truncate Zig expressions like `if (x) "a" else "b"` in attrs.
            if (result == ZIG_BRANCH_EXPR && c == 'e' && has) {
                l->mark_end(l); // tentative end before 'e'
                consume(l);
                if (l->lookahead == 'l') {
                    consume(l);
                    if (l->lookahead == 's') {
                        consume(l);
                        if (l->lookahead == 'e') {
                            consume(l);
                            if (!is_ident(l->lookahead)) {
                                // "else" keyword — stop before it
                                l->result_symbol = result;
                                return true;
                            }
                        }
                    }
                }
                // Not "else" — extend mark to include what we consumed
                has = true;
                l->mark_end(l);
                continue;
            }
        }

        if (c == '"' || c == '\'') { consume_string(l, c); }
        else if (c == '(') { paren++;    consume(l); }
        else if (c == ')') { if (!paren)   break; paren--;    consume(l); }
        else if (c == '{') { brace++;    consume(l); }
        else if (c == '}') { if (!brace)   break; brace--;    consume(l); }
        else if (c == '[') { bracket++;  consume(l); }
        else if (c == ']') { if (!bracket) break; bracket--;  consume(l); }
        else consume(l);

        has = true;
    }

    if (!has) return false;
    l->mark_end(l);
    l->result_symbol = result;
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// RAW_TEXT: consume everything until </ (for style and script elements)
// ─────────────────────────────────────────────────────────────────────────────
static bool scan_raw_text(TSLexer *l) {
    bool has_content = false;
    for (;;) {
        if (l->eof(l)) break;
        if (l->lookahead == '<') {
            l->mark_end(l); // tentative end before '<'
            l->advance(l, false);
            if (l->lookahead == '/') {
                if (!has_content) return false;
                l->result_symbol = RAW_TEXT;
                return true;
            }
            // '<' not followed by '/' — include it and continue
            has_content = true;
            l->mark_end(l);
        } else {
            consume(l);
            has_content = true;
        }
    }
    if (!has_content) return false;
    l->mark_end(l);
    l->result_symbol = RAW_TEXT;
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────

bool tree_sitter_zt_external_scanner_scan(
    void *payload,
    TSLexer *lexer,
    const bool *valid_symbols
) {
    (void)payload;
    if (valid_symbols[RAW_TEXT])        return scan_raw_text(lexer);
    if (valid_symbols[TEXT])            return scan_text(lexer, valid_symbols[ELSE_KEYWORD], valid_symbols[OPEN_PAREN]);
    if (valid_symbols[ZIG_CODE])        return scan_zig_code(lexer);
    if (valid_symbols[ZIG_EXPR])        return scan_zig_expr(lexer, true,  false, true,  ZIG_EXPR);
    if (valid_symbols[ZIG_EXPR_FREE])   return scan_zig_expr(lexer, false, false, false, ZIG_EXPR_FREE);
    if (valid_symbols[ZIG_BRANCH_EXPR]) return scan_zig_expr(lexer, true,  true,  false, ZIG_BRANCH_EXPR);
    return false;
}
