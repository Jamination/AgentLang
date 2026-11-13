// Enum layout: the tag is the smallest unsigned integer that holds the variant number (1 byte
// up to 256 variants, 2 bytes up to 65,536), the payloads follow at their natural alignment.

enum Color { Red, Green, Blue }
enum Big {
    V0, V1, V2, V3, V4, V5, V6, V7, V8, V9, V10, V11, V12, V13, V14,
    V15, V16, V17, V18, V19, V20, V21, V22, V23, V24, V25, V26, V27, V28, V29,
    V30, V31, V32, V33, V34, V35, V36, V37, V38, V39, V40, V41, V42, V43, V44,
    V45, V46, V47, V48, V49, V50, V51, V52, V53, V54, V55, V56, V57, V58, V59,
    V60, V61, V62, V63, V64, V65, V66, V67, V68, V69, V70, V71, V72, V73, V74,
    V75, V76, V77, V78, V79, V80, V81, V82, V83, V84, V85, V86, V87, V88, V89,
    V90, V91, V92, V93, V94, V95, V96, V97, V98, V99, V100, V101, V102, V103, V104,
    V105, V106, V107, V108, V109, V110, V111, V112, V113, V114, V115, V116, V117, V118, V119,
    V120, V121, V122, V123, V124, V125, V126, V127, V128, V129, V130, V131, V132, V133, V134,
    V135, V136, V137, V138, V139, V140, V141, V142, V143, V144, V145, V146, V147, V148, V149,
    V150, V151, V152, V153, V154, V155, V156, V157, V158, V159, V160, V161, V162, V163, V164,
    V165, V166, V167, V168, V169, V170, V171, V172, V173, V174, V175, V176, V177, V178, V179,
    V180, V181, V182, V183, V184, V185, V186, V187, V188, V189, V190, V191, V192, V193, V194,
    V195, V196, V197, V198, V199, V200, V201, V202, V203, V204, V205, V206, V207, V208, V209,
    V210, V211, V212, V213, V214, V215, V216, V217, V218, V219, V220, V221, V222, V223, V224,
    V225, V226, V227, V228, V229, V230, V231, V232, V233, V234, V235, V236, V237, V238, V239,
    V240, V241, V242, V243, V244, V245, V246, V247, V248, V249, V250, V251, V252, V253, V254,
    V255, V256, V257, V258, V259, V260, V261, V262, V263, V264, V265, V266, V267, V268, V269,
    V270, V271, V272, V273, V274, V275, V276, V277, V278, V279, V280, V281, V282, V283, V284,
    V285, V286, V287, V288, V289, V290, V291, V292, V293, V294, V295, V296, V297, V298, V299
}
enum Bytes { B1(u8), B2(u8, u8), BNone }
enum Shorts { S1(u16), S0 }
enum Ints { I1(i32), F1(f32), I0 }
enum Longs { L1(i64), D1(f64), P1(*i64), L0 }
enum Text { T1(str), T0 }
enum Vec4 { V(vec4), VNone }
enum Wide { W0(u8), W1(u8, u16), W2(Color, i32), W3(Opt[u8]), W4 }
enum BigData { BD0, BD1(u8), BD2(i64) }
enum Shape { Circle(f64), Rect(f64, f64), Tri(i32, i32, i32), Empty }
enum Tree { Leaf(i64), Node(*Tree, *Tree) }

struct Tagged { c: Color, b: u8 }
struct Mixed { a: u8, o: Opt[u16], c: Color, x: i32 }
struct Entity { kind: Color, hp: i16, alive: bool, pos: vec2 }

const COLORS = [3]Color{Red, Green, Blue}
const PAIRS = [2]Tagged{Tagged{c: Blue, b: 7}, Tagged{c: Green, b: 9}}
g_color: Color
g_tags: [4]Color

fn name(c: Color) -> str {
    return match c {
        Red => "red"
        Green => "green"
        Blue => "blue"
    }
}

fn big_last(b: Big) -> i64 {
    return match b {
        V0 => 0
        V255 => 255
        V256 => 256
        V299 => 299
        _ => -1
    }
}

fn area(s: Shape) -> f64 {
    return match s {
        Circle(r) => 3.0 * r * r
        Rect(w, h) => w * h
        Tri(a, b, c) if a + b > c => f64(a + b + c)
        Tri(_, _, _) => -1.0
        Empty => 0.0
    }
}

fn wide(w: Wide) -> i64 {
    return match w {
        W0(x) => i64(x)
        W1(a, b) => i64(a) * 1000 + i64(b)
        W2(Red, n), W2(Green, n) => i64(n)
        W2(Blue, n) => -i64(n)
        W3(Some(x)) => 500 + i64(x)
        W3(None) => 499
        W4 => 4
    }
}

fn sum(t: *Tree) -> i64 {
    return match *t {
        Leaf(v) => v
        Node(a, b) => sum(a) + sum(b)
    }
}

// enums by value in more arguments than there are registers, and returned
noinline fn many(a: Color, b: Shape, c: Opt[u8], d: Big, e: Bytes, f: Opt[i64], g: Color, h: Shape, i: Wide, j: Big) -> (Color, Shape, Big) {
    t := area(b) + area(h)
    k := i64(a) + i64(g) + big_last(d) + big_last(j) + wide(i)
    k += match c { Some(x) => i64(x); None => 0 }
    k += match e { B1(x) => i64(x); B2(x, y) => i64(x) + i64(y); BNone => 0 }
    k += f.or(0)
    return (if k > 300 { Blue } else { Red }, Rect(t, f64(k)), Big.V298)
}

fn bump(s: *Shape) {
    match *s {
        Circle(&r) => { *r += 1.0 }
        Rect(&w, _) => { *w *= 2.0 }
        _ => {}
    }
}

fn main() {
    print("sizes", sizeof[Color](), sizeof[Big](), sizeof[Bytes](), sizeof[Shorts](), sizeof[Ints](), sizeof[Longs](), sizeof[Text](), sizeof[Vec4](), sizeof[Wide](), sizeof[BigData](), sizeof[Shape](), sizeof[Tree]())
    print("opt", sizeof[Opt[u8]](), sizeof[Opt[bool]](), sizeof[Opt[Color]](), sizeof[Opt[u16]](), sizeof[Opt[i32]](), sizeof[Opt[i64]](), sizeof[Opt[Opt[u8]]](), sizeof[Opt[Big]](), sizeof[Opt[str]]())
    print("structs", sizeof[Tagged](), sizeof[Mixed](), sizeof[Entity](), sizeof[[10]Color](), sizeof[[3]Opt[u8]](), sizeof[(Color, u8, Color)]())

    // values and conversions
    print(Color.Red, Blue, i64(Color.Blue), u8(Color.Green), i64(Big.V299), u16(Big.V256), i64(cast[Color](2)))
    print(name(COLORS[1]), PAIRS[0].c, PAIRS[1], COLORS)
    g_color = Blue
    g_tags[2] = Green
    print(g_color, g_tags)

    // arrays and structs of enums
    cs: [10]Color
    for i in 0..10 {
        cs[i] = if i % 3 == 0 { Red } else if i % 3 == 1 { Green } else { Blue }
    }
    n := 0
    for c in cs {
        if c == Blue { n += 1 }
    }
    print(cs, n)
    m := Mixed{a: 1, o: Some(u16(65535)), c: Green, x: -5}
    m2 := m
    m2.o = None
    print(m, m2, m == m2, m.o == Some(u16(65535)))
    es := vec[Entity]()
    for i in 0..5 {
        es.push(Entity{kind: if i == 2 { Blue } else { Red }, hp: i16(i * 10), alive: i != 3, pos: vec2(f32(i), 1.0)})
    }
    hp := 0
    for e in es {
        if e.kind == Red && e.alive { hp += i64(e.hp) }
    }
    print(hp, es[2].kind)

    // equality
    print(Bytes.B2(1, 2) == B2(1, 2), Bytes.B2(1, 2) == B2(1, 3), Bytes.B1(1) == B2(1, 0), Bytes.BNone == BNone)
    w := Wide.W1(7, 65535)
    print(w == W1(7, 65535), w != W1(7, 0), w == W4, Wide.W3(Some(3)) == W3(Some(3)), Wide.W3(None) == W3(Some(0)))
    print(Big.V299 == V299, Big.V299 != V298, Opt[Big].Some(V256) == Some(V256), BigData.BD1(3) == BD1(3), BigData.BD2(3) == BD1(3))

    // hashing and Map keys
    print(hash(Color.Blue) == hash(Color.Blue), hash(Color.Blue) == hash(Color.Red), hash(Big.V299) == hash(Big.V299))
    print(hash(Shape.Rect(1.0, 2.0)) == hash(Shape.Rect(1.0, 2.0)), hash(Wide.W1(1, 2)) == hash(Wide.W1(1, 2)), hash(Wide.W1(1, 2)) == hash(Wide.W1(2, 1)))
    counts := map[Color, i64]()
    for c in cs {
        k, _ := counts.get(c)
        counts.set(c, k + 1)
    }
    print(counts)
    bm := map[Big, str]()
    bm.set(V0, "first")
    bm.set(V299, "last")
    bm.set(V256, "past a byte")
    v299, f299 := bm.get(V299)
    v1, f1 := bm.get(V1)
    print(len(bm), v299, f299, v1 == "", f1)
    wm := map[Wide, i64]()
    wm.set(W1(1, 2), 12)
    wm.set(W2(Blue, 9), 9)
    wm.set(W3(None), 0)
    wm.set(W1(1, 2), 13)
    a12, _ := wm.get(W1(1, 2))
    b9, _ := wm.get(W2(Blue, 9))
    _, f3 := wm.get(W3(Some(0)))
    print(len(wm), a12, b9, f3)

    // clone
    t := Text.T1("hello")
    t2 := clone(t)
    print(t, t2, t == t2)
    ts := vec[Text]()
    ts.push(T1("a"))
    ts.push(T0)
    ts2 := clone(ts)
    ts2[0] = T1("b")
    print(ts[0], ts2[0], ts[1] == ts2[1])

    // match on every form
    print(name(Green), big_last(V0), big_last(V255), big_last(V256), big_last(V299), big_last(V5))
    print(area(Circle(1.0)), area(Rect(2.0, 3.0)), area(Tri(1, 2, 3)), area(Tri(1, 2, 9)), area(Empty))
    print(wide(W0(200)), wide(W1(3, 40000)), wide(W2(Green, 5)), wide(W2(Blue, 5)), wide(W3(Some(250))), wide(W3(None)), wide(W4))
    pair := (Color.Blue, Opt[u8].Some(9))
    r := match pair {
        (Red, _) => 1
        (Blue, Some(x)) if x > 5 => 2
        (_, None) => 3
        _ => 4
    }
    print(r)
    l1 := new[Tree]()
    *l1 = Leaf(40)
    l2 := new[Tree]()
    *l2 = Leaf(2)
    root := new[Tree]()
    *root = Node(l1, l2)
    print(sum(root))
    s := Shape.Circle(2.0)
    bump(&s)
    s2 := Shape.Rect(1.5, 4.0)
    bump(&s2)
    print(s, s2)
    x := match Big.V257 { V257 => "257"; _ => "other" }
    print(x)

    // many arguments by value, results
    rc, rs, rb := many(Blue, Circle(1.0), Some(u8(250)), V299, B2(3, 4), Some(100), Green, Rect(2.0, 2.0), W2(Blue, 7), V256)
    print(rc, rs, rb)
    print(Bytes.B2(255, 1), Shorts.S1(65535), Ints.I1(-1), Ints.F1(1.5), Longs.L1(-9), Vec4.V(vec4(1.0, 2.0, 3.0, 4.0)), Opt[Opt[u8]].Some(Some(1)))
}
