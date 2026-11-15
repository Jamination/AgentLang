// sleep_ms and sleep_until with times beyond i64 nanoseconds sleep (limited to ~292 years)
// instead of overflowing to a negative time and returning at once; a repeating Timer whose
// period count does not fit in an i64 reports the largest i64 instead of a negative count
use std.os

// starts the program again with `mode`; after 0.2 s it must still run: (running, the status
// after kill)
fn still_asleep(me: str, mode: str) -> (bool, i64) {
    p, _ := spawn([]str{me, mode})
    sleep_ms(200)
    _, ended := try_wait(p)
    kill(p, 9)
    (!ended, wait(p))
}

fn main() -> i64 {
    a := args()
    if len(a) > 1 && a[1] == "child-ms" {
        sleep_ms(0x7FFF_FFFF_FFFF_FFFF)
        return 0
    }
    if len(a) > 1 && a[1] == "child-until" {
        sleep_until(1e300)
        return 0
    }
    print(still_asleep(a[0], "child-ms"), still_asleep(a[0], "child-until"))
    sleep_until(0.0 / 0.0)
    t := timer(f64(1e-9), true)
    print(t.tick(f64(1e300)) == 0x7FFF_FFFF_FFFF_FFFF, t.left == t.duration, t.tick(f64(0.0) / 0.0), t.tick(f64(2.5e-9)))
    0
}
