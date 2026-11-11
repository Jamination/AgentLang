// Variant names are per enum: bare names resolve by the expected type, qualified names always work.
enum Color { Red, Green, Blue }
enum Light { Red, Amber, Green }
enum Shape { Circle(f64), Rect(f64, f64), Empty }
enum Tree { Leaf(i64), Node(*Tree, *Tree), Empty }
enum G[T] { Full(T, T), Half(T), Zero }
// variants with the names of library declarations: they win in this program
enum Cmd { push, pop, Vec(i64), Map, min }
// an enum with the variant names of the library's Opt
enum Maybe { Some(i64), None }
struct Pix { c Color, l Light }
struct S { B i64 }
enum E { A, B }

fn name(c Color) str {
    match c {
        Red => "red"
        Color.Green => "green"
        Blue => "blue"
    }
}
fn name(l Light) str {
    match l {
        Light.Red => "RED"
        Amber => "AMBER"
        Green => "GREEN"
    }
}
fn show(c Cmd) str {
    match c {
        push => "push"
        Cmd.pop => "pop"
        Vec(n) => fmt("vec ", n)
        Map => "map"
        min => "min"
    }
}
fn take(c Color) str { name(c) }
fn pass(l Light) Light { l }
fn ret() Light { return Green }
fn tail() Light { Red }
fn conv(c Color) Color { c }
fn conv(l Light) Light { l }
fn rank(c Color) i64 { i64(c) + 10 }
fn sum(t Tree) i64 {
    match t {
        Leaf(n) => n
        Node(a, b) => sum(*a) + sum(*b)
        Tree.Empty => 0
    }
}
fn opt_of(m Maybe) Opt[i64] {
    match m {
        Some(n) => Opt.Some(n)
        None => Opt.None
    }
}
fn width[T](g G[T]) i64 {
    match g {
        G.Full(_, _) => 2
        Half(_) => 1
        G[T].Zero => 0
    }
}

fn main() {
    // the expected type decides: typed variables, assignments, arguments, returns
    var c Color = Red
    var l Light = Red
    print(c, l, name(c), name(l))
    c = Green
    l = Green
    print(c, l, take(Green), pass(Green), ret(), tail())
    // struct fields, elements of typed literals, tuples with a type
    p := Pix{c: Green, l: Red}
    q := Pix{Red, Green}
    cs := []Color{Red, Green, Blue}
    ls := [3]Light{Red, Amber, Green}
    var t (Color, Light) = (Red, Red)
    print(p, q, cs, ls, t)
    // the other operand of == and !=
    print(p.c == Green, Red == p.l, p.l != Green, Green != p.c, cs[0] == Red)
    // a name that only one enum has needs nothing
    b := Blue
    a := Amber
    e := Circle(2.0)
    print(b, a, e, name(Blue), name(Amber))
    // qualified names
    x := Color.Red
    y := Light.Red
    print(x, y, i64(x), i64(y), i64(Light.Green), i64(Color.Green), Color.Blue.rank(), Blue.rank())
    s := Shape.Empty
    var te Tree = Empty
    l3 := Tree.Leaf(3)
    l4 := Leaf(4)
    print(s, te, Shape.Rect(1.0, 2.0), sum(Tree.Node(&l3, &l4)), sum(te))
    // overloads: a variant argument picks the definition whose enum has it
    print(name(Color.Red), name(Light.Red), conv(Blue), conv(Amber))
    var lc Light = conv(Red)
    print(lc)
    // generic enums
    g := G[i64].Full(1, 2)
    h := G.Half("x")
    var z G[f64] = Zero
    z2 := G[u8].Zero
    var z3 G[bool] = G.Zero
    print(g, h, z, z2, z3, width(g), width(h), width(z))
    // variants named like library declarations
    v := vec[i64]()
    v.push(3)
    v.push(max(4, 5))
    m := map[str, i64]()
    m.set("k", 1)
    print(v.items(), m.len, show(push), show(Cmd.pop), show(Vec(3)), show(Cmd.Vec(4)), show(Map), show(min))
    // user variants hide the library's; the library's stay reachable by type or qualified
    k := Some(5)
    var k2 Maybe = None
    o := Opt.Some(5)
    var o2 Opt[i64] = Some(6)
    var o3 Opt[i64] = None
    r := Ok(1)
    print(k, k2, o, o2, o3, r, o2.unwrap() + o.or(0), opt_of(k), opt_of(k2))
    var cmd Cmd = min
    print(cmd, Cmd.Map)
    // a local variable with the name of an enum or of a variant wins
    E := S{B: 7}
    print(E.B)
    A := 5
    print(A)
    {
        var ev E = B
        print(ev)
    }
}
