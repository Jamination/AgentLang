// literals in the header of for / if / while / match: one that starts with `[` is written as
// it is, a `Name{...}` literal needs parentheses (a `{` after a name starts the body)
struct Point { x: i64, y: i64 }
struct Box[T] { items: []T, n: i64 }

fn sum(xs: []i64) -> i64 {
    t := 0
    for x in xs { t += x }
    t
}

fn main() {
    for s in []i64{1, 2, 3} {
        put(s, " ")
    }
    for i, s in [2]str{"a", "b"} { put(i, s, " ") }
    for p in []Point{Point{1, 2}, Point{3, 4}} {
        put(p.x + p.y, " ")
    }
    for row in [][]i64{[]i64{1}, []i64{2, 3}} {
        for x in row { put(x, " ") }
    }
    print()
    for x in (Box[i64]{items: []i64{7, 8, 9}, n: 3}).items { put(" ", x) }
    for i in (Point{2, 5}).x..(Point{2, 5}).y { put(" ", i) }
    print()
    xs := []i64{4, 5, 6}
    n := 3
    box := Box[i64]{items: xs, n: n}
    for x in xs { put(x) }
    for i in 0..n {
        for x in box.items { if x == 5 { put("!") } }
    }
    for x in box.items[..n] { put(x) }
    print()
    p := Point{1, 2}
    if p == (Point{1, 2}) { print("same point") }
    if p != (Point{x: 2, y: 2}) {
        print("other point")
    } else if p == (Point{}) {
        print("origin")
    }
    if xs == []i64{4, 5, 6} { print("same slice") }
    if [2]i64{1, 2} == [2]i64{1, 2} { print("same array") }
    k := 0
    while k < sum([]i64{1, 1}) { k += 1 }
    while p != (Point{1, 5}) { p.y += 1 }
    print(k, p)
    match [3]i64{10, 20, 30}[k] {
        30 => print("thirty")
        _ => print("other")
    }
    print(match (Point{5, 6}).y {
        6 => "six"
        _ => "other"
    })
    flag := true
    if flag { print("flag") }
    y := if flag { 1 } else { 2 }
    w := match n {
        3 => "three"
        _ => "many"
    }.len
    print(y, w)
}
