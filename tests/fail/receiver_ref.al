// automatic & on receivers: what is still an error
incr :: (p: *i64) { *p += 1 }
scale :: (p: *f32) { *p *= 2.0 }
reset :: (p: *i64) { *p = 0 }
reset :: (p: *f64) { *p = 0.0 }
deep :: (p: **i64) {}

main :: () {
    f := 1.5
    f.incr()
    v := vec3(1.0, 2.0, 3.0)
    v.x.scale()
    v[1].scale()
    s := "text"
    s.reset()
    x := 1
    x.deep()
    // only the receiver is referenced automatically, not other arguments
    incr(x)
}
