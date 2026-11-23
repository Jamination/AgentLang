// [codegen] tokenizing lexer for a C-like language with a character-class switch, keyword
// recognition and line comments (same loops in C)
inline fn lcg(s: u64) -> u64 { s * 6364136223846793005 + 1442695040888963407 }

const PIECES = [24]str{"if", "while", "return", "fn", "let", "else", "counter", "x", "value_2", "_tmp",
    "12345", "0", "42", "+", "-", "*", "==", "!=", "<=", "&&", "(", ")", "{", "}"}

fn gen(n: i64) -> []u8 {
    out := alloc[u8](n + 64)
    k := 0
    seed: u64 = 17
    while k < n {
        seed = lcg(seed)
        r := (seed >> 33) % 100
        if r < 4 {
            for c in "// note\n" { out[k] = c; k += 1 }
        } else if r < 8 {
            out[k] = '"'
            k += 1
            for c in "text" { out[k] = c; k += 1 }
            out[k] = '"'
            k += 1
        } else if r < 12 {
            out[k] = ';'
            out[k + 1] = '\n'
            k += 2
        } else {
            for c in PIECES[i64((seed >> 40) % 24)] { out[k] = c; k += 1 }
        }
        out[k] = ' '
        k += 1
    }
    out[..k]
}

inline fn is_ident(c: u8) -> bool {
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

fn keyword(s: []u8) -> i64 {
    match len(s) {
        2 => {
            if s[0] == 'i' && s[1] == 'f' { return 1 }
            if s[0] == 'f' && s[1] == 'n' { return 2 }
        }
        3 => {
            if s[0] == 'l' && s[1] == 'e' && s[2] == 't' { return 3 }
        }
        4 => {
            if s[0] == 'e' && s[1] == 'l' && s[2] == 's' && s[3] == 'e' { return 4 }
        }
        5 => {
            if s[0] == 'w' && s[1] == 'h' && s[2] == 'i' && s[3] == 'l' && s[4] == 'e' { return 5 }
        }
        6 => {
            if s[0] == 'r' && s[1] == 'e' && s[2] == 't' && s[3] == 'u' && s[4] == 'r' && s[5] == 'n' { return 6 }
        }
        _ => {}
    }
    0
}

// counts[kind]; returns a hash of the token stream
fn lex(s: []u8, counts: []i64) -> u64 {
    n := len(s)
    h: u64 = 0
    i := 0
    line := 1
    while i < n {
        c := s[i]
        kind := 0
        start := i
        match c {
            ' ', '\t', '\r' => {
                i += 1
                continue
            }
            '\n' => {
                line += 1
                i += 1
                continue
            }
            'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't',
            'u', 'v', 'w', 'x', 'y', 'z', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N',
            'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '_' => {
                while i < n && is_ident(s[i]) { i += 1 }
                kw := keyword(s[start..i])
                kind = if kw > 0 { 10 + kw } else { 1 }
            }
            '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                v := 0
                while i < n && s[i] >= '0' && s[i] <= '9' {
                    v = v * 10 + i64(s[i] - '0')
                    i += 1
                }
                h = h + u64(v)
                kind = 2
            }
            '"' => {
                i += 1
                while i < n && s[i] != '"' { i += 1 }
                i += 1
                kind = 3
            }
            '/' => {
                if i + 1 < n && s[i + 1] == '/' {
                    while i < n && s[i] != '\n' { i += 1 }
                    continue
                }
                i += 1
                kind = 4
            }
            '=', '!', '<', '>' => {
                i += 1
                kind = 5
                if i < n && s[i] == '=' {
                    i += 1
                    kind = 6
                }
            }
            '&' => {
                i += 1
                kind = 7
                if i < n && s[i] == '&' { i += 1 }
            }
            '+', '-', '*' => {
                i += 1
                kind = 8
            }
            '(', ')', '{', '}', ';' => {
                i += 1
                kind = 9
            }
            _ => {
                i += 1
                kind = 0
            }
        }
        counts[kind] += 1
        h = h * 31 + u64(kind) * 7 + u64(i - start) + u64(line)
    }
    h
}

fn main() {
    s := gen(16000000)
    counts := alloc[i64](20)
    h: u64 = 0
    for r in 0..8 {
        h = h * 3 + lex(s, counts)
    }
    print(len(s), h, counts)
}
