// state machine with many branches: a lexer DFA over generated source text

enum St { Start, Ident, Num, Frac, ExpSign, Exp, Str, Esc, Slash, LineCmt, BlockCmt, BlockStar }

fn alpha(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' }
fn digit(c: u8) -> bool { c >= '0' && c <= '9' }

fn lex(text: str, counts: []i64) {
    st := Start
    i := 0
    n := len(text)
    while i < n {
        c := text[i]
        match st {
            Start => {
                if alpha(c) { st = Ident }
                else if digit(c) { st = Num }
                else if c == '"' { st = Str }
                else if c == '/' { st = Slash }
                else if c != ' ' && c != '\n' { counts[8] += 1 }
                i += 1
            }
            Ident => {
                if alpha(c) || digit(c) { i += 1 } else { counts[0] += 1; st = Start }
            }
            Num => {
                if digit(c) { i += 1 }
                else if c == '.' { st = Frac; i += 1 }
                else if c == 'e' { st = ExpSign; i += 1 }
                else { counts[1] += 1; st = Start }
            }
            Frac => {
                if digit(c) { i += 1 }
                else if c == 'e' { st = ExpSign; i += 1 }
                else { counts[2] += 1; st = Start }
            }
            ExpSign => {
                if c == '+' || c == '-' || digit(c) { st = Exp; i += 1 } else { counts[7] += 1; st = Start }
            }
            Exp => {
                if digit(c) { i += 1 } else { counts[2] += 1; st = Start }
            }
            Str => {
                if c == '"' { counts[3] += 1; st = Start }
                else if c == 92 { st = Esc }       // backslash
                else if c == '\n' { counts[7] += 1; st = Start }
                i += 1
            }
            Esc => { st = Str; i += 1 }
            Slash => {
                if c == '/' { st = LineCmt; i += 1 }
                else if c == '*' { st = BlockCmt; i += 1 }
                else { counts[4] += 1; st = Start }
            }
            LineCmt => {
                if c == '\n' { counts[5] += 1; st = Start }
                i += 1
            }
            BlockCmt => {
                if c == '*' { st = BlockStar }
                i += 1
            }
            BlockStar => {
                if c == '/' { counts[6] += 1; st = Start } else if c != '*' { st = BlockCmt }
                i += 1
            }
        }
    }
}

fn main() {
    table := "aaaabbccxyzeeeeE_09912345678.....   \n\n+-+-=();;(){}\"\"\x5c/*/*/*abtr"
    n := 8000000
    text := alloc[u8](n)
    seed: u64 = 2024
    for i in 0..n {
        seed = seed * 6364136223846793005 + 1442695040888963407
        text[i] = table[(seed >> 33) % u64(len(table))]
    }
    counts := alloc[i64](9)
    for r in 0..12 { lex(text[r..], counts) }
    put(counts[0], " ", counts[1], " ", counts[2], " ", counts[3], " ", counts[4], " ",
        counts[5], " ", counts[6], " ", counts[7], " ", counts[8], "\n")
}
