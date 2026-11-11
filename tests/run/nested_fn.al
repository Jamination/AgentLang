// nested functions: variables of the enclosing function, nesting, recursion, forwarding
struct Item { hp i64, name str }
struct P { x i64, y i64 }

fn rank(items []Item, floor i64) i64 {
    n := 0
    fn keep(it Item) bool {      // sees `floor` and `n` of rank
        if it.hp < floor { return false }
        n += 1
        return true
    }
    fn by_hp(a Item, b Item) bool { a.hp > b.hp }   // uses no local: an ordinary function value
    for it in items { keep(it) }
    sort_by(items, by_hp)
    return n
}

// nested in nested: the innermost sees the variables of both enclosing functions
fn outer(n i64) i64 {
    a := 1
    b := 10
    fn mid(x i64) i64 {
        fn inner(y i64) i64 {
            a += 1
            x + y + a + b
        }
        inner(100) + inner(1000)
    }
    r := mid(10000)
    r + a + n
}

// a nested function that calls another one passes on what the callee uses; a variable of
// the same name in between does not change which variable that is
fn tree(n i64) i64 {
    x := 1
    fn bump() { x += 1 }
    fn level1(k i64) i64 {
        x := 100
        fn level2(j i64) i64 {
            bump()
            x += j
            x
        }
        level2(k) + level2(k)
    }
    r := level1(n)
    r * 1000 + x
}

fn forward() i64 {
    total := 0
    fn add(x i64) { total += x }
    fn add2(x i64) { add(x); add(x) }       // uses `total` only through add
    fn add4(x i64) { add2(x); add2(x) }
    for i in 0..5 { add4(i) }
    total
}

// recursion: directly, and with a variable of the enclosing function
fn fact(n i64) i64 {
    fn go(k i64, acc i64) i64 {
        if k <= 1 { return acc }
        go(k - 1, acc * k)
    }
    go(n, 1)
}
fn count_down(n i64) i64 {
    steps := 0
    fn go(k i64) {
        if k == 0 { return }
        steps += 1
        go(k - 1)
    }
    go(n)
    steps
}
// every call of the enclosing function has its own variables
fn fib(n i64) i64 {
    if n < 2 { return n }
    fn f(k i64) i64 { fib(n - k) }
    f(1) + f(2)
}
fn walk(depth i64, visit i64) i64 {
    seen := 0
    fn node(d i64) {
        seen += 1
        if d > 0 {
            node(d - 1)
            node(d - 1)
        }
    }
    node(depth)
    seen + visit
}

// parameters (also one passed by reference), loop variables, variables of outer blocks
fn params(p P, big [6]i64, k i64) i64 {
    fn sum() i64 {
        p.x += 1                 // the parameter of this call
        t := k + p.x + p.y
        for v in big { t += v }
        big[0] = 100
        t
    }
    sum() + sum()
}
fn loops() i64 {
    total := 0
    for i in 0..4 {
        j := i * 10
        fn acc() { total += i + j }
        acc()
        acc()
    }
    {
        z := 5
        fn bump() { z += 1; total += z }
        {
            bump()
            bump()
        }
    }
    for i, s in []str{"a", "bb"} {
        fn note() { total += i * 1000 + len(s) * 100 }
        note()
    }
    total
}

// `return` leaves the nested function only; `defer` and loops inside it are its own
fn early(xs []i64, limit i64) i64 {
    found := -1
    fn find(x i64) bool {
        defer { limit += 1 }
        if x > limit {
            found = x
            return true
        }
        false
    }
    for x in xs {
        if find(x) { break }
    }
    found * 100 + limit
}
fn inner_loops() i64 {
    hits := 0
    fn scan(n i64) i64 {
        r := 0
        rows: for i in 0..n {
            for j in 0..n {
                if j > i { continue rows }
                if i + j > 6 { break rows }
                hits += 1
                r += j
            }
        }
        r
    }
    scan(5) * 1000 + hits
}

// names: a nested function hides top-level functions and builtins of its name, also in
// method-call syntax; its own parameters and locals hide outer variables
fn helper(x i64) i64 { x + 1000 }
fn names() {
    x := 5
    fn f(x i64) i64 {
        y := x * 2
        {
            x := y + 1
            y = x
        }
        y
    }
    print(f(10), x)
    print(helper(1), len("abc"))
    fn helper(x i64) i64 { x + 1 }
    fn len(s str) i64 { 42 }
    print(helper(1), 1.helper(), len("abc"), "abc".len())
    {
        fn helper(x i64) i64 { x + 2 }      // an inner block may declare the name again
        print(helper(1))
        {
            helper := 7                     // and a variable of a block inside may hide it
            print(helper)
        }
    }
    print(helper(1))
}

fn main() {
    items := []Item{Item{3, "a"}, Item{9, "b"}, Item{5, "c"}}
    print(rank(items, 4), items)
    print(outer(5), tree(5), forward())
    print(fact(10), count_down(100), fib(15), walk(4, 1000))
    var big [6]i64
    for i in 0..6 { big[i] = i }
    print(params(P{1, 2}, big, 7), big[0], loops())
    print(early([]i64{1, 5, 9, 12}, 6), early([]i64{1}, 6), inner_loops())
    names()

    // aggregates, floats, vectors and small integers read and assigned
    var grid [4]i64
    words := []str{"a", "b"}
    t := (1, 2.5)
    p := P{1, 10}
    v := vec3(1.0, 2.0, 3.0)
    var b8 u8 = 250
    flag := false
    fn fill(k i64) {
        for i in 0..4 { grid[i] = k + i }
        words[1] = "z"
        t.0 += 1
        t.1 *= 2.0
        p.y = k
        v = v + vec3(1.0)
        b8 += 10
        flag = !flag
    }
    fill(7)
    print(grid, words, t, p, v, b8, flag)

    // match bindings
    var o Opt[P] = Some(P{3, 4})
    match o {
        Some(q) => {
            fn dist(k i64) i64 { q.x * k + q.y + p.y }
            print(dist(10))
        }
        None => {}
    }
    // a nested function with the name of a binding inside its own match
    fn first(o Opt[P], p i64) i64 {
        match o {
            Some(p) => p.x
            None => p
        }
    }
    print(first(o, 9), first(None, 9))
}
