// Loads that are available on every way into a block (after if/else, at a loop header from
// before the loop) are reused only while nothing may have written the location: a store in
// one arm, a store in the loop through another pointer to the same memory, a call in the loop
noinline fn h(x: i64) -> i64 {
    return x
}

noinline fn bump(p: *i64) {
    *p += 100
}

struct Box {
    n: i64
    v: []i64
}

noinline fn arms(b: *Box, c: bool) -> i64 {
    x := b.n
    if c {
        b.n = 7
    } else {
        b.v[0] = 1
    }
    return x + b.n
}

noinline fn both(b: *Box, c: bool) -> i64 {
    x := b.n
    y := 0
    if c {
        y = b.v[0]
    } else {
        y = b.v[1]
    }
    return x + y + b.n + len(b.v)
}

noinline fn loop_alias(b: *Box, p: *i64) -> i64 {
    s := 0
    x := b.n
    for i in 0..3 {
        s += b.n
        *p += 1
    }
    return s + x
}

noinline fn loop_call(b: *Box) -> i64 {
    s := 0
    for i in 0..h(3) {
        s += b.n
        bump(&b.n)
    }
    return s
}

noinline fn loop_len(v: []i64) -> i64 {
    s := 0
    i := 0
    while i + 2 <= len(v) {
        s += v[i] + v[i + 1]
        i += 2
    }
    while i < len(v) {
        s += v[i]
        i += 1
    }
    return s
}

fn main() {
    b := Box{n: 5, v: alloc[i64](2)}
    print(arms(&b, true), b.n, arms(&b, false), b.v[0])
    print(both(&b, true), both(&b, false))
    print(loop_alias(&b, &b.n), b.n)
    print(loop_call(&b), b.n)
    print(loop_len([]i64{1, 2, 3, 4, 5}), loop_len([]i64{}), loop_len([]i64{9}))
}
