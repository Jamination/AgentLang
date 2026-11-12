// std.mem: a Ring without capacity keeps nothing; push_overwrite used to index buf[-1]
fn main() {
    r := ring_new[i64](0)
    r.push_overwrite(1)
    ok := r.push(2)
    _, got := r.pop()
    print(r.len, ok, got, r.is_full())
    s := ring_new[i64](1)
    s.push_overwrite(1)
    s.push_overwrite(2)
    print(s.len, s.at(0))
}
