// division by zero: a checked division fails in __div_fail, an unchecked one (--unchecked)
// faults in the divide instruction; either way the trace starts at the line of the division
fn ratio(a: i64, b: i64) -> i64 {
    q := a / b
    return q + 1
}

fn average(xs: []i64) -> i64 {
    s := 0
    for x in xs { s += x }
    return ratio(s, len(xs))
}

fn main() {
    print(average([]i64{4, 6}))
    print(average(alloc[i64](len(args()) - 3)))
}
