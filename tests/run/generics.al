struct Pair[A, B] { a A, b B }
struct Stack[T] { items []T, n i64 }

fn max2[T](a T, b T) T {
    if a > b { a } else { b }
}
fn swap2[T](p *T, q *T) {
    t := *p
    *p = *q
    *q = t
}
fn mk[T]() Stack[T] {
    Stack[T]{items: alloc[T](4), n: 0}
}
fn spush[T](s *Stack[T], x T) {
    if s.n == len(s.items) {
        bigger := alloc[T](s.n * 2)
        for i in 0..s.n {
            bigger[i] = s.items[i]
        }
        s.items = bigger
    }
    s.items[s.n] = x
    s.n += 1
}
fn spop[T](s *Stack[T]) T {
    s.n -= 1; s.items[s.n]
}
fn map[T, U](a []T, f fn(T) U) []U {
    out := alloc[U](len(a))
    for i, x in a {
        out[i] = f(x)
    }
    out
}
fn sq(x i64) i64 { x * x }
fn half(x i64) f64 { f64(x) / 2.0 }
fn first[A, B](p Pair[A, B]) A { p.a }

fn main() {
    print(max2(3, 9), max2(2.5, 1.5), max2(u8(200), 100))
    x := 1; y := 2
    swap2(&x, &y)
    print(x, y)
    s := mk[i64]()
    for i in 0..10 {
        s.spush(i * 3)
    }
    print(s.n, s.spop(), s.spop(), len(s.items))
    p := Pair[i64, str]{7, "seven"}
    print(p, first(p))
    a := []i64{1, 2, 3}
    print(map(a, sq), map(a, half))
    f := sq
    print(f(12))
    st := mk[Pair[i64, f64]]()
    st.spush(Pair[i64, f64]{1, 1.5})
    print(st.items[0].b, st.n)
}
