// Patterns over payloads with vectors, structs and Vecs.
Body :: enum { Ball(vec3, f32), Box(vec3, vec3), Ghost }
Hit :: struct { at: vec3, t: f32 }
Ray :: enum { Miss, At(Hit), Many(Vec[Hit]) }
size :: (b: Body) -> f32 {
    match b {
        Ball(_, r) => r * 2.0
        Box(lo, hi) => length(hi - lo)
        Ghost => 0.0
    }
}
nudge :: (b: *Body, d: vec3) {
    match *b {
        Ball(&c, _) => { *c = *c + d }
        Box(&lo, &hi) => {
            *lo = *lo + d
            *hi = *hi + d
        }
        Ghost => {}
    }
}
nearest :: (r: Ray) -> f32 {
    match r {
        Miss => -1.0
        At(h) => h.t
        Many(hs) if hs.len == 0 => -1.0
        Many(hs) => hs.buf[0].t
    }
}
main :: () {
    b := Ball(vec3(1.0, 2.0, 3.0), 0.5)
    bx := Box(vec3(0.0), vec3(3.0, 4.0, 0.0))
    nudge(&b, vec3(1.0, 0.0, 0.0))
    nudge(&bx, vec3(0.0, 0.0, 1.0))
    print(b, bx, size(b), size(bx), size(Ghost))
    hs := vec[Hit]()
    hs.push(Hit{at: vec3(1.0), t: 2.5})
    print(nearest(Miss), nearest(At(Hit{vec3(0.0), 1.5})), nearest(Many(hs)), nearest(Many(vec[Hit]())))
    match (b, f32(2.0)) {
        (Ball(c, r), s) if r * s == 1.0 => print("unit ball at", c.x, c.y, c.z)
        _ => print("other")
    }
}
