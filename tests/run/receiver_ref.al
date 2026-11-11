// x.f(...) takes &x automatically when f's first parameter is a pointer, for every
// addressable x (variables, fields, elements; scalars as well as aggregates)
Op :: enum { Add, Sub, Jmp }
Shape :: enum { Circle(f64), Square(f64) }
MFunc :: struct { n: i64, regs: Vec[u8] }
Sel :: struct { mf: MFunc, count: i64, ops: [2]Op, pos: vec3, cur: Op, pair: (i64, Op) }
Wrap[T] :: struct { v: T }
IntPtr :: type *i64

is_pure :: (self: *Op) -> bool { *self != Jmp }
next :: (self: *Op) {
    *self = match *self {
        Add => Sub
        Sub => Jmp
        Jmp => Add
    }
}
incr :: (p: *i64) { *p += 1 }
add :: (p: *i64, k: i64) -> i64 {
    *p += k
    return *p
}
bump :: (p: IntPtr) { *p += 100 }
flip :: (v: *vec3) { v.x = -v.x }
halve :: (x: *f64) { *x /= 2.0 }
toggle :: (b: *bool) { *b = !*b }
grow :: (s: *Shape) {
    match *s {
        Circle(r) => { *s = Circle(r * 2.0) }
        Square(a) => { *s = Square(a + 1.0) }
    }
}
new_vreg :: (f: *MFunc, c: u8) -> i64 {
    f.regs.push(c)
    f.n += 1
    return f.n
}
retarget :: (pp: **i64, to: *i64) { *pp = to }
first_op :: (s: *[2]Op) -> Op { s[0] }
set_len :: (xs: *[]i64, n: i64) { *xs = (*xs)[..n] }

// overloads: the receiver's type picks the definition
reset :: (p: *i64) { *p = 0 }
reset :: (p: *f64) { *p = 0.5 }
reset :: (p: *Op) { *p = Add }
reset :: (f: *MFunc) { f.n = 0 }
reset :: (v: *vec3) { *v = vec3(0.0) }
describe :: (x: i64) -> str { "value" }
describe :: (x: f64) -> str { "float" }

// generics
set_to[T] :: (p: *T, x: T) { *p = x }
take[T] :: (p: *T) -> T {
    zero: T
    old := *p
    *p = zero
    return old
}
put_in[T] :: (w: *Wrap[T], x: T) { w.v = x }
twice[T] :: (x: T) -> (T, T) { (x, x) }

// by value: the reverse direction and plain values keep working
double :: (x: i64) -> i64 { x * 2 }
name :: (o: Op) -> str { fmt(o) }
total :: (m: MFunc) -> i64 { m.n + m.regs.len }

counter: i64
g_op: Op
g_sel: Sel

go :: (self: *Sel) -> i64 {
    a := self.mf.new_vreg(0)
    self.count.incr()
    self.ops[1].next()
    self.cur.next()
    self.pos.flip()
    self.pair.0.incr()
    self.pair.1.next()
    return a
}

side :: (p: *i64) -> i64 {
    *p = 1000
    return 1
}

make :: () -> i64 { 41 }

LIMIT :: 7
TABLE :: [2]Op{Sub, Jmp}

main :: () {
    // locals of scalar type
    op := Add
    print(op.is_pure())
    op.next()
    op.next()
    print(op, op.is_pure())
    x := 5
    x.incr()
    x.incr()
    f := 3.0
    f.halve()
    b := false
    b.toggle()
    v := vec3(1.0, 2.0, 3.0)
    v.flip()
    sx: i16 = 7
    sx.set_to(-3)
    sh := Circle(1.5)
    sh.grow()
    print(x, f, b, v, sx, sh, x.add(10), x)

    // fields, also through pointers; elements of arrays, slices, vectors, tuples
    s := Sel{mf: MFunc{n: 0, regs: vec[u8]()}, cur: Sub, pair: (1, Add)}
    print(s.go(), s.go(), s.mf.n, s.count, s.mf.regs.len, s.ops, s.cur, s.pos.x == 0.0, s.pair)
    sp := &s
    sp.count.incr()
    sp.mf.n.incr()
    sp.ops[0].next()
    print(s.count, s.mf.n, s.ops[0], sp.mf.new_vreg(1), s.mf.total(), sp.mf.total())
    arr := [3]i64{1, 2, 3}
    arr[1].incr()
    sl := arr[..]
    sl[2].incr()
    vs := vec[i64]()
    vs.push(10)
    vs.buf[0].incr()
    vs.len.incr()
    vs.len.add(-1)
    t := (1, 2.0, Jmp)
    t.0.incr()
    t.1.halve()
    t.2.next()
    grid := [2][2]i64{[2]i64{1, 2}, [2]i64{3, 4}}
    grid[1][0].incr()
    print(arr, vs.buf[0], vs.len, t, grid, s.ops.first_op())

    // globals, pointers to pointers, a pointer type behind an alias
    counter.incr()
    counter.add(5)
    g_op.next()
    g_sel.count.incr()
    g_sel.mf.new_vreg(3)
    y := 1
    z := 2
    p := &y
    p.retarget(&z)
    *p = 20
    p.incr()          // p is already a pointer: passed as it is
    y.bump()
    p.bump()
    print(counter, g_op, g_sel.count, g_sel.mf.n, y, z)

    // overloaded and generic functions
    x.reset()
    f.reset()
    op.reset()
    s.mf.reset()
    v.reset()
    s.pos.reset()
    print(x, f, op, s.mf.n, v, s.pos, x.describe(), f.describe(), p.describe())
    w := Wrap[str]{v: "a"}
    w.put_in("b")
    w.v.set_to("c")
    x.set_to(9)
    old := x.take()
    s.cur.set_to(Jmp)
    xs := []i64{1, 2, 3, 4}
    xs.set_len(2)
    print(w, old, x, s.cur, xs, x.twice(), op.twice[Op](), f.take[f64](), f)

    // by value: nothing changes, and a pointer is dereferenced when a value is wanted
    q := &x
    x = 21
    print(x.double(), q.double(), op.name(), (&op).name(), x)

    // the receiver's address is taken first, its value is read by the callee
    n := 1
    print(n.add(side(&n)), n)
    m := 1
    print(m.double().double(), m)

    // not addressable: the function works on a temporary copy
    make().incr()
    (x + 1).incr()
    LIMIT.incr()
    TABLE[0].next()
    print(make().add(1), (x + 1).add(1), LIMIT.add(1), LIMIT, TABLE, TABLE[1].is_pure(), TABLE.first_op(), Sub.is_pure(), 5.add(5))
}
