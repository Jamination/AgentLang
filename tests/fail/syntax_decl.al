// declarations that are written wrongly in the new syntax
f1 :: (x: i64) -> () { }
f2 :: (x i64) -> i64 { x }
f3 :: (x: i64) i64 { x }
f4 :: (x: i64, cb: (i64) bool) { }
f5 :: (a *i64) -> i64 { 1 }
f6 :: (a) { }
f7 :: (x: i64) -> i64
K : i64 :
S1 :: struct { a i64 }
S2 :: struct { a: i64, f: (i64) i64 }
inline S3 :: struct { a: i64 }
noinline E1 :: enum { A, B }
inline R1 :: type i64
noinline C1 :: 5
inline C2 : i64 : 5
inline v1: i64
noinline v2 := 1
extern "libc.so.6" v3: i64
extern "libc.so.6" S4 :: struct { a: i64 }
extern "libc.so.6" c_gen[T] :: (x: T) -> T
extern "libc.so.6" c_body :: () -> i32 { 1 }
extern getpid :: () -> i32
inline priv late :: () { }
A1[T] :: type T
C3[T] :: 5
g1[T] : i64
dangling ::
C4 :: (1 + 2) { }
T1 :: (i64) -> bool

main :: () {
    L1 :: 5
    L2 : i64 : 5
    L3 :: struct { a: i64 }
    L4 :: enum { A }
    L5 :: type i64
    n1 :: (x: i64) -> () { }
    n2 :: (x i64) { }
    a1 := (x: i64) -> () { }
    a2 := (x i64) -> i64 { x }
    a3 := (x: i64) i64 { x }
    a4 := (i64, i64) -> bool { true }
    t1: (i64) i64 = nil
    t2: (i64, i64) *u8
    print(1)
}
