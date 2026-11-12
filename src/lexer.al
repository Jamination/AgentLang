// Lexer for AL: source text to tokens.

enum Tk {
    Id(str),
    Int(u64),
    Float(f64, f32), // the value; the literal rounded once to f32
    Str(str),
    Kw(str),
    P(str),
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

priv PUNCTS := [47]str{
    "<<=", ">>=", "..=", ":=", "->", "==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "+=", "-=", "*=",
    "/=", "%=", "&=", "|=", "^=", "..", "=>", "+", "-", "*", "/", "%", "&", "|", "^", "~", "!", "<",
    ">", "=", "(", ")", "[", "]", "{", "}", ",", ".", ":", ";", "@",
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

// the byte as a Unicode scalar value in UTF-8 (for messages)
priv fn char_str(c: u8) -> str {
    if c < 0x80 {
        out := alloc[u8](1)
        out[0] = c
        return out
    }
    out := alloc[u8](2)
    out[0] = 0xC0 | (c >> 6)
    out[1] = 0x80 | (c & 0x3F)
    return out
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
    return Pos{file: file, line: line, col: i64(u16(at - line_start + 1))}
}

fn lexer_lex(src: str, file: i64, errs: *Vec[Diag]) -> Vec[Token] {
    s := src
    i := 0
    line := 1
    line_start := 0
    out := vec[Token]()
    // bracket stack: '(' / '[' suppress newlines, '{' enables them
    stack := vec[u8]()
    while i < len(s) {
        c := s[i]
        if c == '\n' {
            sig := stack.len == 0 || stack[stack.len - 1] == '{'
            if sig {
                term := false
                if out.len > 0 {
                    term = match out[out.len - 1].t {
                        Id(_), Int(_), Float(_, _), Str(_) => true
                        P(p) => p == ")" || p == "]" || p == "}"
                        Kw(k) => k == "return" || k == "break" || k == "continue" || k == "true" || k == "false" || k == "nil"
                        _ => false
                    }
                }
                if term {
                    out.push(Token{t: Nl, pos: lexer_pos(file, line, i, line_start)})
                }
            }
            i += 1
            line += 1
            line_start = i
            continue
        }
        if c == ' ' || c == '\t' || c == '\r' {
            i += 1
            continue
        }
        if c == '/' && i + 1 < len(s) && s[i + 1] == '/' {
            while i < len(s) && s[i] != '\n' {
                i += 1
            }
            continue
        }
        p := lexer_pos(file, line, i, line_start)
        if is_alpha(c) || c == '_' {
            st := i
            while i < len(s) && (is_alnum(s[i]) || s[i] == '_') {
                i += 1
            }
            w := src[st..i]
            is_kw := false
            for k in KEYWORDS {
                if k == w {
                    out.push(Token{t: Kw(k), pos: p})
                    is_kw = true
                    break
                }
            }
            if !is_kw {
                out.push(Token{t: Id(w), pos: p})
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
                while i < len(s) && (is_alnum(s[i]) || s[i] == '_') {
                    if s[i] != '_' {
                        match to_digit(s[i], radix) {
                            Some(d) => {
                                v = v * u64(radix) + u64(d)
                                any = true
                            }
                            None => {
                                errs.push(Diag{pos: p, msg: "invalid digit in integer literal"})
                            }
                        }
                    }
                    i += 1
                }
                if !any {
                    errs.push(Diag{pos: p, msg: "empty integer literal"})
                }
                out.push(Token{t: Int(v), pos: p})
                continue
            }
            while i < len(s) && (is_digit(s[i]) || s[i] == '_') {
                i += 1
            }
            is_float := false
            if i + 1 < len(s) && s[i] == '.' && is_digit(s[i + 1]) {
                is_float = true
                i += 1
                while i < len(s) && (is_digit(s[i]) || s[i] == '_') {
                    i += 1
                }
            }
            if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
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
            tbuf := alloc[u8](i - st)
            tn := 0
            for k in st..i {
                if s[k] != '_' {
                    tbuf[tn] = s[k]
                    tn += 1
                }
            }
            text := tbuf[..tn]
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
                    out.push(Token{t: Int(v), pos: p})
                } else {
                    errs.push(Diag{pos: p, msg: "integer literal too large"})
                    out.push(Token{t: Int(0), pos: p})
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
            if i >= len(s) {
                errs.push(Diag{pos: p, msg: "unterminated raw string (missing closing `)"})
            }
            out.push(Token{t: Str(s[st..min(i, len(s))]), pos: p})
            i += 1
            continue
        }
        if c == '"' || c == '\'' {
            q := c
            i += 1
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
                if d == '\\' && i + 1 < len(s) {
                    i += 1
                    e := s[i]
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
                            errs.push(Diag{pos: p, msg: fmt("unknown escape \\", char_str(e))})
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
                out.push(Token{t: Int(u64(first)), pos: p})
            }
            continue
        }
        matched := false
        for pp in PUNCTS {
            if starts_with(s[i..], pp) {
                if pp == "(" || pp == "[" || pp == "{" {
                    stack.push(c)
                } else if pp == ")" || pp == "]" || pp == "}" {
                    // (an unmatched closing bracket is left to the parser)
                    if stack.len > 0 {
                        stack.pop()
                    }
                }
                out.push(Token{t: P(pp), pos: p})
                i += len(pp)
                matched = true
                break
            }
        }
        if !matched {
            errs.push(Diag{pos: p, msg: fmt("unexpected character '", char_str(c), "'")})
            i += 1
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
    return out
}
