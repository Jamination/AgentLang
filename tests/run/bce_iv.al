// Loops whose index checks can never fail (`for i in k..n` indexing something of length n):
// the checks are removed, also when the body calls functions or leaves the loop early.
log: Vec[i64]

note :: (x: i64) {
    log.push(x)
}

each :: (s: []i64) {
    for i in 0..len(s) {
        note(s[i])
    }
}

each_from :: (s: []i64, skip: bool) -> i64 {
    n := 0
    for i in 2..len(s) {
        if skip && s[i] == 40 {
            continue
        }
        if s[i] > 60 {
            break
        }
        note(s[i])
        n += 1
    }
    n
}

find :: (s: []str, w: str) -> i64 {
    for i in 0..len(s) {
        if s[i] == w {
            return i
        }
    }
    return -1
}

total :: (v: *Vec[i64]) -> i64 {
    t := 0
    for i in 0..v.len {
        t += v[i]
    }
    t
}

scale :: (v: *Vec[f64], k: f64) {
    for i in 0..len(v) {
        v[i] *= k
    }
}

pairs :: (s: []i64) -> i64 {
    t := 0
    for i in 0..len(s) {
        for j in 0..len(s) {
            t += s[i] * s[j]
            note(t)
        }
    }
    t
}

// the loop bound is not the length: the check stays (and passes here)
first :: (s: []i64, n: i64) -> i64 {
    t := 0
    for i in 0..n {
        t += s[i]
        note(t)
    }
    t
}

main :: () {
    s := []i64{10, 20, 30, 40, 50, 60, 70}
    each(s)
    print(log[..])
    log.len = 0
    print(each_from(s, true), each_from(s, false), each_from(s[..1], false), log[..])
    print(find([]str{"a", "b", "c"}, "c"), find([]str{"a"}, "z"), find(nil, "a"))
    v := vec[i64]()
    for i in 0..100 {
        v.push(i)
    }
    f := vec[f64]()
    f.push(1.5)
    f.push(2.0)
    scale(&f, 2.0)
    log.len = 0
    print(total(&v), f[..], pairs(s[..3]), first(s, 3), log.len)
    none: []i64
    each(none)
    print(total(&log) > 0)
}
