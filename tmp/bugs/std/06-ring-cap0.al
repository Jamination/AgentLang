// push_overwrite on a Ring of capacity 0 indexed buf[-1]: "panic: index out of bounds at std/mem.al"
// expected: 0   actual (before the fix): panic
fn main() {
    r := ring_new[i64](0)
    r.push_overwrite(1)
    print(r.len)
}
