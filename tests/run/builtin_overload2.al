// Untyped literals and constants in calls of names shared by a builtin and declared functions,
// and a library whose functions are named like builtins of the program.
NAME :: "name"
YES :: true
N :: 3
F :: 1.5
Opt[T] :: enum { Some(T), None }
Dir :: enum { Left, Right }

print :: (s: str) { put("<", s, ">\n") }
len :: (n: i64) -> i64 { n * 2 }
len :: (b: bool) -> i64 { 1 }
hash :: (x: f64) -> i64 { 7 }
hash :: (d: Dir) -> i64 { 8 }
clone :: (o: Opt[i64]) -> i64 {
    match o {
        Some(v) => v
        None => -1
    }
}
clone :: (p: *i64) -> i64 { 0 }
fmt[T] :: (x: T, y: T) -> T { y }
ptr :: (k: i64) -> i64 { k + 1 }
put :: (d: Dir) { put("dir ") }

show[T] :: (x: T) -> str {
    // generic code: the choice is made per instantiation
    return fmt(len(x), "/", hash(x) == 7)
}

main :: () {
    print(NAME)                      // declared: a text constant
    print(N)                         // builtin
    print("lit")
    print(1.5, YES)
    print(len(N), len(YES), len(NAME), len(5), len("abc"), len(1 + 1))
    print(hash(F), hash(2.5), hash(N), hash(Left), hash(NAME) == hash("name"))
    o: Opt[i64] = Some(4)
    print(clone(None), clone(o), clone(Some(5)), clone(nil), clone(Right), clone(NAME))
    print(fmt(NAME, "b"), fmt(1, 2), fmt(1, "x"), fmt(1, 2.5), fmt(Left, Right))
    print(ptr(1), ptr(N), ptr(NAME)[0], ptr([]u8{65, 66})[1])
    put(Left)
    put(Right, "\n")
    print(show(4), show(true), show("abcd"), show([]i64{1}))
}
