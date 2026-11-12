// sleep_ms and sleep_until with times beyond i64 nanoseconds sleep (limited to ~292 years)
// instead of overflowing to a negative time and returning at once; a repeating Timer whose
// period count does not fit in an i64 reports the largest i64 instead of a negative count
use std.os

fn main() -> i64 {
    a := args()
    if len(a) > 1 {
        if a[1] == "ms" { sleep_ms(0x7FFF_FFFF_FFFF_FFFF) } else { sleep_until(1e300) }
        return 0
    }
    print(run([]str{"timeout", "0.2", a[0], "ms"}), run([]str{"timeout", "0.2", a[0], "until"}))
    sleep_until(0.0 / 0.0)
    t := timer(1e-9, true)
    print(t.tick(1e300) == 0x7FFF_FFFF_FFFF_FFFF, t.left == t.duration, t.tick(0.0 / 0.0), t.tick(2.5e-9))
    0
}
