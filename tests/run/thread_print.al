// output of many threads: every line stays whole (the program runs itself and checks)
use std.os

fn talk(k: i64) {
    for i in 0..300 {
        print("thread", k, "line", i, "abcdefghijklmnopqrstuvwxyz")
        put("part ", k, " ")
        put(i, "\n")
        if i % 100 == 0 {
            eprint(fmt("err ", k, " ", i))
        }
    }
    put("tail ", k, "\n")
}

fn main() {
    a := args()
    if len(a) > 1 && a[1] == "child" {
        print("child starts")
        ts := vec[Thread]()
        for k in 0..16 {
            t, _ := thread_spawn(talk, k)
            ts.push(t)
        }
        for i in 0..ts.len {
            thread_join(&ts[i])
        }
        print()
        print("child ends")
        return
    }
    out, status := run_capture([]str{a[0], "child"})
    ls := lines(out)
    next_a := vec_fill(16, 0)
    next_b := vec_fill(16, 0)
    bad := 0
    tails := 0
    for l in ls {
        f := fields(l)
        if l == "child starts" || l == "child ends" || l == "" {
            continue
        }
        if starts_with(l, "tail ") {
            tails += 1
            continue
        }
        if len(f) == 5 && f[0] == "thread" && f[4] == "abcdefghijklmnopqrstuvwxyz" {
            k, _ := parse_i64(f[1])
            i, _ := parse_i64(f[3])
            if next_a[k] != i {
                bad += 1
            }
            next_a[k] = i + 1
        } else if len(f) == 3 && f[0] == "part" {
            k, _ := parse_i64(f[1])
            i, _ := parse_i64(f[2])
            if next_b[k] != i {
                bad += 1
            }
            next_b[k] = i + 1
        } else {
            bad += 1
        }
    }
    print(status, ls[0], ls[ls.len - 1], bad, contains(next_a[..], 299), contains(next_b[..], 299), next_a[5], next_b[9], tails)
}
