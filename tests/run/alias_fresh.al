// Fresh allocations as objects of their own (src/opt/alias.al): two allocations never overlap
// while both are live, but memory comes back after release / reset and a pointer to an
// allocation may reach it another way (a slice of a slice, a pointer kept in memory, a phi,
// the same struct seen as a slice, a by-reference parameter)
struct Pair {
    a: i64
    b: i64
}

struct Holder {
    p: *i64
}

noinline fn pick(c: bool) -> bool {
    return c
}

// two allocations, and a slice of the first that the second does not change
fn two(n: i64) -> i64 {
    a := alloc[i64](n)
    b := alloc[i64](n)
    a[1] = 5
    b[1] = 6
    s := a[1..]
    s[0] = 7 // a[1]
    b[0] = 8
    return a[1] * 100 + b[1] * 10 + s[0]
}

// a pointer into an allocation that went through memory
fn through_memory(n: i64) -> i64 {
    a := alloc[i64](n)
    h := new[Holder]()
    h.p = &a[3]
    a[3] = 1
    *h.p = 2
    x := a[3]
    b := alloc[i64](n)
    b[3] = 9
    return x * 10 + a[3]
}

// a phi of two allocations
fn through_phi(n: i64, c: bool) -> i64 {
    a := alloc[i64](n)
    b := alloc[i64](n)
    a[0] = 1
    b[0] = 2
    p := if pick(c) { a } else { b }
    p[0] = 30
    return a[0] + b[0]
}

// a struct and the same memory seen as a slice of its field type
fn struct_as_slice() -> i64 {
    s := new[Pair]()
    s.b = 4
    v := mkslice[i64](cast[i64](s), 2)
    v[1] = 11
    f := &s.a
    v[0] = 12
    return s.b * 100 + *f
}

// memory handed out again after release: a value kept from before must not be forwarded
fn release_reuse() -> i64 {
    t := 0
    for k in 0..4 {
        m := mark()
        a := alloc[i64](8)
        x := a[2] // zero: fresh (zeroed) memory every time
        a[2] = k + 1
        b := alloc[i64](8)
        b[2] = 50
        t += x * 1000 + a[2]
        release(m)
    }
    return t
}

// the same through a region that is reset: the second allocation gets the first's address
fn region_reuse() -> i64 {
    r := region()
    enter(&r)
    a := alloc[i64](4)
    a[0] = 5
    x := a[0]
    pa := cast[i64](ptr(a))
    reset(&r)
    b := alloc[i64](4)
    same := cast[i64](ptr(b)) == pa
    b[0] = 7
    y := b[0]
    leave()
    region_free(&r)
    return x * 100 + y * 10 + if same { 1 } else { 0 }
}

// a Vec that grows inside the loop next to a fresh array: its buffer moves to new fresh
// memory, the writes follow it
fn vec_grow() -> i64 {
    v := vec[i64]()
    v.push(1)
    a := alloc[i64](2)
    total := 0
    for i in 0..40 {
        s := v.items()
        a[0] = s[0]
        v.push(i)
        v[0] += 1
        a[1] += 1
        total += v[0] + a[0]
    }
    return total * 1000 + v[0] + a[1]
}

// a store through a by-reference parameter (inlined into a function with fresh memory)
fn set_ref(p: *i64, x: i64) {
    *p = x
}

fn by_ref(n: i64) -> i64 {
    a := alloc[i64](n)
    b := alloc[i64](n)
    a[2] = 1
    b[2] = 2
    set_ref(&a[2], 40)
    set_ref(&b[2], 50)
    return a[2] + b[2]
}

// a parameter's memory and a fresh copy
noinline fn copy_bump(s: []i64) -> i64 {
    t := alloc[i64](len(s))
    for i in 0..len(s) {
        t[i] = s[i]
    }
    x := s[1]
    t[1] = 99
    return x + s[1] + t[1]
}

// a fresh allocation in a loop, read in the next iteration through a phi
fn loop_carried() -> i64 {
    prev := alloc[i64](2)
    prev[0] = 1
    s := 0
    for i in 0..5 {
        cur := alloc[i64](2)
        cur[0] = prev[0] * 2
        prev[0] = 0 // (the old one, not cur)
        s += cur[0]
        prev = cur
    }
    return s * 10 + prev[0]
}

fn main() {
    put(two(4), "\n")
    put(through_memory(8), "\n")
    put(through_phi(2, true), " ", through_phi(2, false), "\n")
    put(struct_as_slice(), "\n")
    put(release_reuse(), "\n")
    put(region_reuse(), "\n")
    put(vec_grow(), "\n")
    put(by_ref(4), "\n")
    x := alloc[i64](3)
    x[1] = 3
    put(copy_bump(x), "\n")
    put(loop_carried(), "\n")
}
