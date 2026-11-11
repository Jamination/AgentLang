// Lexer for AL: source text to tokens.

enum Tk {
    TkId(str),
    TkInt(u64),
    TkFloat(f64),
    TkStr(str),
    TkKw(str),
    TkP(str),
    TkNl,
    TkEof,
}

struct Token {
    t Tk
    pos Pos
}

var LEXER_KEYWORDS = [26]str{
    "fn", "struct", "enum", "const", "var", "test", "use", "if", "else", "while", "loop", "for",
    "in", "return", "break", "continue", "assert", "true", "false", "nil", "match", "by", "defer",
    "inline", "noinline", "extern",
}

var LEXER_PUNCTS = [46]str{
    "<<=", ">>=", "..=", ":=", "==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "+=", "-=", "*=",
    "/=", "%=", "&=", "|=", "^=", "..", "=>", "+", "-", "*", "/", "%", "&", "|", "^", "~", "!",
    "<", ">", "=", "(", ")", "[", "]", "{", "}", ",", ".", ":", ";", "@",
}

// Rust's `char::to_digit(radix)` for a byte
fn lexer_to_digit(c u8, radix i64) Opt[i64] {
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

// Rust's `c as char` formatted with `{}`: the byte as a Unicode scalar value in UTF-8
fn lexer_char_str(c u8) str {
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

// Rust's `parse::<u64>()` for a non-empty text of decimal digits; false on overflow
fn lexer_parse_u64(text str) (u64, bool) {
    if len(text) == 0 {
        return (0, false)
    }
    var v u64 = 0
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

fn lexer_pos(file i64, line i64, at i64, line_start i64) Pos {
    return Pos{file: file, line: line, col: i64(u16(at - line_start + 1))}
}

fn lexer_lex(src str, file i64, errs *Vec[Diag]) Vec[Token] {
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
            sig := stack.len == 0 || stack.buf[stack.len - 1] == '{'
            if sig {
                term := false
                if out.len > 0 {
                    match out.buf[out.len - 1].t {
                        TkId(x) => {
                            term = true
                        }
                        TkInt(x) => {
                            term = true
                        }
                        TkFloat(x) => {
                            term = true
                        }
                        TkStr(x) => {
                            term = true
                        }
                        TkP(p) => {
                            term = p == ")" || p == "]" || p == "}"
                        }
                        TkKw(k) => {
                            term = k == "return" || k == "break" || k == "continue" || k == "true" || k == "false" || k == "nil"
                        }
                        _ => {}
                    }
                }
                if term {
                    out.push(Token{t: TkNl, pos: lexer_pos(file, line, i, line_start)})
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
            for k in LEXER_KEYWORDS {
                if k == w {
                    out.push(Token{t: TkKw(k), pos: p})
                    is_kw = true
                    break
                }
            }
            if !is_kw {
                out.push(Token{t: TkId(w), pos: p})
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
                var v u64 = 0
                any := false
                while i < len(s) && (is_alnum(s[i]) || s[i] == '_') {
                    if s[i] != '_' {
                        match lexer_to_digit(s[i], radix) {
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
                out.push(Token{t: TkInt(v), pos: p})
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
                    out.push(Token{t: TkFloat(v), pos: p})
                } else {
                    errs.push(Diag{pos: p, msg: "invalid float literal"})
                    out.push(Token{t: TkFloat(0.0), pos: p})
                }
            } else {
                v, ok := lexer_parse_u64(text)
                if ok {
                    out.push(Token{t: TkInt(v), pos: p})
                } else {
                    errs.push(Diag{pos: p, msg: "integer literal too large"})
                    out.push(Token{t: TkInt(0), pos: p})
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
            out.push(Token{t: TkStr(s[st..min(i, len(s))]), pos: p})
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
                            var v u32 = 0
                            n := 0
                            while n < 2 && i < len(s) {
                                match lexer_to_digit(s[i], 16) {
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
                            errs.push(Diag{pos: p, msg: fmt("unknown escape \\", lexer_char_str(e))})
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
                out.push(Token{t: TkStr(buf.buf[..buf.len]), pos: p})
            } else {
                if buf.len != 1 {
                    errs.push(Diag{pos: p, msg: "char literal must be exactly one byte"})
                }
                var first u8 = 0
                if buf.len > 0 {
                    first = buf.buf[0]
                }
                out.push(Token{t: TkInt(u64(first)), pos: p})
            }
            continue
        }
        matched := false
        for pp in LEXER_PUNCTS {
            if starts_with(s[i..], pp) {
                if pp == "(" || pp == "[" || pp == "{" {
                    stack.push(c)
                } else if pp == ")" || pp == "]" || pp == "}" {
                    // (Rust's pop on an empty Vec does nothing)
                    if stack.len > 0 {
                        stack.pop()
                    }
                }
                out.push(Token{t: TkP(pp), pos: p})
                i += len(pp)
                matched = true
                break
            }
        }
        if !matched {
            errs.push(Diag{pos: p, msg: fmt("unexpected character '", lexer_char_str(c), "'")})
            i += 1
        }
    }
    p := lexer_pos(file, line, i, line_start)
    if out.len > 0 {
        last_nl := false
        match out.buf[out.len - 1].t {
            TkNl => {
                last_nl = true
            }
            _ => {}
        }
        if !last_nl {
            out.push(Token{t: TkNl, pos: p})
        }
    }
    out.push(Token{t: TkEof, pos: p})
    return out
}
