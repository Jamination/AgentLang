// Block layout keeps a loop's own code after a branch whose "then" side leaves the loop (the
// loop is left by a taken branch, not continued by one). Loops left from the "then" side of a
// branch at every depth: returns, breaks of one and of two loops, continues, a probe loop with
// two ways out. The order of the blocks must not change what they compute.
noinline fn h(x: i64) -> i64 {
    return x
}

noinline fn find(t: []i64, key: i64) -> i64 {
    mask := len(t) - 1
    i := key & mask
    loop {
        if t[i] == key {
            return i
        }
        if t[i] == 0 {
            return -1
        }
        i = (i + 1) & mask
    }
}

noinline fn first_pair(v: []i64, sum: i64) -> (i64, i64) {
    a := -1
    b := -1
    outer: for i in 0..len(v) {
        for j in i + 1..len(v) {
            if v[i] + v[j] == sum {
                a = i
                b = j
                break outer
            }
            if v[i] + v[j] > sum * 4 {
                continue outer
            }
        }
    }
    return (a, b)
}

noinline fn count_until(v: []i64, stop: i64) -> i64 {
    n := 0
    i := 0
    while i < len(v) {
        if v[i] == stop {
            break
        }
        if v[i] % 3 == 0 {
            i += 1
            continue
        }
        n += v[i]
        i += 1
    }
    return n
}

fn main() {
    t := []i64{0, 9, 2, 0, 12, 0, 6, 7}
    print(find(t[..], h(2)), find(t[..], h(12)), find(t[..], h(7)), find(t[..], h(5)), find(t[..], h(9)))
    v := []i64{4, 8, 1, 30, 5, 7, 2}
    print(first_pair(v[..], h(9)), first_pair(v[..], h(100)), first_pair(v[..], h(3)))
    print(count_until(v[..], h(5)), count_until(v[..], h(99)), count_until(v[..], h(4)))
}
