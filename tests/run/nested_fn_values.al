// nested functions: generic enclosing functions, method-call syntax, function values,
// sort_by with a context
struct P { x i64, y i64 }
struct Holder { f fn(i64) i64, n i64 }
struct Keys { keys []i64, desc bool }

fn apply(f fn(i64) i64, x i64) i64 { f(x) }

// lowered once per instantiation, with T known
fn gsum[T](xs []T, zero T) T {
    acc := zero
    fn add(x T) { acc += x }
    for x in xs { add(x) }
    acc
}
fn gmap[T](xs []T, bias T) []T {
    out := vec[T]()
    fn emit(x T) {
        fn twice(y T) T { y + y + bias }
        out.push(twice(x))
    }
    for x in xs { emit(x) }
    out[..]
}
// a nested function that uses no local is a value of the instantiation
fn ident_of[T]() fn(T) T {
    fn id(x T) T { x }
    id
}
fn largest[T, C](items []T, ctx C, less fn(C, T, T) bool) T {
    best := items[0]
    fn better(x T) bool { less(ctx, best, x) }
    for x in items {
        if x.better() { best = x }
    }
    best
}

fn by_key(c Keys, a i64, b i64) bool {
    if c.desc { c.keys[a] > c.keys[b] } else { c.keys[a] < c.keys[b] }
}

fn main() {
    print(gsum([]i64{1, 2, 3}, 0), gsum([]f64{1.5, 2.5}, 0.0), gmap([]i64{1, 2}, 10), gmap([]f64{0.5}, 1.0))
    fi := ident_of[i64]()
    fs := ident_of[str]()
    print(fi(4), fs("s"))

    // values: variable, argument, struct field, table, returned
    fn dbl(x i64) i64 { x * 2 }
    f := dbl
    h := Holder{f: dbl, n: 1}
    tab := [2]fn(i64) i64{dbl, f}
    var slot fn(i64) i64 = nil
    slot = dbl
    print(apply(dbl, 4), f(5), h.f(6), tab[1](8), slot(9), 7.dbl())
    fn shorter(a str, b str) bool { len(a) < len(b) }
    words := []str{"pear", "fig", "banana"}
    sort_by(words, shorter)
    print(words)

    // method-call syntax: a nested function in scope comes first; pointer receivers
    cnt := 0
    fn bump(p *P, d i64) { p.x += d; cnt += 1 }
    fn px(q P) i64 { q.x + cnt }
    p := P{1, 2}
    p.bump(5)                    // passes &p
    bump(&p, 1)
    pp := &p
    pp.bump(10)
    print(p, cnt, pp.px(), p.px(), P{1, 1}.px())
    n := 3
    fn inc(x *i64) { *x += n }
    n.inc()
    print(n)

    // state for a callback is passed as a context
    keys := []i64{50, 10, 40, 20, 30}
    idx := []i64{0, 1, 2, 3, 4}
    sort_by(idx, Keys{keys, false}, by_key)
    print(idx)
    sort_by(idx, Keys{keys, true}, by_key)
    print(idx)
    fn by_ptr(k *[]i64, a i64, b i64) bool { (*k)[a] < (*k)[b] }
    sort_by(idx, &keys, by_ptr)
    print(idx)
    fn less_mod(m i64, a i64, b i64) bool { a % m < b % m }
    print(largest(keys, 7, less_mod), largest([]str{"aa", "b"}, 0, by_len))
}

fn by_len(unused i64, a str, b str) bool { len(a) < len(b) }
