// A repeating timer(0.1) ticked by 8.7 s: 87 periods have ended, but tick returned 86 and left
// `left` at exactly 0, so the next tick(0.0) fired once more without any time passing.
// tick(1.1) left `left` at 0.10000000000000009 > duration: progress() was negative.
// expected: 87 0 / true   actual (before the fix): 86 1 / false
fn main() {
    t := timer(f64(0.1), true)
    print(t.tick(f64(8.7)), t.tick(f64(0.0)))
    u := timer(f64(0.1), true)
    u.tick(f64(1.1))
    print(u.progress() >= 0.0)
}
