// sums of bytes divided by a constant and stored as a byte: the vectorizer computes them in
// 16-bit lanes (vec_narrow in src/opt/vec.al); every length (vector loop and remainder) and
// several divisors against a plain function. Then two functions that tail-call each other
// (one loop with two back edges, src/opt/simplify.al step 3b).

noinline fn ref3(a: u8, b: u8, c: u8, d: u32) -> u8 {
    s := u32(a) + u32(b) + u32(c)
    return u8(s / d)
}

fn blur3(src: []u8, dst: []u8, n: i64) {
    for x in 1..n {
        s := u32(src[x - 1]) + u32(src[x]) + u32(src[x + 1])
        dst[x] = u8(s / 3)
    }
}

fn blur7(src: []u8, dst: []u8, n: i64) {
    for x in 1..n {
        s := u32(src[x - 1]) + u32(src[x]) + u32(src[x + 1])
        dst[x] = u8(s / 7)
    }
}

fn avg2(src: []u8, dst: []u8, n: i64) {
    for x in 1..n {
        dst[x] = u8((u32(src[x - 1]) + u32(src[x]) + 1) >> 1)
    }
}

fn even_step(n: i64, steps: i64) -> i64 {
    if n == 1 { return steps }
    if n & 1 == 1 { return odd_step(n, steps) }
    even_step(n >> 1, steps + 1)
}

fn odd_step(n: i64, steps: i64) -> i64 { even_step(3 * n + 1, steps + 1) }

// a value the compiler does not know
noinline fn hide(x: i64) -> i64 { x }

fn main() {
    bad := 0
    for n in 1..80 {
        src := alloc[u8](n + 2)
        dst := alloc[u8](n + 2)
        for i in 0..n + 2 {
            src[i] = u8((i * 37 + n * 101 + 250) % 256)
        }
        blur3(src, dst, n)
        for x in 1..n {
            if dst[x] != ref3(src[x - 1], src[x], src[x + 1], 3) { bad += 1 }
        }
        blur7(src, dst, n)
        for x in 1..n {
            if dst[x] != ref3(src[x - 1], src[x], src[x + 1], 7) { bad += 1 }
        }
        avg2(src, dst, n)
        for x in 1..n {
            if u32(dst[x]) != (u32(src[x - 1]) + u32(src[x]) + 1) / 2 { bad += 1 }
        }
    }
    all := alloc[u8](770)
    out := alloc[u8](770)
    for i in 0..770 { all[i] = 255 }
    blur3(all, out, 768)
    print("bad", bad, out[1], out[767])
    c := 0
    for i in 1..3000 { c += even_step(hide(i), 0) }
    print(c)
}
