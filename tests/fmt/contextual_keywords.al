// `in`, `by`, `test`: laid out as keywords where they are keywords, as names elsewhere
fn by(n: i64) -> i64 { n }
test := 1
fn main() {
    by := 2
    in := []i64{1,2}
    for i in 9..=0   by   -1 {
        print(i)
    }
    for i in(in) {
        print(by -1, by (3), - by, in [0])
    }
    for i in 0..10 by(by) {
    }
}
test   "t" {
    assert test==1
}
