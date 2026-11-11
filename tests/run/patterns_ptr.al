// Variant and tuple patterns look through pointers; nil matches no such pattern.
enum Tree { Leaf(i64), Node(*Tree, *Tree), Empty }
enum List { Cons(i64, *List), End }
fn sum(t *Tree) i64 {
    match t {
        nil => 0
        Leaf(n) => n
        Node(l, r) => sum(l) + sum(r)
        Empty => 0
    }
}
fn shape(t *Tree) str {
    match t {
        Node(Leaf(a), Leaf(b)) => fmt("two leaves ", a, " ", b)
        Node(Leaf(a), &rest) => fmt("leaf ", a, " and more: ", *rest != nil)
        Node(nil, _), Node(_, nil) => "half"
        Node(Empty, Tree.Empty) => "empty pair"
        Node(_, _) => "node"
        Leaf(_) => "leaf"
        Empty => "empty"
        nil => "nil"
    }
}
fn bump(t *Tree) {
    match t {
        Leaf(&n) => { *n += 100 }
        Node(l, r) => {
            bump(l)
            bump(r)
        }
        _ => {}
    }
}
fn second(l *List) Opt[i64] {
    match l {
        Cons(_, Cons(x, _)) => Some(x)
        _ => None
    }
}
fn len2(l *List) i64 {
    n := 0
    cur := l
    loop {
        match cur {
            Cons(_, next) => {
                n += 1
                cur = next
            }
            End => break
            nil => break
        }
    }
    n
}
fn pp(p **Tree) str {
    match p {
        Leaf(n) => fmt("pp leaf ", n)
        _ => "pp other"
    }
}
fn tup(p *(i64, Opt[i64])) i64 {
    match p {
        (a, Some(b)) => a + b
        (a, None) => a
        nil => -1
    }
}
fn main() {
    a := Leaf(1)
    b := Leaf(2)
    e := Tree.Empty
    e2 := Tree.Empty
    n := Node(&a, &b)
    m := Node(&a, &n)
    h := Node(nil, &a)
    ee := Node(&e, &e2)
    en := Node(&e, &n)
    var z *Tree
    print(sum(&m), sum(nil), sum(&e))
    print(shape(&n), shape(&m), shape(&h), shape(&ee), shape(&en), shape(&a), shape(&e), shape(z))
    bump(&m)
    print(a, b, sum(&m))
    end := End
    c3 := Cons(3, &end)
    c2 := Cons(2, &c3)
    c1 := Cons(1, &c2)
    print(second(&c1), second(&c3), second(nil), len2(&c1), len2(nil))
    pa := &a
    print(pp(&pa), pp(nil))
    t := (5, Opt[i64].Some(6))
    t2 := (7, Opt[i64].None)
    print(tup(&t), tup(&t2), tup(nil))
}
