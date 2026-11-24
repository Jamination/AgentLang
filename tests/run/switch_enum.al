// match on enums with payloads, through pointers (a nil test before every tag test, which
// the optimiser threads away before it makes a Switch of the tag tests), with guards, with
// constants inside the payload and as a value

enum E {
    Num(i64)
    Var
    Add(*E, *E)
    Mul(*E, *E)
    Neg(*E)
    Sel(*E, *E)
    Pair(i64, i64)
}

seed: u64 = 7

fn rnd(n: u64) -> i64 {
    seed = seed * 6364136223846793005 + 1442695040888963407
    return i64((seed >> 33) % n)
}

fn build(d: i64) -> *E {
    e := new[E]()
    if d == 0 || rnd(8) == 0 {
        *e = match rnd(4) {
            0 => Var
            1 => Pair(rnd(3), rnd(3))
            _ => Num(rnd(100) - 50)
        }
        return e
    }
    *e = match rnd(5) {
        0 => Neg(build(d - 1))
        1 => Add(build(d - 1), build(d - 1))
        2 => Mul(build(d - 1), build(d - 1))
        3 => Sel(build(d - 1), build(d - 1))
        _ => Neg(nil)
    }
    return e
}

fn eval(e: *E, x: i64) -> i64 {
    match e {
        Num(v) => v
        Var => x
        Add(a, b) => eval(a, x) + eval(b, x)
        Mul(a, b) => (eval(a, x) * eval(b, x)) % 1000003
        Neg(a) => -eval(a, x)
        Sel(a, b) => {
            v := eval(a, x)
            if v & 1 != 0 { v } else { eval(b, x) }
        }
        Pair(0, k) => k
        Pair(k, 0) => 10 * k
        Pair(a, b) if a == b => 100 * a
        Pair(a, b) => a - b
        nil => 1
    }
}

// the same on a value, with alternatives and a default
fn kind(e: E) -> i64 {
    return match e {
        Num(0) => 10
        Num(_), Var => 1
        Add(_, _), Mul(_, _) => 2
        Neg(_) => 3
        _ => 4
    }
}

enum Color {
    Red
    Green
    Blue
    Cyan
    Magenta
    Yellow
    Black
    White
}

fn hue(c: Color) -> i64 {
    match c {
        Red => 0
        Yellow => 60
        Green => 120
        Cyan => 180
        Blue => 240
        Magenta => 300
        Black, White => -1
    }
}

fn main() {
    total := 0
    kinds := [5]i64{}
    for t in 0..40 {
        tr := build(6)
        for x in -3..4 {
            total = total * 31 + eval(tr, x)
        }
        k := kind(*tr)
        kinds[k % 5] += 1
        if k == 10 {
            kinds[0] += 100
        }
    }
    put(total, "\n", kinds[0], " ", kinds[1], " ", kinds[2], " ", kinds[3], " ", kinds[4], "\n")
    cs := []Color{Red, Green, Blue, Cyan, Magenta, Yellow, Black, White}
    for c in cs {
        put(hue(c), " ")
    }
    put("\n", eval(nil, 5), "\n")
}
