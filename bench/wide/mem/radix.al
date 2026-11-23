// LSD radix sort of u32 keys, 8 bits per pass: counting pass, prefix sum, scatter
fn radix_sort(a: []u32, tmp: []u32) {
    count: [256]i64
    src := a
    dst := tmp
    for shift in 0..4 {
        sh := u32(shift * 8)
        fill(count[..], 0)
        for x in src {
            count[i64((x >> sh) & 255)] += 1
        }
        s := 0
        for d in 0..256 {
            c := count[d]
            count[d] = s
            s += c
        }
        for x in src {
            b := i64((x >> sh) & 255)
            dst[count[b]] = x
            count[b] += 1
        }
        t := src
        src = dst
        dst = t
    }
}

fn main() {
    n := 5000000
    a := alloc[u32](n)
    tmp := alloc[u32](n)
    seed: u64 = 9
    check: u64 = 0
    for r in 0..6 {
        for i in 0..n {
            seed = seed * 6364136223846793005 + 1442695040888963407
            a[i] = u32(seed >> 32)
        }
        radix_sort(a, tmp)
        for i in 0..n by 1000 {
            check = check * 31 + u64(a[i])
        }
    }
    put(check, "\n")
}
