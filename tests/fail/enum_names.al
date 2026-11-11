Color :: enum { Red, Green, Blue }
Light :: enum { Red, Amber, Green }
Maybe[T] :: enum { Some(T), None }
f :: (c: Color) -> str { "color" }
f :: (l: Light) -> str { "light" }
Blue2 :: () -> i64 { 1 }
Bad :: enum { Blue2, f }
Dup :: enum { X, Y, X }
Red2 :: struct { x: i64 }
Bad2 :: enum { Red2 }
Node :: struct { next: *Node }
main :: () {
    print(f(Red))
    a := Red
    b := Color.Purple
    c := Maybe.Some
    d := Maybe[i64, i64].None
    e := Opt.Nothing(1)
    g := Color.Red(3)
    h := Light
    i := Colour.Red
    j: Color = Amber
    k := Maybe[i64].Some("x")
    l := Maybe[i64].Some(1, 2)
    m := None
    n: Opt[i64] = Maybe.None
    o: *Node = None
    p := (Green, 1)
    q := Green == Green
    r: Opt[i64] = Some(1)
    s: Maybe[i64] = Some(1)
    t := r == s
    u := is_some(s)
}
