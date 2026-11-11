// nested functions and anonymous functions: ordinary functions written inside another one.
// They see globals, constants, other functions and the type parameters of the enclosing
// function, but none of its variables.
Item :: struct { name: str, hp: i64 }
Ops :: struct { f: (i64) -> i64, g: (*i64) -> () }
Big :: struct { a: i64, b: i64, c: i64, d: i64, e: i64, f: f64 }
K :: 10
total: i64

apply[T, U] :: (x: T, f: (T) -> U) -> U { f(x) }
compose :: (f: (i64) -> i64, g: (i64) -> i64, x: i64) -> i64 { f(g(x)) }

// the type parameter of the enclosing function, one lowering per instantiation
sorted[T] :: (xs: []T, less: (T, T) -> bool) -> []T {
    swap :: (a: *T, b: *T) {
        t := *a
        *a = *b
        *b = t
    }
    for i in 0..len(xs) {
        for j in i + 1..len(xs) {
            if less(xs[j], xs[i]) { swap(&xs[i], &xs[j]) }
        }
    }
    return xs
}
largest[T] :: (xs: []T, key: (T) -> i64) -> T {
    best := xs[0]
    better :: (a: T, b: T, key: (T) -> i64) -> bool { key(a) > key(b) }
    for x in xs {
        if better(x, best, key) { best = x }
    }
    return best
}
zero_of[T] :: () -> () -> T {
    return () -> T {
        z: T
        z
    }
}

// a function value that outlives the call that made it
adder :: () -> (i64) -> i64 {
    add_k :: (x: i64) -> i64 { x + K }
    return add_k
}
tripler :: () -> (i64) -> i64 { return (x: i64) -> i64 { x * 3 } }

fib :: (n: i64) -> i64 {
    go :: (n: i64, a: i64, b: i64) -> i64 {
        if n == 0 { return a }
        return go(n - 1, b, a + b)
    }
    return go(n, 0, 1)
}

shadow :: (x: i64) -> i64 {
    len :: (s: str) -> i64 { 100 }
    x2 :: (x: i64) -> i64 { x * 2 }
    r := x2(x) + len("abc") + "abc".len()
    if x > 0 {
        x2 :: (x: i64) -> i64 { x * 20 }
        return r + x2(x)
    }
    return r
}

main :: () {
    // explicit state: pointers and context parameters
    n := 0
    bump :: (n: *i64, k: i64) { *n += k }
    bump(&n, 4)
    n.bump(1)
    for i in 0..3 {
        step :: (acc: *i64, i: i64) { *acc += i * K }
        step(&n, i)
    }
    print(n)

    // named and anonymous functions as values
    xs := []Item{Item{name: "a", hp: 3}, Item{name: "b", hp: 9}, Item{name: "c", hp: 5}}
    by_name :: (a: Item, b: Item) -> bool { a.name[0] < b.name[0] }
    sort_by(xs, (a: Item, b: Item) -> bool { a.hp > b.hp })
    print(xs[0].name, xs[1].name, xs[2].name)
    sort_by(xs, by_name)
    print(xs[0].name, largest(xs, (it: Item) -> i64 { it.hp }).name)
    keys := []i64{30, 10, 20}
    idx := []i64{0, 1, 2}
    sort_by(idx, keys, (k: []i64, a: i64, b: i64) -> bool { k[a] < k[b] })
    print(idx, sorted([]str{"pear", "fig", "apple"}, (a: str, b: str) -> bool { len(a) < len(b) }))

    o := Ops{f: (x: i64) -> i64 { x + 1 }, g: (p: *i64) { *p = -*p }}
    o.g(&n)
    add := adder()
    tri: (i64) -> i64 = tripler()
    print(n, o.f(1), add(1), tri(5), compose(add, tri, 2), compose((x: i64) -> i64 { x - 1 }, o.f, 0))
    print(apply(2, (x: i64) -> str { fmt("<", x, ">") }), apply("abc", (s: str) -> i64 { len(s) }))
    print(zero_of[i64]()(), zero_of[f64]()(), len(zero_of[str]()()))
    fs := [](i64) -> i64{add, tri, (x: i64) -> i64 { -x }}
    for f in fs { put(f(7), " ") }
    print()

    // globals are visible
    count :: (x: i64) { total += x }
    count(3)
    count(4)
    print(total, fib(30), shadow(2), shadow(0))

    // nested in nested, an anonymous function inside a nested one, forward to a later scope
    outer :: (x: i64) -> i64 {
        inner :: (y: i64) -> i64 {
            innermost :: (z: i64) -> i64 { z + K }
            innermost(y) * 2
        }
        g := (v: i64) -> i64 { inner(v) + 1 }
        g(x)
    }
    print(outer(1))

    // many parameters, floats, structs by value and as result
    m8 :: (a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64) -> i64 { a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h }
    mixed :: (a: f64, b: i64, v: vec3, it: Item, g: Big, s: str, h: f32) -> Big {
        Big{b, it.hp, len(it.name), g.e, len(s), a + f64(v.z) + g.f + f64(h)}
    }
    print(m8(1, 2, 3, 4, 5, 6, 7, 8), mixed(1.5, 2, vec3(1.0, 2.0, 3.0), xs[0], Big{1, 2, 3, 4, 5, 6.5}, "hey", 0.25))

    // declared in a block that is lowered more than once
    defer {
        bye :: () { print("bye") }
        bye()
    }
    k := 0
    while (x: i64) -> bool { x < 3 }(k) {
        k += 1
    }
    print(k, () -> i64 { 42 }())
    if k > 100 { return }
}
