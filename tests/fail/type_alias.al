// type alias errors: cycles, name clashes, unknown targets, misuse
type A = B
type B = *A
type C = C
type D = [sizeof[D]()]u8
type E = Nope
type Reg = i64
struct Reg { x: i64 }
type Dup = i64
type Dup = u8
fn Fun() {}
type Fun = i64
type i32 = i64
type G = Reg[i64]
enum Col { Red, Green }
type Red = i64
type Text = str
type Table = [4]Reg

fn takes(t: Text) {}

fn main() {
    x: Reg = "s"
    y := Reg
    takes(5)
    t: Table
    t.nope = 1
}

// the same parameter types behind different names
fn dup(r: Reg) {}
fn dup(n: i64) {}
fn dup(t: Text) {}
fn dup(b: []u8) {}
