// clone(x): an independent deep copy of any value. Every copy below is changed afterwards and
// the original is printed to show that nothing is shared.
struct P { x: i64, y: f64 }
struct Named { name: str, tags: []str, pos: P }
struct Node { val: i64, kids: []Node }
struct Wrap[T] { item: T, list: []T }
struct Table { rows: Vec[Named], index: Map[str, i64], grid: [2][]i64 }
struct Link { val: i64, next: *Link }
enum Color { Red, Green, Blue }
enum Shape { Dot, Circle(P, f64), Poly([]P), Label(str, i64) }
enum Tree { Leaf(i64), Fork([]Tree) }
enum Opt[T] { Some(T), None }

fn twice(x: i64) -> i64 { x * 2 }

fn depth(n: *Node) -> i64 {
    d := 0
    for k in n.kids {
        d = max(d, depth(&k))
    }
    d + 1
}

fn sum(t: Tree) -> i64 {
    match t {
        Leaf(v) => v
        Fork(ks) => {
            s := 0
            for k in ks {
                s += sum(k)
            }
            s
        }
    }
}

fn copy_of[T](x: T) -> T {
    return clone(x)
}

fn main() {
    // scalars: the value itself
    i := 42
    f := 2.5
    c := Green
    v3 := vec3(1.0, 2.0, 3.0)
    print(clone(i), clone(f), clone(true), clone(c) == Green, clone(v3), clone(7), clone('a'))

    // str and slices
    s := "hello"
    s2 := clone(s)
    s2[0] = 'j'                      // a literal is read-only, its clone is not
    xs := []i64{1, 2, 3}
    ys := clone(xs)
    ys[0] = 100
    words := []str{"ab", "cd"}
    w2 := clone(words)
    w2[0][0] = 'X'
    w2[1] = "zz"
    nested := [][]i64{[]i64{1, 2}, []i64{3}}
    n2 := clone(nested)
    n2[0][1] = 20
    empty: []i64
    print(s, s2, xs, ys, words, w2, nested, n2, len(clone(empty)), len(clone("")))

    // arrays, tuples, structs: member by member
    arr := [3]i64{1, 2, 3}
    arr2 := clone(arr)
    arr2[1] = 0
    sa := [2]str{"p", "q"}
    sa2 := clone(sa)
    sa2[0][0] = 'P'
    tup := (1, "one", []f64{1.5})
    tup2 := clone(tup)
    tup2.1[0] = 'O'
    tup2.2[0] = 9.5
    p := P{1, 2.0}
    p2 := clone(p)
    p2.x = 10
    nm := Named{"n", []str{"t1", "t2"}, P{3, 4.0}}
    nm2 := clone(nm)
    nm2.name[0] = 'N'
    nm2.tags[1][1] = '9'
    nm2.pos.x = 30
    print(arr, arr2, sa, sa2, tup, tup2)
    print(p, p2, nm, nm2)

    // enums: same variant, payload cloned
    sh := []Shape{Dot, Circle(P{1, 1.0}, 2.0), Poly([]P{P{1, 1.0}, P{2, 2.0}}), Label("lbl", 5)}
    sh2 := clone(sh)
    match sh2[2] {
        Poly(pts) => { pts[0].x = 111 }
        _ => {}
    }
    match sh2[3] {
        Label(text, k) => { text[0] = 'L' }
        _ => {}
    }
    sh2[0] = Label("new", 1)
    print(sh)
    print(sh2)
    o: Opt[[]i64] = Some([]i64{5, 6})
    o2 := clone(o)
    match o2 {
        Some(a) => { a[0] = 50 }
        None => {}
    }
    none: Opt[str] = None
    print(o, o2, clone(none))

    // recursive data through slices
    tree := Node{1, []Node{Node{2, nil}, Node{3, []Node{Node{4, []Node{Node{5, nil}}}}}}}
    t2 := clone(tree)
    t2.kids[1].kids[0].kids[0].val = 500
    t2.kids[0].kids = []Node{Node{6, nil}}
    print(depth(&tree), depth(&t2), tree.kids[1].kids[0].kids[0].val, t2.kids[1].kids[0].kids[0].val, len(tree.kids[0].kids), len(t2.kids[0].kids))
    et := Fork([]Tree{Leaf(1), Fork([]Tree{Leaf(2), Leaf(3)})})
    et2 := clone(et)
    match et2 {
        Fork(ks) => { ks[0] = Leaf(100) }
        _ => {}
    }
    print(sum(et), sum(et2))

    // Vec: the live elements; Map: keys and values
    v := vec[Named]()
    v.push(nm)
    v.push(Named{"second", nil, P{0, 0.0}})
    v2 := clone(v)
    v2[0].tags[0][0] = 'T'
    v2.push(nm)
    v2[1].name = "2nd"
    print(v.len, v2.len, v[0].tags, v2[0].tags, v[1].name, v2[1].name, len(v2.buf) >= 3)
    nums := vec[i64]()
    for k in 0..5 {
        nums.push(k)
    }
    nums2 := clone(nums)
    nums2[0] = -1
    nums2.push(5)
    nums.push(50)
    print(nums[..], nums2[..])
    zv: Vec[str]
    zv2 := clone(zv)
    zv2.push("x")
    print(zv.len, zv2.len)
    m := map[str, []i64]()
    m.set("a", []i64{1})
    m.set("b", []i64{2})
    m.del("b")
    m2 := clone(m)
    m2.get("a").0[0] = 10
    m2.set("c", []i64{3})
    print(m.get("a").0, m2.get("a").0, m.len, m2.len, m.has("c"), m2.has("c"), m2.has("b"))
    counts := map[i64, i64]()
    for k in 0..100 {
        counts.set(k, k * k)
    }
    counts2 := clone(counts)
    counts2.set(7, 0)
    counts2.del(8)
    print(counts.get_or(7, -1), counts2.get_or(7, -1), counts.len, counts2.len, counts2.get_or(99, -1))
    zm: Map[str, i64]
    zm2 := clone(zm)
    zm2.set("k", 1)
    print(zm.len, zm2.len)

    // everything together, and generic types
    tb := Table{v, map[str, i64](), [2][]i64{[]i64{1}, []i64{2, 3}}}
    tb.index.set("n", 0)
    tb2 := clone(tb)
    tb2.rows[0].name[0] = '#'
    tb2.index.set("n", 9)
    tb2.grid[1][0] = 20
    print(tb.rows[0].name, tb2.rows[0].name, tb.index.get_or("n", -1), tb2.index.get_or("n", -1), tb.grid, tb2.grid)
    wr := Wrap[str]{"it", []str{"l0", "l1"}}
    wr2 := copy_of(wr)
    wr2.item[0] = 'I'
    wr2.list[0][0] = 'L'
    wi := copy_of(Wrap[i64]{1, []i64{2}})
    print(wr, wr2, wi, copy_of(3), copy_of("s"), copy_of([]bool{true}))

    // pointers and function values are copied as they are: the pointee is shared
    tail := Link{2, nil}
    head := Link{1, &tail}
    h2 := clone(head)
    h2.val = 10
    h2.next.val = 20
    fp := clone(twice)
    pp := &p
    pp.x = 77
    print(head.val, tail.val, h2.val, fp(4), p.x)

    // method form, and clone of a temporary
    print(xs.clone(), "tmp".clone(), nm.clone().tags, clone(clone(xs))[2], clone([]i64{9})[0])
}
