// type alias errors: cycles, name clashes, unknown targets, misuse
A :: type B
B :: type *A
C :: type C
D :: type [sizeof[D]()]u8
E :: type Nope
Reg :: type i64
Reg :: struct { x: i64 }
Dup :: type i64
Dup :: type u8
Fun :: () {}
Fun :: type i64
i32 :: type i64
G :: type Reg[i64]
Col :: enum { Red, Green }
Red :: type i64
Text :: type str
Table :: type [4]Reg

takes :: (t: Text) {}

main :: () {
    x: Reg = "s"
    y := Reg
    takes(5)
    t: Table
    t.nope = 1
}

// the same parameter types behind different names
dup :: (r: Reg) {}
dup :: (n: i64) {}
dup :: (t: Text) {}
dup :: (b: []u8) {}
