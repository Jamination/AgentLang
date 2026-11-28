// state machines whose arms set the state to a constant: the back end threads the jump from
// such an arm to the next arm (src/x86/thread.al); the results must not depend on it

enum St { Start, Word, Num, Str, Esc }

fn scan(text: str) -> (i64, i64, i64) {
    st := Start
    words := 0
    nums := 0
    strs := 0
    i := 0
    while i < len(text) {
        c := text[i]
        match st {
            Start => {
                if c >= 'a' && c <= 'z' { st = Word } else if c >= '0' && c <= '9' { st = Num } else if c == '"' { st = Str }
                i += 1
            }
            Word => {
                if c >= 'a' && c <= 'z' { i += 1 } else { words += 1; st = Start }
            }
            Num => {
                if c >= '0' && c <= '9' { i += 1 } else { nums += 1; st = Start }
            }
            Str => {
                if c == '"' { strs += 1; st = Start } else if c == 92 { st = Esc }
                i += 1
            }
            Esc => { st = Str; i += 1 }
        }
    }
    return (words, nums, strs)
}

// an integer state with a default arm, a state that is read in an arm, and a state computed
// (not constant) in one arm
fn run(n: i64) -> i64 {
    state := 0
    acc := 0
    for i in 0..n {
        match state {
            0 => { acc += 1; state = 3 }
            1 => { acc += state * 10; state = (i % 5) }
            2 => { acc += 100; state = 9 }
            3 => { acc += 1000; state = 1 }
            4 => { acc -= 7; state = 2 }
            _ => { acc += i; state = 0 }
        }
    }
    return acc * 10 + state
}

// a 64-bit state far from zero
fn far(n: i64) -> i64 {
    s := 1000000000000
    t := 0
    for i in 0..n {
        match s {
            1000000000000 => { t += 1; s = 1000000000002 }
            1000000000001 => { t += 2; s = 1000000000000 }
            1000000000002 => { t += 3; s = 1000000000003 }
            1000000000003 => { t += 5; s = if i % 3 == 0 { 1000000000001 } else { 7 } }
            _ => { t += 11; s = 1000000000001 }
        }
    }
    return t
}

// a value the compiler does not know
noinline fn hide(x: i64) -> i64 { x }

fn main() {
    w, n, s := scan("abc 123 \"x\\\"y\" de 4 \"\" f ")
    print(w, n, s)
    for k in [6]i64{0, 1, 2, 7, 100, 12345} {
        print(run(hide(k)), far(hide(k)))
    }
}
