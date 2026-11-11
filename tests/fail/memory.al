T :: struct { n: i64 }
len :: (t: *T) -> i64 { t.n }
clone :: (t: T, k: i64) -> T { T{t.n + k} }
ptr :: (t: *T) -> i64 { 7 }
nothing :: () { }
main :: () {
    t := T{3}
    v := vec[i64]()
    a := len(3)
    b := clone()
    c := clone(t, "x")
    d := t.print()
    e := clone[i64](t)
    f := len(t, t)
    x := 5
    g := x.len()
    h := t.ptr(1)
    i := v["a"]
    j := v.sizeof()
    k := clone(nothing())
    l := v[1..2.5]
    for q in t { }
    m := t[0]
    o := v.len(1)
    p := clone(nil)
    v[0] = "s"
    r := &v[..]
}
Opt[T] :: enum { Some(T), None }
hash :: (o: Opt[i64]) -> i64 { 1 }
later :: () {
    a := hash(Some("s"))
    b := hash(None, 1)
}
