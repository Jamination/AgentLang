// Fill and copy loops (src/opt/idiom.al turns them into MemSet / MemCpy when long enough and,
// for copies, when the ranges do not overlap): the results must be those of the loops, for
// every length around the threshold, element sizes, offsets, empty and reversed ranges,
// overlapping copies in both directions, and loops that must stay loops.

// a checksum of a byte buffer (position-dependent)
fn sum8(a: []u8) -> u64 {
    h: u64 = 1469598103934665603
    for i in 0..len(a) {
        h = (h ^ u64(a[i])) * 1099511628211
    }
    h
}

fn bytes_of[T](a: []T) -> []u8 {
    return cast[[]u8](a)
}

noinline fn fill8(a: []u8, lo: i64, hi: i64, v: u8) {
    for i in lo..hi {
        a[i] = v
    }
}

noinline fn fill16(a: []u16, lo: i64, hi: i64, v: u16) {
    for i in lo..hi {
        a[i] = v
    }
}

noinline fn zero32(a: []u32, lo: i32, hi: i32) {
    for i in lo..hi {
        a[i] = 0
    }
}

noinline fn zero_around(a: []u32, lo: i64, hi: i64) {
    for i in lo..hi {
        a[i + 100] = 0
    }
}

noinline fn ones64(a: []i64, n: i64) {
    for i in 0..n {
        a[i] = -1
    }
}

noinline fn fill64_pattern(a: []u64, n: i64) {
    // the same in every byte
    for i in 0..n {
        a[i] = 0x2525252525252525
    }
}

noinline fn fill32_nonuniform(a: []u32, n: i64) {
    // not the same in every byte: stays a loop
    for i in 0..n {
        a[i] = 0x01020304
    }
}

noinline fn fillf64(a: []f64, n: i64, neg: bool) {
    if neg {
        // -0.0 is not all zero bytes
        for i in 0..n {
            a[i] = -0.0
        }
    } else {
        for i in 0..n {
            a[i] = 0.0
        }
    }
}

noinline fn fill_u32_counter(a: []u8, lo: u32, hi: u32, v: u8) {
    for i in lo..hi {
        a[i] = v
    }
}

noinline fn copy8(dst: []u8, src: []u8, n: i64) {
    for i in 0..n {
        dst[i] = src[i]
    }
}

noinline fn copy32(dst: []u32, src: []u32, lo: i64, hi: i64) {
    for i in lo..hi {
        dst[i] = src[i]
    }
}

noinline fn copyf64(dst: []f64, src: []f64, n: i32) {
    for i in 0..n {
        dst[i] = src[i]
    }
}

// must stay loops: two stores, a stored value that changes, a value used after the loop
noinline fn two_stores(a: []u8, b: []u8, n: i64) {
    for i in 0..n {
        a[i] = 1
        b[i] = 2
    }
}

noinline fn iota(a: []u8, n: i64) {
    for i in 0..n {
        a[i] = u8(i)
    }
}

noinline fn fill_last(a: []u8, n: i64) -> i64 {
    i := 0
    while i < n {
        a[i] = 9
        i += 1
    }
    return i
}

fn main() {
    lens := []i64{0, 1, 2, 3, 4, 5, 7, 8, 9, 31, 63, 64, 127, 128, 129, 255, 256, 1000, 4099}
    buf := alloc[u8](5000)
    for n in lens {
        for i in 0..len(buf) {
            buf[i] = u8(i * 7)
        }
        fill8(buf, 3, 3 + n, u8(n + 1))
        print("fill8", n, sum8(buf))
    }
    // empty and reversed ranges
    fill8(buf, 10, 10, 1)
    fill8(buf, 200, 10, 2)
    print("fill8 empty", sum8(buf))
    w := alloc[u16](3000)
    for n in lens {
        if n < 2990 {
            fill16(w, 5, 5 + n, u16(0x7777))
            print("fill16 uniform", n, sum8(bytes_of(w)))
            fill16(w, 2, 2 + n, u16(0x1234))
            print("fill16", n, sum8(bytes_of(w)))
        }
    }
    d := alloc[u32](2000)
    for i in 0..len(d) {
        d[i] = u32(i)
    }
    for n in []i32{0, 1, 5, 31, 32, 33, 100, 1500} {
        zero32(d, 7, 7 + n)
        print("zero32", n, sum8(bytes_of(d)))
        for i in 0..len(d) {
            d[i] = u32(i)
        }
    }
    // a reversed range; a negative start: the counter goes through zero
    zero32(d, 0, -5)
    print("zero32 reversed", sum8(bytes_of(d)))
    zero_around(d, -50, 50)
    print("zero around", sum8(bytes_of(d)))
    zero_around(d, -1, 0)
    print("zero around 1", sum8(bytes_of(d)))
    q := alloc[i64](600)
    for n in []i64{0, 1, 15, 16, 17, 600} {
        ones64(q, n)
        print("ones64", n, sum8(bytes_of(q)))
    }
    p := alloc[u64](600)
    fill64_pattern(p, 599)
    print("pattern", sum8(bytes_of(p)))
    fill32_nonuniform(d, 1999)
    print("nonuniform", sum8(bytes_of(d)))
    fl := alloc[f64](300)
    for i in 0..len(fl) {
        fl[i] = 1.5
    }
    fillf64(fl, 250, true)
    print("-0.0", sum8(bytes_of(fl)), fl[0], fl[249], fl[250])
    fillf64(fl, 299, false)
    print("0.0", sum8(bytes_of(fl)), fl[0], fl[299])
    fill_u32_counter(buf, u32(4000), u32(4500), 0xAB)
    fill_u32_counter(buf, u32(4500), u32(4000), 0xCD)
    print("u32 counter", sum8(buf))

    // copies
    src := alloc[u8](5000)
    for i in 0..len(src) {
        src[i] = u8(i * 13 + 1)
    }
    for n in lens {
        for i in 0..len(buf) {
            buf[i] = 0
        }
        copy8(buf[7..], src[3..], n)
        print("copy8", n, sum8(buf))
    }
    // overlapping: the destination after the source (the loop repeats the first bytes)
    for n in []i64{3, 100, 127, 128, 129, 1000} {
        for i in 0..len(buf) {
            buf[i] = u8(i * 13 + 1)
        }
        copy8(buf[1..], buf, n)
        print("copy8 forward overlap", n, sum8(buf))
        for i in 0..len(buf) {
            buf[i] = u8(i * 13 + 1)
        }
        copy8(buf[40..], buf, n)
        print("copy8 overlap 40", n, sum8(buf))
        for i in 0..len(buf) {
            buf[i] = u8(i * 13 + 1)
        }
        // the destination before the source (a shift down)
        copy8(buf, buf[1..], n)
        print("copy8 backward overlap", n, sum8(buf))
        // onto itself
        copy8(buf, buf, n)
        print("copy8 same", n, sum8(buf))
    }
    s32 := alloc[u32](1200)
    t32 := alloc[u32](1200)
    for i in 0..len(s32) {
        s32[i] = u32(i * 2654435761)
    }
    for n in []i64{0, 1, 2, 3, 31, 32, 33, 1000} {
        copy32(t32, s32, 100, 100 + n)
        print("copy32", n, sum8(bytes_of(t32)))
    }
    // overlapping u32 copies, also by a part of an element
    for n in []i64{10, 40, 1000} {
        for i in 0..len(s32) {
            s32[i] = u32(i * 2654435761)
        }
        copy32(s32[1..], s32, 0, n)
        print("copy32 overlap 1", n, sum8(bytes_of(s32)))
        bs := bytes_of(s32)
        for i in 0..len(s32) {
            s32[i] = u32(i * 2654435761)
        }
        copy32(cast[[]u32](bs[2..4002]), s32, 0, n)
        print("copy32 overlap half", n, sum8(bytes_of(s32)))
        for i in 0..len(s32) {
            s32[i] = u32(i * 2654435761)
        }
        copy32(cast[[]u32](bs[0..4000]), cast[[]u32](bs[6..4006]), 0, n)
        print("copy32 overlap down", n, sum8(bytes_of(s32)))
    }
    sf := alloc[f64](500)
    tf := alloc[f64](500)
    for i in 0..len(sf) {
        sf[i] = f64(i) * 0.25 - 3.0
    }
    copyf64(tf, sf, 499)
    print("copyf64", sum8(bytes_of(tf)), tf[0], tf[498], tf[499])
    copyf64(tf, sf, -3)
    print("copyf64 empty", sum8(bytes_of(tf)))

    // loops that stay loops
    a := alloc[u8](1000)
    b := alloc[u8](1000)
    two_stores(a, b, 1000)
    two_stores(a, a[1..], 999)
    print("two stores", sum8(a), sum8(b))
    iota(a, 1000)
    print("iota", sum8(a))
    print("fill last", fill_last(a, 700), sum8(a))
}
