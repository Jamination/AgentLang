// Vec[T] as an indexable value: v[i] as a place, slices, iteration, len(v).
struct P { x: i64, y: i64 }
struct Grid { cells: Vec[Vec[i64]], w: i64 }

fn total[T](v: *Vec[T]) -> T {
    s: T
    for x in v {
        s += x
    }
    s
}

fn sum_idx(v: *Vec[i64]) -> i64 {
    s := 0
    for i in 0..v.len {
        s += v[i]
    }
    s
}

fn last_two[T](v: Vec[T]) -> []T {
    return v[len(v) - 2..]
}

fn squares(n: i64) -> Vec[i64] {
    v := vec[i64]()
    for i in 0..n {
        v.push(i * i)
    }
    v
}

fn find_first[T](v: *Vec[T], x: T) -> i64 {
    for i, y in v {
        if y == x {
            return i
        }
    }
    return -1
}

fn bump(p: *i64) {
    *p += 1
}

gv: Vec[str]

fn main() {
    v := squares(10)
    // reading
    print(v[0], v[3], v[9], len(v), v.len, v.len())
    // assignment, compound assignment, address, field of an element
    v[3] = 7
    v[4] += 100
    v[5] <<= 1
    p := &v[6]
    *p = -6
    bump(&v[7])
    print(v[3], v[4], v[5], v[6], v[7])
    ps := vec[P]()
    ps.push(P{1, 2})
    ps.push(P{3, 4})
    ps[1].y = 40
    ps[0].x += 10
    q := &ps[1]
    q.x = 30
    print(ps[0], ps[1], ps[1].x + ps[0].y)
    // slices of the live elements (the capacity is 16 here)
    print(v[2..5], v[..2], v[8..], len(v[..]), len(v.buf))
    s := v[..]
    s[0] = 99                       // a slice shares the storage
    print(v[0], last_two(v), last_two(ps))
    // iteration
    for x in v {
        put(x, " ")
    }
    print()
    for i, x in v {
        if i == 2 {
            continue
        }
        if x < 0 {
            break
        }
        put(i, ":", x, " ")
    }
    print()
    // the length is read once: elements pushed during the loop are not visited
    n := 0
    for x in v {
        if n < 3 {
            v.push(x)
        }
        n += 1
    }
    print(n, v.len)
    // through a pointer: p[i] indexes the Vec
    pv := &v
    pv[1] = 11
    print(pv[1], pv[0..2], len(pv), sum_idx(pv), total(pv))
    for i, x in pv {
        if i < 3 {
            put(x, " ")
        }
    }
    print()
    // nested, in struct fields, from calls, in globals
    g := Grid{vec[Vec[i64]](), 3}
    for r in 0..2 {
        g.cells.push(squares(3))
    }
    g.cells[1][2] = 42
    g.cells[0][0] += 5
    print(g.cells[0][..], g.cells[1][..], g.cells.len, len(g.cells[1]))
    for row in g.cells {
        for c in row {
            put(c, ",")
        }
    }
    print()
    print(squares(5)[4], squares(4)[1..3], len(squares(6)))
    for x in squares(4) {
        put(x, ";")
    }
    print()
    gv.push("a")
    gv.push("bc")
    gv[0] = "A"
    print(gv[0], gv[1][1], gv[..], len(gv))
    for w in gv {
        put(w, w.len, " ")
    }
    print()
    // other element types
    fs := vec[f64]()
    fs.push(1.5)
    fs.push(2.5)
    fs[0] *= 2.0
    print(fs[0] + fs[1], total(&fs))
    ts := vec[(i64, str)]()
    ts.push((1, "one"))
    ts[0].1 = "uno"
    print(ts[0], ts[0].1)
    bs := vec[u8]()
    for c in "hey" {
        bs.push(c)
    }
    bs[0] = 'H'
    print(bs[..], bs[1..].len)
    // empty and zero-valued Vecs
    z: Vec[i64]
    e := vec[i64]()
    cnt := 0
    for x in z {
        cnt += 1
    }
    for x in e {
        cnt += 1
    }
    print(cnt, len(z), len(e), z[..], e[0..0])
    // a Vec in a Map value and in a tuple
    m := map[str, Vec[i64]]()
    m.set("sq", squares(4))
    got, _ := m.get("sq")
    pair := (got, 5)
    print(got[3], pair.0[2], m.get("sq").0[1..])
    // vector and matrix elements: components of an element are places too
    vs := vec[vec3]()
    vs.push(vec3(1.0, 2.0, 3.0))
    vs.push(vec3(4.0))
    vs[0].y = 20.0
    vs[1] = vs[1] * 2.0 + vs[0]
    vs[1][2] = -1.0
    acc := vec3(0.0)
    for q in vs {
        acc = acc + q
    }
    ms := vec[mat4]()
    ms.push(mat4(1.0))
    ms[0][3] = vec4(1.0, 2.0, 3.0, 1.0)
    ms[0][3].x = 9.0
    print(vs[0], vs[1], acc, ms[0][3], ms[0][1][1], len(vs[..1]))
    // sorting and searching through the slice view
    us := squares(6)
    us[0] = 100
    sort(us[..])
    print(us[..], us[5], find_first(&us, 9), find_first(&us, 10))
}
