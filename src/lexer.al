// Lexer for AL: source text to tokens.

enum Tk {
    Id(str),
    Int(u64, bool), // value, written in decimal
    Float(f64, f32), // the value; the literal rounded once to f32
    Str(str),
    // a keyword: its index in KEYWORDS (KW_FN ...)
    Kw(i64),
    // punctuation: its bytes, the first in the low byte (`'('`, or P_ARROW for `->`)
    P(i64),
    Nl,
    Eof,
}

struct Token {
    t: Tk
    pos: Pos
}

priv KEYWORDS := [26]str{
    "fn", "struct", "enum", "const", "test", "use", "if", "else", "while", "loop", "for", "in",
    "return", "break", "continue", "assert", "true", "false", "nil", "match", "by", "defer",
    "inline", "noinline", "extern", "priv",
}

// the keywords by their index in KEYWORDS
const KW_FN = 0
const KW_STRUCT = 1
const KW_ENUM = 2
const KW_CONST = 3
const KW_TEST = 4
const KW_USE = 5
const KW_IF = 6
const KW_ELSE = 7
const KW_WHILE = 8
const KW_LOOP = 9
const KW_FOR = 10
const KW_IN = 11
const KW_RETURN = 12
const KW_BREAK = 13
const KW_CONTINUE = 14
const KW_ASSERT = 15
const KW_TRUE = 16
const KW_FALSE = 17
const KW_NIL = 18
const KW_MATCH = 19
const KW_BY = 20
const KW_DEFER = 21
const KW_INLINE = 22
const KW_NOINLINE = 23
const KW_EXTERN = 24
const KW_PRIV = 25

// punctuation of more than one byte (one byte: the character itself, `P('(')`)
const P_SHL_EQ = 0x3D3C3C // <<=
const P_SHR_EQ = 0x3D3E3E // >>=
const P_RANGE_EQ = 0x3D2E2E // ..=
const P_DECL = 0x3D3A // :=
const P_ARROW = 0x3E2D // ->
const P_EQ = 0x3D3D // ==
const P_NE = 0x3D21 // !=
const P_LE = 0x3D3C // <=
const P_GE = 0x3D3E // >=
const P_LAND = 0x2626 // &&
const P_LOR = 0x7C7C // ||
const P_SHL = 0x3C3C // <<
const P_SHR = 0x3E3E // >>
const P_ADD_EQ = 0x3D2B // +=
const P_SUB_EQ = 0x3D2D // -=
const P_MUL_EQ = 0x3D2A // *=
const P_DIV_EQ = 0x3D2F // /=
const P_REM_EQ = 0x3D25 // %=
const P_AND_EQ = 0x3D26 // &=
const P_OR_EQ = 0x3D7C // |=
const P_XOR_EQ = 0x3D5E // ^=
const P_RANGE = 0x2E2E // ..
const P_FAT_ARROW = 0x3E3D // =>

// the text of a keyword
fn lexer_kw_text(k: i64) -> str {
    return KEYWORDS[k]
}

// the text of a punctuation token
fn lexer_p_text(c: i64) -> str {
    n := if c >> 16 != 0 { 3 } else if c >> 8 != 0 { 2 } else { 1 }
    b := alloc[u8](n)
    for j in 0..n {
        b[j] = u8(c >> (8 * j))
    }
    return b
}

// the keyword index of an identifier-shaped word, or -1
priv fn kw_index(w: str) -> i64 {
    n := len(w)
    if n < 2 || n > 8 {
        return -1
    }
    k := match w[0] {
        'a' => KW_ASSERT
        'b' => if n == 2 { KW_BY } else { KW_BREAK }
        'c' => if n == 5 { KW_CONST } else { KW_CONTINUE }
        'd' => KW_DEFER
        'e' => if w[1] == 'l' { KW_ELSE } else if w[1] == 'n' { KW_ENUM } else { KW_EXTERN }
        'f' => if n == 2 { KW_FN } else if n == 3 { KW_FOR } else { KW_FALSE }
        'i' => if n == 2 { if w[1] == 'f' { KW_IF } else { KW_IN } } else { KW_INLINE }
        'l' => KW_LOOP
        'm' => KW_MATCH
        'n' => if n == 3 { KW_NIL } else { KW_NOINLINE }
        'p' => KW_PRIV
        'r' => KW_RETURN
        's' => KW_STRUCT
        't' => if n == 4 { if w[1] == 'e' { KW_TEST } else { KW_TRUE } } else { -1 }
        'u' => KW_USE
        'w' => KW_WHILE
        _ => -1
    }
    if k >= 0 && w == KEYWORDS[k] {
        return k
    }
    return -1
}

// ---------- f32 value of a float literal ----------
// `f32(v)` of the f64 value `v` rounds twice: wrong when `v` is exactly half-way between two
// f32 values but the literal is not. Then the literal is compared exactly with `v`.

// big natural numbers: little-endian base 2^32 limbs
priv fn big_mul_add(a: *Vec[u64], m: u64, add: u64) {
    carry := add
    for i in 0..a.len {
        x := a[i] * m + carry
        a[i] = x & 0xFFFFFFFF
        carry = x >> 32
    }
    if carry != 0 {
        a.push(carry)
    }
}

priv fn big_cmp(a: *Vec[u64], b: *Vec[u64]) -> i64 {
    while a.len > 0 && a[a.len - 1] == 0 {
        a.pop()
    }
    while b.len > 0 && b[b.len - 1] == 0 {
        b.pop()
    }
    if a.len != b.len {
        return if a.len < b.len { -1 } else { 1 }
    }
    for k in 0..a.len {
        i := a.len - 1 - k
        if a[i] != b[i] {
            return if a[i] < b[i] { -1 } else { 1 }
        }
    }
    return 0
}

// compares the decimal literal `text` (digits, point, exponent) with the positive finite `v`
priv fn dec_cmp_f64(text: str, v: f64) -> i64 {
    a := vec[u64]()
    k := 0
    i := 0
    frac := false
    while i < len(text) && text[i] != 'e' && text[i] != 'E' {
        if text[i] == '.' {
            frac = true
        } else {
            big_mul_add(&a, 10, u64(text[i] - '0'))
            if frac {
                k -= 1
            }
        }
        i += 1
    }
    if i < len(text) {
        e, ok := parse_i64(text[i + 1..])
        if !ok || e > 100000 || e < -100000 {
            return 0
        }
        k += e
    }
    bits := cast[u64](v)
    ex := i64(bits >> 52)
    fr := bits & 0xFFFFFFFFFFFFF
    m := if ex == 0 { fr } else { fr | (u64(1) << 52) }
    q := if ex == 0 { -1074 } else { ex - 1075 }
    b := vec[u64]()
    b.push(m & 0xFFFFFFFF)
    b.push(m >> 32)
    // a * 10^k against b * 2^q
    for _ in 0..max(k, 0) {
        big_mul_add(&a, 10, 0)
    }
    for _ in 0..max(-k, 0) {
        big_mul_add(&b, 10, 0)
    }
    for _ in 0..max(q, 0) {
        big_mul_add(&b, 2, 0)
    }
    for _ in 0..max(-q, 0) {
        big_mul_add(&a, 2, 0)
    }
    return big_cmp(&a, &b)
}

fn lexer_f32(text: str, v: f64) -> f32 {
    r := f32(v)
    if f64(r) == v || v != v || v > 3.4028234663852886e38 {
        return r
    }
    // the f32 neighbour of r on the other side of v
    rb := cast[u32](r)
    other := cast[f32](if f64(r) < v { rb + 1 } else { rb - 1 })
    if f64(r) + f64(other) != 2.0 * v {
        return r
    }
    c := dec_cmp_f64(text, v)
    if c == 0 {
        return r
    }
    up := c > 0
    if up == (f64(other) > f64(r)) {
        return other
    }
    return r
}

// the value of the digit `c` in the given radix, if it is one
priv fn to_digit(c: u8, radix: i64) -> Opt[i64] {
    d := -1
    if c >= '0' && c <= '9' {
        d = i64(c - '0')
    } else if c >= 'a' && c <= 'z' {
        d = i64(c - 'a') + 10
    } else if c >= 'A' && c <= 'Z' {
        d = i64(c - 'A') + 10
    }
    if d >= 0 && d < radix {
        return Some(d)
    }
    return None
}

// the character that starts at s[i], for messages, and its length in bytes: a printable
// ASCII character or a valid UTF-8 sequence as it is, any other byte as `\xHH`
priv fn char_at(s: str, i: i64) -> (str, i64) {
    c := s[i]
    if c >= 0x20 && c < 0x7F {
        return (s[i..i + 1], 1)
    }
    n := 0
    if c >= 0xC2 && c <= 0xDF {
        n = 2
    } else if c >= 0xE0 && c <= 0xEF {
        n = 3
    } else if c >= 0xF0 && c <= 0xF4 {
        n = 4
    }
    ok := n > 0 && i + n <= len(s)
    if ok {
        for k in 1..n {
            if s[i + k] & 0xC0 != 0x80 {
                ok = false
            }
        }
    }
    if ok {
        return (s[i..i + n], n)
    }
    return (concat("\\x", to_upper(hex(u64(c), 2))), 1)
}

// the value of a non-empty text of decimal digits; false on overflow
priv fn parse_u64(text: str) -> (u64, bool) {
    if len(text) == 0 {
        return (0, false)
    }
    v: u64 = 0
    for c in text {
        if c < '0' || c > '9' {
            return (0, false)
        }
        d := u64(c - '0')
        if v > (0xFFFFFFFFFFFFFFFF - d) / 10 {
            return (0, false)
        }
        v = v * 10 + d
    }
    return (v, true)
}

priv fn lexer_pos(file: i64, line: i64, at: i64, line_start: i64) -> Pos {
    return Pos{file: file, line: line, col: at - line_start + 1}
}

// bytes that continue an identifier: [A-Za-z0-9_] (filled on first use)
priv ident_tab: [256]bool
priv ident_tab_ready: bool

priv fn ident_tab_init() {
    for c in 0..256 {
        b := u8(c)
        ident_tab[c] = is_alnum(b) || b == '_'
    }
    ident_tab_ready = true
}

// a token after which a newline ends the statement
priv fn ends_stmt(t: Tk) -> bool {
    return match t {
        Id(_), Int(_, _), Float(_, _), Str(_) => true
        P(p) => p == ')' || p == ']' || p == '}'
        Kw(k) => k == KW_RETURN || k == KW_BREAK || k == KW_CONTINUE || k == KW_TRUE || k == KW_FALSE || k == KW_NIL
        _ => false
    }
}

// the length of the punctuation token that starts with `c` (followed by `c1`, `c2`, or 0 at
// the end), 0 if `c` starts none: the longest one that matches
priv fn punct_len(c: u8, c1: u8, c2: u8) -> i64 {
    return match c {
        '<', '>' => if c1 == c { if c2 == '=' { 3 } else { 2 } } else if c1 == '=' { 2 } else { 1 }
        '.' => if c1 == '.' { if c2 == '=' { 3 } else { 2 } } else { 1 }
        ':' => if c1 == '=' { 2 } else { 1 }
        '-' => if c1 == '>' || c1 == '=' { 2 } else { 1 }
        '=' => if c1 == '=' || c1 == '>' { 2 } else { 1 }
        '&', '|' => if c1 == c || c1 == '=' { 2 } else { 1 }
        '!', '+', '*', '/', '%', '^' => if c1 == '=' { 2 } else { 1 }
        '~', '(', ')', '[', ']', '{', '}', ',', ';', '@' => 1
        _ => 0
    }
}

// the tokens of one file at a time (lexer_lex reuses the buffer)
priv tok_buf: Vec[Token]

// The tokens of `src`; they stay valid until the next call.
fn lexer_lex(src: str, file: i64, errs: *Vec[Diag]) -> Vec[Token] {
    if !ident_tab_ready {
        ident_tab_init()
    }
    s := src
    n := len(s)
    i := 0
    line := 1
    line_start := 0
    // a UTF-8 byte order mark at the start is not part of the text
    if starts_with(s, "\xEF\xBB\xBF") {
        i = 3
        line_start = 3
    }
    out := tok_buf
    out.len = 0
    out.reserve(n / 4 + 16)
    // bracket stack: '(' / '[' suppress newlines, '{' enables them
    stack := vec[u8]()
    while i < n {
        c := s[i]
        if c == '\n' {
            sig := stack.len == 0 || stack[stack.len - 1] == '{'
            if sig && out.len > 0 && ends_stmt(out[out.len - 1].t) {
                out.push(Token{t: Nl, pos: lexer_pos(file, line, i, line_start)})
            }
            i += 1
            line += 1
            line_start = i
            // the indentation of the next line
            while i < n && s[i] == ' ' {
                i += 1
            }
            continue
        }
        if c == ' ' || c == '\t' || c == '\r' {
            i += 1
            while i < n && s[i] == ' ' {
                i += 1
            }
            continue
        }
        if c == '/' && i + 1 < n && s[i + 1] == '/' {
            while i < n && s[i] != '\n' {
                i += 1
            }
            continue
        }
        p := lexer_pos(file, line, i, line_start)
        if ident_tab[c] && !is_digit(c) {
            st := i
            h := (AST_SYM_H0 ^ u64(c)) * AST_SYM_HMUL
            i += 1
            while i < n && ident_tab[s[i]] {
                h = (h ^ u64(s[i])) * AST_SYM_HMUL
                i += 1
            }
            w := src[st..i]
            k := kw_index(w)
            if k >= 0 {
                out.push(Token{t: Kw(k), pos: p})
            } else {
                out.push(Token{t: Id(ast_sym_name(ast_sym_hashed(w, h))), pos: p})
            }
            continue
        }
        if is_digit(c) {
            st := i
            if c == '0' && i + 1 < len(s) && (s[i + 1] == 'x' || s[i + 1] == 'b' || s[i + 1] == 'o') {
                radix := match s[i + 1] {
                    'x' => 16
                    'b' => 2
                    _ => 8
                }
                i += 2
                v: u64 = 0
                any := false
                big := false
                bad := false
                while i < len(s) && (is_alnum(s[i]) || s[i] == '_') {
                    if s[i] != '_' {
                        match to_digit(s[i], radix) {
                            Some(d) => {
                                if v > (0xFFFFFFFFFFFFFFFF - u64(d)) / u64(radix) {
                                    big = true
                                }
                                v = v * u64(radix) + u64(d)
                            }
                            None => {
                                if !bad {
                                    errs.push(Diag{pos: p, msg: fmt("invalid digit `", s[i..i + 1], "` in a base-", radix, " integer literal")})
                                }
                                bad = true
                            }
                        }
                        any = true
                    }
                    i += 1
                }
                if !any {
                    errs.push(Diag{pos: p, msg: "empty integer literal"})
                }
                if big {
                    errs.push(Diag{pos: p, msg: "integer literal too large"})
                    v = 0
                }
                out.push(Token{t: Int(v, false), pos: p})
                continue
            }
            while i < len(s) && (is_digit(s[i]) || s[i] == '_') {
                i += 1
            }
            is_float := false
            // after a `.` a number is a tuple field: `t.0.1` is (t.0).1
            field := out.len > 0 && out[out.len - 1].t == P('.')
            if !field && i + 1 < len(s) && s[i] == '.' && is_digit(s[i + 1]) {
                is_float = true
                i += 1
                while i < len(s) && (is_digit(s[i]) || s[i] == '_') {
                    i += 1
                }
            }
            if !field && i < len(s) && (s[i] == 'e' || s[i] == 'E') {
                j := i + 1
                if j < len(s) && (s[j] == '+' || s[j] == '-') {
                    j += 1
                }
                if j < len(s) && is_digit(s[j]) {
                    is_float = true
                    i = j
                    while i < len(s) && is_digit(s[i]) {
                        i += 1
                    }
                }
            }
            // the literal without its underscores
            text := s[st..i]
            if contains(text, '_') {
                tbuf := alloc[u8](i - st)
                tn := 0
                for k in st..i {
                    if s[k] != '_' {
                        tbuf[tn] = s[k]
                        tn += 1
                    }
                }
                text = tbuf[..tn]
            }
            if is_float {
                v, ok := parse_f64(text)
                if ok {
                    out.push(Token{t: Float(v, lexer_f32(text, v)), pos: p})
                } else {
                    errs.push(Diag{pos: p, msg: "invalid float literal"})
                    out.push(Token{t: Float(0.0, 0.0), pos: p})
                }
            } else {
                v, ok := parse_u64(text)
                if ok {
                    out.push(Token{t: Int(v, true), pos: p})
                } else {
                    errs.push(Diag{pos: p, msg: "integer literal too large"})
                    out.push(Token{t: Int(0, true), pos: p})
                }
            }
            continue
        }
        if c == '`' {
            // raw string: no escapes, may span lines; ends at the next backquote
            i += 1
            st := i
            while i < len(s) && s[i] != '`' {
                if s[i] == '\n' {
                    line += 1
                    line_start = i + 1
                }
                i += 1
            }
            out.push(Token{t: Str(s[st..i]), pos: p})
            if i >= len(s) {
                errs.push(Diag{pos: p, msg: "unterminated raw string (missing closing `)"})
            } else {
                i += 1
            }
            continue
        }
        if c == '"' || c == '\'' {
            q := c
            i += 1
            // without escapes the literal is the text between the quotes
            j := i
            while j < n && s[j] != q && s[j] != '\n' && s[j] != '\\' {
                j += 1
            }
            if j < n && s[j] == q {
                lit := s[i..j]
                i = j + 1
                if q == '"' {
                    out.push(Token{t: Str(lit), pos: p})
                } else {
                    if len(lit) != 1 {
                        errs.push(Diag{pos: p, msg: "char literal must be exactly one byte"})
                    }
                    first: u8 = 0
                    if len(lit) > 0 {
                        first = lit[0]
                    }
                    out.push(Token{t: Int(u64(first), false), pos: p})
                }
                continue
            }
            buf := vec[u8]()
            closed := false
            while i < len(s) {
                d := s[i]
                if d == q {
                    closed = true
                    i += 1
                    break
                }
                if d == '\n' {
                    break
                }
                if d == '\\' && i + 1 < len(s) && s[i + 1] != '\n' {
                    i += 1
                    e := s[i]
                    shown, elen := char_at(s, i)
                    i += 1
                    match e {
                        'n' => buf.push('\n')
                        't' => buf.push('\t')
                        'r' => buf.push('\r')
                        '0' => buf.push(0)
                        '\\' => buf.push('\\')
                        '"' => buf.push('"')
                        '\'' => buf.push('\'')
                        'x' => {
                            v: u32 = 0
                            n := 0
                            while n < 2 && i < len(s) {
                                match to_digit(s[i], 16) {
                                    Some(dg) => {
                                        v = v * 16 + u32(dg)
                                        i += 1
                                        n += 1
                                    }
                                    None => {
                                        break
                                    }
                                }
                            }
                            if n != 2 {
                                errs.push(Diag{pos: p, msg: "\\x escape needs two hex digits"})
                            }
                            buf.push(u8(v))
                        }
                        _ => {
                            errs.push(Diag{pos: p, msg: fmt("unknown escape \\", shown)})
                            i += elen - 1
                        }
                    }
                    continue
                }
                buf.push(d)
                i += 1
            }
            if !closed {
                errs.push(Diag{pos: p, msg: "unterminated string/char literal"})
            }
            if q == '"' {
                out.push(Token{t: Str(buf[..buf.len]), pos: p})
            } else {
                if buf.len != 1 {
                    errs.push(Diag{pos: p, msg: "char literal must be exactly one byte"})
                }
                first: u8 = 0
                if buf.len > 0 {
                    first = buf[0]
                }
                out.push(Token{t: Int(u64(first), false), pos: p})
            }
            continue
        }
        c1: u8 = if i + 1 < n { s[i + 1] } else { 0 }
        c2: u8 = if i + 2 < n { s[i + 2] } else { 0 }
        plen := punct_len(c, c1, c2)
        if plen > 0 {
            if c == '(' || c == '[' || c == '{' {
                stack.push(c)
            } else if c == ')' || c == ']' || c == '}' {
                // (an unmatched closing bracket is left to the parser)
                if stack.len > 0 {
                    stack.pop()
                }
            }
            code := i64(c)
            if plen >= 2 {
                code |= i64(c1) << 8
            }
            if plen == 3 {
                code |= i64(c2) << 16
            }
            out.push(Token{t: P(code), pos: p})
            i += plen
        } else {
            shown, clen := char_at(s, i)
            if clen > 1 {
                // the code point too: the character may be invisible (U+00A0, U+200B)
                cp := u64(s[i]) & (0x7F >> u64(clen))
                for k in 1..clen {
                    cp = (cp << 6) | u64(s[i + k] & 0x3F)
                }
                shown = fmt(shown, "' (U+", to_upper(hex(cp, 4)), ")")
            } else {
                shown = fmt(shown, "'")
            }
            errs.push(Diag{pos: p, msg: fmt("unexpected character '", shown)})
            i += clen
        }
    }
    p := lexer_pos(file, line, i, line_start)
    if out.len > 0 {
        match out[out.len - 1].t {
            Nl => {}
            _ => out.push(Token{t: Nl, pos: p})
        }
    }
    out.push(Token{t: Eof, pos: p})
    tok_buf = out
    return out
}
