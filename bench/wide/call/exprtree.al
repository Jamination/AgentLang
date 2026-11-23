// tagged union + match: build random expression trees, evaluate them recursively

enum Expr {
    Num(i64)
    Var
    Add(*Expr, *Expr)
    Sub(*Expr, *Expr)
    Mul(*Expr, *Expr)
    Neg(*Expr)
    Min(*Expr, *Expr)
    Max(*Expr, *Expr)
    And(*Expr, *Expr)
    Xor(*Expr, *Expr)
    Shr(*Expr)
    Sel(*Expr, *Expr)       // left if it is odd, else right
}

seed: u64 = 42

fn rnd(n: u64) -> i64 {
    seed = seed * 6364136223846793005 + 1442695040888963407
    i64((seed >> 33) % n)
}

fn build(depth: i64) -> *Expr {
    e := new[Expr]()
    if depth == 0 || rnd(16) == 0 {
        if rnd(3) == 0 { *e = Var } else { *e = Num(rnd(1000) - 500) }
        return e
    }
    k := rnd(10)
    if k == 0 { *e = Neg(build(depth - 1)); return e }
    if k == 1 { *e = Shr(build(depth - 1)); return e }
    l := build(depth - 1)
    r := build(depth - 1)
    *e = match k {
        2 => Add(l, r)
        3 => Sub(l, r)
        4 => Mul(l, r)
        5 => Min(l, r)
        6 => Max(l, r)
        7 => And(l, r)
        8 => Xor(l, r)
        _ => Sel(l, r)
    }
    e
}

fn eval(e: *Expr, x: i64) -> i64 {
    match e {
        Num(v) => v
        Var => x
        Add(a, b) => eval(a, x) + eval(b, x)
        Sub(a, b) => eval(a, x) - eval(b, x)
        Mul(a, b) => eval(a, x) * eval(b, x)
        Neg(a) => -eval(a, x)
        Min(a, b) => min(eval(a, x), eval(b, x))
        Max(a, b) => max(eval(a, x), eval(b, x))
        And(a, b) => eval(a, x) & eval(b, x)
        Xor(a, b) => eval(a, x) ^ eval(b, x)
        Shr(a) => eval(a, x) >> 3
        Sel(a, b) => {
            v := eval(a, x)
            if v & 1 != 0 { v } else { eval(b, x) }
        }
        nil => 0
    }
}

fn count(e: *Expr) -> i64 {
    match e {
        Num(_), Var => 1
        Neg(a), Shr(a) => 1 + count(a)
        Add(a, b), Sub(a, b), Mul(a, b), Min(a, b), Max(a, b), And(a, b), Xor(a, b), Sel(a, b) => 1 + count(a) + count(b)
        nil => 0
    }
}

fn main() {
    trees := alloc[*Expr](8)
    nodes := 0
    for t in 0..8 {
        trees[t] = build(16)
        nodes += count(trees[t])
    }
    sum := 0
    for x in 0..1200 {
        for t in trees { sum = sum * 31 + eval(t, x - 600) }
    }
    put(nodes, " ", sum, "\n")
}
