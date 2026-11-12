// Frame slots of aggregate temporaries are shared when their contents are never needed at
// the same time (src/x86/isel.al alloca_slots); values that are needed together keep
// separate slots, also across loop iterations and when one is copied into another.
struct Big { a: [20]i64, tag: str }

inline fn mk(k: i64, tag: str) -> (Big, bool) {
    b: Big
    for i in 0..20 { b.a[i] = k * 100 + i }
    b.tag = tag
    (b, k % 2 == 0)
}

inline fn sum(b: Big) -> i64 {
    s := 0
    for x in b.a { s += x }
    s
}

noinline fn pick(n: i64) -> (Big, bool) {
    if n == 0 { return mk(1, "one") }
    if n == 1 { return mk(2, "two") }
    if n == 2 {
        r, ok := mk(3, "three")
        r.a[5] = -1
        return (r, ok)
    }
    mk(n, "many")
}

noinline fn together(n: i64) -> i64 {
    x, _ := mk(n, "x")
    y, _ := mk(n + 1, "y")
    z, _ := mk(n + 2, "z")
    keep := x
    t := 0
    for i in 0..3 {
        w, ok := mk(i, "w")
        if ok { t += sum(w) - sum(keep) } else { keep = w }
        x.a[i] = t
    }
    sum(x) + sum(y) * 3 + sum(z) * 7 + sum(keep) + t
}

fn main() {
    for n in 0..5 {
        b, ok := pick(n)
        print(b.tag, ok, sum(b), b.a[5])
    }
    print(together(4), together(-3))
}
