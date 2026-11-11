P :: struct { x: i64, y: i64 }
W :: struct { ps: Vec[P], one: P, ptrs: Vec[*P] }
top :: (w: *W) {
    a := w.ps[0]
    a.x = 1
}
nested :: (w: *W, n: i64) -> i64 {
    s := 0
    for i in 0..n {
        p := w.ps.buf[i]
        if p.y > 0 {
            s += 1
        }
        q := w.one
        q.y += 2
    }
    return s
}
fine :: (w: *W) -> i64 {
    a := w.ps[0]
    a.x = 1
    b := w.ptrs[0]
    b.x = 2
    c := &w.ps[1]
    c.x = 3
    d := w.one
    d.y = 4
    w.ps.push(d)
    return a.x
}
main :: () {
    w := W{ps: vec[P](), one: P{x: 0, y: 0}, ptrs: vec[*P]()}
    w.ps.push(P{x: 1, y: 1})
    w.ps.push(P{x: 1, y: 1})
    w.ptrs.push(&w.one)
    top(&w)
    print(nested(&w, 1), fine(&w))
}
