// endless recursion overflows the stack: the trace shows the first 20 and the last 5 frames
fn descend(n: i64, path: *[4]i64) -> i64 {
    path[n % 4] = n
    return descend(n + 1, path) + path[0]
}

fn main() {
    p: [4]i64
    print("down")
    print(descend(0, &p))
}
