use std.audio
fn main() {
    a := args()
    for i in 1..len(a) {
        put(a[i], " ")
        flush()
        data, _ := read_file(a[i])
        s, ok := wav_decode(data)
        if !ok { print("bad"); continue }
        h: u64 = 0
        for x in s.samples { h = h * 31 + cast[u64](f64(x)) }
        print("ok", s.rate, s.channels, len(s.samples), h)
    }
}
