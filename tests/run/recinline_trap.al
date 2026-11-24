// a failed check inside the copy of a recursive function inlined into itself
// (inline_recursive) reports its own line and the frames of the recursion
fn sum(t: []i64, i: i64) -> i64 {
    if i == 0 { return 0 }
    return t[i] + sum(t, i - 1)
}

fn main() {
    t := []i64{1, 2, 3, 4}
    print(sum(t, 3))
    print(sum(t, 5))
}
