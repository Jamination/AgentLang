// Names shared between variants, builtins, and declarations of the program and the library.
// declarations of the program hide the bare names of the library's variants
Some :: (x: i64) -> i64 { x * 2 }
None :: 7
Ok :: struct { v: i64 }
// variants with the names of builtin functions and types
Ty :: enum { i64, f64, str, bool, len, print, hash(i64), vec3 }
Color :: enum { Red, Green }
W :: enum { A(i64), B(Color) }

name :: (t: Ty) -> str {
    match t {
        i64 => "i64"
        f64 => "f64"
        str => "str"
        bool => "bool"
        len => "len"
        print => "print"
        hash(n) => fmt("hash ", n)
        vec3 => "vec3"
    }
}

main :: () {
    print(Some(4), None, Ok{v: 1})
    o: Opt[i64] = Opt.Some(3)
    print(o, Opt[i64].None, Res[i64].Ok(5), Res[i64].Err("e").error())
    // in a pattern the matched type decides, whatever else has the name
    match o {
        Some(x) => print("some", x)
        None => print("none")
    }
    // a name that is not a variant of the matched part is a binding
    w := A(3)
    match w {
        A(Red) => print("binding:", Red)
        B(Red) => print("red")
        B(_) => print("other")
    }
    match B(Red) {
        A(Red) => print("binding:", Red)
        B(Red) => print("red")
        B(_) => print("other")
    }
    // builtins stay callable; without a call the names are the variants
    xs := []i64{1, 2, 3}
    t := i64
    u: Ty = print
    h := Ty.hash(4)
    print(len(xs), i64(2.5), hash(7) != 0, name(t), name(u), name(len), name(h), name(f64), vec3(1.0, 2.0, 3.0))
    print(t, u, h, Ty.vec3, Ty.str)
}
