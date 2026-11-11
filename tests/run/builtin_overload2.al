// Untyped literals and constants in calls of names shared by a builtin and declared functions,
// and a library whose functions are named like builtins of the program.
const NAME = "name"
const YES = true
const N = 3
const F = 1.5
enum Opt[T] { Some(T), None }
enum Dir { Left, Right }

fn print(s str) { put("<", s, ">\n") }
fn len(n i64) i64 { n * 2 }
fn len(b bool) i64 { 1 }
fn hash(x f64) i64 { 7 }
fn hash(d Dir) i64 { 8 }
fn clone(o Opt[i64]) i64 {
    match o {
        Some(v) => v
        None => -1
    }
}
fn clone(p *i64) i64 { 0 }
fn fmt[T](x T, y T) T { y }
fn ptr(k i64) i64 { k + 1 }
fn put(d Dir) { put("dir ") }

fn show[T](x T) str {
    // generic code: the choice is made per instantiation
    return fmt(len(x), "/", hash(x) == 7)
}

fn main() {
    print(NAME)                      // declared: a text constant
    print(N)                         // builtin
    print("lit")
    print(1.5, YES)
    print(len(N), len(YES), len(NAME), len(5), len("abc"), len(1 + 1))
    print(hash(F), hash(2.5), hash(N), hash(Left), hash(NAME) == hash("name"))
    var o Opt[i64] = Some(4)
    print(clone(None), clone(o), clone(Some(5)), clone(nil), clone(Right), clone(NAME))
    print(fmt(NAME, "b"), fmt(1, 2), fmt(1, "x"), fmt(1, 2.5), fmt(Left, Right))
    print(ptr(1), ptr(N), ptr(NAME)[0], ptr([]u8{65, 66})[1])
    put(Left)
    put(Right, "\n")
    print(show(4), show(true), show("abcd"), show([]i64{1}))
}
