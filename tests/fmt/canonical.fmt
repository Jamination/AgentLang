// A file in the canonical layout: `alc fmt` changes nothing (canonical.fmt is the same text).
use std.os

priv const LIMIT = 3                   // a trailing comment in its own column
priv const TABLE = [4]i64{1, 2, 4, 8}

// a struct with one field per line
priv struct Item {
    name: str
    tags: []str             // aligned comments
    next: *Item             // stay aligned
}

priv enum Shape { Circle(f64), Rect(f64, f64), Empty }

priv fn area(s: Shape) -> f64 {
    return match s {
        Circle(r) => 3.14159 * r * r
        Rect(w, h) => w * h
        Empty => 0.0
    }
}

fn main() -> i64 {
    items := vec[Item]()
    items.push(Item{name: "a", tags: []str{"x", "y"}})
    for i, it in items {
        if i < LIMIT && len(it.tags) > 0 {
            print(it.name, it.tags[..1], TABLE[i])
        } else if it.next != nil {
            continue
        }
    }
    p := &items[0]
    p.name = "b"
    t := TABLE
    n := -t[1] + *&t[2] * 2
    shapes := []Shape{Circle(1.0), Rect(2.0, 3.0), Empty}
    sort_by(shapes, fn(a: Shape, b: Shape) -> bool { area(a) > area(b) })
    when TARGET_OS == Windows {
        sep := "\\"
    } else {
        sep := "/"
    }
    print(n, shapes[0], sep, `raw
text`, 'a', 0xFF, 1_000, 2.5e-3)
    loop {
        break
    }
    return if n > 0 { 0 } else { 1 }
}

test "area" {
    assert area(Rect(2.0, 3.0)) == 6.0, "rect"
}
