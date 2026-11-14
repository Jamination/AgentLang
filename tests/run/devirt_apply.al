// user generics that call function values with known targets (inlined, or specialised when too
// big), recursion and mutual recursion that hand the function on, function values in
// variables, fields and results, and one chosen at run time (stays an indirect call)
fn sq(x: i64) -> i64 {
    return x * x
}

fn neg(x: i64) -> i64 {
    return -x
}

fn add(a: i64, b: i64) -> i64 {
    return a + b
}

fn apply[T](x: T, f: fn(T) -> T) -> T {
    return f(x)
}

fn twice[T](x: T, f: fn(T) -> T) -> T {
    return apply(apply(x, f), f)
}

// too big to be inlined everywhere: specialised for each function passed
fn fold_sum(v: []i64, f: fn(i64) -> i64) -> i64 {
    s := 0
    for x in v {
        if x > 100 {
            s += f(x) % 1000
        } else if x < -100 {
            s -= f(-x) % 1000
        } else {
            s += f(x)
        }
        if s > 1000000 {
            s = s % 1000003
        }
    }
    return s
}

// hands f on to fold_sum
fn fold_both(a: []i64, b: []i64, f: fn(i64) -> i64) -> i64 {
    x := fold_sum(a, f)
    y := fold_sum(b, f)
    if x > y {
        return x - y + fold_sum(a[..len(a) / 2], f)
    }
    return y - x + fold_sum(b[..len(b) / 2], f)
}

struct Tree {
    val: i64
    kids: Vec[Tree]
}

// recursive, hands f on to itself
fn tree_sum(t: *Tree, f: fn(i64) -> i64) -> i64 {
    s := f(t.val)
    for i in 0..t.kids.len {
        s += tree_sum(&t.kids[i], f)
    }
    if s > 1000000 {
        s = s % 1000003
    }
    return s
}

// mutual recursion, both hand f on
fn even_steps(n: i64, f: fn(i64) -> i64) -> i64 {
    if n <= 0 {
        return 0
    }
    return f(n) + odd_steps(n - 1, f)
}

fn odd_steps(n: i64, f: fn(i64) -> i64) -> i64 {
    if n <= 0 {
        return 0
    }
    return f(-n) + even_steps(n - 1, f)
}

// a binary function value and a generic with two of them
fn combine[T](a: T, b: T, op: fn(T, T) -> T, post: fn(T) -> T) -> T {
    return post(op(a, b))
}

struct Ops {
    unary: fn(i64) -> i64
    binary: fn(i64, i64) -> i64
}

fn pick(square: bool) -> fn(i64) -> i64 {
    if square {
        return sq
    }
    return neg
}

fn mk_tree(depth: i64, v: i64) -> Tree {
    t := Tree{val: v, kids: vec[Tree]()}
    if depth > 0 {
        for i in 0..3 {
            t.kids.push(mk_tree(depth - 1, v * 3 + i))
        }
    }
    return t
}

fn main() {
    print(apply(7, sq), apply(7, neg), twice(3, sq), twice(5, neg))
    print(apply(2.5, fn(x: f64) -> f64 { x * 2.0 }))
    fn cube(x: i64) -> i64 {
        return x * x * x
    }
    print(apply(3, cube), twice(2, cube))
    v := []i64{3, -4, 150, -200, 7, 0, 12}
    w := []i64{1, 2, 3, 400, -5}
    print(fold_sum(v, sq), fold_sum(v, neg), fold_sum(v, cube), fold_sum(v, fn(x: i64) -> i64 { x + 1 }))
    print(fold_sum(w, sq), fold_both(v, w, sq), fold_both(w, v, cube))
    t := mk_tree(3, 1)
    print(tree_sum(&t, sq), tree_sum(&t, neg), tree_sum(&t, fn(x: i64) -> i64 { x % 7 }))
    print(even_steps(10, sq), odd_steps(9, cube), even_steps(6, fn(x: i64) -> i64 { 2 * x }))
    print(combine(3, 4, add, sq), combine(3, 4, fn(a: i64, b: i64) -> i64 { a * b }, neg))
    // function values in variables, fields and results
    g := sq
    h := g
    print(g(9), h(-3))
    ops := Ops{unary: cube, binary: add}
    print(ops.unary(4), ops.binary(5, 6), apply(4, ops.unary))
    print(pick(true)(6), pick(false)(6), apply(5, pick(true)))
    // chosen at run time: the target is not known
    r := if len(args()) > 2 { sq } else { neg }
    print(r(8), apply(8, r), fold_sum(v, r))
    fs := []fn(i64) -> i64{sq, neg, cube}
    total := 0
    for i in 0..len(args()) + 1 {
        total += fs[i % 3](i + 2)
    }
    print(total)
}
