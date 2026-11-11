// std.image: 8-bit images in memory, PNG and BMP files, deflate/zlib, CRC-32 and Adler-32.
// Everything is written in AL: no libc and no shared library is needed.

// ---------- checksums ----------
// slicing-by-8 tables for crc32, filled on first use
priv var crc_tab [2048]u32

priv fn crc_init() {
    for i in 0..256 {
        c := u32(i)
        for k in 0..8 {
            c = if c & 1 != 0 { c >> 1 ^ 0xEDB88320 } else { c >> 1 }
        }
        crc_tab[i] = c
    }
    for i in 0..256 {
        c := crc_tab[i]
        for t in 1..8 {
            c = crc_tab[c & 255] ^ c >> 8
            crc_tab[t * 256 + i] = c
        }
    }
}

priv inline fn load64(addr i64) u64 {
    cast[*u64](addr)[0]
}

// CRC-32 (the PNG / zip / gzip polynomial) of data, continuing from the CRC `prev` of the bytes before it
fn crc32(prev u32, data []u8) u32 {
    if crc_tab[1] == 0 {
        crc_init()
    }
    c := ~prev
    n := len(data)
    p := cast[i64](ptr(data))
    i := 0
    while i + 8 <= n {
        w := load64(p + i) ^ u64(c)
        c = crc_tab[1792 + (w & 255)] ^ crc_tab[1536 + (w >> 8 & 255)] ^
            crc_tab[1280 + (w >> 16 & 255)] ^ crc_tab[1024 + (w >> 24 & 255)] ^
            crc_tab[768 + (w >> 32 & 255)] ^ crc_tab[512 + (w >> 40 & 255)] ^
            crc_tab[256 + (w >> 48 & 255)] ^ crc_tab[w >> 56]
        i += 8
    }
    while i < n {
        c = crc_tab[(c ^ u32(data[i])) & 255] ^ c >> 8
        i += 1
    }
    ~c
}

// CRC-32 of data
fn crc32(data []u8) u32 {
    crc32(u32(0), data)
}

// Adler-32 (the zlib checksum) of data, continuing from the checksum `prev` of the bytes before it (1 for none)
fn adler32(prev u32, data []u8) u32 {
    a := u64(prev & 0xFFFF)
    b := u64(prev >> 16)
    n := len(data)
    i := 0
    while i < n {
        // 5552 bytes is the longest run whose sums cannot overflow 32 bits
        e := min(n, i + 5552)
        while i < e {
            a += u64(data[i])
            b += a
            i += 1
        }
        a = a % 65521
        b = b % 65521
    }
    u32(b << 16 | a)
}

// Adler-32 of data
fn adler32(data []u8) u32 {
    adler32(u32(1), data)
}

// ---------- byte order helpers ----------
priv inline fn be16(d []u8, i i64) i64 {
    i64(d[i]) << 8 | i64(d[i + 1])
}

priv inline fn be32(d []u8, i i64) i64 {
    i64(d[i]) << 24 | i64(d[i + 1]) << 16 | i64(d[i + 2]) << 8 | i64(d[i + 3])
}

priv inline fn le16(d []u8, i i64) i64 {
    i64(d[i]) | i64(d[i + 1]) << 8
}

priv inline fn le32(d []u8, i i64) i64 {
    i64(d[i]) | i64(d[i + 1]) << 8 | i64(d[i + 2]) << 16 | i64(d[i + 3]) << 24
}

priv fn put_be32(d []u8, i i64, v i64) {
    d[i] = u8(v >> 24)
    d[i + 1] = u8(v >> 16)
    d[i + 2] = u8(v >> 8)
    d[i + 3] = u8(v)
}

priv fn put_le16(d []u8, i i64, v i64) {
    d[i] = u8(v)
    d[i + 1] = u8(v >> 8)
}

priv fn put_le32(d []u8, i i64, v i64) {
    put_le16(d, i, v)
    put_le16(d, i + 2, v >> 16)
}

// ---------- inflate ----------
priv var LEN_BASE = [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
priv var LEN_EXTRA = [29]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
priv var DIST_BASE = [30]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
priv var DIST_EXTRA = [30]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}
priv var CL_ORDER = [19]u8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

// Decoding table entries: bits 0-7 code bits to consume, bits 8-12 number of extra bits (or the
// index bits of a subtable), bits 16-31 literal / base value / subtable offset, and the flags:
priv const F_SUB u32 = 0x2000      // pointer to a subtable for codes longer than the root index
priv const F_BASE u32 = 0x4000     // length or distance: base value plus extra bits
priv const F_END u32 = 0x8000      // end of block (value 0) or invalid code (value 1)
priv const BAD_CODE u32 = 0x18000
priv const LIT_ROOT = 10
priv const DIST_ROOT = 8

// kind of code a decoding table is built for
priv const K_LIT = 0
priv const K_DIST = 1
priv const K_LENS = 2

priv struct Inflate {
    src []u8
    pos i64          // next byte of src that is not in bitbuf
    bitbuf u64
    bitcnt i64       // valid bits in bitbuf; negative after reading past the end of src
    out []u8
    n i64            // bytes written to out
    grow bool        // out may be replaced by a larger buffer
    lit [1334]u32    // enough for 288 symbols, 10 root bits, 15-bit codes
    dist [402]u32    // enough for 32 symbols, 8 root bits, 15-bit codes
}

// the low n (1..16) bits of x in reverse order
priv inline fn rev_bits(x i64, n i64) i64 {
    x = (x & 0x5555) << 1 | (x >> 1 & 0x5555)
    x = (x & 0x3333) << 2 | (x >> 2 & 0x3333)
    x = (x & 0x0F0F) << 4 | (x >> 4 & 0x0F0F)
    ((x & 0xFF) << 8 | (x >> 8 & 0xFF)) >> (16 - n)
}

priv fn huff_entry(sym i64, kind i64) u32 {
    if kind == K_LIT {
        if sym < 256 {
            return u32(sym) << 16
        }
        if sym == 256 {
            return F_END
        }
        if sym > 285 {
            return BAD_CODE
        }
        return u32(LEN_BASE[sym - 257]) << 16 | F_BASE | u32(LEN_EXTRA[sym - 257]) << 8
    }
    if kind == K_DIST {
        if sym > 29 {
            return BAD_CODE
        }
        return u32(DIST_BASE[sym]) << 16 | F_BASE | u32(DIST_EXTRA[sym]) << 8
    }
    u32(sym) << 16
}

// Fills `tab` for the canonical Huffman code with the given code lengths: codes are looked up
// by their first `root` bits (LSB first), longer ones continue in a subtable. Like zlib, it
// rejects over-subscribed codes and incomplete ones other than a single 1-bit code.
priv fn huff_build(tab []u32, lens []u8, root i64, kind i64) bool {
    var count [16]i64
    for l in lens {
        count[l] += 1
    }
    size := 1 << root
    maxl := 15
    while maxl > 0 && count[maxl] == 0 {
        maxl -= 1
    }
    if maxl == 0 {
        fill(tab[..size], BAD_CODE)
        return true
    }
    left := 1
    for l in 1..16 {
        left = left * 2 - count[l]
        if left < 0 {
            return false
        }
    }
    if left > 0 {
        if kind == K_LENS || maxl != 1 {
            return false
        }
        fill(tab[..size], BAD_CODE)
    }
    // symbols ordered by code length, then by value: the order of their canonical codes
    var offs [17]i64
    for l in 1..16 {
        offs[l + 1] = offs[l] + count[l]
    }
    var sorted [288]u16
    for s in 0..len(lens) {
        l := lens[s]
        if l != 0 {
            sorted[offs[l]] = u16(s)
            offs[l] += 1
        }
    }
    code := 0
    si := 0
    used := size
    sub_prefix := -1
    sub_off := 0
    sub_bits := 0
    for l in 1..=maxl {
        for k in 0..count[l] {
            r := rev_bits(code, l)
            e := huff_entry(i64(sorted[si]), kind)
            si += 1
            code += 1
            if l <= root {
                e |= u32(l)
                for j in r..size by 1 << l {
                    tab[j] = e
                }
                continue
            }
            prefix := r & (size - 1)
            if prefix != sub_prefix {
                // a new subtable, just large enough for the longest code that shares this prefix
                sub_bits = l - root
                room := 1 << sub_bits
                ll := l
                rem := count[l] - k
                while ll < maxl {
                    room -= rem
                    if room <= 0 {
                        break
                    }
                    ll += 1
                    sub_bits += 1
                    room = room << 1
                    rem = count[ll]
                }
                if used + (1 << sub_bits) > len(tab) {
                    return false
                }
                sub_prefix = prefix
                sub_off = used
                used += 1 << sub_bits
                tab[prefix] = u32(sub_off) << 16 | F_SUB | u32(sub_bits) << 8 | u32(root)
            }
            e |= u32(l - root)
            for j in r >> root..1 << sub_bits by 1 << (l - root) {
                tab[sub_off + j] = e
            }
        }
        code = code << 1
    }
    true
}

// moves whole bytes from src into the bit buffer
priv fn refill(s *Inflate) {
    while s.bitcnt <= 56 && s.pos < len(s.src) {
        s.bitbuf |= u64(s.src[s.pos]) << s.bitcnt
        s.pos += 1
        s.bitcnt += 8
    }
}

// Takes the next n (at most 32) bits. Past the end of the input it yields zeros and leaves
// bitcnt negative, which the callers check once per block or symbol.
priv fn take_bits(s *Inflate, n i64) i64 {
    if s.bitcnt < n {
        refill(s)
    }
    v := i64(s.bitbuf & ((u64(1) << n) - 1))
    s.bitbuf = s.bitbuf >> n
    s.bitcnt -= n
    v
}

// makes room for n more output bytes; false if the output buffer is fixed and full
priv fn out_room(s *Inflate, n i64) bool {
    if s.n + n <= len(s.out) {
        return true
    }
    if !s.grow {
        return false
    }
    nb := alloc[u8](max(len(s.out) * 2, s.n + n + 4096))
    memcopy(ptr(nb), ptr(s.out), s.n)
    s.out = nb
    true
}

priv fn inflate_stored(s *Inflate) bool {
    if s.bitcnt < 0 {
        return false
    }
    // skip to the next byte boundary and hand back the whole bytes that were read ahead
    s.pos -= s.bitcnt >> 3
    s.bitbuf = 0
    s.bitcnt = 0
    if s.pos + 4 > len(s.src) {
        return false
    }
    n := le16(s.src, s.pos)
    if n != le16(s.src, s.pos + 2) ^ 0xFFFF {
        return false
    }
    s.pos += 4
    if s.pos + n > len(s.src) || !out_room(s, n) {
        return false
    }
    copy(s.out[s.n..s.n + n], s.src[s.pos..s.pos + n])
    s.n += n
    s.pos += n
    true
}

// reads the code lengths of a dynamic block and builds both decoding tables
priv fn inflate_dynamic(s *Inflate) bool {
    hlit := take_bits(s, 5) + 257
    hdist := take_bits(s, 5) + 1
    hclen := take_bits(s, 4) + 4
    if hlit > 286 || hdist > 30 {
        return false
    }
    var cl [19]u8
    for i in 0..hclen {
        cl[CL_ORDER[i]] = u8(take_bits(s, 3))
    }
    var cltab [128]u32
    if !huff_build(cltab[..], cl[..], 7, K_LENS) {
        return false
    }
    var lens [316]u8
    total := hlit + hdist
    i := 0
    while i < total {
        if s.bitcnt < 7 {
            refill(s)
        }
        e := cltab[s.bitbuf & 127]
        nb := i64(e & 255)
        s.bitbuf = s.bitbuf >> nb
        s.bitcnt -= nb
        if s.bitcnt < 0 || e & F_END != 0 {
            return false
        }
        sym := i64(e >> 16)
        if sym < 16 {
            lens[i] = u8(sym)
            i += 1
            continue
        }
        var val u8 = 0
        rep := 0
        if sym == 16 {
            if i == 0 {
                return false
            }
            val = lens[i - 1]
            rep = 3 + take_bits(s, 2)
        } else if sym == 17 {
            rep = 3 + take_bits(s, 3)
        } else {
            rep = 11 + take_bits(s, 7)
        }
        if i + rep > total {
            return false
        }
        fill(lens[i..i + rep], val)
        i += rep
    }
    // a block without an end-of-block code could never finish
    if s.bitcnt < 0 || lens[256] == 0 {
        return false
    }
    huff_build(s.lit[..], lens[..hlit], LIT_ROOT, K_LIT) &&
        huff_build(s.dist[..], lens[hlit..total], DIST_ROOT, K_DIST)
}

// decodes the symbols of one Huffman-coded block with the tables in s
priv fn inflate_codes(s *Inflate) bool {
    src := s.src
    in_n := len(src)
    in_p := cast[i64](ptr(src))
    pos := s.pos
    bb := s.bitbuf
    bc := s.bitcnt
    out := s.out
    cap := len(out)
    n := s.n
    lit := s.lit[..]
    dist := s.dist[..]
    ok := false
    // every symbol needs at most 48 bits (15 + 5 for a length, 15 + 13 for a distance)
    while bc >= 0 {
        if pos + 8 <= in_n {
            bb |= load64(in_p + pos) << bc
            pos += (63 - bc) >> 3
            bc |= 56
        } else {
            while bc <= 56 && pos < in_n {
                bb |= u64(src[pos]) << bc
                pos += 1
                bc += 8
            }
        }
        e := lit[bb & 1023]
        if e & F_SUB != 0 {
            bb = bb >> LIT_ROOT
            bc -= LIT_ROOT
            e = lit[u64(e >> 16) + (bb & ((u64(1) << (e >> 8 & 31)) - 1))]
        }
        nb := i64(e & 255)
        bb = bb >> nb
        bc -= nb
        if e & (F_BASE | F_END) == 0 {
            if n == cap {
                s.n = n
                if !out_room(s, 1) {
                    break
                }
                out = s.out
                cap = len(out)
            }
            out[n] = u8(e >> 16)
            n += 1
            continue
        }
        if e & F_BASE == 0 {
            ok = e >> 16 == 0 && bc >= 0
            break
        }
        xb := i64(e >> 8 & 31)
        length := i64(e >> 16) + i64(bb & ((u64(1) << xb) - 1))
        bb = bb >> xb
        bc -= xb
        e = dist[bb & 255]
        if e & F_SUB != 0 {
            bb = bb >> DIST_ROOT
            bc -= DIST_ROOT
            e = dist[u64(e >> 16) + (bb & ((u64(1) << (e >> 8 & 31)) - 1))]
        }
        nb = i64(e & 255)
        bb = bb >> nb
        bc -= nb
        if e & F_BASE == 0 {
            break
        }
        xb = i64(e >> 8 & 31)
        d := i64(e >> 16) + i64(bb & ((u64(1) << xb) - 1))
        bb = bb >> xb
        bc -= xb
        if bc < 0 || d > n {
            break
        }
        if n + length + 8 > cap {
            s.n = n
            if !out_room(s, length) {
                break
            }
            out = s.out
            cap = len(out)
        }
        if d >= 8 && n + length + 8 <= cap {
            // 8 bytes at a time; this may write up to 7 bytes past the match, inside the buffer
            q := cast[i64](ptr(out)) + n
            end := q + length
            loop {
                cast[*u64](q)[0] = load64(q - d)
                q += 8
                if q >= end {
                    break
                }
            }
        } else if d == 1 {
            fill(out[n..n + length], out[n - 1])
        } else {
            for k in n..n + length {
                out[k] = out[k - d]
            }
        }
        n += length
    }
    s.pos = pos
    s.bitbuf = bb
    s.bitcnt = bc
    s.n = n
    ok
}

// decodes all blocks of a deflate stream starting at s.pos
priv fn inflate_run(s *Inflate) bool {
    loop {
        final := take_bits(s, 1)
        kind := take_bits(s, 2)
        if kind == 0 {
            if !inflate_stored(s) {
                return false
            }
        } else if kind == 1 {
            var lens [320]u8
            fill(lens[..144], 8)
            fill(lens[144..256], 9)
            fill(lens[256..280], 7)
            fill(lens[280..288], 8)
            fill(lens[288..], 5)
            huff_build(s.lit[..], lens[..288], LIT_ROOT, K_LIT)
            huff_build(s.dist[..], lens[288..], DIST_ROOT, K_DIST)
            if !inflate_codes(s) {
                return false
            }
        } else if kind == 3 || !inflate_dynamic(s) || !inflate_codes(s) {
            return false
        }
        if s.bitcnt < 0 {
            return false
        }
        if final != 0 {
            return true
        }
    }
}

// checks the zlib header, inflates, and verifies the Adler-32 that follows the deflate stream
priv fn zlib_run(s *Inflate) bool {
    d := s.src
    if len(d) < 6 || d[0] & 15 != 8 || d[0] >> 4 > 7 || d[1] & 0x20 != 0 || be16(d, 0) % 31 != 0 {
        return false
    }
    s.pos = 2
    if !inflate_run(s) {
        return false
    }
    end := s.pos - (s.bitcnt >> 3)
    end + 4 <= len(d) && u32(be32(d, end)) == adler32(s.out[..s.n])
}

// Decompresses a raw deflate stream (RFC 1951) into a new buffer. Allocates: the buffer is
// doubled as needed, so up to twice the result size stays behind in the arena.
fn inflate(data []u8) ([]u8, bool) {
    var s Inflate
    s.src = data
    s.out = alloc[u8](len(data) * 4 + 4096)
    s.grow = true
    ok := inflate_run(&s)
    (s.out[..s.n], ok)
}

// Decompresses a raw deflate stream into `out` without allocating. Returns the number of bytes
// written; false if the stream is malformed or does not fit.
fn inflate_into(data []u8, out []u8) (i64, bool) {
    var s Inflate
    s.src = data
    s.out = out
    ok := inflate_run(&s)
    (s.n, ok)
}

// Decompresses a zlib stream (RFC 1950) into a new buffer and verifies its Adler-32. Allocates like inflate.
fn zlib_decompress(data []u8) ([]u8, bool) {
    var s Inflate
    s.src = data
    s.out = alloc[u8](len(data) * 4 + 4096)
    s.grow = true
    ok := zlib_run(&s)
    (s.out[..s.n], ok)
}

// Decompresses a zlib stream into `out` without allocating and verifies its Adler-32. Returns
// the number of bytes written; false if the stream is malformed or does not fit.
fn zlib_decompress_into(data []u8, out []u8) (i64, bool) {
    var s Inflate
    s.src = data
    s.out = out
    ok := zlib_run(&s)
    (s.n, ok)
}

// ---------- deflate ----------
priv const BLOCK_SYMS = 32768      // symbols per block
priv const MAX_CHAIN = 128         // hash chain entries examined per position
priv const GOOD_LEN = 8            // a pending match this long quarters the chain limit
priv const MAX_LAZY = 16           // a pending match this long is taken without looking further
priv const NICE_LEN = 128          // a match this long ends the search

priv struct BitWriter { buf []u8, n i64, acc u64, cnt i64 }

priv struct Deflate {
    w *BitWriter
    src []u8
    syms []u32       // literal byte, or match length | distance << 9
    nsym i64
    start i64        // first byte of src covered by syms
    lfreq [288]i64
    dfreq [32]i64
}

// appends the low nbits (at most 32) bits of v
priv inline fn put_bits(w *BitWriter, v i64, nbits i64) {
    w.acc |= u64(v) << w.cnt
    w.cnt += nbits
    if w.cnt >= 32 {
        put_le32(w.buf, w.n, i64(w.acc & 0xFFFFFFFF))
        w.n += 4
        w.acc = w.acc >> 32
        w.cnt -= 32
    }
}

// pads with zero bits to the next byte boundary
priv fn flush_bits(w *BitWriter) {
    while w.cnt > 0 {
        w.buf[w.n] = u8(w.acc)
        w.n += 1
        w.acc = w.acc >> 8
        w.cnt -= 8
    }
    w.cnt = 0
}

// index (0..28) of the length code for a match length 3..258
priv inline fn len_code(length i64) i64 {
    l := length - 3
    if l < 8 {
        return l
    }
    if l == 255 {
        return 28
    }
    msb := 63 - clz(l)
    (msb - 1) * 4 + (l >> (msb - 2) & 3)
}

// distance code (0..29) for a distance 1..32768
priv inline fn dist_code(dist i64) i64 {
    d := dist - 1
    if d < 4 {
        return d
    }
    msb := 63 - clz(d)
    msb * 2 + (d >> (msb - 1) & 1)
}

// Code lengths (0 for unused symbols, at most maxlen) of a minimum-redundancy prefix code for
// the given frequencies. At least two symbols get a code, so the code is always complete.
priv fn huff_lengths(freq []i64, lens []u8, maxlen i64) {
    var key [288]i64
    n := 0
    for s in 0..len(freq) {
        lens[s] = 0
        if freq[s] != 0 {
            key[n] = freq[s] << 9 | s
            n += 1
        }
    }
    s := 0
    while n < 2 {
        if freq[s] == 0 {
            key[n] = 1 << 9 | s
            n += 1
        }
        s += 1
    }
    sort(key[..n])
    // Moffat and Katajainen's in-place algorithm: a[i] becomes the code length of the i-th rarest symbol
    var a [288]i64
    for i in 0..n {
        a[i] = key[i] >> 9
    }
    a[0] += a[1]
    root := 0
    leaf := 2
    for next in 1..n - 1 {
        if leaf >= n || a[root] < a[leaf] {
            a[next] = a[root]
            a[root] = next
            root += 1
        } else {
            a[next] = a[leaf]
            leaf += 1
        }
        if leaf >= n || (root < next && a[root] < a[leaf]) {
            a[next] += a[root]
            a[root] = next
            root += 1
        } else {
            a[next] += a[leaf]
            leaf += 1
        }
    }
    a[n - 2] = 0
    for next in n - 3..=0 by -1 {
        a[next] = a[a[next]] + 1
    }
    avail := 1
    used := 0
    depth := 0
    root = n - 2
    next := n - 1
    while avail > 0 {
        while root >= 0 && a[root] == depth {
            used += 1
            root -= 1
        }
        while avail > used {
            a[next] = depth
            next -= 1
            avail -= 1
        }
        avail = 2 * used
        depth += 1
        used = 0
    }
    // limit the lengths: move codes down from maxlen until the code fits again
    var count [16]i64
    for i in 0..n {
        count[min(a[i], maxlen)] += 1
    }
    total := 0
    for l in 1..=maxlen {
        total += count[l] << (maxlen - l)
    }
    while total > 1 << maxlen {
        count[maxlen] -= 1
        l := maxlen - 1
        while count[l] == 0 {
            l -= 1
        }
        count[l] -= 1
        count[l + 1] += 2
        total -= 1
    }
    k := 0
    for l in maxlen..=1 by -1 {
        for c in 0..count[l] {
            lens[key[k] & 511] = u8(l)
            k += 1
        }
    }
}

// canonical codes for the given lengths, bit-reversed so that they can be written LSB first
priv fn huff_codes(lens []u8, codes []u16) {
    var count [16]i64
    for l in lens {
        count[l] += 1
    }
    count[0] = 0
    var next [16]i64
    code := 0
    for b in 1..16 {
        code = (code + count[b - 1]) << 1
        next[b] = code
    }
    for s in 0..len(lens) {
        l := i64(lens[s])
        if l != 0 {
            codes[s] = u16(rev_bits(next[l], l))
            next[l] += 1
        }
    }
}

// Writes the pending symbols, which cover src[d.start..end], as one block: stored, fixed or
// dynamic Huffman, whichever is smallest.
priv fn flush_block(d *Deflate, end i64, final bool) {
    w := d.w
    last := if final { 1 } else { 0 }
    d.lfreq[256] = 1
    var llen [288]u8
    var dlen [32]u8
    huff_lengths(d.lfreq[..286], llen[..286], 15)
    huff_lengths(d.dfreq[..30], dlen[..30], 15)
    hlit := 286
    while hlit > 257 && llen[hlit - 1] == 0 {
        hlit -= 1
    }
    hdist := 30
    while hdist > 1 && dlen[hdist - 1] == 0 {
        hdist -= 1
    }
    // run-length code the two length lists: symbol | repeat count bits << 8
    var all [316]u8
    copy(all[..hlit], llen[..hlit])
    copy(all[hlit..hlit + hdist], dlen[..hdist])
    total := hlit + hdist
    var rle [316]u16
    nrle := 0
    var clfreq [19]i64
    i := 0
    while i < total {
        v := all[i]
        run := 1
        while i + run < total && all[i + run] == v {
            run += 1
        }
        i += run
        if v != 0 {
            rle[nrle] = u16(v)
            nrle += 1
            clfreq[v] += 1
            run -= 1
        }
        while run >= 3 {
            sym := 16
            k := min(run, 6)
            xv := k - 3
            if v == 0 {
                k = min(run, 138)
                sym = if k < 11 { 17 } else { 18 }
                xv = if k < 11 { k - 3 } else { k - 11 }
            }
            rle[nrle] = u16(sym | xv << 8)
            nrle += 1
            clfreq[sym] += 1
            run -= k
        }
        while run > 0 {
            rle[nrle] = u16(v)
            nrle += 1
            clfreq[v] += 1
            run -= 1
        }
    }
    var cllen [19]u8
    huff_lengths(clfreq[..], cllen[..], 7)
    hclen := 19
    while hclen > 4 && cllen[CL_ORDER[hclen - 1]] == 0 {
        hclen -= 1
    }
    // exact sizes in bits of the three encodings
    var flen [288]u8
    fill(flen[..144], 8)
    fill(flen[144..256], 9)
    fill(flen[256..280], 7)
    fill(flen[280..], 8)
    dyn := 3 + 14 + 3 * hclen + clfreq[16] * 2 + clfreq[17] * 3 + clfreq[18] * 7
    for s in 0..19 {
        dyn += clfreq[s] * i64(cllen[s])
    }
    fix := 3
    for s in 0..286 {
        f := d.lfreq[s]
        x := if s > 256 { i64(LEN_EXTRA[s - 257]) } else { 0 }
        dyn += f * (i64(llen[s]) + x)
        fix += f * (i64(flen[s]) + x)
    }
    for s in 0..30 {
        f := d.dfreq[s]
        dyn += f * i64(dlen[s] + DIST_EXTRA[s])
        fix += f * i64(5 + DIST_EXTRA[s])
    }
    span := end - d.start
    stored := span * 8 + 42 * max(1, (span + 65534) / 65535)
    if stored < min(dyn, fix) {
        p := d.start
        loop {
            k := min(end - p, 65535)
            put_bits(w, if p + k == end { last } else { 0 }, 3)
            flush_bits(w)
            put_le16(w.buf, w.n, k)
            put_le16(w.buf, w.n + 2, k ^ 0xFFFF)
            copy(w.buf[w.n + 4..w.n + 4 + k], d.src[p..p + k])
            w.n += 4 + k
            p += k
            if p == end {
                break
            }
        }
    } else {
        if fix <= dyn {
            put_bits(w, last | 2, 3)
            copy(llen[..], flen[..])
            fill(dlen[..], 5)
        } else {
            put_bits(w, last | 4, 3)
            put_bits(w, hlit - 257, 5)
            put_bits(w, hdist - 1, 5)
            put_bits(w, hclen - 4, 4)
            for k in 0..hclen {
                put_bits(w, i64(cllen[CL_ORDER[k]]), 3)
            }
            var clcode [19]u16
            huff_codes(cllen[..], clcode[..])
            for k in 0..nrle {
                sym := i64(rle[k] & 255)
                put_bits(w, i64(clcode[sym]), i64(cllen[sym]))
                if sym >= 16 {
                    put_bits(w, i64(rle[k] >> 8), if sym == 16 { 2 } else if sym == 17 { 3 } else { 7 })
                }
            }
        }
        var lcode [288]u16
        var dcode [32]u16
        huff_codes(llen[..], lcode[..])
        huff_codes(dlen[..], dcode[..])
        for k in 0..d.nsym {
            sym := i64(d.syms[k])
            dist := sym >> 9
            if dist == 0 {
                put_bits(w, i64(lcode[sym]), i64(llen[sym]))
                continue
            }
            length := sym & 511
            lc := len_code(length)
            nb := i64(llen[257 + lc])
            put_bits(w, i64(lcode[257 + lc]) | (length - i64(LEN_BASE[lc])) << nb, nb + i64(LEN_EXTRA[lc]))
            dc := dist_code(dist)
            nb = i64(dlen[dc])
            put_bits(w, i64(dcode[dc]) | (dist - i64(DIST_BASE[dc])) << nb, nb + i64(DIST_EXTRA[dc]))
        }
        put_bits(w, i64(lcode[256]), i64(llen[256]))
    }
    d.nsym = 0
    d.start = end
    fill(d.lfreq[..], 0)
    fill(d.dfreq[..], 0)
}

// number of equal bytes (at most maxlen) at addresses a and b
priv inline fn match_len(a i64, b i64, maxlen i64) i64 {
    l := 0
    while l + 8 <= maxlen {
        x := load64(a + l) ^ load64(b + l)
        if x != 0 {
            return l + i64(ctz(x) >> 3)
        }
        l += 8
    }
    while l < maxlen && cast[*u8](a + l)[0] == cast[*u8](b + l)[0] {
        l += 1
    }
    l
}

// hash of the three bytes at src[i]
priv inline fn hash3(src []u8, i i64) i64 {
    i64((u32(src[i]) | u32(src[i + 1]) << 8 | u32(src[i + 2]) << 16) * 0x9E3779B1 >> 17)
}

// an upper limit for the deflate stream of n bytes: stored blocks plus their headers
priv inline fn deflate_bound(n i64) i64 {
    n + (n >> 10) + 64
}

// Appends the deflate stream for src to w, whose buffer must have deflate_bound(len(src))
// bytes of room. LZ77 with hash chains and lazy matching; working memory is released again.
priv fn deflate_body(w *BitWriter, src []u8) {
    m := mark()
    var d Deflate
    d.w = w
    d.src = src
    d.syms = alloc[u32](BLOCK_SYMS)
    // head[h]: last position with hash h, prev[p & 32767]: the position before p with the same
    // hash; both store position + 1 so that 0 means none
    head := alloc[i64](32768)
    prev := alloc[i64](32768)
    n := len(src)
    base := cast[i64](ptr(src))
    plen := 0       // length of the match found at i - 1 that is waiting for a better one at i
    pdist := 0
    i := 0
    while i < n {
        mlen := 0
        mdist := 0
        if i + 3 <= n {
            h := hash3(src, i)
            c := head[h] - 1
            head[h] = i + 1
            prev[i & 32767] = c + 1
            maxlen := min(n - i, 258)
            best := max(plen, 2)
            if plen < MAX_LAZY && best < maxlen {
                chain := if plen >= GOOD_LEN { MAX_CHAIN >> 2 } else { MAX_CHAIN }
                limit := max(i - 32767, 0)
                while c >= limit && chain > 0 {
                    if src[c + best] == src[i + best] {
                        l := match_len(base + c, base + i, maxlen)
                        if l > best {
                            best = l
                            mlen = l
                            mdist = i - c
                            if l >= NICE_LEN || l == maxlen {
                                break
                            }
                        }
                    }
                    c = prev[c & 32767] - 1
                    chain -= 1
                }
                // a minimal match far away costs more than three literals
                if mlen == 3 && mdist > 4096 {
                    mlen = 0
                }
            }
        }
        end := i + 1
        if plen != 0 && mlen <= plen {
            // the match at i - 1 stands: emit it and index the positions it covers
            d.syms[d.nsym] = u32(plen | pdist << 9)
            d.lfreq[257 + len_code(plen)] += 1
            d.dfreq[dist_code(pdist)] += 1
            end = i - 1 + plen
            i += 1
            while i < end {
                if i + 3 <= n {
                    h := hash3(src, i)
                    prev[i & 32767] = head[h]
                    head[h] = i + 1
                }
                i += 1
            }
            plen = 0
        } else if plen == 0 && mlen != 0 {
            // keep the match back: the next position may start a longer one
            plen = mlen
            pdist = mdist
            i += 1
            continue
        } else {
            // a literal: the byte at i - 1 if its match was beaten, else the byte at i
            if plen != 0 {
                end = i
            }
            c := src[end - 1]
            d.syms[d.nsym] = u32(c)
            d.lfreq[c] += 1
            plen = mlen
            pdist = mdist
            i += 1
        }
        d.nsym += 1
        if d.nsym == BLOCK_SYMS {
            flush_block(&d, end, false)
        }
    }
    flush_block(&d, n, true)
    flush_bits(w)
    release(m)
}

// Compresses data into a raw deflate stream (RFC 1951). Allocates the result; it is never
// more than len(data) / 1024 + 64 bytes longer than data.
fn deflate(data []u8) []u8 {
    var w BitWriter
    w.buf = alloc[u8](deflate_bound(len(data)))
    deflate_body(&w, data)
    w.buf[..w.n]
}

// Compresses data into a zlib stream (RFC 1950: header, deflate stream, Adler-32). Allocates the result.
fn zlib_compress(data []u8) []u8 {
    var w BitWriter
    w.buf = alloc[u8](deflate_bound(len(data)) + 6)
    w.buf[0] = 0x78
    w.buf[1] = 0x9C
    w.n = 2
    deflate_body(&w, data)
    put_be32(w.buf, w.n, i64(adler32(data)))
    w.buf[..w.n + 4]
}

// ---------- images ----------
// An 8-bit image. `channels` bytes per pixel: 1 grey, 2 grey + alpha, 3 RGB, 4 RGBA. Rows run
// from the top down without padding: pixel (x, y) starts at pix[(y * w + x) * channels].
struct Image { w i64, h i64, channels i64, pix []u8 }

// limits of the decoders: larger dimensions or decoded sizes are rejected
priv const MAX_DIM = 1 << 24
priv const MAX_BYTES = 1 << 31

// a new image with every byte zero (allocates w * h * channels bytes)
fn image_new(w i64, h i64, channels i64) Image {
    assert w >= 0 && h >= 0 && channels >= 1 && channels <= 4, "image_new: bad size or channel count"
    Image{w, h, channels, alloc[u8](w * h * channels)}
}

// channel c of the pixel at (x, y)
inline fn get(img Image, x i64, y i64, c i64) u8 {
    img.pix[(y * img.w + x) * img.channels + c]
}

// sets channel c of the pixel at (x, y)
inline fn set(img *Image, x i64, y i64, c i64, v u8) {
    img.pix[(y * img.w + x) * img.channels + c] = v
}

// the pixel starting at pix[i] as red, green, blue, alpha (grey is spread, missing alpha is 255)
priv inline fn rgba(img Image, i i64) (u8, u8, u8, u8) {
    p := img.pix
    match img.channels {
        1 => (p[i], p[i], p[i], u8(255))
        2 => (p[i], p[i], p[i], p[i + 1])
        3 => (p[i], p[i + 1], p[i + 2], u8(255))
        _ => (p[i], p[i + 1], p[i + 2], p[i + 3])
    }
}

// grey value of a colour, with the integer weights 77 / 150 / 29 for red / green / blue
priv inline fn luma(r u8, g u8, b u8) u8 {
    u8((i64(r) * 77 + i64(g) * 150 + i64(b) * 29) >> 8)
}

// stores a colour in the pixel starting at pix[i]: 1 and 2 channel images keep its grey value
priv inline fn set_rgba(img Image, i i64, r u8, g u8, b u8, a u8) {
    p := img.pix
    if img.channels >= 3 {
        p[i] = r
        p[i + 1] = g
        p[i + 2] = b
    } else {
        p[i] = luma(r, g, b)
    }
    if img.channels == 2 || img.channels == 4 {
        p[i + img.channels - 1] = a
    }
}

// the pixel at (x, y) as an RGBA colour with components 0..1
fn get(img Image, x i64, y i64) vec4 {
    r, g, b, a := rgba(img, (y * img.w + x) * img.channels)
    vec4(f32(r), f32(g), f32(b), f32(a)) / 255.0
}

// sets the pixel at (x, y) from an RGBA colour with components 0..1 (clamped, rounded to 8 bits)
fn set(img *Image, x i64, y i64, col vec4) {
    c := fmin(fmax(col, vec4(0.0)), vec4(1.0)) * 255.0 + vec4(0.5)
    set_rgba(*img, (y * img.w + x) * img.channels, u8(i64(c.x)), u8(i64(c.y)), u8(i64(c.z)), u8(i64(c.w)))
}

// The image with another channel count (allocates; returns img itself if it already has that
// many). Grey spreads to RGB, RGB becomes grey by its luma, new alpha is 255, dropped alpha is lost.
fn convert(img Image, channels i64) Image {
    if channels == img.channels {
        return img
    }
    out := image_new(img.w, img.h, channels)
    for i in 0..img.w * img.h {
        r, g, b, a := rgba(img, i * img.channels)
        set_rgba(out, i * channels, r, g, b, a)
    }
    out
}

// mirrors the image top to bottom in place
fn flip_y(img *Image) {
    stride := img.w * img.channels
    for y in 0..img.h / 2 {
        a := img.pix[y * stride..(y + 1) * stride]
        b := img.pix[(img.h - 1 - y) * stride..(img.h - y) * stride]
        for i in 0..stride {
            t := a[i]
            a[i] = b[i]
            b[i] = t
        }
    }
}

// a copy of the w x h rectangle at (x, y), clipped to the image (allocates)
fn crop(img Image, x i64, y i64, w i64, h i64) Image {
    x0 := max(x, 0)
    y0 := max(y, 0)
    out := image_new(max(min(x + w, img.w) - x0, 0), max(min(y + h, img.h) - y0, 0), img.channels)
    blit(&out, img, -x0, -y0)
    out
}

// copies src into dst with its top-left corner at (x, y), clipped to dst; both need the same channel count
fn blit(dst *Image, src Image, x i64, y i64) {
    assert dst.channels == src.channels, "blit: channel counts differ"
    ch := src.channels
    x0 := max(x, 0)
    x1 := min(x + src.w, dst.w)
    if x0 >= x1 {
        return
    }
    for dy in max(y, 0)..min(y + src.h, dst.h) {
        s := ((dy - y) * src.w + x0 - x) * ch
        copy(dst.pix[(dy * dst.w + x0) * ch..(dy * dst.w + x1) * ch], src.pix[s..s + (x1 - x0) * ch])
    }
}

// the image scaled to w x h by picking the nearest source pixel (allocates)
fn resize_nearest(img Image, w i64, h i64) Image {
    ch := img.channels
    out := image_new(w, h, ch)
    if img.w == 0 || img.h == 0 {
        return out
    }
    o := 0
    for y in 0..h {
        row := (2 * y + 1) * img.h / (2 * h) * img.w
        for x in 0..w {
            s := (row + (2 * x + 1) * img.w / (2 * w)) * ch
            for c in 0..ch {
                out.pix[o + c] = img.pix[s + c]
            }
            o += ch
        }
    }
    out
}

// position of the centre of destination pixel i in a source of sn pixels, in 1/256 pixel units
priv inline fn src_pos(i i64, sn i64, dn i64) i64 {
    max(0, min((2 * i + 1) * sn * 128 / dn - 128, (sn - 1) * 256))
}

// The image scaled to w x h with bilinear interpolation between pixel centres (allocates). All
// channels are filtered alike: premultiply alpha first if transparent pixels have arbitrary colours.
// The arithmetic is fixed-point, so results are identical on every machine. When shrinking by
// more than 2x, average with generate_mipmap first to avoid aliasing.
fn resize_bilinear(img Image, w i64, h i64) Image {
    ch := img.channels
    out := image_new(w, h, ch)
    if img.w == 0 || img.h == 0 {
        return out
    }
    m := mark()
    xs := alloc[i64](w)
    for x in 0..w {
        xs[x] = src_pos(x, img.w, w)
    }
    o := 0
    for y in 0..h {
        sy := src_pos(y, img.h, h)
        fy := sy & 255
        r0 := (sy >> 8) * img.w
        r1 := min((sy >> 8) + 1, img.h - 1) * img.w
        for x in 0..w {
            fx := xs[x] & 255
            x0 := xs[x] >> 8
            x1 := min(x0 + 1, img.w - 1)
            for c in 0..ch {
                top := i64(img.pix[(r0 + x0) * ch + c]) * (256 - fx) + i64(img.pix[(r0 + x1) * ch + c]) * fx
                bot := i64(img.pix[(r1 + x0) * ch + c]) * (256 - fx) + i64(img.pix[(r1 + x1) * ch + c]) * fx
                out.pix[o + c] = u8((top * (256 - fy) + bot * fy + 32768) >> 16)
            }
            o += ch
        }
    }
    release(m)
    out
}

// multiplies the colour channels by alpha (rounded) in place; images without alpha are unchanged
fn premultiply_alpha(img *Image) {
    ch := img.channels
    if ch != 2 && ch != 4 {
        return
    }
    for i in 0..img.w * img.h * ch by ch {
        a := i64(img.pix[i + ch - 1])
        for c in 0..ch - 1 {
            t := i64(img.pix[i + c]) * a + 128
            img.pix[i + c] = u8((t + (t >> 8)) >> 8)
        }
    }
}

// The next mipmap level (allocates): half the width and height, rounded down but at least 1,
// each pixel the rounded average of a 2x2 block (box filter). The last column / row of an odd
// size is dropped.
fn generate_mipmap(img Image) Image {
    ch := img.channels
    out := image_new(max(img.w / 2, 1), max(img.h / 2, 1), ch)
    if img.w == 0 || img.h == 0 {
        return out
    }
    o := 0
    for y in 0..out.h {
        r0 := 2 * y * img.w
        r1 := min(2 * y + 1, img.h - 1) * img.w
        for x in 0..out.w {
            x0 := 2 * x
            x1 := min(x0 + 1, img.w - 1)
            for c in 0..ch {
                sum := i64(img.pix[(r0 + x0) * ch + c]) + i64(img.pix[(r0 + x1) * ch + c]) +
                    i64(img.pix[(r1 + x0) * ch + c]) + i64(img.pix[(r1 + x1) * ch + c])
                out.pix[o + c] = u8((sum + 2) >> 2)
            }
            o += ch
        }
    }
    out
}

// the whole mipmap chain (allocates): element 0 is img itself, the last one is 1 x 1
fn mipmap_chain(img Image) []Image {
    n := 1
    while max(img.w, img.h) >> n > 0 {
        n += 1
    }
    levels := alloc[Image](n)
    levels[0] = img
    for i in 1..n {
        levels[i] = generate_mipmap(levels[i - 1])
    }
    levels
}

// ---------- PNG ----------
priv struct Png {
    w i64
    h i64
    depth i64        // bits per sample
    ctype i64        // colour type: 0 grey, 2 RGB, 3 palette, 4 grey + alpha, 6 RGBA
    interlace i64
    nin i64          // samples per pixel in the file
    channels i64     // bytes per pixel of the decoded image
    npal i64
    trns bool        // grey or RGB with a transparent colour, or a palette with alpha
    key [4]i64       // the transparent colour (grey or RGB samples)
    pal [1024]u8     // palette as RGBA
}

// The Paeth predictor: whichever of left, up, up-left is closest to left + up - up-left (ties
// in that order). Written as two selects so that it compiles without branches.
priv inline fn paeth(a i64, b i64, c i64) i64 {
    pa := abs(b - c)
    pb := abs(a - c)
    pc := abs(a + b - 2 * c)
    r := if pb <= pc { b } else { c }
    if pa <= min(pb, pc) { a } else { r }
}

// Reverses the scanline filter `ft`: reads the filtered bytes src, writes the row to cur (which
// may be the same memory); prev is the row above, bpp the bytes per complete pixel.
priv fn png_unfilter(ft u8, cur []u8, src []u8, prev []u8, bpp i64) bool {
    n := len(cur)
    if ft == 0 {
        if ptr(cur) != ptr(src) {
            copy(cur, src)
        }
    } else if ft == 1 {
        for i in 0..bpp {
            cur[i] = src[i]
        }
        for i in bpp..n {
            cur[i] = src[i] + cur[i - bpp]
        }
    } else if ft == 2 {
        for i in 0..n {
            cur[i] = src[i] + prev[i]
        }
    } else if ft == 3 {
        for i in 0..bpp {
            cur[i] = src[i] + (prev[i] >> 1)
        }
        for i in bpp..n {
            cur[i] = src[i] + u8((i64(cur[i - bpp]) + i64(prev[i])) >> 1)
        }
    } else if ft == 4 {
        for i in 0..bpp {
            cur[i] = src[i] + prev[i]
        }
        for i in bpp..n {
            cur[i] = src[i] + u8(paeth(i64(cur[i - bpp]), i64(prev[i]), i64(prev[i - bpp])))
        }
    } else {
        return false
    }
    true
}

// sample i of an unfiltered row with `depth` bits per sample
priv inline fn png_sample(row []u8, i i64, depth i64) i64 {
    if depth == 8 {
        return i64(row[i])
    }
    if depth == 16 {
        return be16(row, 2 * i)
    }
    i64(row[i * depth >> 3]) >> (8 - depth - (i * depth & 7)) & ((1 << depth) - 1)
}

// Converts w pixels of an unfiltered row to 8-bit pixels in dst: applies the palette and the
// transparent colour, scales 1/2/4-bit grey to 0..255 and keeps the high byte of 16-bit samples.
priv fn png_expand(p *Png, row []u8, dst []u8, w i64) bool {
    depth := p.depth
    scale := if depth < 8 { 255 / ((1 << depth) - 1) } else { 1 }
    o := 0
    for x in 0..w {
        if p.ctype == 3 {
            i := png_sample(row, x, depth)
            if i >= p.npal {
                return false
            }
            copy(dst[o..o + p.channels], p.pal[i * 4..i * 4 + 4])
        } else {
            clear := p.trns
            for c in 0..p.nin {
                s := png_sample(row, x * p.nin + c, depth)
                if s != p.key[c] {
                    clear = false
                }
                dst[o + c] = u8(if depth == 16 { s >> 8 } else { s * scale })
            }
            if p.trns {
                dst[o + p.nin] = if clear { 0 } else { 255 }
            }
        }
        o += p.channels
    }
    true
}

// width or height of an Adam7 pass: the pixels start, start + step, ... below n
priv inline fn pass_size(n i64, start i64, step i64) i64 {
    (n - start + step - 1) / step
}

priv var ADAM7_X = [7]u8{0, 4, 0, 2, 0, 1, 0}
priv var ADAM7_Y = [7]u8{0, 0, 4, 0, 2, 0, 1}
priv var ADAM7_DX = [7]u8{8, 8, 4, 4, 2, 2, 1}
priv var ADAM7_DY = [7]u8{8, 8, 8, 4, 4, 2, 2}

// bytes of the inflated image data: every scanline of every pass plus its filter byte
priv fn png_raw_size(p *Png) i64 {
    bits := p.nin * p.depth
    if p.interlace == 0 {
        return p.h * (1 + (p.w * bits + 7) / 8)
    }
    n := 0
    for i in 0..7 {
        pw := pass_size(p.w, i64(ADAM7_X[i]), i64(ADAM7_DX[i]))
        ph := pass_size(p.h, i64(ADAM7_Y[i]), i64(ADAM7_DY[i]))
        if pw > 0 {
            n += ph * (1 + (pw * bits + 7) / 8)
        }
    }
    n
}

// unfilters the inflated data `raw` in place and writes the pixels to pix
priv fn png_rows(p *Png, raw []u8, pix []u8) bool {
    bits := p.nin * p.depth
    bpp := max(bits / 8, 1)
    ch := p.channels
    zero := alloc[u8]((p.w * bits + 7) / 8)
    if p.interlace == 0 {
        stride := len(zero)
        // 8-bit samples without palette or transparent colour are the pixels themselves
        direct := p.depth == 8 && p.ctype != 3 && !p.trns
        prev := zero
        for y in 0..p.h {
            at := y * (stride + 1)
            src := raw[at + 1..at + 1 + stride]
            dst := pix[y * p.w * ch..(y + 1) * p.w * ch]
            cur := if direct { dst } else { src }
            if !png_unfilter(raw[at], cur, src, prev, bpp) || (!direct && !png_expand(p, src, dst, p.w)) {
                return false
            }
            prev = cur
        }
        return true
    }
    line := alloc[u8](p.w * ch)
    at := 0
    for i in 0..7 {
        dx := i64(ADAM7_DX[i])
        dy := i64(ADAM7_DY[i])
        pw := pass_size(p.w, i64(ADAM7_X[i]), dx)
        ph := pass_size(p.h, i64(ADAM7_Y[i]), dy)
        if pw == 0 {
            continue
        }
        stride := (pw * bits + 7) / 8
        prev := zero[..stride]
        for y in 0..ph {
            src := raw[at + 1..at + 1 + stride]
            if !png_unfilter(raw[at], src, src, prev, bpp) || !png_expand(p, src, line, pw) {
                return false
            }
            o := ((i64(ADAM7_Y[i]) + y * dy) * p.w + i64(ADAM7_X[i])) * ch
            for x in 0..pw {
                copy(pix[o..o + ch], line[x * ch..x * ch + ch])
                o += dx * ch
            }
            prev = src
            at += stride + 1
        }
    }
    true
}

// reads and checks the IHDR fields at data[at..at + 13]
priv fn png_header(p *Png, data []u8, at i64) bool {
    p.w = be32(data, at)
    p.h = be32(data, at + 4)
    p.depth = i64(data[at + 8])
    p.ctype = i64(data[at + 9])
    p.interlace = i64(data[at + 12])
    d := p.depth
    p.nin = match p.ctype {
        0 => 1
        2 => 3
        3 => 1
        4 => 2
        6 => 4
        _ => 0
    }
    // allowed depths: grey 1-16, palette 1-8, everything else 8 or 16
    depth_ok := d == 8 || (d == 16 && p.ctype != 3) || ((d == 1 || d == 2 || d == 4) && p.nin == 1)
    p.nin != 0 && depth_ok && p.w > 0 && p.h > 0 && p.w <= MAX_DIM && p.h <= MAX_DIM &&
        data[at + 10] == 0 && data[at + 11] == 0 && p.interlace <= 1
}

// Decodes a PNG file held in memory: every colour type, bit depth and interlacing; all CRCs and
// the Adler-32 are verified. The image has 1 (grey), 2 (grey + alpha), 3 (RGB) or 4 (RGBA)
// channels as stored in the file; palettes are expanded to RGB, or RGBA with a tRNS chunk, and
// 16-bit samples keep their high byte. Returns false for anything malformed. Allocates only
// the pixels (working memory is released again).
fn png_decode(data []u8) (Image, bool) {
    var none Image
    var p Png
    n := len(data)
    if n < 57 || data[..8] != "\x89PNG\r\n\x1a\n" {
        return (none, false)
    }
    pos := 8
    idat := 0       // offset of the first IDAT chunk
    nidat := 0
    zlen := 0       // total length of the IDAT data
    kind := ""
    while kind != "IEND" {
        if pos + 12 > n {
            return (none, false)
        }
        clen := be32(data, pos)
        body := pos + 8
        if clen > n - pos - 12 || u32(be32(data, body + clen)) != crc32(data[pos + 4..body + clen]) {
            return (none, false)
        }
        kind = data[pos + 4..body]
        if (pos == 8) != (kind == "IHDR") {
            return (none, false)
        }
        if kind == "IHDR" {
            if clen != 13 || !png_header(&p, data, body) {
                return (none, false)
            }
        } else if kind == "PLTE" {
            if p.npal != 0 || nidat != 0 || clen == 0 || clen % 3 != 0 || clen > 768 {
                return (none, false)
            }
            p.npal = clen / 3
            for i in 0..p.npal {
                copy(p.pal[i * 4..i * 4 + 3], data[body + i * 3..body + i * 3 + 3])
                p.pal[i * 4 + 3] = 255
            }
        } else if kind == "tRNS" {
            // a transparent colour for grey and RGB, alpha values for a palette, not allowed otherwise
            want := match p.ctype {
                0 => 2
                2 => 6
                3 => min(clen, p.npal)
                _ => -1
            }
            if nidat != 0 || clen != want {
                return (none, false)
            }
            p.trns = true
            for i in 0..clen {
                if p.ctype == 3 {
                    p.pal[i * 4 + 3] = data[body + i]
                } else if i & 1 == 0 {
                    p.key[i >> 1] = be16(data, body + i)
                }
            }
        } else if kind == "IDAT" {
            if nidat == 0 {
                idat = pos
            }
            nidat += 1
            zlen += clen
        } else if kind != "IEND" && kind[0] & 0x20 == 0 {
            // a critical chunk this decoder does not know
            return (none, false)
        }
        pos = body + clen + 4
    }
    p.channels = if p.ctype == 3 { 3 } else { p.nin }
    if p.trns {
        p.channels += 1
    }
    rawn := png_raw_size(&p)
    // deflate cannot expand by more than 1032:1, so short data for a huge image is rejected
    // before anything is allocated
    if nidat == 0 || (p.ctype == 3 && p.npal == 0) || rawn > zlen * 1032 + 1024 || p.w * p.h * p.channels > MAX_BYTES {
        return (none, false)
    }
    m0 := mark()
    img := image_new(p.w, p.h, p.channels)
    m := mark()
    z := data[idat + 8..idat + 8 + be32(data, idat)]
    if nidat > 1 {
        z = alloc[u8](zlen)
        o := 0
        q := idat
        while q < pos {
            clen := be32(data, q)
            if data[q + 4..q + 8] == "IDAT" {
                copy(z[o..o + clen], data[q + 8..q + 8 + clen])
                o += clen
            }
            q += clen + 12
        }
    }
    raw := alloc[u8](rawn)
    got, ok := zlib_decompress_into(z, raw)
    ok = ok && got == rawn && png_rows(&p, raw, img.pix)
    release(m)
    if !ok {
        release(m0)
        return (none, false)
    }
    (img, true)
}

// Filters the row cur with filter type ft into dst (prev is the row above); returns the sum of
// the filtered bytes taken as signed values, the usual measure of how well a filter fits.
priv fn png_filter(ft i64, dst []u8, cur []u8, prev []u8, bpp i64) i64 {
    sum := 0
    for i in 0..len(cur) {
        a := if i >= bpp { i64(cur[i - bpp]) } else { 0 }
        b := i64(prev[i])
        pred := match ft {
            0 => 0
            1 => a
            2 => b
            3 => (a + b) >> 1
            _ => paeth(a, b, if i >= bpp { i64(prev[i - bpp]) } else { 0 })
        }
        v := cur[i] - u8(pred)
        dst[i] = v
        sum += if v < 128 { i64(v) } else { 256 - i64(v) }
    }
    sum
}

// writes the length and CRC of the chunk whose type and data are out[at + 4..end]; returns the offset after it
priv fn png_seal(out []u8, at i64, end i64) i64 {
    put_be32(out, at, end - at - 8)
    put_be32(out, end, i64(crc32(out[at + 4..end])))
    end + 4
}

// Encodes an image as a PNG file in memory (allocates the result): 8 bits per sample, colour
// type by channel count, the best of the five filters chosen per scanline, deflate-compressed.
// The image must not be empty.
fn png_encode(img Image) []u8 {
    assert img.w > 0 && img.h > 0, "png_encode: empty image"
    ch := img.channels
    stride := img.w * ch
    rawn := (stride + 1) * img.h
    out := alloc[u8](8 + 25 + 12 + 6 + deflate_bound(rawn) + 12)
    m := mark()
    // filter every scanline with the type that gives the smallest sum
    raw := alloc[u8](rawn)
    try := alloc[u8](stride)
    prev := alloc[u8](stride)
    for y in 0..img.h {
        cur := img.pix[y * stride..(y + 1) * stride]
        row := raw[y * (stride + 1) + 1..(y + 1) * (stride + 1)]
        best := png_filter(0, row, cur, prev, ch)
        for ft in 1..5 {
            sum := png_filter(ft, try, cur, prev, ch)
            if sum < best {
                best = sum
                raw[y * (stride + 1)] = u8(ft)
                copy(row, try)
            }
        }
        prev = cur
    }
    copy(out, "\x89PNG\r\n\x1a\n")
    copy(out[12..], "IHDR")
    put_be32(out, 16, img.w)
    put_be32(out, 20, img.h)
    out[24] = 8
    out[25] = match ch {
        1 => 0
        2 => 4
        3 => 2
        _ => 6
    }
    at := png_seal(out, 8, 29)
    copy(out[at + 4..], "IDAT\x78\x9C")
    var w BitWriter
    w.buf = out
    w.n = at + 10
    deflate_body(&w, raw)
    put_be32(out, w.n, i64(adler32(raw)))
    at = png_seal(out, at, w.n + 4)
    copy(out[at + 4..], "IEND")
    at = png_seal(out, at, at + 8)
    release(m)
    out[..at]
}

// ---------- BMP ----------
// the bits of v selected by mask, scaled to 0..255
priv inline fn bmp_field(v i64, mask i64) u8 {
    m := mask >> ctz(mask)
    x := (v & mask) >> ctz(mask)
    u8(if m == 255 { x } else { (x * 255 + (m >> 1)) / m })
}

// true if mask is a single run of 1 bits
priv inline fn bmp_mask_ok(mask i64) bool {
    m := mask >> ctz(mask)
    mask != 0 && m & (m + 1) == 0
}

// Decodes a BMP file held in memory: uncompressed 24- and 32-bit (also with bit-field masks)
// and 1/4/8-bit palettised images, bottom-up or top-down, with a BITMAPINFOHEADER, V4 or V5
// header. Palettised and 24-bit images give 3 channels; 32-bit images give 4 (alpha 255
// everywhere if the file stores none), or 3 if its bit fields define no alpha. Returns false
// for anything else. Allocates only the pixels.
fn bmp_decode(data []u8) (Image, bool) {
    var none Image
    n := len(data)
    if n < 54 || data[0] != 'B' || data[1] != 'M' {
        return (none, false)
    }
    off := le32(data, 10)
    hsize := le32(data, 14)
    w := i64(i32(le32(data, 18)))
    h := i64(i32(le32(data, 22)))
    bpp := le16(data, 28)
    comp := le32(data, 30)
    bottom_up := h > 0
    h = abs(h)
    if (hsize != 40 && hsize != 52 && hsize != 56 && hsize != 108 && hsize != 124) || 14 + hsize > n ||
        w <= 0 || h == 0 || w > MAX_DIM || h > MAX_DIM || le16(data, 26) != 1 {
        return (none, false)
    }
    rmask := 0xFF0000
    gmask := 0xFF00
    bmask := 0xFF
    amask := 0
    channels := 3
    pal := 14 + hsize
    npal := 0
    if bpp == 1 || bpp == 4 || bpp == 8 {
        npal = le32(data, 46)
        if npal == 0 {
            npal = 1 << bpp
        }
        if comp != 0 || npal > 1 << bpp || pal + npal * 4 > n {
            return (none, false)
        }
    } else if bpp == 32 && (comp == 3 || comp == 6) {
        // bit fields: the masks follow the 40 header bytes (inside a larger header or after a short one)
        if n < 70 {
            return (none, false)
        }
        rmask = le32(data, 54)
        gmask = le32(data, 58)
        bmask = le32(data, 62)
        if hsize >= 56 || comp == 6 {
            amask = le32(data, 66)
        }
        if !bmp_mask_ok(rmask) || !bmp_mask_ok(gmask) || !bmp_mask_ok(bmask) || (amask != 0 && !bmp_mask_ok(amask)) {
            return (none, false)
        }
        if amask != 0 {
            channels = 4
        }
    } else if bpp == 32 && comp == 0 {
        amask = 0xFF000000
        channels = 4
    } else if bpp != 24 || comp != 0 {
        return (none, false)
    }
    // rows are padded to 4 bytes; the padding of the last row in the file may be missing
    stride := (w * bpp + 31) / 32 * 4
    if off > n || stride * (h - 1) + (w * bpp + 7) / 8 > n - off || w * h * channels > MAX_BYTES {
        return (none, false)
    }
    m := mark()
    img := image_new(w, h, channels)
    pix := img.pix
    opaque := 0     // OR of all alpha values
    o := 0
    for y in 0..h {
        row := data[off + (if bottom_up { h - 1 - y } else { y }) * stride..]
        for x in 0..w {
            if bpp <= 8 {
                i := i64(row[x * bpp >> 3]) >> (8 - bpp - (x * bpp & 7)) & ((1 << bpp) - 1)
                if i >= npal {
                    release(m)
                    return (none, false)
                }
                pix[o] = data[pal + i * 4 + 2]
                pix[o + 1] = data[pal + i * 4 + 1]
                pix[o + 2] = data[pal + i * 4]
            } else if bpp == 24 {
                pix[o] = row[x * 3 + 2]
                pix[o + 1] = row[x * 3 + 1]
                pix[o + 2] = row[x * 3]
            } else {
                v := le32(row, x * 4)
                pix[o] = bmp_field(v, rmask)
                pix[o + 1] = bmp_field(v, gmask)
                pix[o + 2] = bmp_field(v, bmask)
                if channels == 4 {
                    pix[o + 3] = bmp_field(v, amask)
                    opaque |= v & amask
                }
            }
            o += channels
        }
    }
    if channels == 4 && opaque == 0 {
        // the fourth byte was never used as alpha: the image is opaque
        for i in 3..len(pix) by 4 {
            pix[i] = 255
        }
    }
    (img, true)
}

// Encodes an image as a BMP file in memory (allocates the result): 24-bit for 1 and 3 channels,
// 32-bit with an alpha mask (V4 header) for 2 and 4 channels. The image must not be empty.
fn bmp_encode(img Image) []u8 {
    assert img.w > 0 && img.h > 0, "bmp_encode: empty image"
    alpha := img.channels == 2 || img.channels == 4
    bytes := if alpha { 4 } else { 3 }
    hsize := if alpha { 108 } else { 40 }
    stride := (img.w * bytes + 3) & ~3
    off := 14 + hsize
    out := alloc[u8](off + stride * img.h)
    out[0] = 'B'
    out[1] = 'M'
    put_le32(out, 2, len(out))
    put_le32(out, 10, off)
    put_le32(out, 14, hsize)
    put_le32(out, 18, img.w)
    put_le32(out, 22, img.h)
    put_le16(out, 26, 1)
    put_le16(out, 28, bytes * 8)
    put_le32(out, 34, stride * img.h)
    // 72 dpi
    put_le32(out, 38, 2835)
    put_le32(out, 42, 2835)
    if alpha {
        // bit fields for B, G, R, A byte order and the sRGB colour space tag
        put_le32(out, 30, 3)
        put_le32(out, 54, 0xFF0000)
        put_le32(out, 58, 0xFF00)
        put_le32(out, 62, 0xFF)
        put_le32(out, 66, 0xFF000000)
        put_le32(out, 70, 0x73524742)
    }
    for y in 0..img.h {
        o := off + (img.h - 1 - y) * stride
        for x in 0..img.w {
            r, g, b, a := rgba(img, (y * img.w + x) * img.channels)
            out[o] = b
            out[o + 1] = g
            out[o + 2] = r
            if alpha {
                out[o + 3] = a
            }
            o += bytes
        }
    }
    out
}

// ---------- files ----------
// decodes a PNG or BMP file held in memory, told apart by its signature
fn image_decode(data []u8) (Image, bool) {
    if len(data) >= 2 && data[0] == 'B' && data[1] == 'M' {
        return bmp_decode(data)
    }
    png_decode(data)
}

// Loads a PNG or BMP file. Allocates the pixels; the file's bytes stay in the arena too.
fn image_load(path str) (Image, bool) {
    data, ok := read_file(path)
    if !ok {
        var none Image
        return (none, false)
    }
    image_decode(data)
}

// Loads a PNG file (see png_decode). Allocates the pixels; the file's bytes stay in the arena too.
fn png_load(path str) (Image, bool) {
    data, ok := read_file(path)
    if !ok {
        var none Image
        return (none, false)
    }
    png_decode(data)
}

// Loads a BMP file (see bmp_decode). Allocates the pixels; the file's bytes stay in the arena too.
fn bmp_load(path str) (Image, bool) {
    data, ok := read_file(path)
    if !ok {
        var none Image
        return (none, false)
    }
    bmp_decode(data)
}

// writes the image as a PNG file; false if the file cannot be written (leaves nothing in the arena)
fn png_save(path str, img Image) bool {
    m := mark()
    ok := write_file(path, png_encode(img))
    release(m)
    ok
}

// writes the image as a BMP file; false if the file cannot be written (leaves nothing in the arena)
fn bmp_save(path str, img Image) bool {
    m := mark()
    ok := write_file(path, bmp_encode(img))
    release(m)
    ok
}
