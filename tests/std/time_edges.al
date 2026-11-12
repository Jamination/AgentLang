// FixedStep.advance stays within 0..max_steps for any dt (a huge or infinite dt used to give
// i64 MIN through the float to integer conversion and broke the accumulator for good);
// a repeating Timer counts a period that ends exactly at the end of a tick in that tick and
// keeps progress() in [0, 1]
fn main() {
    f := fixed_step(60.0)
    print(f.advance(1e300), f.steps, f.acc, f.advance(1.0 / 60.0), f.steps)
    g := fixed_step(60.0)
    print(g.advance(1.0 / 0.0), g.advance(0.05), g.steps, g.alpha() < 1.0)
    h := fixed_step(60.0)
    print(h.advance(0.125), h.advance(1e19), h.advance(0.0), h.steps)
    t := timer(0.1, true)
    print(t.tick(8.7), t.tick(0.0), t.tick(0.05))
    u := timer(0.1, true)
    print(u.tick(1.1), u.progress() >= 0.0, u.left <= u.duration)
}
