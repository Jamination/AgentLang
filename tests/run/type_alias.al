// type aliases: `Name :: type T` is another name for T, usable before its declaration
fn total(l: List) -> Reg {
    s := 0
    p := l
    while p != nil {
        s += p.v
        p = p.next
    }
    s
}

type Reg = i64
type Callback = fn(*u8, i64) -> i32
type Grid = [8][8]u8
type Names = Vec[str]
type List = *Node
struct Node { v: Reg, next: List, arr: *Arr }
type Arr = [4]Node
type P = Point
struct Point { x: i64, y: i64 }
type Pair = (Reg, str)
type Bytes = []u8
type Chain = Reg2
type Reg2 = Reg
type MaybeReg = Maybe[Reg]
enum Maybe[T] { Just(T), Nothing }
enum Tree { Leaf(Reg), Fork(Kids) }
type Kids = []Tree

// a user alias may reuse a library type name; the library keeps its own type
type Ring = [4]i64

fn cb(p: *u8, n: i64) -> i32 { return i32(n) + 1 }
fn add(a: Reg, b: i64) -> Reg { a + b }
fn first[T](xs: []T, d: Reg) -> T { xs[d] }
fn wrap[T](x: T) -> Maybe[T] { Just(x) }
fn sum(n: Names) -> i64 {
    t := 0
    for s in n.items() {
        t += len(s)
    }
    t
}
fn sum(r: Reg) -> i64 { r * 2 }
fn sum(b: Bytes) -> i64 { len(b) }
fn norm1(p: P) -> Reg { p.x + p.y }
fn bump(p: *P) { p.x += 10 }
fn weight(t: Tree) -> Reg {
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
fn apply(f: Callback, n: i64) -> i32 { f(nil, n) }

counter: Reg
const LIMIT: Reg = 40

fn main() {
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
