// `t.0.1` is (t.0).1: after `.` a number is a field, not a float literal
fn main() {
    t := ((1, (2, 3)), 4.5)
    t.0.1.0 = 20
    print(t.0.1, t.0.1.1, t.1, t.0 .0)   // (20, 3) 3 4.5 1
    x := 1.5
    s := []i64{5, 6, 7}
    print(x, 2.25e1, s[0..2], s[1..])   // 1.5 22.5 [5, 6] [6, 7]
}
