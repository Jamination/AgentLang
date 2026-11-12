use std.image
// for each file: inflate, zlib_decompress, inflate_into with small buffers, deflate round trip
fn main() {
    a := args()
    for i in 1..len(a) {
        put(a[i], " ")
        flush()
        data, _ := read_file(a[i])
        m := mark()
        r1, ok1 := inflate(data)
        r2, ok2 := zlib_decompress(data)
        put(ok1, " ", len(r1), " ", hex(u64(crc32(r1))), " ", ok2, " ", len(r2), " ", hex(u64(crc32(r2))))
        // into-buffer variants must agree with the growing ones when big enough, and fail cleanly when not
        for k in []i64{0, 1, 7, 8, 9, len(r1) - 1, len(r1), len(r1) + 1, len(r1) + 8} {
            if k < 0 { continue }
            buf := alloc[u8](k + 16)
            for j in 0..len(buf) { buf[j] = 0xAA }
            n, ok := inflate_into(data, buf[..k])
            for j in k..len(buf) { assert buf[j] == 0xAA, "inflate_into wrote past its buffer" }
            if ok { assert ok1 && n == len(r1) && buf[..n] == r1, "inflate_into disagrees" }
            if ok1 && k >= len(r1) { assert ok && n == len(r1), "inflate_into failed with room" }
            n2, okz := zlib_decompress_into(data, buf[..k])
            for j in k..len(buf) { assert buf[j] == 0xAA, "zlib_decompress_into wrote past its buffer" }
            if okz { assert ok2 && n2 == len(r2) && buf[..n2] == r2, "zlib_decompress_into disagrees" }
            if ok2 && k >= len(r2) { assert okz && n2 == len(r2), "zlib_into failed with room" }
        }
        d := deflate(data)
        back, okb := inflate(d)
        assert okb && back == data, "deflate round trip"
        assert len(d) <= len(data) + len(data) / 1024 + 64, "deflate bound"
        z := zlib_compress(data)
        back2, okz2 := zlib_decompress(z)
        assert okz2 && back2 == data, "zlib round trip"
        write_file(fmt(a[i], ".z"), z)
        print("")
        release(m)
    }
}
