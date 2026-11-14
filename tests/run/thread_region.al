// regions and marks inside threads; a joined thread's memory is an ordinary region
use std.os

struct Res { best: str, used_after: i64, peak: i64 }

scratch_used: i64

fn job(out: *Res) {
    r := region()
    enter(&r)
    words := vec[str]()
    for i in 0..500 {
        words.push(fmt("word", i * 7 % 501))
    }
    best := words[0]
    for w in words {
        if cmp(w, best) > 0 {
            best = w
        }
    }
    leave()
    out.best = clone(best)
    reset(&r)
    out.used_after = used(&r)
    region_free(&r)
    // a long-running loop bounds its memory with mark / release
    peak := 0
    for round in 0..100 {
        m := mark()
        tmp := alloc[u8](100000)
        tmp[99999] = 1
        peak = max(peak, mark() - m)
        release(m)
    }
    out.peak = peak
    frame_begin()
    s := fmt("in a frame ", 1)
    frame_end()
}

fn main() {
    results := alloc[Res](4)
    ts := vec[Thread]()
    for k in 0..4 {
        t, _ := thread_spawn(job, &results[k])
        ts.push(t)
    }
    for i in 0..ts.len {
        thread_join(&ts[i])
    }
    for r in results {
        print(r.best, r.used_after, r.peak)
    }
    // the joiner allocates in a thread's region, then frees it
    enter(&ts[0].region)
    x := fmt("more ", 42)
    leave()
    print(x, used(&ts[0].region) > 0)
    for i in 0..ts.len {
        region_free(&ts[i].region)
    }
}
