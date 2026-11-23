// generics: one binary heap and one generic reduction, instantiated on i64, f64 and a struct

struct Job { prio: i64, id: i64 }

fn before(a: i64, b: i64) -> bool { a < b }
fn before(a: f64, b: f64) -> bool { a < b }
fn before(a: Job, b: Job) -> bool { a.prio < b.prio || (a.prio == b.prio && a.id < b.id) }

fn key(x: i64) -> i64 { x }
fn key(x: f64) -> i64 { i64(x * 1000.0) }
fn key(x: Job) -> i64 { x.prio * 7 + x.id }

struct Heap[T] { items: []T, n: i64 }

fn heap_push[T](h: *Heap[T], x: T) {
    i := h.n
    h.n += 1
    while i > 0 {
        p := (i - 1) / 2
        if !before(x, h.items[p]) { break }
        h.items[i] = h.items[p]
        i = p
    }
    h.items[i] = x
}

fn heap_pop[T](h: *Heap[T]) -> T {
    top := h.items[0]
    h.n -= 1
    x := h.items[h.n]
    i := 0
    loop {
        c := 2 * i + 1
        if c >= h.n { break }
        if c + 1 < h.n && before(h.items[c + 1], h.items[c]) { c += 1 }
        if !before(h.items[c], x) { break }
        h.items[i] = h.items[c]
        i = c
    }
    h.items[i] = x
    top
}

fn heapsort_checksum[T](xs: []T) -> i64 {
    h := Heap[T]{alloc[T](len(xs)), 0}
    for x in xs { heap_push(&h, x) }
    sum := 0
    for i in 0..len(xs) { sum = sum * 31 + key(heap_pop(&h)) }
    sum
}

fn main() {
    n := 400000
    ints := alloc[i64](n)
    floats := alloc[f64](n)
    jobs := alloc[Job](n)
    seed: u64 = 7
    for i in 0..n {
        seed = seed * 6364136223846793005 + 1442695040888963407
        ints[i] = i64(seed >> 20)
        floats[i] = f64(seed >> 11) * (1.0 / 9007199254740992.0)
        jobs[i] = Job{i64(seed >> 50), i}
    }
    total := 0
    for r in 0..3 {
        total = total * 13 + heapsort_checksum(ints)
        total = total * 13 + heapsort_checksum(floats)
        total = total * 13 + heapsort_checksum(jobs)
    }
    put(total, "\n")
}
