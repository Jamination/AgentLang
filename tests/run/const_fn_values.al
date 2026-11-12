// function values in constants and globals: a constant that is a function name (also typed,
// of an overloaded name, or naming another constant), called directly; tuple elements called
// like struct fields
struct Ops { k: i64, f: fn(i64) -> i64 }
fn double(x: i64) -> i64 { x * 2 }
fn inc(x: i64) -> i64 { x + 1 }
fn inc(x: str) -> str { fmt(x, "+") }
fn chain(x: i64) -> i64 { hidden(x) + 100 }
fn hidden(x: i64) -> i64 { x * 10 }
const D = double
const D2 = D
const INC: fn(i64) -> i64 = inc
const INC_S: fn(str) -> str = inc
const CHAIN = chain
const TAB = [3]fn(i64) -> i64{D, D2, CHAIN}
const OPS = Ops{k: 1, f: D2}
const PAIR = (5, CHAIN)
g := D
pair: (i64, fn(i64) -> i64) = (7, INC)

fn main() {
    f := D
    h: fn(i64) -> i64 = D2
    print(D(1), D2(2), f(3), h(4), INC(5), INC_S("s"), CHAIN(1), g(6))
    print(TAB[2](2), OPS.f(5), PAIR.1(3), (PAIR.1)(4), pair.1(pair.0))
    t := (1, D)
    print(t.1(21))
    g = CHAIN
    pair.1 = D
    print(g(0), pair.1(8))
}
