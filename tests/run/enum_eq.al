// `==` / `!=` / `hash` on enums with data: the same variant with equal payload values.
struct Pos { x: i64, y: i64 }
enum Tk { Id(str), Num(f64), Pair(i64, []i64), At(Pos), Nl, Eof }
enum Tree { Leaf(i64), Node(*Tree, *Tree), Many([]Tree), Empty }
enum Color { Red, Green }
struct Cell { t: Tk, c: Color }

fn is_nl(t: Tk) -> bool { t == Nl }                 // one comparison of the tag
fn not_eof(t: *Tk) -> bool { *t != Tk.Eof }
fn count(ts: []Tk, what: Tk) -> i64 {
    n := 0
    for t in ts {
        if t == what { n += 1 }
    }
    n
}

fn main() {
    t := Tk.Nl
    print(t == Nl, Nl == t, t != Nl, t == Tk.Eof, Tk.Nl == t, is_nl(Id("x")), not_eof(&t))
    print(Id("ab") == Id(concat("a", "b")), Id("a") == Num(1.0), Num(0.0) == Num(-0.0), Num(1.5) != Num(1.5))
    print(Pair(1, []i64{1, 2}) == Pair(1, []i64{1, 2}), Pair(1, []i64{1, 2}) == Pair(1, []i64{1, 3}), Pair(2, nil) != Pair(1, nil))
    print(At(Pos{1, 2}) == At(Pos{1, 2}), At(Pos{1, 2}) == At(Pos{2, 1}))
    a := Leaf(1)
    b := Leaf(1)
    // pointers compare by address; slices by content
    print(a == b, Node(&a, &b) == Node(&a, &b), Node(&a, &b) == Node(&b, &a), Many([]Tree{a, Empty}) == Many([]Tree{b, Empty}), a == Empty, Tree.Empty == Empty)
    // inside structs, tuples, Opt, arrays
    print(Cell{Nl, Red} == Cell{Nl, Red}, Cell{Id("q"), Red} == Cell{Id("q"), Green}, (Nl, 1) == (Tk.Nl, 1), [2]Tk{Nl, Eof} == [2]Tk{Nl, Eof})
    o: Opt[Tk] = Some(Nl)
    print(o == Some(Nl), o == None, o != None, Some(Id("z")) == o, o == Opt[Tk].None)
    // library functions that compare
    ts := []Tk{Nl, Id("a"), Nl, Num(2.0), Id("a")}
    print(count(ts, Nl), count(ts, Id("a")), count(ts, Eof), index_of(ts, Num(2.0)), contains(ts, Id("b")), ts == ts[..5], ts[..2] == ts[2..4])
    // keys of a Map, hash
    m := map[Tk, i64]()
    for x in ts { m.set(x, m.get_or(x, 0) + 1) }
    print(m.len, m.get_or(Id("a"), 0), m.get_or(Nl, 0), m.has(Eof), m.del(Num(2.0)), len(m))
    print(hash(Id("a")) == hash(Id(concat("", "a"))), hash(Nl) != hash(Eof), hash(Num(0.0)) == hash(Num(-0.0)), hash(Id("a")) != hash(Id("b")))
}
