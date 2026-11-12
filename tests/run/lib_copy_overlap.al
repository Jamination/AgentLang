// copy between overlapping parts of one slice works in both directions (like Go's copy)
struct P { a: i32, b: u8 }

fn main() {
    a := []i64{1, 2, 3, 4, 5, 6, 7, 8}
    print(copy(a[2..], a[..]), a)                     // shift right
    b := []i64{1, 2, 3, 4, 5, 6, 7, 8}
    print(copy(b[..], b[3..]), b)                     // shift left
    s := alloc[u8](10)
    for i in 0..10 { s[i] = 'a' + u8(i) }
    copy(s[1..], s[..])
    print(s)
    p := []P{P{1, 1}, P{2, 2}, P{3, 3}}
    copy(p[1..], p)
    print(p)
}
