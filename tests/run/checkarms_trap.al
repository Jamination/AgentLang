// the check merged ahead of a branch (checkmerge_arms) fails on the arm that was not taken
// before as on the one that was (both arms on one line: one location)
noinline fn put_min(t: []i64, ks: []i64, x: i64, y: i64) {
    for m in 0..len(ks) {
        k := ks[m]
        if x + m < y { t[k] = x + m } else { t[k] = y }
    }
}

fn main() {
    t := alloc[i64](4)
    put_min(t, []i64{0, 3, 1}, 3, 4)
    print(t)
    put_min(t, []i64{2, 4}, 1, 9)
    print("not reached")
}
