// an inclusive bound runs one past the end: the index check must still fail
fn show(x i64) {
    print(x)
}

fn main() {
    s := []i64{1, 2, 3}
    for i in 0..=len(s) {
        show(s[i])
    }
    print("not reached")
}
