// Processes through std.os, with the same output on every target (also run by
// `tests/run.sh --target windows`): the program starts copies of itself. Arguments keep
// spaces, quotes, backslashes, tabs, empty strings and non-ASCII text on the way.
use std.os

fn main() -> i64 {
    a := args()
    if len(a) > 2 && a[1] == "child" {
        for x in a[3..] {
            print(fmt("[", x, "]"))
        }
        code, _ := parse_i64(a[2])
        return code
    }
    if len(a) > 1 && a[1] == "stderr" {
        put("out ")
        flush()
        eput("err ")
        return 0
    }
    if len(a) > 1 && a[1] == "sleep" {
        sleep_ms(20000)
        return 0
    }
    if len(a) > 1 && a[1] == "panic" {
        panic("from the child")
    }
    me := a[0]
    print("args:", a[1..])
    out, st := run_capture([]str{me, "child", "3", "a b", "", "q\"uote", "back\\slash\\", "end\\\\", "tab\there", "\xc3\xbcn\xc3\xaf", "\\\\\"x", "-"})
    put(out)
    print("status:", st, io_error())
    out2, st2 := run_capture_all([]str{me, "stderr"})
    print("both:", out2, st2)
    p, ok := spawn([]str{me, "sleep"})
    print("spawn:", ok, pid(p) > 0, pid(p) != process_id())
    s1, d1 := try_wait(p)
    print("running:", s1, d1, kill(p, 0))
    print("kill:", kill(p, 9), wait(p), wait(p), try_wait(p), kill(p, 9), io_error())
    q, _ := spawn([]str{me, "child", "300"})
    print("exit 300:", wait(q))
    print("panic:", run([]str{me, "panic"}))
    _, okm := spawn([]str{"no-such-program-al"})
    print("missing:", okm, io_error(), error_text(io_error()))
    empty: []str
    _, oke := spawn(empty)
    print("empty:", oke, io_error())
    none: Process
    print("not started:", wait(none), io_error(), kill(none, 9))
    v, has := env_get("PORTABLE_PROCESS_NOT_SET")
    print("env:", v, has, len(current_dir()) > 0)
    return 0
}
