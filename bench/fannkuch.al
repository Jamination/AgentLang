fannkuch :: (n: i32) -> i32 {
    perm: [16]i32
    perm1: [16]i32
    count: [16]i32
    maxflips: i32 = 0
    checksum: i32 = 0
    permcount: i32 = 0
    r := n
    for i in 0..n {
        perm1[i] = i
    }
    loop {
        while r != 1 {
            count[r - 1] = r
            r -= 1
        }
        for i in 0..n {
            perm[i] = perm1[i]
        }
        flips: i32 = 0
        loop {
            k := perm[0]
            if k == 0 {
                break
            }
            k2 := (k + 1) >> 1
            for i in 0..k2 {
                t := perm[i]
                perm[i] = perm[k - i]
                perm[k - i] = t
            }
            flips += 1
        }
        if flips > maxflips {
            maxflips = flips
        }
        checksum += if permcount % 2 == 0 { flips } else { -flips }
        loop {
            if r == n {
                put(checksum, "\nPfannkuchen(", n, ") = ", maxflips, "\n")
                return maxflips
            }
            p0 := perm1[0]
            for i in 0..r {
                perm1[i] = perm1[i + 1]
            }
            perm1[r] = p0
            count[r] -= 1
            if count[r] > 0 {
                break
            }
            r += 1
        }
        permcount += 1
    }
}

main :: () {
    fannkuch(10)
}
