// closures: capture by reference, mutation, nesting, struct fields, conversions
struct P { x i64, y i64 }
struct Big { a [8]i64, n i64 }
struct Handler { name str, cb |i64| i64, n i64 }
struct Ops {
    add |i64, i64| i64
    neg |i64| i64
    log |str|
}
enum Ev { Click(|i64| i64), Nothing }

var gcount i64
var gcb |i64| i64
var ginit |i64| i64 = double
var gtab = [2]|i64| i64{double, triple}

fn double(x i64) i64 { x * 2 }
fn triple(x i64) i64 { x * 3 }
fn apply(f |i64| i64, x i64) i64 { f(x) }
fn call_fn(f fn(i64) i64, x i64) i64 { f(x) }
fn adder() |i64, i64| i64 { |a i64, b i64| i64 { a + b } }
fn compose(f |i64| i64, g |i64| i64, x i64) i64 { g(f(x)) }
fn twice(f |i64| i64, x i64) i64 { f(f(x)) }
fn sel(c bool) |i64| i64 {
    if c { |x i64| i64 { x } } else { |x i64| i64 { -x } }
}

fn counter(n i64) i64 {
    total := 0
    step := |d i64| { total += d }
    for i in 0..n {
        step(i)
    }
    total
}

fn nested() i64 {
    a := 1
    b := 10
    outer := |x i64| i64 {
        inner := |y i64| i64 {
            a += 1
            x + y + a + b
        }
        inner(100) + inner(1000)
    }
    r := outer(10000)
    r + a
}

// a by-reference parameter (more than four words) is captured like a local
fn sum_big(b Big) i64 {
    t := 0
    each(b.a[..b.n], |x i64| { t += x + b.n })
    b.n = 100
    t
}

fn with_ptr(p *P) i64 {
    f := || i64 { p.x += 1; p.x + p.y }
    f() + f()
}

fn show(o Ops) {
    o.log(fmt(o.add(2, 3), " ", o.neg(7)))
}

fn early(xs []i64, limit i64) i64 {
    found := -1
    find := |x i64| bool {
        if x > limit {
            found = x
            return true
        }
        false
    }
    for x in xs {
        if find(x) { break }
    }
    found
}

// recursion: every activation has its own variables and environment
fn fib(n i64) i64 {
    if n < 2 { return n }
    f := |k i64| i64 { fib(n - k) }
    f(1) + f(2)
}

fn sum_to(n i64, add |i64|) {
    if n == 0 { return }
    add(n)
    sum_to(n - 1, add)
}

fn depth(n i64, f |i64| i64) i64 {
    if n == 0 { return f(0) }
    local := n
    depth(n - 1, |x i64| i64 { f(x) + local })
}

fn fact(n i64, rec |i64| i64) i64 {
    if n <= 1 { return 1 }
    n * rec(n - 1)
}

fn main() {
    // capture and mutation
    count := 0
    inc := || { count += 1 }
    inc()
    inc()
    print(count)
    k := 10
    add := |x i64| i64 { x + k }
    print(add(5), apply(add, 7), apply(double, 4), apply(|x i64| i64 { x * x }, 9))
    k = 100
    print(add(5), add)
    print(counter(10), nested())

    // closure variables, assignment, zero value
    var f |i64|
    var g || i64
    n := 5
    f = |x i64| { n += x }
    g = || i64 { n * 2 }
    f(10)
    print(g(), n)
    var z |i64| i64
    z = double
    print(z(21))
    var opt |i64| bool = nil
    opt = |x i64| bool { x > n }
    print(opt(5), opt(50))

    // functions and fn values where closures are expected, and the reverse for literals
    fv := triple
    var c1 |i64| i64 = fv
    print(c1(5), compose(double, fv, 2), compose(|x i64| i64 { x + n }, double, 1))
    print(call_fn(|x i64| i64 { x + 1 }, 41), call_fn(double, 4))
    var thin fn(i64) i64 = |x i64| i64 { x * 7 }
    print(thin(6), double.twice(5), twice(|x i64| i64 { x * n }, 1))
    cl := |x i64| i64 { x - n }
    print(cl.twice(100))
    q := if n > 0 { double } else { triple }
    var c2 |i64| i64 = q
    m := match n {
        15 => |x i64| i64 { x }
        _ => double
    }
    print(c2(8), m(3), sel(true)(4), sel(false)(4))

    // returned closures (no captures), immediate call
    ad := adder()
    print(ad(3, 4), adder()(5, 6), |x i64| i64 { x + 1 }(41))

    // struct fields
    h := Handler{name: "h", cb: |x i64| i64 { x + k }, n: 1}
    print(h.cb(10), h)
    h.cb = double
    hp := &h
    print(h.cb(10), hp.cb(11))
    log := vec[str]()
    show(Ops{add: |a i64, b i64| i64 { a + b }, neg: |a i64| i64 { -a }, log: |s str| { log.push(s) }})
    show(Ops{add: adder(), neg: double, log: |s str| { log.push(concat("2:", s)) }})
    print(log.items())

    // enum payloads, globals, vectors, arrays, slices, tuples of closures
    evs := []Ev{Click(|x i64| i64 { x + n }), Nothing, Click(double)}
    for e in evs {
        match e {
            Click(cb) => print("click", cb(1))
            Nothing => print("nothing")
        }
    }
    gcb = |x i64| i64 { gcount += x; gcount }
    print(gcb(5), gcb(6), ginit(21), gtab[0](5), gtab[1](5))
    fs := vec[|i64| i64]()
    fs.push(double)
    fs.push(|x i64| i64 { x - 1 })
    fs.push(|x i64| i64 { x + n })
    for hh in fs.items() {
        put(hh(100), " ")
    }
    print(fs.len, fs.items())
    arr := [3]|i64| i64{double, triple, |x i64| i64 { x * x }}
    sl := []|i64| i64{double, |x i64| i64 { x + count }}
    tup := (double, |x i64| i64 { x + 1 })
    t1 := tup.1
    print(arr[2](7), arr[0](7), sl[1](40), t1(1))
    print(sizeof[|i64| i64](), sizeof[||](), sizeof[Ops]())

    // parameters passed by reference, pointers
    var b Big
    b.n = 3
    b.a[0] = 1
    b.a[1] = 2
    b.a[2] = 3
    print(sum_big(b), b.n)
    p := P{1, 10}
    print(with_ptr(&p), p)

    // early return from the closure, loops, defer
    print(early([]i64{1, 5, 9, 12}, 6), early([]i64{1}, 6))
    total := 0
    for i in 0..4 {
        j := i * 10
        acc := || { total += i + j }
        acc()
    }
    print(total)
    {
        d := 0
        defer { print("deferred", d) }
        bump := || {
            defer { d += 10 }
            d += 1
        }
        bump()
        bump()
    }

    // recursion
    s := 0
    sum_to(100, |x i64| { s += x })
    print(fib(15), s, depth(10, |x i64| i64 { x + 1 }))
    var fr |i64| i64
    fr = |x i64| i64 { fact(x, fr) }
    print(fr(10))

    // aggregates, floats, vectors and small integers captured and assigned
    var grid [4]i64
    names := []str{"a", "b"}
    fill_grid := |v i64| { for i in 0..4 { grid[i] = v + i } }
    fill_grid(7)
    rename := |i i64, t str| { names[i] = t }
    rename(1, "z")
    print(grid, names)
    t := (1, 2.5)
    scale := 2.0
    upd := || { t.0 += 1; t.1 *= scale; scale += 1.0 }
    upd()
    upd()
    print(t, scale)
    v := vec3(1.0, 2.0, 3.0)
    addv := |dv vec3| vec3 { v = v + dv; v }
    print(addv(vec3(1.0)), v.x)
    var b8 u8 = 250
    flag := false
    var i3 i32 = -5
    mut := || { b8 += 10; flag = !flag; i3 -= 1 }
    mut()
    print(b8, flag, i3)

    // names declared inside the literal shadow outer ones
    x := 5
    shadow := |x i64| i64 {
        y := x * 2
        {
            x := y + 1
            y = x
        }
        y
    }
    print(shadow(10), x)
}
