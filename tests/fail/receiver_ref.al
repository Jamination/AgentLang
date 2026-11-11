// automatic & on receivers: what is still an error
fn incr(p: *i64) { *p += 1 }
fn scale(p: *f32) { *p *= 2.0 }
fn reset(p: *i64) { *p = 0 }
fn reset(p: *f64) { *p = 0.0 }
fn deep(p: **i64) {}

fn main() {
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
