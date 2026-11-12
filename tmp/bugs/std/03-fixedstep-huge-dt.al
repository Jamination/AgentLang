// FixedStep.advance is documented to return 0..max_steps. With a huge or infinite dt,
// i64(acc / step) overflows to i64 MIN: advance returns -9223372036854775808, steps goes
// negative, and acc stays huge, so every later advance is broken too.
// expected: 8 8 0.0 1   actual (before the fix): MIN MIN 1e300 MIN
fn main() {
    f := fixed_step(60.0)
    print(f.advance(1e300), f.steps, f.acc, f.advance(1.0 / 60.0))
}
