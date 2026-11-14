// 64 threads allocate at the same time (Vec growth, Map, fmt, clone, slice literals); their
// results are used after the joins without a copy, then their memory is given back
use std.os

struct Item { name: str, tags: []i64 }

struct Out { items: []Item, check: i64 }

fn work(a: (i64, *Out)) {
    k, out := a
    v := vec[Item]()
    m := map[str, i64]()
    for i in 0..2000 {
        name := fmt("t", k, "-", i)
        v.push(Item{name, []i64{k, i, k * i}})
        m.set(name, i)
    }
    c := clone(v)
    check := 0
    for it in c.items() {
        check += m.get_or(it.name, -1) + it.tags[2]
    }
    out.items = c.items()
    out.check = check
}

fn main() {
    outs := alloc[Out](64)
    ts := vec[Thread]()
    for k in 0..64 {
        t, ok := thread_spawn(work, (k, &outs[k]))
        assert ok
        ts.push(t)
    }
    for i in 0..ts.len {
        thread_join(&ts[i])
    }
    good := 0
    for k in 0..64 {
        o := outs[k]
        // sum of i plus sum of k * i over 0..2000
        want := 1999000 + k * 1999000
        if o.check == want && len(o.items) == 2000 && o.items[1999].name == fmt("t", k, "-1999") && o.items[5].tags[1] == 5 {
            good += 1
        }
    }
    print(good, used(&ts[3].region) > 0)
    for i in 0..ts.len {
        region_free(&ts[i].region)
    }
    print(used(&ts[3].region))
}
