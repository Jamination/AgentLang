// every declaration form of the language, and the places where the parser has to look ahead
// to tell a function from an expression or a type

// constants
N :: 5
LIMIT : i64 : 100
TABLE :: [4]i64{1, 2, 4, 8}
NEG :: -(N + 1)
GROUPED :: (N + 1) * 2
PAIR :: (N, LIMIT)
priv SECRET :: 7
priv MASK : u8 : 0x0F

// globals
counter: i64
ratio: f64 = 0.5
names := [2]str{"a", "b"}
priv hidden: i64 = 3
ops := [2](i64) -> i64{double, negate}
hook: (i64) -> () = nil
gt: (i64, bool)
HANDLERS : [2](i64) -> i64 : [2](i64) -> i64{double, negate}

// types
Item :: struct { name: str, hp: i64 }
Stack[T] :: struct {
    buf: Vec[T]
    top: i64,
    cmp: (T, T) -> bool
}
Shape :: enum { Circle(f64), Rect(f64, f64), Dot }
Maybe[T] :: enum { Just(T), Nothing }
Reg :: type i64
Pred :: type (Item) -> bool
Pairs :: type [](i64, i64)
priv Hidden :: struct { v: i64 }
OneLine :: struct { a: (i64, i64) b: i64 c: () -> i64 }

// functions
double :: (x: i64) -> i64 { x * 2 }
negate :: (x: i64) -> i64 { return -x }
area :: (s: Shape) -> f64 {
    match s {
        Circle(r) => 3.0 * r * r
        Rect(w, h) => w * h
        Dot => 0.0
    }
}
apply[T, U] :: (x: T, f: (T) -> U) -> U { f(x) }
pair :: (x: i64) -> (i64, bool) { (x + 1, x > 0) }
mk :: () -> (i64) -> i64 { double }
mk2 :: (
    a: i64,
    b: i64,
) -> () -> i64 {
    counter = a + b
    get_counter
}
get_counter :: () -> i64 { counter }
noresult :: () { counter += 1 }
takes_cb :: (cb: () -> (), n: i64) {
    for i in 0..n { cb() }
}
priv helper :: () -> i64 { SECRET }
inline fast :: (x: i64) -> i64 { x + 1 }
noinline slow :: (x: i64) -> i64 { x + 2 }
priv inline both :: (x: i64) -> i64 { x + 3 }
push[T] :: (s: *Stack[T], x: T) {
    s.buf.push(x)
    s.top += 1
}
sort_by[T] :: (v: []T, less: (T, T) -> bool) {
    for i in 1..len(v) {
        j := i
        while j > 0 && less(v[j], v[j - 1]) {
            t := v[j]
            v[j] = v[j - 1]
            v[j - 1] = t
            j -= 1
        }
    }
}
fn_table :: () -> [2](i64) -> i64 { ops }
type :: (x: i64) -> i64 { x }

main :: () {
    // variables
    x := 5
    y: i64 = 6
    z: i64
    a, b := pair(x)
    f: (i64) -> i64 = double
    g: (i64) -> () = nil
    t: (i64, bool) = (1, true)
    u: (i64, bool)
    arr: [N]i64
    p: *Item = nil
    print(x, y, z, a, b, f(3), g == nil, t, u, arr, p == nil)

    // parenthesised expressions, tuples, multi-assignment
    q := (x)
    r := (x + y) * 2
    tup := (x, y)
    a, b = pair(a + 10)
    (tup).0 = 9
    print(q, r, tup, a, b, (x), ((x)), (x, (y, z)))

    // struct literals: `name: expr` in call arguments and headers
    it := Item{name: "sword", hp: 3}
    show(Item{name: "axe", hp: 4}, Item{name: "bow", hp: 1})
    if it == Item{name: "sword", hp: 3} { print("same") }
    for e in []Item{Item{name: "k", hp: 1}, it} { print(e.name) }
    while it.hp > Item{name: "x", hp: 1}.hp { it.hp -= 1 }
    match Item{name: "m", hp: 2}.hp {
        2 => print("matched")
        _ => print("no")
    }
    match (Item{name: "m", hp: 2}.hp, 1) {
        (2, o) => print("matched", o)
        _ => print("no")
    }

    // labels
    outer: for i in 0..3 {
        inner: loop {
            if i == 1 { continue outer }
            break inner
        }
        print("i", i)
    }

    // nested functions
    keep :: (it: Item, n: *i64) -> bool {
        *n += 1
        it.hp > 1
    }
    bump :: () { counter += 10 }
    twice :: (h: (i64) -> i64, v: i64) -> i64 { h(h(v)) }
    cnt := 0
    print(keep(it, &cnt), keep(Item{name: "z", hp: 9}, &cnt), cnt)
    bump()
    print(counter, twice(double, 3))

    // anonymous functions
    items := []Item{Item{name: "a", hp: 2}, Item{name: "b", hp: 7}, Item{name: "c", hp: 5}}
    sort_by(items, (a: Item, b: Item) -> bool { a.hp > b.hp })
    print(items[0].name, items[1].name, items[2].name)
    sort_by(items, (
        a: Item,
        b: Item,
    ) -> bool {
        d := a.hp - b.hp
        d < 0
    })
    print(items[0].name, items[1].name, items[2].name)
    h := (v: i64) -> i64 { v * v }
    k := () -> i64 { 42 }
    w := () { counter += 100 }
    takes_cb(w, 2)
    takes_cb(() { counter += 1 }, 3)
    print(h(7), k(), counter, apply(3, (v: i64) -> str { fmt("<", v, ">") }))
    print(apply(2, (v: i64) -> (i64, i64) { (v, v) }), (() -> i64 { 1 })())
    pred: Pred = (it: Item) -> bool { it.hp > 3 }
    print(pred(items[0]), pred(items[2]))

    // function types: in type arguments, casts, literals, results
    fs := [](i64) -> i64{double, negate}
    gs := [2](i64) -> i64{negate, double}
    vs := vec[(i64) -> i64]()
    vs.push(h)
    c := cast[(i64) -> i64](cast[*u8](double))
    vv := vec[() -> ()]()
    vv.push(w)
    vv[0]()
    m := map[str, (i64) -> i64]()
    m.set("d", double)
    ff := vec[((i64) -> i64, i64)]()
    ff.push((negate, 5))
    ff0 := ff[0].0
    hh := vec[() -> (i64) -> i64]()
    hh.push(mk)
    print(fs[0](1), fs[1](1), gs[0](1), vs[0](3), c(4), counter, m.get_or("d", negate)(8), ff0(ff[0].1), hh[0]()(6), mk()(5), mk2(1, 2)(), fn_table()[1](9))
    for fx in [](i64) -> i64{double, negate} { put(fx(2), " ") }
    print(sizeof[(i64) -> ()](), sizeof[() -> ()](), sizeof[(i64, i64)]())
    if fs[0] == [](i64) -> i64{double}[0] { print("eq") }

    // types and declarations of every kind in use
    st := Stack[i64]{buf: vec[i64](), top: 0, cmp: (a: i64, b: i64) -> bool { a < b }}
    st.push(3)
    ol := OneLine{a: (1, 2), b: 3, c: k}
    rg: Reg = 7
    mb: Maybe[i64] = Just(1)
    ps: Pairs = [](i64, i64){(1, 2)}
    hd := Hidden{v: 1}
    print(st.top, st.cmp(1, 2), ol.a, ol.b, ol.c(), rg, mb, ps, hd.v, area(Rect(2.0, 3.0)), area(Circle(1.0)), area(Dot))
    print(N, LIMIT, TABLE, NEG, GROUPED, PAIR, SECRET, MASK, ratio, names, hidden, ops[1](4), hook == nil)
    print(helper(), fast(1), slow(1), both(1), type(3), noresult == noresult)
    noresult()
    print(counter)
    more()
}

Wide :: struct {
    a: i64,
    f: () -> (),
    g: () -> () -> i64,
}

Tree :: enum {
    Leaf(i64),
    Node(*Tree, *Tree),
    Fn((i64) -> i64),
    Empty,
}

// a function that returns an anonymous function that returns a function
get :: () -> () -> (i64) -> i64 { () -> (i64) -> i64 { double } }

more :: () {
    x := 3
    y := 4
    // `(` at the start of an expression or statement: grouping, tuples, tuple patterns
    if (x) < y { print("lt") }
    if (x + 1) * 2 > 3 { print("gt") }
    for i in (0)..(2) { put(i, " ") }
    while (x, y) == (3, 4) { x += 1 }
    match (x) {
        4 => print("four")
        _ => print("other")
    }
    match (x, y) {
        (4, b) => print("pair", b)
        _ => print("other")
    }
    it := Item{name: "i", hp: 1}
    (it).hp = 5
    (&it).hp += 1
    print(it.hp, (x), (x, y), ((x), (y)))

    // function types as values of every position
    w := Wide{a: 1, f: () { counter = 0 }, g: () -> () -> i64 { get_counter }}
    w.f()
    inner_mk :: () -> (i64) -> i64 { negate }
    t := Tree.Fn((v: i64) -> i64 { v + 100 })
    r := match t {
        Fn(f) => f(1)
        Leaf(v) => v
        _ => 0
    }
    pairs: [2](i64, (i64) -> i64) = [2](i64, (i64) -> i64){(1, double), (2, negate)}
    tab: [2]() -> i64 = [2]() -> i64{get_counter, () -> i64 { 9 }}
    p1 := pairs[1].1
    print(w.g()(), inner_mk()(2), get()()(21), r, pairs[0].0, p1(5), tab[1](), HANDLERS[0](4), gt)

    // a block right after a call, a literal or a function type in a header
    n := 0
    for f in [](i64) -> i64{double, negate, HANDLERS[0]} { n += f(1) }
    if apply(n, (v: i64) -> bool { v > 0 }) { print("pos", n) }
    while apply(n, (v: i64) -> bool {
        v > 0
    }) {
        n -= 1
    }
    for k in 0..apply(2, (v: i64) -> i64 { v + 1 }) { put(k, " ") }
    print(n, len([]() -> (){w.f, noresult}))
}

show :: (a: Item, b: Item) {
    print(a.name, b.name)
}

test "declarations inside a test" {
    sq :: (x: i64) -> i64 { x * x }
    v: i64 = sq(3)
    assert v == 9
}
