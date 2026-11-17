// std.audio_vorbis: Ogg Vorbis I decoding for std.audio, which loads this file (a program
// writes `use std.audio`). Pure AL, no library: the Ogg page and packet layer (CRC-checked),
// the three Vorbis headers, Huffman codebooks with VQ lookup, floor type 1, residue types
// 0, 1 and 2, channel coupling, the inverse MDCT (an N/4-point complex FFT), windowing and
// overlap-add. Floor type 0 (an LSP floor no current encoder writes) is refused.
//
// Two interfaces: ogg_decode / ogg_load decode a whole file into a Sound, and an OggStream
// decodes packet by packet (ogg_open, ogg_read, ogg_seek / ogg_rewind) without allocating
// after ogg_open, which play_stream plugs into the mixer for music.
//
// Malformed input never stops the program: every length and index taken from the file is
// checked, and decoding returns failure with a reason in ogg_error() / st.error. The decoded
// PCM follows libvorbis: the same sample count (granule positions trim the start and the end)
// and the same samples up to float rounding.

// ---- bit reader (Vorbis packs bits least significant first) ----

priv struct Bits {
    data: str
    pos: i64
    acc: u64
    n: i64
    eop: bool
}

priv fn fill(b: *Bits) {
    while b.n <= 56 && b.pos < len(b.data) {
        b.acc |= u64(b.data[b.pos]) << b.n
        b.pos += 1
        b.n += 8
    }
}

// the next k bits (k <= 32); past the end of the packet 0, and b.eop is set
priv fn get(b: *Bits, k: i64) -> i64 {
    if b.n < k {
        fill(b)
        if b.n < k {
            b.eop = true
            b.n = 0
            b.acc = 0
            return 0
        }
    }
    v := i64(b.acc & ((u64(1) << k) - 1))
    b.acc >>= k
    b.n -= k
    v
}

// bits left in the packet
priv fn left(b: *Bits) -> i64 {
    (len(b.data) - b.pos) * 8 + b.n
}

priv fn ilog(x: i64) -> i64 {
    if x <= 0 {
        return 0
    }
    64 - i64(clz(u64(x)))
}

priv fn rev32(x: u32) -> u32 {
    x = ((x >> 1) & 0x55555555) | ((x & 0x55555555) << 1)
    x = ((x >> 2) & 0x33333333) | ((x & 0x33333333) << 2)
    x = ((x >> 4) & 0x0F0F0F0F) | ((x & 0x0F0F0F0F) << 4)
    bswap(x)
}

// ---- codebooks ----

priv const FAST_BITS = 10
priv const MAX_ENTRIES = 1 << 20      // entries of one codebook (the format allows 2^24; encoders use thousands)
priv const MAX_VQ = 1 << 22           // floats of one codebook's vector table

priv struct Book {
    dims: i64
    entries: i64
    lens: []u8           // codeword length per entry, 0: unused
    fmask: i64
    fast: []i32          // entry of the codeword in the low bits, or -1 (longer, or none)
    sorted: []u32        // all codewords, most significant bit first, left aligned, ascending
    sorted_entry: []i32
    vq: []f32            // entries * dims vector values (lookup types 1 and 2), else empty
}

// decodes one codeword; -1 (and b.eop) at the end of the packet or for a codeword not in the book
priv fn decode(b: *Bits, c: *Book) -> i64 {
    if b.n < 32 {
        fill(b)
    }
    e := c.fast[i64(b.acc) & c.fmask]
    if e >= 0 {
        l := i64(c.lens[e])
        if l <= b.n {
            b.acc >>= l
            b.n -= l
            return i64(e)
        }
        b.eop = true
        return -1
    }
    decode_slow(b, c)
}

priv fn decode_slow(b: *Bits, c: *Book) -> i64 {
    s := c.sorted
    if len(s) == 0 {
        b.eop = true
        return -1
    }
    code := rev32(u32(b.acc & 0xFFFFFFFF))
    x := 0
    n := len(s)
    while n > 1 {
        m := x + (n >> 1)
        if s[m] <= code {
            x = m
            n -= n >> 1
        } else {
            n >>= 1
        }
    }
    e := i64(c.sorted_entry[x])
    l := i64(c.lens[e])
    if s[x] > code || ((s[x] ^ code) >> (32 - l)) != 0 || l > b.n {
        b.eop = true
        return -1
    }
    b.acc >>= l
    b.n -= l
    e
}

// Vorbis' 32-bit float format: 21-bit mantissa, 10-bit exponent biased by 788, sign
priv fn unpack_float(x: i64) -> f32 {
    m := f64(x & 0x1FFFFF)
    e := (x >> 21) & 0x3FF
    v := m * pow(2.0, f64(e - 788))
    if x & 0x80000000 != 0 {
        v = -v
    }
    f32(v)
}

// the largest r with r^dims <= entries
priv fn lookup1_values(entries: i64, dims: i64) -> i64 {
    r := i64(floor(pow(f64(entries), 1.0 / f64(dims))))
    fn power_le(r: i64, dims: i64, limit: i64) -> bool {
        p := 1
        for i in 0..dims {
            p *= r
            if p > limit {
                return false
            }
        }
        true
    }
    while power_le(r + 1, dims, entries) {
        r += 1
    }
    while r > 0 && !power_le(r, dims, entries) {
        r -= 1
    }
    r
}

priv fn read_book(b: *Bits, c: *Book) -> str {
    if get(b, 24) != 0x564342 {
        return "bad codebook sync pattern"
    }
    dims := get(b, 16)
    entries := get(b, 24)
    if entries > MAX_ENTRIES {
        return "codebook too large"
    }
    if dims == 0 && entries > 0 {
        return "codebook with 0 dimensions"
    }
    c.dims = dims
    c.entries = entries
    lens := alloc[u8](entries)
    if get(b, 1) == 0 {
        sparse := get(b, 1) == 1
        if left(b) < entries {
            return "setup header truncated"
        }
        for i in 0..entries {
            if !sparse || get(b, 1) == 1 {
                lens[i] = u8(get(b, 5) + 1)
            }
        }
    } else {
        cur := 0
        l := get(b, 5) + 1
        while cur < entries {
            num := get(b, ilog(entries - cur))
            if b.eop || l > 32 || num > entries - cur {
                return "bad codebook lengths"
            }
            for i in cur..cur + num {
                lens[i] = u8(l)
            }
            cur += num
            l += 1
        }
    }
    c.lens = lens
    lookup := get(b, 4)
    if lookup == 1 || lookup == 2 {
        minv := unpack_float(get(b, 32))
        delta := unpack_float(get(b, 32))
        vbits := get(b, 4) + 1
        seq := get(b, 1) == 1
        nvals := if lookup == 1 { lookup1_values(entries, dims) } else { entries * dims }
        if nvals * vbits > left(b) {
            return "setup header truncated"
        }
        if entries * dims > MAX_VQ {
            return "codebook too large"
        }
        mult := alloc[f32](nvals)
        for i in 0..nvals {
            mult[i] = f32(get(b, vbits))
        }
        vq := alloc[f32](entries * dims)
        for e in 0..entries {
            last: f32 = 0.0
            div := 1
            for i in 0..dims {
                mo := if lookup == 1 { (e / div) % nvals } else { e * dims + i }
                v := mult[mo] * delta + minv + last
                vq[e * dims + i] = v
                if seq {
                    last = v
                }
                if lookup == 1 {
                    div *= nvals
                }
            }
        }
        c.vq = vq
    } else if lookup != 0 {
        return "bad codebook lookup type"
    }
    if b.eop {
        return "setup header truncated"
    }
    huffman(c)
}

// assigns the codewords (each entry gets the lowest free codeword of its length, in entry
// order) and builds the decoding tables; an over- or underfull code is an error, except a
// book with a single entry
priv fn huffman(c: *Book) -> str {
    avail: [33]u64
    codes := alloc[u32](c.entries)
    used := 0
    maxlen := 0
    for i in 0..c.entries {
        l := i64(c.lens[i])
        if l == 0 {
            continue
        }
        maxlen = max(maxlen, l)
        if used == 0 {
            codes[i] = 0
            for k in 1..=l {
                avail[k] = u64(1) << (32 - k)
            }
        } else {
            z := l
            while z > 0 && avail[z] == 0 {
                z -= 1
            }
            if z == 0 {
                return "codebook overspecified"
            }
            res := avail[z]
            avail[z] = 0
            codes[i] = u32(res)
            for y in z + 1..=l {
                avail[y] = res + (u64(1) << (32 - y))
            }
        }
        used += 1
    }
    if used > 1 {
        for k in 1..33 {
            if avail[k] != 0 {
                return "codebook underspecified"
            }
        }
    }
    fb := max(min(FAST_BITS, maxlen), 1)
    c.fmask = (1 << fb) - 1
    c.fast = alloc[i32](1 << fb)
    fill(c.fast, -1)
    c.sorted = alloc[u32](used)
    c.sorted_entry = alloc[i32](used)
    k := 0
    for i in 0..c.entries {
        l := i64(c.lens[i])
        if l == 0 {
            continue
        }
        if l <= fb {
            r := i64(rev32(codes[i]))
            for f in 0..1 << (fb - l) {
                c.fast[r | f << l] = i32(i)
            }
        }
        c.sorted[k] = codes[i]
        c.sorted_entry[k] = i32(i)
        k += 1
    }
    // insertion sort is too slow for big books: sort an index by codeword
    order := alloc[i64](used)
    for i in 0..used {
        order[i] = i
    }
    sort_by(order, c.sorted, fn(s: []u32, a: i64, b: i64) -> bool { s[a] < s[b] })
    s2 := alloc[u32](used)
    e2 := alloc[i32](used)
    for i in 0..used {
        s2[i] = c.sorted[order[i]]
        e2[i] = c.sorted_entry[order[i]]
    }
    c.sorted = s2
    c.sorted_entry = e2
    ""
}

// ---- setup structures ----

priv struct Floor {
    partitions: i64
    pclass: []i64
    cdim: []i64          // per class
    csub: []i64
    cmaster: []i64
    subbooks: []i64      // class * 8 + subclass: book or -1
    mult: i64
    range: i64
    rbits: i64
    values: i64
    xs: []i64
    sorted: []i64        // indices of xs in ascending order of x
    lo: []i64
    hi: []i64
}

priv struct Residue {
    typ: i64
    begin: i64
    end: i64
    psize: i64
    nclass: i64
    classbook: i64
    books: []i64         // class * 8 + pass: book or -1
}

priv struct Mapping {
    submaps: i64
    mag: []i64
    ang: []i64
    mux: []i64
    sub_floor: []i64
    sub_res: []i64
}

priv struct Mode {
    long: bool
    mapping: i64
}

// IMDCT tables of one block size n: pre/post twiddles e^(-i pi (k + 1/8) / (n/2)) and the
// n/4-point FFT's twiddles and bit-reversal order
priv struct Tw {
    c: []f32
    s: []f32
    fc: []f32
    fs: []f32
    rev: []i64
}

priv struct Page {
    off: i64
    nseg: i64
    body: i64
    gran: i64
    flags: i64
    last_end: i64        // index of the last segment that ends a packet, -1 if none
    c0: i64              // position of the first packet that starts on this page, -1 if none
}

// The decoder's state behind an OggStream.
priv struct Dec {
    data: str
    pages: []Page
    // packet iterator
    pi: i64
    si: i64
    bpos: i64
    assembling: bool
    pk: []u8
    pk_len: i64
    pk_page: i64
    pk_gran: i64
    pk_eos: bool
    bad_pk: bool
    // where the audio packets start
    a_pi: i64
    a_si: i64
    a_bpos: i64
    // setup
    channels: i64
    bs0: i64
    bs1: i64
    books: []Book
    floors: []Floor
    residues: []Residue
    maps: []Mapping
    modes: []Mode
    mode_bits: i64
    tw0: Tw
    tw1: Tw
    win0: []f32
    win1: []f32
    dbtab: []f32
    // position bookkeeping (positions are in frames from the centre of the first block)
    skip: i64            // positions before this are dropped (the start trim)
    end_abs: i64         // positions from this on are dropped (the end trim)
    lo_abs: i64          // first position ogg_read returns (skip, or a seek target)
    cpos: i64            // centre of the last decoded block
    prev_n: i64          // its size, 0 before the first block
    prev_flat: i64
    prev_ov: i64
    done: bool
    // output of the last packet: outb[c][out_l..out_r)
    out_l: i64
    out_r: i64
    // buffers
    chan: [][]f32
    prev: [][]f32
    outb: [][]f32
    fy: [][]i64
    floor_of: []i64
    fused: []bool
    nodec: []bool
    finaly: []i64
    step2: []bool
    classif: []i32
    cls_stride: i64
    chs: []i64
    re: []f32
    im: []f32
    u: []f32
    mixbuf: []f32        // the read-ahead window of a voice that plays the stream
}

// ---- streams (public) ----

// A Vorbis stream being decoded. `rate` and `channels` are the format, `frames` the length in
// frames, `pos` the next frame ogg_read returns, `error` why decoding stopped early ("" if
// it did not). The data given to ogg_open is referenced, not copied.
struct OggStream {
    rate: i64
    channels: i64
    frames: i64
    pos: i64
    error: str
    dec: *Dec
}

priv ogg_err: str

// Why the last ogg_open / ogg_decode / ogg_load failed ("" after a success).
fn ogg_error() -> str {
    ogg_err
}

priv crc_table: [256]u32
priv crc_ready: bool

priv fn ogg_crc(d: str) -> u32 {
    if !crc_ready {
        for i in 0..256 {
            r := u32(i) << 24
            for k in 0..8 {
                r = if r & 0x80000000 != 0 { (r << 1) ^ 0x04C11DB7 } else { r << 1 }
            }
            crc_table[i] = r
        }
        crc_ready = true
    }
    crc: u32 = 0
    for i in 0..len(d) {
        x := d[i]
        if i >= 22 && i < 26 {
            x = 0
        }
        crc = (crc << 8) ^ crc_table[i64((crc >> 24) ^ u32(x))]
    }
    crc
}

priv fn le(d: str, at: i64, n: i64) -> i64 {
    v := 0
    for i in 0..n {
        v |= i64(d[at + i]) << (8 * i)
    }
    v
}

// reads the page structure of the whole stream: checks every page (capture pattern, version,
// lengths, CRC, sequence numbers) and keeps those of the first Vorbis stream up to its last
// page. Returns the size of the largest packet.
priv fn scan(d: *Dec) -> (i64, str) {
    data := d.data
    pages := vec[Page]()
    p := 0
    serial := -1
    seq := 0
    biggest := 0
    cur := 0
    while p < len(data) {
        if p + 27 > len(data) {
            return (0, fmt("truncated page at byte ", p))
        }
        if data[p..p + 4] != "OggS" {
            return (0, fmt("no Ogg page at byte ", p))
        }
        if data[p + 4] != 0 {
            return (0, fmt("unknown Ogg version at byte ", p))
        }
        flags := i64(data[p + 5])
        gran := le(data, p + 6, 8)
        ser := le(data, p + 14, 4)
        pseq := le(data, p + 18, 4)
        crc := le(data, p + 22, 4)
        nseg := i64(data[p + 26])
        body := p + 27 + nseg
        if body > len(data) {
            return (0, fmt("truncated page at byte ", p))
        }
        size := 0
        last_end := -1
        for i in 0..nseg {
            l := i64(data[p + 27 + i])
            size += l
            if l < 255 {
                last_end = i
            }
        }
        if body + size > len(data) {
            return (0, fmt("truncated page at byte ", p))
        }
        if i64(ogg_crc(data[p..body + size])) != crc {
            return (0, fmt("CRC mismatch in the page at byte ", p))
        }
        if serial < 0 {
            if flags & 2 == 0 {
                return (0, "not an Ogg Vorbis stream")
            }
            if size >= 7 && data[body] == 1 && data[body + 1..body + 7] == "vorbis" {
                serial = ser
                seq = pseq
            }
        }
        if serial >= 0 && ser == serial {
            if pseq != seq {
                return (0, fmt("missing page before byte ", p))
            }
            seq = (seq + 1) & 0xFFFFFFFF
            if flags & 1 == 0 {
                cur = 0
            }
            for i in 0..nseg {
                l := i64(data[p + 27 + i])
                cur += l
                if l < 255 {
                    biggest = max(biggest, cur)
                    cur = 0
                }
            }
            biggest = max(biggest, cur)
            pages.push(Page{off: p, nseg: nseg, body: body, gran: gran, flags: flags, last_end: last_end, c0: -1})
            if flags & 4 != 0 {
                break
            }
        }
        p = body + size
    }
    if serial < 0 {
        return (0, "not an Ogg Vorbis stream")
    }
    d.pages = pages.items()
    (biggest, "")
}

priv fn pk_append(d: *Dec, part: str) {
    if d.pk_len + len(part) > len(d.pk) {
        d.bad_pk = true
        return
    }
    copy(d.pk[d.pk_len..], part)
    d.pk_len += len(part)
}

// the next packet of the stream; false at its end. d.pk_gran is the page's granule position
// if the packet is the last one that ends on its page (else -1), d.pk_eos is set for the
// last packet of the stream, d.pk_page is the page the packet starts on.
priv fn next_packet(d: *Dec) -> (str, bool) {
    loop {
        if d.pi >= len(d.pages) {
            return ("", false)
        }
        pg := d.pages[d.pi]
        lace := d.data[pg.off + 27..pg.off + 27 + pg.nseg]
        if d.si == 0 {
            d.bpos = pg.body
            if pg.flags & 1 != 0 && !d.assembling {
                // the page continues a packet we do not have
                while d.si < pg.nseg {
                    l := i64(lace[d.si])
                    d.si += 1
                    d.bpos += l
                    if l < 255 {
                        break
                    }
                }
            } else if pg.flags & 1 == 0 && d.assembling {
                d.assembling = false
                d.pk_len = 0
            }
        }
        start := d.bpos
        size := 0
        segs := 0
        done := false
        while d.si < pg.nseg {
            l := i64(lace[d.si])
            d.si += 1
            segs += 1
            size += l
            if l < 255 {
                done = true
                break
            }
        }
        d.bpos = start + size
        part := d.data[start..start + size]
        if done {
            lastp := d.si - 1 == pg.last_end
            d.pk_gran = if lastp { pg.gran } else { -1 }
            d.pk_eos = lastp && pg.flags & 4 != 0
            if d.assembling {
                pk_append(d, part)
                d.assembling = false
                n := d.pk_len
                d.pk_len = 0
                return (d.pk[..n], true)
            }
            d.pk_page = d.pi
            return (part, true)
        }
        if segs > 0 {
            if !d.assembling {
                d.assembling = true
                d.pk_len = 0
                d.pk_page = d.pi
            }
            pk_append(d, part)
        }
        d.pi += 1
        d.si = 0
    }
}

// ---- headers ----

priv fn read_id(d: *Dec, rate: *i64, p: str) -> str {
    if len(p) < 30 || p[0] != 1 || p[1..7] != "vorbis" {
        return "not an Ogg Vorbis stream"
    }
    if le(p, 7, 4) != 0 {
        return "unknown Vorbis version"
    }
    d.channels = i64(p[11])
    *rate = le(p, 12, 4)
    e0 := i64(p[28] & 15)
    e1 := i64(p[28] >> 4)
    if d.channels == 0 || *rate == 0 || e0 < 6 || e1 > 13 || e0 > e1 || p[29] & 1 == 0 {
        return "bad identification header"
    }
    d.bs0 = 1 << e0
    d.bs1 = 1 << e1
    ""
}

priv fn read_floor(d: *Dec, b: *Bits, f: *Floor) -> str {
    nb := len(d.books)
    f.partitions = get(b, 5)
    f.pclass = alloc[i64](f.partitions)
    maxc := -1
    for i in 0..f.partitions {
        f.pclass[i] = get(b, 4)
        maxc = max(maxc, f.pclass[i])
    }
    f.cdim = alloc[i64](maxc + 1)
    f.csub = alloc[i64](maxc + 1)
    f.cmaster = alloc[i64](maxc + 1)
    f.subbooks = alloc[i64]((maxc + 1) * 8)
    for i in 0..=maxc {
        f.cdim[i] = get(b, 3) + 1
        f.csub[i] = get(b, 2)
        if f.csub[i] != 0 {
            f.cmaster[i] = get(b, 8)
            if f.cmaster[i] >= nb {
                return "bad floor"
            }
        }
        for j in 0..1 << f.csub[i] {
            f.subbooks[i * 8 + j] = get(b, 8) - 1
            if f.subbooks[i * 8 + j] >= nb {
                return "bad floor"
            }
        }
    }
    f.mult = get(b, 2) + 1
    f.range = [4]i64{256, 128, 86, 64}[f.mult - 1]
    f.rbits = ilog(f.range - 1)
    rbits := get(b, 4)
    values := 2
    for i in 0..f.partitions {
        values += f.cdim[f.pclass[i]]
    }
    f.values = values
    f.xs = alloc[i64](values)
    f.xs[1] = 1 << rbits
    k := 2
    for i in 0..f.partitions {
        for j in 0..f.cdim[f.pclass[i]] {
            f.xs[k] = get(b, rbits)
            k += 1
        }
    }
    if b.eop {
        return "setup header truncated"
    }
    // x values must be distinct (the curve is drawn between neighbours)
    f.sorted = alloc[i64](values)
    for i in 0..values {
        f.sorted[i] = i
        for j in 0..i {
            if f.xs[i] == f.xs[j] {
                return "bad floor"
            }
        }
    }
    sort_by(f.sorted, f.xs, fn(xs: []i64, a: i64, b: i64) -> bool { xs[a] < xs[b] })
    f.lo = alloc[i64](values)
    f.hi = alloc[i64](values)
    for i in 2..values {
        lo := 0
        hi := 1
        for j in 0..i {
            if f.xs[j] < f.xs[i] && f.xs[j] > f.xs[lo] {
                lo = j
            }
            if f.xs[j] > f.xs[i] && f.xs[j] < f.xs[hi] {
                hi = j
            }
        }
        f.lo[i] = lo
        f.hi[i] = hi
    }
    ""
}

priv fn read_residue(d: *Dec, b: *Bits, r: *Residue) -> str {
    nb := len(d.books)
    r.begin = get(b, 24)
    r.end = get(b, 24)
    r.psize = get(b, 24) + 1
    r.nclass = get(b, 6) + 1
    r.classbook = get(b, 8)
    if r.classbook >= nb {
        return "bad residue"
    }
    cascade := alloc[i64](r.nclass)
    for i in 0..r.nclass {
        low := get(b, 3)
        high := if get(b, 1) == 1 { get(b, 5) } else { 0 }
        cascade[i] = high * 8 + low
    }
    r.books = alloc[i64](r.nclass * 8)
    for i in 0..r.nclass {
        for j in 0..8 {
            bk := -1
            if cascade[i] & (1 << j) != 0 {
                bk = get(b, 8)
                if bk >= nb || len(d.books[bk].vq) == 0 {
                    return "bad residue"
                }
            }
            r.books[i * 8 + j] = bk
        }
    }
    if d.books[r.classbook].dims == 0 {
        return "bad residue"
    }
    ""
}

priv fn read_mapping(d: *Dec, b: *Bits, m: *Mapping) -> str {
    ch := d.channels
    if get(b, 16) != 0 {
        return "bad mapping type"
    }
    m.submaps = if get(b, 1) == 1 { get(b, 4) + 1 } else { 1 }
    steps := if get(b, 1) == 1 { get(b, 8) + 1 } else { 0 }
    m.mag = alloc[i64](steps)
    m.ang = alloc[i64](steps)
    for i in 0..steps {
        m.mag[i] = get(b, ilog(ch - 1))
        m.ang[i] = get(b, ilog(ch - 1))
        if m.mag[i] == m.ang[i] || m.mag[i] >= ch || m.ang[i] >= ch {
            return "bad channel coupling"
        }
    }
    if get(b, 2) != 0 {
        return "bad mapping"
    }
    m.mux = alloc[i64](ch)
    if m.submaps > 1 {
        for c in 0..ch {
            m.mux[c] = get(b, 4)
            if m.mux[c] >= m.submaps {
                return "bad mapping"
            }
        }
    }
    m.sub_floor = alloc[i64](m.submaps)
    m.sub_res = alloc[i64](m.submaps)
    for s in 0..m.submaps {
        get(b, 8)
        m.sub_floor[s] = get(b, 8)
        m.sub_res[s] = get(b, 8)
        if m.sub_floor[s] >= len(d.floors) || m.sub_res[s] >= len(d.residues) {
            return "bad mapping"
        }
    }
    ""
}

priv fn read_setup(d: *Dec, p: str) -> str {
    if len(p) < 7 || p[0] != 5 || p[1..7] != "vorbis" {
        return "missing setup header"
    }
    bits := Bits{data: p[7..]}
    b := &bits
    d.books = alloc[Book](get(b, 8) + 1)
    for i in 0..len(d.books) {
        err := read_book(b, &d.books[i])
        if err != "" {
            return err
        }
    }
    ntime := get(b, 6) + 1
    for i in 0..ntime {
        if get(b, 16) != 0 {
            return "bad time domain transform"
        }
    }
    d.floors = alloc[Floor](get(b, 6) + 1)
    for i in 0..len(d.floors) {
        t := get(b, 16)
        if t == 0 {
            return "floor type 0 is not supported"
        }
        if t != 1 {
            return "bad floor type"
        }
        err := read_floor(d, b, &d.floors[i])
        if err != "" {
            return err
        }
    }
    d.residues = alloc[Residue](get(b, 6) + 1)
    for i in 0..len(d.residues) {
        r := &d.residues[i]
        r.typ = get(b, 16)
        if r.typ > 2 {
            return "bad residue type"
        }
        err := read_residue(d, b, r)
        if err != "" {
            return err
        }
    }
    d.maps = alloc[Mapping](get(b, 6) + 1)
    for i in 0..len(d.maps) {
        err := read_mapping(d, b, &d.maps[i])
        if err != "" {
            return err
        }
    }
    d.modes = alloc[Mode](get(b, 6) + 1)
    for i in 0..len(d.modes) {
        md := &d.modes[i]
        md.long = get(b, 1) == 1
        wt := get(b, 16)
        tt := get(b, 16)
        md.mapping = get(b, 8)
        if wt != 0 || tt != 0 || md.mapping >= len(d.maps) {
            return "bad mode"
        }
    }
    d.mode_bits = ilog(len(d.modes) - 1)
    if get(b, 1) != 1 || b.eop {
        return "setup header truncated"
    }
    ""
}

priv fn make_tw(n: i64) -> Tw {
    m := n / 2
    q := n / 4
    t := Tw{alloc[f32](q), alloc[f32](q), alloc[f32](q / 2), alloc[f32](q / 2), alloc[i64](q)}
    for k in 0..q {
        a := 3.141592653589793 * (f64(k) + 0.125) / f64(m)
        t.c[k] = f32(cos(a))
        t.s[k] = f32(sin(a))
    }
    for k in 0..q / 2 {
        a := 6.283185307179586 * f64(k) / f64(q)
        t.fc[k] = f32(cos(a))
        t.fs[k] = f32(sin(a))
    }
    bits := ilog(q) - 1
    for k in 0..q {
        r := 0
        for i in 0..bits {
            if k & (1 << i) != 0 {
                r |= 1 << (bits - 1 - i)
            }
        }
        t.rev[k] = r
    }
    t
}

// the rising half of the Vorbis window over l samples
priv fn make_win(l: i64) -> []f32 {
    w := alloc[f32](l)
    for j in 0..l {
        s := sin((f64(j) + 0.5) / f64(l) * 1.5707963267948966)
        w[j] = f32(sin(1.5707963267948966 * s * s))
    }
    w
}

// allocates the buffers of the decoder once the setup is known
priv fn prepare(d: *Dec) {
    ch := d.channels
    d.tw0 = make_tw(d.bs0)
    d.tw1 = make_tw(d.bs1)
    d.win0 = make_win(d.bs0 / 2)
    d.win1 = make_win(d.bs1 / 2)
    d.dbtab = alloc[f32](256)
    for i in 0..256 {
        d.dbtab[i] = f32(pow(10.0, 7.0 * f64(i - 255) / 256.0))
    }
    d.chan = alloc[[]f32](ch)
    d.prev = alloc[[]f32](ch)
    d.outb = alloc[[]f32](ch)
    d.fy = alloc[[]i64](ch)
    maxv := 2
    for f in d.floors {
        maxv = max(maxv, f.values)
    }
    for c in 0..ch {
        d.chan[c] = alloc[f32](d.bs1)
        d.prev[c] = alloc[f32](d.bs1 / 2)
        d.outb[c] = alloc[f32](d.bs1)
        d.fy[c] = alloc[i64](maxv)
    }
    d.finaly = alloc[i64](maxv)
    d.step2 = alloc[bool](maxv)
    d.floor_of = alloc[i64](ch)
    d.fused = alloc[bool](ch)
    d.nodec = alloc[bool](ch)
    d.chs = alloc[i64](ch)
    stride := 1
    for r in d.residues {
        actual := d.bs1 / 2 * (if r.typ == 2 { ch } else { 1 })
        nread := max(min(r.end, actual) - min(r.begin, actual), 0)
        stride = max(stride, nread / r.psize + d.books[r.classbook].dims)
    }
    d.cls_stride = stride
    d.classif = alloc[i32](stride * ch)
    d.re = alloc[f32](d.bs1 / 4)
    d.im = alloc[f32](d.bs1 / 4)
    d.u = alloc[f32](d.bs1 / 2)
    d.mixbuf = alloc[f32](OGG_MIX_FRAMES * ch)
}

priv const OGG_MIX_FRAMES = 1024

// ---- audio packets ----

priv fn floor_decode(d: *Dec, b: *Bits, f: *Floor, y: []i64) -> bool {
    if get(b, 1) == 0 {
        return false
    }
    y[0] = get(b, f.rbits)
    y[1] = get(b, f.rbits)
    off := 2
    for i in 0..f.partitions {
        cls := f.pclass[i]
        cdim := f.cdim[cls]
        cbits := f.csub[cls]
        csub := (1 << cbits) - 1
        cval := 0
        if cbits > 0 {
            cval = decode(b, &d.books[f.cmaster[cls]])
            if cval < 0 {
                return false
            }
        }
        for j in 0..cdim {
            book := f.subbooks[cls * 8 + (cval & csub)]
            cval >>= cbits
            if book >= 0 {
                v := decode(b, &d.books[book])
                if v < 0 {
                    return false
                }
                y[off + j] = v
            } else {
                y[off + j] = 0
            }
        }
        off += cdim
    }
    !b.eop
}

priv fn render_point(x0: i64, y0: i64, x1: i64, y1: i64, x: i64) -> i64 {
    dy := y1 - y0
    off := abs(dy) * (x - x0) / (x1 - x0)
    if dy < 0 { y0 - off } else { y0 + off }
}

// multiplies v[x0..min(x1, n)) by the floor line from (x0, y0) to (x1, y1)
priv fn render_line(x0: i64, y0: i64, x1: i64, y1: i64, v: []f32, n: i64, tab: []f32) {
    adx := x1 - x0
    if adx <= 0 {
        return
    }
    dy := y1 - y0
    base := dy / adx
    sy := if dy < 0 { base - 1 } else { base + 1 }
    ady := abs(dy) - abs(base) * adx
    end := min(x1, n)
    y := y0
    err := 0
    x := x0
    if x < end {
        v[x] *= tab[min(max(y, 0), 255)]
    }
    x += 1
    while x < end {
        err += ady
        if err >= adx {
            err -= adx
            y += sy
        } else {
            y += base
        }
        v[x] *= tab[min(max(y, 0), 255)]
        x += 1
    }
}

priv fn floor_render(d: *Dec, f: *Floor, y: []i64, v: []f32, n2: i64) {
    fin := d.finaly
    st := d.step2
    st[0] = true
    st[1] = true
    fin[0] = y[0]
    fin[1] = y[1]
    for i in 2..f.values {
        lo := f.lo[i]
        hi := f.hi[i]
        pred := render_point(f.xs[lo], fin[lo], f.xs[hi], fin[hi], f.xs[i])
        val := y[i]
        highroom := f.range - pred
        lowroom := pred
        room := if highroom < lowroom { highroom * 2 } else { lowroom * 2 }
        if val != 0 {
            st[lo] = true
            st[hi] = true
            st[i] = true
            if val >= room {
                fin[i] = if highroom > lowroom { val - lowroom + pred } else { pred - val + highroom - 1 }
            } else if val & 1 == 1 {
                fin[i] = pred - (val + 1) / 2
            } else {
                fin[i] = pred + val / 2
            }
        } else {
            st[i] = false
            fin[i] = pred
        }
    }
    lx := 0
    ly := fin[0] * f.mult
    for k in 1..f.values {
        i := f.sorted[k]
        if st[i] {
            hy := fin[i] * f.mult
            hx := f.xs[i]
            render_line(lx, ly, hx, hy, v, n2, d.dbtab)
            lx = hx
            ly = hy
        }
    }
    if lx < n2 {
        render_line(lx, ly, n2, ly, v, n2, d.dbtab)
    }
}

// adds one partition of residue values to v (format 0: interleaved by dimension; 1: in order)
priv fn partition(b: *Bits, bk: *Book, v: []f32, off: i64, psize: i64, typ: i64) -> bool {
    dims := bk.dims
    vq := bk.vq
    if typ == 0 {
        step := psize / dims
        for i in 0..step {
            e := decode(b, bk)
            if e < 0 {
                return false
            }
            for j in 0..dims {
                v[off + i + j * step] += vq[e * dims + j]
            }
        }
    } else {
        i := 0
        lim := min(psize, len(v) - off)
        while i < psize {
            e := decode(b, bk)
            if e < 0 {
                return false
            }
            for j in 0..dims {
                if i < lim {
                    v[off + i] += vq[e * dims + j]
                }
                i += 1
            }
        }
    }
    true
}

// format 2: one vector interleaving the channels chs[0..k): element t is chan[chs[t % k]][t / k]
priv fn partition2(d: *Dec, b: *Bits, bk: *Book, k: i64, off: i64, psize: i64, n2: i64) -> bool {
    dims := bk.dims
    vq := bk.vq
    c := off % k
    x := off / k
    i := 0
    while i < psize {
        e := decode(b, bk)
        if e < 0 {
            return false
        }
        for j in 0..dims {
            if x < n2 {
                d.chan[d.chs[c]][x] += vq[e * dims + j]
            }
            c += 1
            if c == k {
                c = 0
                x += 1
            }
            i += 1
        }
    }
    true
}

priv fn residue_decode(d: *Dec, r: *Residue, b: *Bits, k: i64, n2: i64) {
    chs := d.chs
    for j in 0..k {
        fill(d.chan[chs[j]][..n2], 0.0)
    }
    vectors := k
    actual := n2
    if r.typ == 2 {
        any := false
        for j in 0..k {
            if !d.nodec[chs[j]] {
                any = true
            }
        }
        if !any {
            return
        }
        vectors = 1
        actual = n2 * k
    }
    beg := min(r.begin, actual)
    end := min(r.end, actual)
    if end <= beg {
        return
    }
    parts := (end - beg) / r.psize
    cb := &d.books[r.classbook]
    cw := cb.dims
    stride := d.cls_stride
    cls := d.classif
    for pass in 0..8 {
        p := 0
        while p < parts {
            if pass == 0 {
                for j in 0..vectors {
                    if r.typ != 2 && d.nodec[chs[j]] {
                        continue
                    }
                    t := decode(b, cb)
                    if t < 0 {
                        return
                    }
                    for i in cw - 1..=0 by -1 {
                        cls[j * stride + p + i] = i32(t % r.nclass)
                        t /= r.nclass
                    }
                }
            }
            for i in 0..cw {
                if p >= parts {
                    break
                }
                for j in 0..vectors {
                    if r.typ != 2 && d.nodec[chs[j]] {
                        continue
                    }
                    book := r.books[i64(cls[j * stride + p]) * 8 + pass]
                    if book < 0 {
                        continue
                    }
                    off := beg + p * r.psize
                    ok := if r.typ == 2 {
                        partition2(d, b, &d.books[book], k, off, r.psize, n2)
                    } else {
                        partition(b, &d.books[book], d.chan[chs[j]][..n2], off, r.psize, r.typ)
                    }
                    if !ok {
                        return
                    }
                }
                p += 1
            }
        }
    }
}

// in-place forward complex FFT of q points (re, im in bit-reversed order on entry)
priv fn fft(re: []f32, im: []f32, q: i64, fc: []f32, fs: []f32) {
    size := 2
    while size <= q {
        half := size / 2
        tstep := q / size
        for start in 0..q by size {
            for k in 0..half {
                c := fc[k * tstep]
                s := fs[k * tstep]
                i := start + k
                j := i + half
                tr := re[j] * c + im[j] * s
                ti := im[j] * c - re[j] * s
                re[j] = re[i] - tr
                im[j] = im[i] - ti
                re[i] += tr
                im[i] += ti
            }
        }
        size *= 2
    }
}

// x[0..n/2) holds the spectrum; afterwards x[0..n) holds
// y[i] = sum over k of x[k] cos(pi / (2 n) (2 i + 1 + n / 2) (2 k + 1))
priv fn imdct(d: *Dec, x: []f32, n: i64, t: *Tw) {
    m := n / 2
    q := n / 4
    re := d.re
    im := d.im
    tc := t.c
    ts := t.s
    rev := t.rev
    for j in 0..q {
        a := x[2 * j]
        b := x[m - 1 - 2 * j]
        c := tc[j]
        s := ts[j]
        r := rev[j]
        re[r] = a * c + b * s
        im[r] = b * c - a * s
    }
    fft(re, im, q, t.fc, t.fs)
    u := d.u
    for p in 0..q {
        zr := re[p]
        zi := im[p]
        c := tc[p]
        s := ts[p]
        u[2 * p] = zr * c + zi * s
        u[m - 1 - 2 * p] = zr * s - zi * c
    }
    h := m / 2
    for i in 0..h {
        x[i] = u[i + h]
    }
    for i in h..3 * h {
        x[i] = -u[3 * h - 1 - i]
    }
    for i in 3 * h..n {
        x[i] = -u[i - 3 * h]
    }
}

// Decodes an audio packet. Returns 1 with output in outb[c][out_l..out_r), 0 for a packet
// without output (the first block, or not an audio packet), -1 for a broken packet.
priv fn decode_packet(d: *Dec, p: str) -> i64 {
    d.out_l = 0
    d.out_r = 0
    if len(p) == 0 {
        return 0
    }
    bits := Bits{data: p}
    b := &bits
    if get(b, 1) != 0 {
        return 0
    }
    mi := get(b, d.mode_bits)
    if mi >= len(d.modes) || b.eop {
        return -1
    }
    md := d.modes[mi]
    mp := &d.maps[md.mapping]
    ch := d.channels
    n := if md.long { d.bs1 } else { d.bs0 }
    n2 := n / 2
    pf := true
    nf := true
    if md.long {
        pf = get(b, 1) == 1
        nf = get(b, 1) == 1
    }
    ls := 0
    le := n2
    if md.long && !pf {
        ls = n / 4 - d.bs0 / 4
        le = n / 4 + d.bs0 / 4
    }
    rs := n2
    re := n
    if md.long && !nf {
        rs = n * 3 / 4 - d.bs0 / 4
        re = n * 3 / 4 + d.bs0 / 4
    }
    // floors
    for c in 0..ch {
        fl := mp.sub_floor[mp.mux[c]]
        d.floor_of[c] = fl
        d.fused[c] = floor_decode(d, b, &d.floors[fl], d.fy[c])
        d.nodec[c] = !d.fused[c]
    }
    for i in 0..len(mp.mag) {
        if !d.nodec[mp.mag[i]] || !d.nodec[mp.ang[i]] {
            d.nodec[mp.mag[i]] = false
            d.nodec[mp.ang[i]] = false
        }
    }
    // residues, per submap
    for s in 0..mp.submaps {
        k := 0
        for c in 0..ch {
            if mp.mux[c] == s {
                d.chs[k] = c
                k += 1
            }
        }
        residue_decode(d, &d.residues[mp.sub_res[s]], b, k, n2)
    }
    // inverse coupling
    for i in len(mp.mag) - 1..=0 by -1 {
        mv := d.chan[mp.mag[i]][..n2]
        av := d.chan[mp.ang[i]][..n2]
        for j in 0..n2 {
            m := mv[j]
            a := av[j]
            if m > 0.0 {
                if a > 0.0 {
                    av[j] = m - a
                } else {
                    av[j] = m
                    mv[j] = m + a
                }
            } else {
                if a > 0.0 {
                    av[j] = m + a
                } else {
                    av[j] = m
                    mv[j] = m - a
                }
            }
        }
    }
    // floor curves, inverse MDCT
    t := if md.long { &d.tw1 } else { &d.tw0 }
    for c in 0..ch {
        v := d.chan[c]
        if d.fused[c] {
            floor_render(d, &d.floors[d.floor_of[c]], d.fy[c], v, n2)
        } else {
            fill(v[..n2], 0.0)
        }
        imdct(d, v[..n], n, t)
    }
    // overlap-add with the previous block: the output runs from its centre to this one's
    result := 0
    if d.prev_n > 0 {
        d.cpos += d.prev_n / 4 + n / 4
        ov := min(le - ls, d.prev_ov)
        w := if ov == d.bs0 / 2 { d.win0 } else { d.win1 }
        flat := d.prev_flat
        tail := n2 - le
        for c in 0..ch {
            o := d.outb[c]
            pv := d.prev[c]
            v := d.chan[c]
            for j in 0..flat {
                o[j] = pv[j]
            }
            for j in 0..ov {
                o[flat + j] = v[ls + j] * w[j] + pv[flat + j] * w[ov - 1 - j]
            }
            for j in 0..tail {
                o[flat + ov + j] = v[le + j]
            }
        }
        d.out_r = flat + ov + tail
        result = 1
    }
    // keep the second half for the next block
    d.prev_n = n
    d.prev_flat = rs - n2
    d.prev_ov = re - rs
    for c in 0..ch {
        copy(d.prev[c][..re - n2], d.chan[c][n2..re])
    }
    result
}

// position of the output of the packet just decoded (its first frame)
priv fn out_start(d: *Dec) -> i64 {
    d.cpos - (d.out_r - d.out_l)
}

// the size of an audio packet's block from its first bits, 0 if it is not an audio packet
priv fn packet_size(d: *Dec, p: str) -> i64 {
    if len(p) == 0 {
        return 0
    }
    bits := Bits{data: p}
    if get(&bits, 1) != 0 {
        return 0
    }
    mi := get(&bits, d.mode_bits)
    if mi >= len(d.modes) || bits.eop {
        return -1
    }
    if d.modes[mi].long { d.bs1 } else { d.bs0 }
}

// walks all audio packets once: positions of the pages for seeking, the length and the
// trims from the granule positions (as libvorbis applies them)
priv fn walk(d: *Dec) -> (i64, str) {
    c := 0
    prevn := 0
    seen := false
    g1 := 0
    s1 := 0
    eos1 := false
    eos := false
    gend := 0
    loop {
        p, ok := next_packet(d)
        if !ok {
            break
        }
        n := packet_size(d, p)
        if n < 0 {
            return (0, "bad audio packet")
        }
        if n == 0 {
            continue
        }
        if prevn > 0 {
            c += prevn / 4 + n / 4
        }
        prevn = n
        if d.pages[d.pk_page].c0 < 0 {
            d.pages[d.pk_page].c0 = c
        }
        if d.pk_gran >= 0 && !seen {
            seen = true
            g1 = d.pk_gran
            s1 = c
            eos1 = d.pk_eos
        }
        if d.pk_eos {
            eos = true
            gend = d.pk_gran
        }
    }
    if d.bad_pk {
        return (0, "bad packet")
    }
    total := c
    base := 0
    if seen {
        base = g1 - s1
        if base < 0 {
            if eos1 {
                base = 0
            } else {
                d.skip = -base
            }
        }
    }
    d.end_abs = total
    if eos {
        d.end_abs = max(min(total, gend - base), d.skip)
    }
    (d.end_abs - d.skip, "")
}

// restarts decoding at the start of the packets of page index pi (-1: the first audio packet)
priv fn restart(d: *Dec, pi: i64) {
    if pi < 0 {
        d.pi = d.a_pi
        d.si = d.a_si
        d.bpos = d.a_bpos
        d.cpos = 0
    } else {
        d.pi = pi
        d.si = 0
        d.cpos = d.pages[pi].c0
    }
    d.assembling = false
    d.pk_len = 0
    d.prev_n = 0
    d.out_l = 0
    d.out_r = 0
    d.done = false
}

// Opens a Vorbis stream in an Ogg file image: reads the headers and checks the page structure
// of the whole file (no audio is decoded yet). False if it is not such a file or it is
// damaged; ogg_error() says why. `data` is referenced while the stream is used; the buffers
// (about 50 KB per channel plus the codebooks) are allocated here, ogg_read allocates nothing.
fn ogg_open(data: str) -> (*OggStream, bool) {
    d := new[Dec]()
    d.data = data
    st := new[OggStream]()
    st.dec = d
    biggest, err := scan(d)
    if err != "" {
        ogg_err = err
        return (nil, false)
    }
    d.pk = alloc[u8](biggest + 1)
    p1, ok1 := next_packet(d)
    if ok1 {
        err = read_id(d, &st.rate, p1)
    } else {
        err = "not an Ogg Vorbis stream"
    }
    if err == "" {
        p2, ok2 := next_packet(d)
        if !ok2 || len(p2) < 7 || p2[0] != 3 || p2[1..7] != "vorbis" {
            err = "missing comment header"
        }
    }
    if err == "" {
        p3, ok3 := next_packet(d)
        err = if ok3 { read_setup(d, p3) } else { "missing setup header" }
    }
    if err == "" && d.bad_pk {
        err = "bad packet"
    }
    if err != "" {
        ogg_err = err
        return (nil, false)
    }
    st.channels = d.channels
    d.a_pi = d.pi
    d.a_si = d.si
    d.a_bpos = d.bpos
    st.frames, err = walk(d)
    if err != "" {
        ogg_err = err
        return (nil, false)
    }
    prepare(d)
    restart(d, -1)
    d.lo_abs = d.skip
    ogg_err = ""
    (st, true)
}

// Reads a file and opens it as a stream (the compressed file stays in memory).
fn ogg_open_file(path: str) -> (*OggStream, bool) {
    data, ok := read_file(path)
    if !ok {
        ogg_err = fmt("cannot read ", path, ": ", error_text(io_error()))
        return (nil, false)
    }
    ogg_open(data)
}

// Decodes the next frames into `out` (interleaved, `channels` samples per frame) and returns
// how many: `frames`, fewer only at the end of the stream (or if it is damaged there: then
// st.error says why). Allocates nothing.
fn ogg_read(st: *OggStream, out: []f32, frames: i64) -> i64 {
    assert len(out) >= frames * st.channels, "ogg_read: output buffer too small"
    d := st.dec
    if d == nil {
        return 0
    }
    ch := st.channels
    got := 0
    while got < frames {
        if d.out_l < d.out_r {
            k := min(frames - got, d.out_r - d.out_l)
            for c in 0..ch {
                o := d.outb[c]
                at := got * ch + c
                for i in d.out_l..d.out_l + k {
                    out[at] = o[i]
                    at += ch
                }
            }
            got += k
            d.out_l += k
            st.pos += k
            continue
        }
        if d.done {
            break
        }
        p, ok := next_packet(d)
        if !ok || d.bad_pk {
            d.done = true
            break
        }
        r := decode_packet(d, p)
        if r < 0 {
            st.error = "bad audio packet"
            d.done = true
            break
        }
        if r == 0 {
            continue
        }
        // keep what lies in lo_abs..end_abs
        a0 := out_start(d)
        if d.cpos >= d.end_abs {
            d.out_r -= min(d.cpos - d.end_abs, d.out_r)
            d.done = true
        }
        if a0 < d.lo_abs {
            d.out_l = min(d.lo_abs - a0, d.out_r)
        }
    }
    got
}

// Continues decoding at frame `frame` (0 ..= st.frames); false (and no change) outside that
// range. Seeking jumps to the page before the frame and decodes from there.
fn ogg_seek(st: *OggStream, frame: i64) -> bool {
    d := st.dec
    if d == nil || frame < 0 || frame > st.frames {
        return false
    }
    target := d.skip + frame
    start := -1
    for i in d.a_pi..len(d.pages) {
        c0 := d.pages[i].c0
        if c0 >= 0 && i > d.a_pi && c0 <= target {
            start = i
        }
        if c0 > target {
            break
        }
    }
    restart(d, start)
    d.lo_abs = target
    st.pos = frame
    st.error = ""
    true
}

// Goes back to the first frame (for looping).
fn ogg_rewind(st: *OggStream) -> bool {
    ogg_seek(st, 0)
}

// Ends the stream: further reads return 0. The memory stays allocated (it is arena memory).
fn ogg_close(st: *OggStream) {
    st.dec = nil
}

priv fn stream_read(ctx: *u8, out: []f32, frames: i64) -> i64 {
    ogg_read(cast[*OggStream](ctx), out, frames)
}

priv fn stream_rewind(ctx: *u8) -> bool {
    ogg_rewind(cast[*OggStream](ctx))
}

// The stream as a source for the mixer's play_stream (with a read-ahead buffer of 1024 frames
// allocated by ogg_open).
fn audio_stream(st: *OggStream) -> AudioStream {
    buf: []f32
    if st.dec != nil {
        buf = st.dec.mixbuf
    }
    AudioStream{cast[*u8](st), st.rate, st.channels, stream_read, stream_rewind, buf}
}

// Plays an Ogg stream on the mixer from where it stands, decoding as it plays (no allocation):
// play_stream(m, audio_stream(st), ...). With `looped` it rewinds at the end, without a gap.
fn play_stream(m: *Mixer, st: *OggStream, volume: f32, pan: f32, pitch: f32, looped: bool) -> VoiceId {
    play_stream(m, audio_stream(st), volume, pan, pitch, looped)
}

// Decodes a whole Ogg Vorbis file image into a Sound; false if it is not one or it is damaged
// anywhere (ogg_error() says why). Only the samples stay allocated: the decoder works in a
// region of its own.
fn ogg_decode(data: str) -> (Sound, bool) {
    none: Sound
    r: Region
    enter(&r)
    st, ok := ogg_open(data)
    leave()
    if !ok {
        ogg_err = clone(ogg_err)
        region_free(&r)
        return (none, false)
    }
    s := Sound{alloc[f32](st.frames * st.channels), st.rate, st.channels}
    enter(&r)
    got := ogg_read(st, s.samples, st.frames)
    err := st.error
    leave()
    ok = got == st.frames && err == ""
    if !ok {
        ogg_err = if err != "" { clone(err) } else { "stream shorter than its granule positions" }
    }
    region_free(&r)
    if !ok {
        return (none, false)
    }
    (s, true)
}

// Reads and decodes an Ogg Vorbis file; false if it is missing or not a valid one.
fn ogg_load(path: str) -> (Sound, bool) {
    data, ok := read_file(path)
    if !ok {
        none: Sound
        ogg_err = fmt("cannot read ", path, ": ", error_text(io_error()))
        return (none, false)
    }
    ogg_decode(data)
}
