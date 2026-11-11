// closures with generics, overloading, UFCS and the slice helpers of the library
struct Acc { total i64, calls i64 }
struct Stack[T] { items Vec[T] }
struct Box[T] { v T, f |T| T }

fn double(x i64) i64 { x * 2 }
fn inc(x i64) i64 { x + 1 }
fn apply[T, U](x T, f |T| U) U { f(x) }
fn twice[T](x T, f |T| T) T { f(f(x)) }
fn apply_fn[T](x T, f fn(T) T) T { f(x) }
fn call_it[F](f F) i64 { f(20) }
fn for_each[T](s *Stack[T], f |T|) {
    for x in s.items.items() { f(x) }
}
fn fold[T, A](xs []T, init A, f |A, T| A) A {
    acc := init
    for x in xs { acc = f(acc, x) }
    acc
}
// the literal is lowered once per instantiation, with T known
fn gen_sum[T](xs []T, zero T) T {
    acc := zero
    each(xs, |x T| { acc += x })
    acc
}
fn gen_nested[T](xs []T, bias T) []T {
    out := vec[T]()
    each(xs, |x T| {
        add := |y T| { out.push(y + bias) }
        add(x)
        add(x + x)
    })
    out.items()
}
fn largest[T](items []T, less |T, T| bool) T {
    best := items[0]
    for x in items {
        if less(best, x) { best = x }
    }
    best
}

fn over(f |i64| i64) str { fmt("int ", f(1)) }
fn over(f |str| str) str { fmt("str ", f("s")) }
fn over(f fn(f64) f64) str { fmt("fn ", f(1.5)) }
fn run(f ||) { f() }
fn run(f |i64|, x i64) { f(x) }
fn by_len(a str, b str) bool { len(a) < len(b) }
fn pair() (i64, |i64| i64) { (3, inc) }

fn main() {
    k := 3
    print(apply(4, |x i64| i64 { x * k }), apply(4, double), apply("abc", |s str| i64 { len(s) + k }))
    print(twice(5, double), twice(5, |x i64| i64 { x + k }), twice("ab", |s str| str { concat(s, s) }))
    print(apply_fn(4, |x i64| i64 { x * 10 }), apply_fn("ab", |s str| str { concat(s, "!") }))
    print(call_it(inc), call_it(|x i64| i64 { x + k }))
    print(gen_sum([]i64{1, 2, 3}, 0), gen_sum([]f64{1.5, 2.5}, 0.0))
    print(gen_nested([]i64{1, 2}, 10), gen_nested([]f64{0.5}, 1.0))
    print(fold([]i64{1, 2, 3}, "", |a str, x i64| str { fmt(a, x) }), fold([]f64{1.5, 2.0}, 1.0, |a f64, x f64| f64 { a * x }))
    print(largest([]i64{3, 9, 4}, |a i64, b i64| bool { a < b }), largest([]str{"aa", "b", "cccc"}, by_len))

    acc := Acc{0, 0}
    st := Stack[i64]{items: vec[i64]()}
    st.items.push(4)
    st.items.push(5)
    st.for_each(|x i64| { acc.total += x; acc.calls += 1 })
    print(acc)
    bx := Box[i64]{v: 4, f: |x i64| i64 { x * k }}
    bs := Box[str]{v: "a", f: |s str| str { concat(s, s) }}
    print(bx.f(bx.v), bs.f(bs.v))

    // overloads: a literal has the closure type of its written types
    print(over(|x i64| i64 { x + k }), over(|s str| str { s }), over(|x f64| f64 { x * 2.0 }))
    hits := 0
    run(|| { hits += 1 })
    run(|x i64| { hits += x }, 10)
    n, f := pair()
    print(hits, n, f(n))

    // sort_by with local state: indices ordered by a key array
    keys := []i64{50, 10, 40, 20, 30}
    idx := []i64{0, 1, 2, 3, 4}
    sort_by(idx, |a i64, b i64| bool { keys[a] < keys[b] })
    print(idx)
    desc := true
    sort_by(keys, |a i64, b i64| bool { if desc { a > b } else { a < b } })
    print(keys)
    words := []str{"pear", "fig", "banana", "kiwi"}
    sort_by(words, by_len)
    print(words)
    compares := 0
    sort_by(words, |a str, b str| bool { compares += 1; cmp(a, b) < 0 })
    print(words, compares > 0)

    // slice helpers
    xs := []i64{1, 2, 3, 4, 5, 6}
    print(xs.any(|x i64| bool { x > 5 }), xs.all(|x i64| bool { x > 1 }), any(xs[..0], |x i64| bool { true }), all(xs[..0], |x i64| bool { false }))
    print(xs.count_if(|x i64| bool { x % 2 == 0 }), xs.index_where(|x i64| bool { x * x > 10 }), xs.index_where(|x i64| bool { x > 100 }))
    print(xs.filter(|x i64| bool { x % k == 0 }), xs.map_to(|x i64| f64 { f64(x) / 2.0 }), map_to(xs, double))
    print(xs.map_to(|x i64| (i64, str) { (x, fmt("#", x)) })[1], len(filter(xs, |x i64| bool { false })))
    sum := 0
    each(xs, |x i64| {
        if x == 2 {
            return
        }
        sum += x
    })
    print(sum)
    if xs.any(|x i64| bool { x > k }) {
        for x in xs.filter(|x i64| bool { x > k }) {
            put(x, " ")
        }
        print("")
    }
}
