// type aliases: `type Name = T` is another name for T, usable before its declaration
total :: (l: List) -> Reg {
    s := 0
    p := l
    while p != nil {
        s += p.v
        p = p.next
    }
    s
}

Reg :: type i64
Callback :: type (*u8, i64) -> i32
Grid :: type [8][8]u8
Names :: type Vec[str]
List :: type *Node
Node :: struct { v: Reg, next: List, arr: *Arr }
Arr :: type [4]Node
P :: type Point
Point :: struct { x: i64, y: i64 }
Pair :: type (Reg, str)
Bytes :: type []u8
Chain :: type Reg2
Reg2 :: type Reg
MaybeReg :: type Maybe[Reg]
Maybe[T] :: enum { Just(T), Nothing }
Tree :: enum { Leaf(Reg), Fork(Kids) }
Kids :: type []Tree

// a user alias may reuse a library type name; the library keeps its own type
Ring :: type [4]i64

cb :: (p: *u8, n: i64) -> i32 { return i32(n) + 1 }
add :: (a: Reg, b: i64) -> Reg { a + b }
first[T] :: (xs: []T, d: Reg) -> T { xs[d] }
wrap[T] :: (x: T) -> Maybe[T] { Just(x) }
sum :: (n: Names) -> i64 {
    t := 0
    for s in n.items() {
        t += len(s)
    }
    t
}
sum :: (r: Reg) -> i64 { r * 2 }
sum :: (b: Bytes) -> i64 { len(b) }
norm1 :: (p: P) -> Reg { p.x + p.y }
bump :: (p: *P) { p.x += 10 }
weight :: (t: Tree) -> Reg {
    match t {
        Leaf(n) => n
        Fork(kids) => {
            s := 0
            for k in kids {
                s += weight(k)
            }
            s
        }
    }
}
apply :: (f: Callback, n: i64) -> i32 { f(nil, n) }

counter: Reg
LIMIT : Reg : 40

main :: () {
    r: Reg = 5
    c: Callback = cb
    g: Grid
    g[1][2] = 7
    n := Names{}
    n.push("ab")
    n.push("cde")
    names: Names = vec[str]()
    names.push("x")
    l := &Node{v: 1, next: &Node{v: 2, next: nil}}
    p := P{x: 1, y: 2}
    q: Point = p
    pr: Pair = (3, "three")
    print(add(r, 2), c(nil, 4), g[1][2], n.len, names.len, total(l), q, pr)
    print(Reg(3.7), sizeof[Grid](), sizeof[Arr](), sizeof[Node](), first([]str{"a", "b"}, 1))
    // overloads are chosen by the underlying type
    print(n.sum(), r.sum(), sum("hello"), sum(7))
    // UFCS, also through a pointer
    p.bump()
    print(p.norm1(), (&p).norm1())
    // generics see the underlying type
    xs := vec[Reg]()
    xs.push(r)
    ys: Vec[i64] = xs
    m: MaybeReg = wrap(r)
    ch: Chain = r + 1
    print(ys.items(), len(alloc[Reg](3)), m, ch)
    t := Fork([]Tree{Leaf(1), Fork([]Tree{Leaf(2), Leaf(3)})})
    print(weight(t), apply(cb, 9))
    counter += LIMIT
    ring: Ring
    ring[3] = counter
    lib_ring := ring_new[i64](2)
    lib_ring.push(3)
    print(ring, sizeof[Ring](), lib_ring.len)
    // conversions and literals through an alias
    print(Reg(250) + 6, Pair{4, "four"}, Grid{}[0][0])
}
