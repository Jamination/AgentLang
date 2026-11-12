// reads pairs of f64 from /tmp/mfz/in64.bin and pairs of f32 from /tmp/mfz/in32.bin, writes
// the results of every scalar function as raw bits to /tmp/mfz/out64.bin / out32.bin
fn main() {
    d64, _ := read_file("/tmp/mfz/in64.bin")
    a := from_bytes[f64](d64)
    n := len(a) / 2
    o := alloc[f64](n * 19)
    k := 0
    for i in 0..n {
        x := a[2 * i]
        y := a[2 * i + 1]
        s, c := sin_cos(x)
        for v in []f64{sin(x), cos(x), tan(x), asin(x), acos(x), atan(x), atan2(y, x), exp(x), log(x), log2(x), pow(x, y), fmod(x, y), trunc(x), round(x), fract(x), s, c, floor(x), ceil(x)} {
            o[k] = v
            k += 1
        }
    }
    write_file("/tmp/mfz/out64.bin", as_bytes(o))
    d32, _ := read_file("/tmp/mfz/in32.bin")
    b := from_bytes[f32](d32)
    m := len(b) / 2
    p := alloc[f32](m * 19)
    k = 0
    for i in 0..m {
        x := b[2 * i]
        y := b[2 * i + 1]
        s, c := sin_cos(x)
        for v in []f32{sin(x), cos(x), tan(x), asin(x), acos(x), atan(x), atan2(y, x), exp(x), log(x), log2(x), pow(x, y), fmod(x, y), trunc(x), round(x), fract(x), s, c, floor(x), ceil(x)} {
            p[k] = v
            k += 1
        }
    }
    write_file("/tmp/mfz/out32.bin", as_bytes(p))
}
