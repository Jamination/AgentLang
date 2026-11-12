// Lexer for AL: source text to tokens.

enum Tk {
    Id(str),
    Int(u64),
    Float(f64),
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
                        Id(_), Int(_), Float(_), Str(_) => true
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
                out.push(Token{t: Int(v), pos: p})
                continue
            }
            while i < len(s) && (is_digit(s[i]) || s[i] == '_') {
                i += 1
            }
            is_float := false
            // after a `.` a number is a tuple field: `t.0.1` is (t.0).1
            field := false
            if out.len > 0 {
                field = match out[out.len - 1].t {
                    P(q) => q == "."
                    _ => false
                }
            }
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
                    out.push(Token{t: Float(v), pos: p})
                } else {
                    errs.push(Diag{pos: p, msg: "invalid float literal"})
                    out.push(Token{t: Float(0.0), pos: p})
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
            shown, clen := char_at(s, i)
            errs.push(Diag{pos: p, msg: fmt("unexpected character '", shown, "'")})
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
    return out
}
