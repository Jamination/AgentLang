// sleep_ms(huge) and sleep_until(1e300) overflowed i64 nanoseconds and returned at once; a
// repeating timer(1e-9).tick(1e300) returned a negative count.
// expected: sleeps (killed by timeout: 124) / true   actual (before the fix): 0 / false
fn main() {
    t := timer(1e-9, true)
    print(t.tick(1e300) > 0)
    sleep_ms(0x7FFF_FFFF_FFFF_FFFF)
}
