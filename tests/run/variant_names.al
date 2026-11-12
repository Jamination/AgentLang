// A variant may have the name of a struct; a value-match takes its type from the arms that
// have one; `[_]T{...}` counts its elements.
struct Expr { x: i64 }
struct Loop { n: i64 }
enum SK { Expr(i64), Loop, Wrap(Expr) }
enum BinOp { Shl, Shr, Add }
enum Op { Shl, LShr, AShr, Rotl, Rotr }
enum MOp { Shl, Shr, Sar, Rol, Ror }
const NAMES = [_]str{"a", "b", "c"}

fn show(s: SK) -> str {
    match s {
        Expr(n) => fmt("expr ", n)
        Loop => "loop"
        Wrap(e) => fmt("wrap ", e.x)
    }
}

fn pick(o: Op) -> MOp {
    m := match o {
        Shl => Shl                  // Shl is in three enums: typed by the arms below
        LShr => Shr
        AShr => Sar
        Rotl => Rol
        _ => Ror
    }
    m
}

fn half(n: i64) -> Opt[i64] {
    r := match n % 2 {
        1 => None                   // typed by the next arm
        _ => Some(n / 2)
    }
    r
}

fn main() {
    e := Expr{x: 3}
    l := Loop{n: 2}
    s: SK = Loop
    print(show(SK.Expr(1)), show(s), show(Wrap(e)), l.n, s == Loop, Expr(4) == SK.Expr(4), Wrap(Expr{5}))
    print(pick(Shl), pick(LShr), pick(Rotr), half(3), half(8))
    xs := [_]i64{1, 2, 3, 4}
    empty := [_]u8{}
    print(xs.len, xs, len(empty), NAMES.len, NAMES, len([_](i64, str){(1, "x")}))
}
