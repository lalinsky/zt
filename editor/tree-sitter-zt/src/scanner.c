#include "tree_sitter/parser.h"
#include <stdbool.h>
#include <stdint.h>

// Order must match externals[] in grammar.js
typedef enum {
    ZIG_CODE,
    ZIG_EXPR,         // _expr_content: won't consume if/for/switch keywords
    ZIG_EXPR_FREE,    // attributes, conditions: unconstrained
    ZIG_BRANCH_EXPR,  // _branch positions: like ZIG_EXPR + rejects <, @, { as first char
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

    // In _branch context, yield to element (<), component_call (@), branch_block ({)
    if (branch_mode && (first == '<' || first == '@' || first == '{')) return false;

    // In _expr_content, yield to raw_marker ("!") so {!expr} is parsed correctly
    if (yield_excl && first == '!') return false;

    // In _expr_content context, yield to inline control-flow keywords.
    // at_control_flow_keyword may speculatively consume 1-2 chars; if it returns
    // false for a variable like `s`, `i`, `f`, those chars are part of the token.
    if (block_keywords && at_control_flow_keyword(l)) return false;

    int paren = 0, brace = 0, bracket = 0;
    // If at_control_flow_keyword consumed chars speculatively and returned false,
    // we've already advanced past the first char — mark it as real content.
    bool has = block_keywords && (first == 'i' || first == 'f' || first == 's');

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

bool tree_sitter_zt_external_scanner_scan(
    void *payload,
    TSLexer *lexer,
    const bool *valid_symbols
) {
    (void)payload;
    if (valid_symbols[ZIG_CODE])        return scan_zig_code(lexer);
    if (valid_symbols[ZIG_EXPR])        return scan_zig_expr(lexer, true,  false, true,  ZIG_EXPR);
    if (valid_symbols[ZIG_EXPR_FREE])   return scan_zig_expr(lexer, false, false, false, ZIG_EXPR_FREE);
    if (valid_symbols[ZIG_BRANCH_EXPR]) return scan_zig_expr(lexer, true,  true,  false, ZIG_BRANCH_EXPR);
    return false;
}
