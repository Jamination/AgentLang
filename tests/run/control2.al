enum Tok { Num(i64), Plus, Times, LParen, RParen, End }

struct Lexer { src: str, pos: i64 }

fn next(lx: *Lexer) -> Tok {
    while lx.pos < len(lx.src) && lx.src[lx.pos] == ' ' {
        lx.pos += 1
    }
    if lx.pos >= len(lx.src) {
        return End
    }
    c := lx.src[lx.pos]
    lx.pos += 1
    match c {
        '+' => return Plus
        '*' => return Times
        '(' => return LParen
        ')' => return RParen
        _ => {}
    }
    n := i64(c - '0')
    while lx.pos < len(lx.src) && lx.src[lx.pos] >= '0' && lx.src[lx.pos] <= '9' {
        n = n * 10 + i64(lx.src[lx.pos] - '0')
        lx.pos += 1
    }
    Num(n)
}

struct Parser { lx: Lexer, cur: Tok }

fn advance(p: *Parser) {
    p.cur = next(&p.lx)
}

fn primary(p: *Parser) -> i64 {
    match p.cur {
        Num(n) => {
            advance(p)
            return n
        }
        LParen => {
            advance(p)
            v := expr(p)
            advance(p)
            return v
        }
        _ => panic("unexpected token")
    }
}

fn term(p: *Parser) -> i64 {
    v := primary(p)
    loop {
        match p.cur {
            Times => {
                advance(p)
                v = v * primary(p)
            }
            _ => break
        }
    }
    v
}

fn expr(p: *Parser) -> i64 {
    v := term(p)
    loop {
        match p.cur {
            Plus => {
                advance(p)
                v += term(p)
            }
            _ => return v
        }
    }
}

fn eval(s: str) -> i64 {
    p := Parser{lx: Lexer{s, 0}, cur: End}
    advance(&p)
    expr(&p)
}

fn classify(n: i64) -> str {
    match n % 15 {
        0 => "fizzbuzz"
        3, 6, 9, 12 => "fizz"
        5, 10 => "buzz"
        _ => "-"
    }
}

fn first_neg(a: []i64) -> i64 {
    for i, x in a {
        if x < 0 {
            return i
        }
    }
    -1
}

fn main() {
    print(eval("1 + 2 * 3"), eval("(1 + 2) * 3"), eval("2 * (3 + 4) * 5 + 6"), eval("42"))
    for i in 9..=15 {
        put(classify(i), " ")
    }
    print()
    print(first_neg([]i64{3, 1, -4, 1, -5}), first_neg([]i64{1, 2}))
    // nested loops with labeled-style exits through flags and early returns
    found := false
    count := 0
    for i in 0..10 {
        for j in 0..10 {
            count += 1
            if i * j == 42 {
                found = true
                break
            }
        }
        if found {
            break
        }
    }
    print(found, count)
    // while with compound conditions
    i := 0
    j := 20
    while i < j && (i * i < 50 || j > 15) {
        i += 1
        j -= 1
    }
    print(i, j)
    t := Num(7)
    desc := match t {
        Num(n) => if n > 5 { "big" } else { "small" }
        Plus, Times => "op"
        _ => "other"
    }
    print(desc, t, Plus)
}
