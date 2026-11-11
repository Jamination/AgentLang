// Functions named like builtins live next to the builtins: a call uses a declared function
// when one accepts the arguments, and the builtin otherwise. Arguments are evaluated once.
struct P { x i64, y i64 }
struct Types { n i64 }
struct Stack { items Vec[i64] }

var count i64

fn mk() []i64 {
    count += 1
    return []i64{1, 2, 3}
}

fn mkp() P {
    count += 1
    return P{1, 2}
}

fn tick(x i64) i64 {
    count += 1
    x
}

fn bump(p *P) i64 {
    p.x += 10
    p.x
}

fn ptr(self *Types, t i64) i64 { t + self.n }
fn len(t *Types) i64 { t.n }
fn len(s *Stack) i64 { s.items.len * 100 }
fn len(t Types, extra i64) i64 { t.n + extra }
fn clone(t Types) Types { Types{t.n + 1} }
fn clone[T](s *Stack, x T) T { x }
fn hash(a P, b i64) i64 { a.x * 1000 + b }
fn print(p P) { put("P<", p.x, ",", p.y, ">\n") }
fn sqrt(t Types) i64 { t.n * t.n }
fn fmt(t Types) str { "Types!" }
fn rotl(s str, n i64) str { concat(s[n..], s[..n]) }
fn panic(t Types) i64 { -t.n }
fn cast[T](t Types) T { T(t.n) }
fn sizeof[T](t Types) i64 { t.n + sizeof[T]() }

fn main() {
    ty := Types{3}
    st := Stack{vec[i64]()}
    st.items.push(5)

    // ptr
    xs := []i64{10, 20, 30}
    print(ptr(&ty, 4), ty.ptr(4), ptr(xs)[1], ptr("abc")[2], xs.ptr()[2])

    // len: three declared functions and the builtin
    print(len(&ty), ty.len(), len(&st), st.len(), len(ty, 2), ty.len(2), len(xs), xs.len(), len("four"), len(st.items), st.items.len())

    // clone
    p := P{1, 2}
    c1 := clone(ty)                  // declared
    c2 := ty.clone()                 // declared
    c3 := clone(p)                   // builtin
    c4 := p.clone()                  // builtin
    c5 := clone(xs)                  // builtin
    c5[0] = -1
    print(c1.n, c2.n, c3, c4, xs[0], c5[0], clone(&st, 7), st.clone("s"), clone(st).items.len)

    // arguments are evaluated exactly once, whichever is chosen
    count = 0
    n1 := len(mk())                  // builtin
    n2 := len(ty, tick(4))           // declared
    h1 := hash(mkp()) == hash(P{1, 2}) // builtin
    h2 := hash(mkp(), tick(5))       // declared
    c6 := clone(mk())                // builtin
    print(n1, n2, h1, h2, c6, count)
    // an earlier argument keeps its value when a later one changes the variable
    print(hash(p, bump(&p)), p.x)

    // print, put, fmt
    print(p)                         // declared
    print(p, 1)                      // builtin (two arguments)
    print(ty)                        // builtin
    print(fmt(ty), fmt(p), fmt(ty, 1))

    // numeric builtins
    print(sqrt(ty), ty.sqrt(), sqrt(16.0), (2.25).sqrt(), rotl("abcdef", 2), rotl(u8(0x81), 1), "xyz".rotl(1))
    print(popcnt(255), (255).popcnt(), fabs(-1.5), fmin(1.0, 2.0), hash("a") == "a".hash())

    // builtins with type arguments
    print(cast[i32](ty), cast[i64](&ty) != 0, sizeof[u16](ty), sizeof[u16](), panic(ty))

    // the library keeps using the builtins: Map hashes its keys, Vec measures its buffer
    m := map[P, str]()
    m.set(P{1, 2}, "one-two")
    m.set(P{3, 4}, "three-four")
    v := vec[Types]()
    for i in 0..20 {
        v.push(Types{i})
    }
    print(m.get_or(P{3, 4}, "?"), m.len, v.len, v[19].n, split("a b", ' '), join([]str{"x", "y"}, "+"))
}
