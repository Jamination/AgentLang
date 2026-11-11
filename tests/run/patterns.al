// match: nested patterns, guards, alternatives with bindings, tuple patterns, `&name`.
enum Shape { Circle(f64), Rect(f64, f64), Empty }
enum Color { Red, Green, Blue }
enum Tree { Leaf(i64), Node(*Tree, *Tree), Nil }
enum Pair { Two(i64, i64), Single(i64) }
enum Tok { Num(i64), Word(str), Flag(bool), Ratio(f64), Byte(u8), Ptr(*i64), Sym(Color) }
enum Wrap { W(P, Opt[Color]), Z }
enum Big { Arr([100]i64), Small(i64) }
enum Cell { Full(P, str), Free }
struct P { x: i64, y: i64 }
struct Holder { name: str, slot: Opt[P] }
const LIMIT = 10
const NAME = "ada"

fn describe(o: Opt[Shape]) -> str {
    // nested variant patterns cover Opt[Shape] together: no `_` arm is needed
    match o {
        Some(Circle(r)) if r > 10.0 => fmt("big circle ", r)
        Some(Circle(r)) => fmt("circle ", r)
        Some(Rect(w, h)) if w == h => fmt("square ", w)
        Some(Rect(w, h)) => fmt("rect ", w, "x", h)
        Some(Empty) => "empty shape"
        None => "nothing"
    }
}

fn pair(p: Pair) -> str {
    match p {
        Two(0, _) => "zero first"
        Two(_, 0) => "zero second"
        Two(LIMIT, y) => fmt("limit and ", y)
        Two(x, y) if x == y => "equal"
        Two(x, _), Single(x) if x < 0 => fmt("negative ", x)
        Two(x, y) => fmt(x, "+", y)
        Single(n) => fmt("single ", n)
    }
}

fn both(a: Opt[i64], b: Opt[i64]) -> i64 {
    match (a, b) {
        (Some(x), Some(y)) => x + y
        (Some(x), None), (None, Some(x)) => x
        (None, None) => -1
    }
}

fn classify(t: (i64, str, bool)) -> str {
    match t {
        (0, _, _) => "zero"
        (_, "hi", true) => "greeting"
        (n, s, false) => fmt("no:", n, s)
        (n, s, _) => fmt("yes:", n, s)
    }
}

fn tok(t: Tok) -> str {
    match t {
        Num(0) => "zero"
        Num(-1) => "minus one"
        Num('a') => "letter a"
        Num(LIMIT + 1) => "eleven"
        Num(n) => fmt("num ", n)
        Word("") => "empty word"
        Word(NAME) => "ada!"
        Word(w) => fmt("word ", w)
        Flag(true) => "yes"
        Flag(false) => "no"
        Ratio(0.5) => "half"
        Ratio(r) => fmt("ratio ", r)
        Byte(200) => "byte 200"
        Byte(b) => fmt("byte ", b)
        Ptr(nil) => "null"
        Ptr(p) => fmt("ptr to ", *p)
        Sym(Red) => "red"
        Sym(Color.Green) => "green"
        Sym(c) => fmt("other colour ", c)
    }
}

fn depth(t: *Tree) -> i64 {
    match *t {
        Nil => 0
        Leaf(_) => 1
        Node(l, r) => 1 + max(depth(l), depth(r))
    }
}

// adds `d` to every leaf, in place
fn add(t: *Tree, d: i64) {
    match *t {
        Leaf(&n) => { *n += d }
        Node(l, r) => {
            add(l, d)
            add(r, d)
        }
        Nil => {}
    }
}

fn sum(t: *Tree) -> i64 {
    match *t {
        Leaf(n) => n
        Node(l, r) => sum(l) + sum(r)
        Nil => 0
    }
}

fn wrap(w: Wrap) -> str {
    match w {
        W(p, Some(Red)) => fmt("red at ", p.x, ",", p.y)
        W(p, Some(c)) => fmt(c, " at ", p)
        W(&p, None) => fmt("plain ", p.x)
        Z => "z"
    }
}

fn pick[T](o: Opt[T], d: T) -> T {
    match o {
        Some(x) => x
        None => d
    }
}

fn first_or[T](o: Opt[(T, T)], d: T) -> T {
    match o {
        Some((a, _)) => a
        None => d
    }
}

fn mk() -> Opt[P] { Some(P{1, 2}) }
fn scaled(p: P, k: i64) -> i64 { p.x * k }

fn colour_pair(p: (Color, Color)) -> i64 {
    match p {
        (Red, _) => 1
        (_, Red) => 2
        (Green, Green), (Blue, Blue) => 3
        (Green, Blue), (Blue, Green) => 4
    }
}

fn bools(t: (bool, bool)) -> str {
    match t {
        (true, true) => "both"
        (true, false), (false, true) => "one"
        (false, false) => "none"
    }
}

state: Opt[P]
fn clobber() -> bool {
    state = None
    false
}

calls: i64
fn tick() -> bool {
    calls += 1
    calls % 2 == 0
}

fn main() {
    print(describe(Some(Circle(11.0))), describe(Some(Circle(1.0))), describe(Some(Rect(2.0, 2.0))), describe(Some(Rect(2.0, 3.0))), describe(Some(Shape.Empty)), describe(None))
    print(pair(Two(0, 5)), pair(Two(5, 0)), pair(Two(10, 7)), pair(Two(4, 4)), pair(Two(-3, 2)), pair(Single(-1)), pair(Two(1, 2)), pair(Single(9)))
    print(both(Some(1), Some(2)), both(Some(5), None), both(None, Some(7)), both(None, None))
    print(classify((0, "a", true)), classify((1, "hi", true)), classify((2, "x", false)), classify((3, "y", true)))
    k := 5
    print(tok(Num(0)), tok(Num(-1)), tok(Num(97)), tok(Num(11)), tok(Num(12)))
    print(tok(Word("")), tok(Word("ada")), tok(Word("bob")), tok(Flag(true)), tok(Flag(false)))
    print(tok(Ratio(0.5)), tok(Ratio(0.25)), tok(Byte(200)), tok(Byte(7)), tok(Ptr(nil)), tok(Ptr(&k)))
    print(tok(Sym(Red)), tok(Sym(Green)), tok(Sym(Blue)))

    // trees: by-reference bindings modify the matched value in place
    l1 := Leaf(1)
    l2 := Leaf(2)
    l3 := Leaf(3)
    n1 := Node(&l1, &l2)
    root := Node(&n1, &l3)
    add(&root, 10)
    print(depth(&root), sum(&root), l1, l2, l3)

    o: Opt[i64] = Some(41)
    match o {
        Some(&v) => { *v += 1 }
        None => {}
    }
    print(o)
    // a copy does not change the matched value
    match o {
        Some(v) => { v += 1; print(v) }
        None => {}
    }
    print(o)
    print(wrap(W(P{1, 2}, Some(Red))), wrap(W(P{3, 4}, Some(Blue))), wrap(W(P{5, 6}, None)), wrap(Z))

    // the matched value is a field, an element, the target of a pointer
    h := Holder{name: "h", slot: Some(P{1, 1})}
    match h.slot {
        Some(&p) => { p.x = 7 }
        None => {}
    }
    cells := []Cell{Full(P{1, 2}, "a"), Free, Full(P{3, 4}, "b")}
    for i in 0..len(cells) {
        match cells[i] {
            Full(&p, &s) => {
                p.y *= 10
                *s = concat(*s, "!")
            }
            Free => {}
        }
    }
    print(h, cells)
    v := vec[Opt[i64]]()
    v.push(Some(1))
    v.push(None)
    v.push(Some(3))
    total := 0
    for i in 0..v.len {
        match v.buf[i] {
            Some(&n) => {
                *n *= 2
                total += *n
            }
            None => { v.buf[i] = Some(100) }
        }
    }
    print(v.items(), total)

    // a value that is not a place lives in a temporary: the pointer is valid in the arm
    match mk() {
        Some(&p) => {
            p.x = 50
            print(p.x, p.y)
        }
        None => {}
    }

    // tuples
    t := (1, P{2, 3})
    match t {
        (&a, &b) => {
            *a = 10
            b.y = 30
        }
    }
    print(t)
    x := 3
    y := 4
    match (x, y) {
        (0, 0) => print("origin")
        (a, 0), (0, a) => print("on an axis at", a)
        (a, b) if a == b => print("diagonal")
        (a, b) => print("at", a, b)
    }
    print(colour_pair((Red, Blue)), colour_pair((Blue, Red)), colour_pair((Green, Green)), colour_pair((Blue, Green)))
    print(bools((true, true)), bools((false, true)), bools((false, false)))
    print(pick(Some("s"), "d"), pick(Opt[f64].None, 2.5), first_or(Some((1, 2)), 0), first_or(Opt[(i64, i64)].None, 9))

    // large payloads are copied or referenced as a whole
    arr: [100]i64
    for i in 0..100 {
        arr[i] = i
    }
    big := Arr(arr)
    match big {
        Arr(&a) => { a[99] = -1 }
        Small(_) => {}
    }
    match big {
        Arr(a) => {
            a[0] = 12345
            print(a[1], a[98], a[99])
        }
        Small(n) => print(n)
    }
    match big {
        Arr(a), Arr(a) => print(a[0])
        Small(_) => {}
    }

    // alternatives with bindings of aggregate and pointer types
    w := W(P{8, 9}, None)
    match (w, Free) {
        (W(p, _), Free), (Z, Full(p, _)) => print(p)
        _ => print("?")
    }
    match (Full(P{4, 5}, "n"), 1) {
        (Full(&p, _), 0), (Full(&p, _), 1) => {
            p.x += 1
            print(p.x, p.y)
        }
        _ => print("?")
    }

    // guards: evaluated once per arm, after the bindings; false continues with the next arm
    for i in 0..6 {
        match i {
            0 => put("zero ")
            _ if i % 2 == 0 => put("even ")
            1, 3 => put("one-or-three ")
            _ => put("other ")
        }
    }
    print()
    calls = 0
    r := match Some(5) {
        Some(n) if tick() => n
        Some(n) if tick() => n * 2
        Some(n) => n * 3
        None => 0
    }
    print(r, calls)

    // a guard that changes the matched variable: the arms keep looking at the value as it was
    state = Some(P{1, 2})
    match state {
        Some(p) if clobber() => print("not taken", p)
        Some(p) => print("still", p, state)
        None => print("none")
    }

    // match as a value in several positions; loops and defer inside arms
    s := "abc"
    q := match (s, len(s)) {
        ("abc", 3) => 1
        (_, 0) => 2
        _ => 3
    }
    print(q, match Two(1, 2) { Two(a, b) => a * b; Single(a) => a })
    out := vec[str]()
    for sh in ([]Shape{Circle(1.0), Empty, Rect(1.0, 2.0), Circle(3.0)}) {
        match sh {
            Empty => continue
            Circle(r) if r > 2.0 => break
            Circle(r) => {
                defer { out.push("done") }
                out.push(fmt("c", r))
            }
            Rect(a, b) => out.push(fmt("r", a * b))
        }
    }
    print(out.items())
    // an arm's own pattern may be any expression that is compared with the value (as before)
    lim := 3
    bx := P{4, 0}
    px := &lim
    match 12 {
        lim => print("lim")
        bx.scaled(2) => print("eight")
        bx.scaled(3) => print("twelve")
        _ => print("other")
    }
    match px {
        nil => print("nil")
        &k => print("k")
        &lim => print("lim")
        _ => print("other")
    }
    // a binding hides an outer variable of the same name
    n := 1
    match Some(2) {
        Some(n) => print(n)
        None => {}
    }
    print(n)
}
