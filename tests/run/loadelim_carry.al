// Loads whose address is a linear form (src/opt/alias.al) and loads that take the value of the
// previous iteration (loadelim's carry_run): only when nothing may have written the location
// in between, also when the same memory is reached through another slice, a pointer, a Vec
// that grows or a by-reference parameter
struct Grid {
    d: []i64
    w: i64
}

// the value stored at d[i * w + j - 1] in the previous iteration
noinline fn prefix_rows(g: *Grid, rows: i64) -> i64 {
    w := g.w
    for i in 0..rows {
        for j in 1..w {
            g.d[i * w + j] += g.d[i * w + j - 1]
        }
    }
    return g.d[rows * w - 1]
}

// the same over a whole slice (no checks left in the loop), and with a second slice written
// after the store that may be the same memory one element on
noinline fn prefix_flat(d: []i64) -> i64 {
    for j in 1..len(d) {
        d[j] += d[j - 1]
    }
    return d[len(d) - 1]
}

noinline fn prefix_flat2(d: []i64, e: []i64) -> i64 {
    n := min(len(d), len(e))
    for j in 1..n {
        d[j] += d[j - 1]
        e[j - 1] = 2 * j // when e is d[1..] this writes d[j]
    }
    return d[n - 1]
}

// the same, but another slice of the same memory is written between: no carried value
noinline fn prefix_alias(d: []i64, e: []i64, n: i64) -> i64 {
    s := 0
    for j in 1..n {
        d[j] = d[j - 1] + 1
        e[j] = 100 + j // e may be d shifted by one
        s += d[j]
    }
    return s
}

// written through a pointer the loop does not know
noinline fn prefix_ptr(d: []i64, p: *i64, n: i64) -> i64 {
    s := 0
    for j in 1..n {
        d[j] = d[j - 1] * 2 + 1
        *p += 3
        s += d[j]
    }
    return s
}

// a store before the load in the header writes the location
noinline fn prefix_overwrite(d: []i64, n: i64) -> i64 {
    s := 0
    for j in 1..n {
        d[j - 1] = j * 7
        d[j] = d[j - 1] + 1
        s += d[j]
    }
    return s
}

// a Vec that grows inside the loop: its buffer moves, so does the location
noinline fn prefix_vec(n: i64) -> i64 {
    v := vec[i64]()
    v.push(1)
    for j in 1..n {
        v.push(v[j - 1] + j)
    }
    s := 0
    for x in v {
        s += x
    }
    return s
}

fn bump(p: *i64) {
    *p += 1000
}

// a by-reference store (inlined) into the location
noinline fn prefix_byref(d: []i64, n: i64) -> i64 {
    for j in 1..n {
        d[j] = d[j - 1] + 1
        if j % 3 == 0 {
            bump(&d[j])
        }
    }
    return d[n - 1]
}

// stepping by two and backwards; i32 elements
noinline fn steps(d: []i32, n: i64) -> i64 {
    for j in 2..n by 2 {
        d[j] = d[j - 2] + 3
    }
    for j in n - 2..=0 by -1 {
        d[j] = d[j + 1] - d[j]
    }
    t := 0
    for x in d {
        t += i64(x)
    }
    return t
}

// neighbours that differ by a constant: d[i + 1] does not alias d[i], d[i + 2] the same
// location computed another way
noinline fn neighbours(d: []i64, k: i64) -> i64 {
    a := d[k + 1]
    d[k] = 5
    b := d[k + 1]
    d[(k + 2) - 1] = 9
    c := d[k + 1]
    return a * 100 + b * 10 + c
}

fn main() {
    g := Grid{d: alloc[i64](30), w: 6}
    for i in 0..30 {
        g.d[i] = i % 4
    }
    put(prefix_rows(&g, 5), "\n")
    put(prefix_flat(g.d), "\n")
    put(prefix_flat2(g.d, alloc[i64](30)), " ", prefix_flat2(g.d, g.d[1..]), "\n")
    d := alloc[i64](12)
    put(prefix_alias(d, d[1..], 11), " ", d[5], "\n")
    e := alloc[i64](12)
    put(prefix_alias(e, alloc[i64](12), 11), "\n")
    f := alloc[i64](8)
    put(prefix_ptr(f, &f[3], 8), " ", f[3], "\n")
    put(prefix_overwrite(alloc[i64](9), 9), "\n")
    put(prefix_vec(50), "\n")
    put(prefix_byref(alloc[i64](10), 10), "\n")
    x := alloc[i32](11)
    for i in 0..11 {
        x[i] = i32(i * i)
    }
    put(steps(x, 11), "\n")
    y := alloc[i64](5)
    y[1] = 4
    put(neighbours(y, 0), "\n")
}
