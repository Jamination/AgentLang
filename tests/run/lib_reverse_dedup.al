// reverse (a slice, in place) and dedup (adjacent equal elements of a Vec)
fn main() {
    xs := []i64{1, 2, 3, 4, 5}
    reverse(xs)
    one := []str{"only"}
    one.reverse()
    none: []f64
    reverse(none)
    word := clone("stressed")
    word.reverse()
    print(xs, one, none, word)
    reverse(xs[1..4])
    print(xs)
    v := vec_of([]i64{1, 1, 2, 2, 2, 3, 1, 1})
    v.dedup()
    names := vec_of([]str{"b", "a", "b", "a", "a"})
    sort(names[..])
    names.dedup()
    empty := vec[i64]()
    empty.dedup()
    single := vec_of([]i64{7})
    single.dedup()
    print(v[..], names[..], empty.len, single[..])
}
