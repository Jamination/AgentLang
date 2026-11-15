// Programs started from several threads at once do not hold each other's pipes: run_capture
// returns when its program has ended, also while another thread starts programs that go on
// running. (On Windows a program inherits every inheritable handle of its parent; the copies
// of the standard handles that a starting program gets were inherited by a program that
// another thread started at that moment, which kept the capture pipe open until it ended.)
use std.os

fn num(s: str) -> i64 {
    n, _ := parse_i64(s)
    n
}

// the command line that runs this program as a child
fn me(what: []str) -> []str {
    argv := vec_of([]str{args()[0], "child"})
    argv.extend(what)
    argv.items()
}

struct Work { rounds: i64, good: *i64, worst_ms: *i64 }

// captures the output of short programs, one after the other
fn capture(w: Work) {
    for i in 0..w.rounds {
        t := clock_ns()
        out, status := run_capture(me([]str{"say", fmt(i)}))
        ms := (clock_ns() - t) / 1_000_000
        if ms > *w.worst_ms { *w.worst_ms = ms }
        if status == 0 && out == fmt("said ", i, "\n") { *w.good += 1 }
    }
}

fn main() -> i64 {
    a := args()
    if len(a) > 3 && a[1] == "child" {
        if a[2] == "sleep" { sleep_ms(num(a[3])) }
        if a[2] == "say" { print("said", a[3]) }
        return 0
    }
    good := 0
    worst := 0
    t, ok := thread_spawn(capture, Work{40, &good, &worst})
    // meanwhile: programs that run for 6 seconds
    sleepers := vec[Process]()
    for i in 0..40 {
        p, okp := spawn(me([]str{"sleep", "6000"}))
        if okp { sleepers.push(p) }
    }
    thread_join(&t)
    print("started:", ok, sleepers.len, "captured:", good, "no capture waited for a sleeper:", worst < 3000)
    if worst >= 3000 { print("  the longest took", worst, "ms") }
    statuses := 0
    for p in sleepers {
        kill(p, 9)
        statuses += wait(p)
    }
    print("sleepers ended:", statuses == 137 * sleepers.len)
    return 0
}
