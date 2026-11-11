struct Vec2 { x: f64, y: f64 }
struct Rect { min: Vec2, max: Vec2, tag: i32 }
struct Node { val: i64, next: *Node }

fn add(a: Vec2, b: Vec2) -> Vec2 {
    Vec2{x: a.x + b.x, y: a.y + b.y}
}

fn area(r: Rect) -> f64 {
    (r.max.x - r.min.x) * (r.max.y - r.min.y)
}

fn grow(r: *Rect, d: f64) {
    r.max.x += d
    r.max.y += d
}

fn sum_list(n: *Node) -> i64 {
    s := 0
    while n != nil {
        s += n.val
        n = n.next
    }
    s
}

fn main() {
    a := Vec2{1.0, 2.0}
    b := Vec2{x: 0.5, y: 0.25}
    c := add(a, b)
    print(c.x, c.y, c)
    r := Rect{min: a, max: Vec2{4.0, 6.0}, tag: 7}
    print(area(r))
    grow(&r, 1.0)
    print(area(r), r.tag)
    r2 := r
    r2.min.x = 0.0
    print(r.min.x, r2.min.x)
    head: *Node = nil
    for i in 1..=5 {
        head = &Node{val: i * i, next: head}
    }
    print(sum_list(head), head.val, head.next.val)
    z: Rect
    print(z)
    p := &r
    p.tag = 9
    print(r.tag, (*p).tag)
    q := *p
    q.tag = 1
    print(r.tag, q.tag)
    print(sizeof[Rect](), sizeof[Node](), sizeof[Vec2]())
}
