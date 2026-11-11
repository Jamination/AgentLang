// `priv` declarations inside one file: shadowing of the library, generics, method calls,
// locals of the same name, function values, constants in types and patterns.

priv struct Vec2i { x i64, y i64 }
priv struct Box[T] { v T, count i64 }
priv struct Node { val i64, next *Node }
priv struct Handler { run fn(i64) i64, base i64 }
priv enum Tree { Leaf(i64), Fork(*Tree, *Tree) }
priv const N = 4
priv const NAME = "names"
priv const HALF f64 = 0.5
priv var grid [N]i64
priv var ops = [2]fn(i64) i64{twice, negate}
priv var origin = Vec2i{x: 1, y: 2}

// shadows of library functions: the private one wins where it fits
priv fn min(a i64, b i64) i64 { 1000 + a + b }
priv fn max[T](a T, b T) T { a }
priv fn push(b *Box[i64], x i64) {
    b.v += x
    b.count += 1
}
priv fn size(b Box[i64]) i64 { b.count }
// a builtin is replaced in this file, as a public function of its name would replace it
priv fn popcnt(x i64) i64 { 99 }

priv inline fn twice(x i64) i64 { x * 2 }
priv noinline fn negate(x i64) i64 { -x }
priv fn run(h Handler, x i64) i64 { -1 }
priv fn count(b Box[str]) i64 { 77 }

// generic private functions and structs
priv fn pick[T](a T, b T) T { b }
priv fn wrap[T](v T) Box[T] { Box[T]{v: v, count: 1} }
priv fn unwrap[T](b Box[T]) T { b.v }
priv fn convert[T, U](b Box[T], f fn(T) U) Box[U] { Box[U]{v: f(b.v), count: b.count} }

// overloads, all private
priv fn area(v Vec2i) i64 { v.x * v.y }
priv fn area(b Box[i64]) i64 { b.v }
priv fn area(t *Tree) i64 {
    match *t {
        Leaf(v) => v
        Fork(l, r) => area(l) + area(r)
    }
}

// recursion through private names
priv fn sum(n *Node) i64 {
    if n == nil { 0 } else { n.val + sum(n.next) }
}
priv fn even(n i64) bool { if n == 0 { true } else { odd(n - 1) } }
priv fn odd(n i64) bool { if n == 0 { false } else { even(n - 1) } }

priv fn less(a Vec2i, b Vec2i) bool { a.x < b.x }
priv fn to_text(x i64) str { fmt("<", x, ">") }
priv fn to_float(x i64) f64 { f64(x) }
priv fn both() (Vec2i, Box[str]) { (Vec2i{3, 4}, wrap("w")) }
priv fn kind(x i64) str {
    match x {
        N => "N"
        0, 1 => "small"
        _ => "other"
    }
}

fn main() {
    // library names: private definitions first, the library's for other types
    print(min(1, 2), min(1.5, 2.5), max(1, 2), max("a", "b"))
    v := vec[i64]()
    v.push(5)
    v.push(6)
    b := wrap(10)
    b.push(5)
    push(&b, 6)
    print(v.len, len(v.items()), b.size(), size(b), len("four"), b, popcnt(7))

    // generics, explicit type arguments, method syntax
    print(pick(1, 2), pick[str]("p", "q"), unwrap(wrap(2.5)), wrap(Vec2i{1, 2}))
    t := b.convert(to_text)
    u := convert[i64, f64](b, to_float)
    print(t, u.v * HALF, t.unwrap(), b.unwrap[i64]())

    // overloads and receivers
    leaf1 := Leaf(3)
    leaf2 := Leaf(4)
    tree := Fork(&leaf1, &leaf2)
    print(area(Vec2i{3, 5}), b.area(), tree.area(), origin.area())

    // a field that holds a function is called before a private function of that name;
    // a field name is never a private name
    h := Handler{run: twice, base: 1}
    print(h.run(21), run(h, 21), h.base)
    sb := Box[str]{v: "s", count: 3}
    print(sb.count, sb.count(), count(sb))

    // locals, parameters and loop variables may reuse private names
    twice := 3
    print(twice + 1, negate(twice))
    for N in 0..2 {
        put(N, " ")
    }
    {
        min := 7
        print(min)
    }
    print(min(2, 3), kind(N), kind(1), kind(9))

    // constants in types, globals, function values
    var local [N]i64
    grid[N - 1] = 9
    local[0] = len(NAME)
    print(grid, local, sizeof[Vec2i](), sizeof[[N]Vec2i]())
    f := negate
    var g fn(i64) i64 = twice2
    print(f(4), g(4), ops[0](8), ops[1](8))
    pts := []Vec2i{Vec2i{3, 0}, Vec2i{1, 0}, Vec2i{2, 0}}
    sort_by(pts, less)
    print(pts)

    // pointers, recursion, tuples, maps, equality, hashing
    n2 := Node{val: 2, next: nil}
    n1 := &Node{val: 1, next: &n2}
    p, q := both()
    m := map[Vec2i, str]()
    m.set(p, "found")
    print(sum(n1), even(10), odd(10), p, q, m.get_or(Vec2i{3, 4}, "missing"), p == Vec2i{3, 4}, hash(p) == hash(Vec2i{3, 4}))
    pn := new[Node]()
    pn.val = 40
    pn.next = n1
    print(sum(pn), origin)
    statements()
}

priv var depth i64
priv fn enter() i64 {
    depth += 1
    depth
}
priv fn leave() { depth -= 1 }
priv fn pair() (i64, str) { (N, NAME) }

// private names in every kind of statement and expression
priv fn statements() {
    xs := []i64{10, 20, 30, 40, 50, 60}
    print(xs[1..N], xs[..N - 2], xs[N..], -N, !even(N), ~N, (N, NAME).0)
    {
        enter()
        defer { leave() }
        print("depth", depth)
    }
    print("depth", depth)
    assert N == 4, NAME
    assert even(N)
    var a i64
    var s str
    a, s = pair()
    c, d := pair()
    print(a, s, c, d)
    i := 0
    while i < N {
        i += twice2(1)
    }
    loop {
        i -= 1
        if i < N {
            break
        }
    }
    for k, x in xs[..N / 2] {
        put(k, ":", x + N, " ")
    }
    for j in N..=N + 4 by N / 2 {
        put(j, " ")
    }
    e := if even(i) { NAME } else { "odd" }
    var w Vec2i = origin
    w.x += N
    *(&w.y) = area(w)
    pw := &w
    grid[i] = pw.x
    print(e, w, grid[i], i)
    t := Leaf(N)
    r := match t {
        Leaf(N) => N + 1
        Fork(l, r) => 0
    }
    print(r, N)
}

priv fn twice2(x i64) i64 { twice(twice(x)) }
