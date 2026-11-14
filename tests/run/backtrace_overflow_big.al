// the same with frames of more than a page (Windows probes the stack page by page there).
// (not --unchecked: that build ends silently under Wine, as it did before stack traces)
fn descend(n: i64) -> i64 {
    buf: [700]i64
    buf[n % 700] = n
    return descend(n + 1) + buf[(n * 7) % 700]
}

fn main() {
    print("down")
    print(descend(0))
}
