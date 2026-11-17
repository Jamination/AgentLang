// std.image, JPEG part (included by std/image.al): a decoder for baseline, extended sequential
// and progressive Huffman-coded JPEG (8-bit samples) and a baseline encoder. Written in AL like
// the rest of std.image. The decoder follows libjpeg's default decoding (accurate integer IDCT,
// "fancy" triangular upsampling of 2x subsampled chroma, the same fixed-point colour
// conversion), so its pixels agree with libjpeg-turbo's to within rounding.

// limits of the decoder (the format itself limits each dimension to 65535)
priv const MAX_BYTES = 1 << 31

// position in the 8x8 block (row-major) of the k-th coefficient in zigzag order
priv const ZIGZAG = [64]u8{
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
}

// A Huffman decoding table. Codes are read MSB first: codes of up to 9 bits are looked up by
// the next 9 bits; longer ones by comparing with the largest code of each length.
priv struct JHuff {
    fast: [512]u16     // length << 8 | symbol; 0: the code is longer than 9 bits
    maxcode: [17]i64   // largest code of each length (smaller than the first one if there is none)
    delta: [17]i64     // a code of length l is symbol vals[code + delta[l]]
    vals: [256]u8
    defined: bool
}

priv struct JComp {
    id: i64
    h: i64           // sampling factors
    v: i64
    tq: i64          // quantisation table
    td: i64          // DC and AC Huffman tables of the current scan
    ta: i64
    cw: i64          // width and height in samples
    ch: i64
    bw: i64          // blocks per row and per column that are stored (whole MCUs)
    bh: i64
    pred: i64        // DC predictor
    q: [64]u16       // the quantisation table, latched at the component's first scan (natural order)
    latched: bool
    plane: []u8      // samples, bw * 8 per row (sequential: decoded scan by scan; progressive: at the end)
    coefs: []i16     // progressive: 64 coefficients per block, natural order
}

priv struct JDec {
    d: []u8
    pos: i64         // next byte of d
    bits: u64        // bit buffer, next bit in bit 63
    cnt: i64         // bits in the buffer
    fake: i64        // zero bits appended because a marker or the end of the data was reached
    w: i64
    h: i64
    ncomp: i64
    progressive: bool
    hmax: i64
    vmax: i64
    mcux: i64        // MCUs per row and column of an interleaved scan
    mcuy: i64
    comps: [4]JComp
    qt: [4][64]u16
    qdef: [4]bool
    dc: [4]JHuff
    ac: [4]JHuff
    ri: i64          // restart interval in MCUs, 0 for none
    eobrun: i64
    jfif: bool
    adobe: bool
    transform: i64   // Adobe colour transform: 0 none (RGB / CMYK), 1 YCbCr, 2 YCCK
    scanned: [4]bool
}

// Builds the table for the code lengths `counts` (16 counts: codes of 1..16 bits) and the
// symbols in code order. Like libjpeg it rejects a set of lengths that does not fit (which
// includes a code of all 1 bits).
priv fn jhuff_build(t: *JHuff, counts: []u8, syms: []u8) -> bool {
    fill(t.fast[..], 0)
    copy(t.vals[..], syms)
    code := 0
    k := 0
    for l in 1..=16 {
        n := i64(counts[l - 1])
        t.delta[l] = k - code
        t.maxcode[l] = code + n - 1
        if l <= 9 {
            for i in 0..n {
                e := u16(l << 8) | u16(syms[k + i])
                c := code + i
                for f in c << (9 - l)..(c + 1) << (9 - l) {
                    t.fast[f] = e
                }
            }
        }
        code += n
        k += n
        if code >= 1 << l {
            return false
        }
        code = code << 1
    }
    t.defined = true
    true
}

// Fills the bit buffer up to at least 57 bits. Stuffed bytes (0xFF 0x00) give 0xFF; at a
// marker or the end of the data zero bits are appended and counted in `fake`.
priv fn jfill(j: *JDec) {
    d := j.d
    n := len(d)
    if j.fake == 0 && j.pos + 8 <= n {
        // fast path: the next 8 bytes hold no 0xFF, so as many as fit can be taken at once
        w := bswap(cast[*u64](cast[i64](ptr(d)) + j.pos)[0])
        x := ~w
        if (x - 0x0101010101010101) & ~x & 0x8080808080808080 == 0 {
            k := (64 - j.cnt) >> 3
            j.bits |= w >> (64 - 8 * k) << (64 - 8 * k - j.cnt)
            j.pos += k
            j.cnt += 8 * k
            return
        }
    }
    while j.cnt <= 56 {
        b: u64 = 0
        if j.fake == 0 && j.pos < n {
            b = u64(d[j.pos])
            if b != 0xFF {
                j.pos += 1
            } else if j.pos + 1 < n && d[j.pos + 1] == 0 {
                j.pos += 2
            } else {
                b = 0
                j.fake += 8
            }
        } else {
            j.fake += 8
        }
        j.bits |= b << (56 - j.cnt)
        j.cnt += 8
    }
}

// true if bits were taken that are not in the data (the scan is cut short or corrupt)
priv inline fn joverrun(j: *JDec) -> bool {
    j.fake > j.cnt
}

// the next n (0..16) bits as an unsigned number
priv inline fn jbits(j: *JDec, n: i64) -> i64 {
    if n == 0 {
        return 0
    }
    if j.cnt < n {
        jfill(j)
    }
    v := i64(j.bits >> (64 - n))
    j.bits = j.bits << n
    j.cnt -= n
    v
}

// an n-bit value of a coefficient (n 1..15): the high half is positive, the low half negative
priv inline fn jextend(v: i64, n: i64) -> i64 {
    if v < 1 << (n - 1) { v - (1 << n) + 1 } else { v }
}

// the next Huffman-coded symbol, -1 for a code that is not in the table
priv inline fn jdecode(j: *JDec, t: *JHuff) -> i64 {
    if j.cnt < 16 {
        jfill(j)
    }
    e := i64(t.fast[j.bits >> 55])
    if e != 0 {
        l := e >> 8
        j.bits = j.bits << l
        j.cnt -= l
        return e & 255
    }
    for l in 10..=16 {
        c := i64(j.bits >> (64 - l))
        if c <= t.maxcode[l] {
            i := c + t.delta[l]
            if i < 0 || i > 255 {
                return -1
            }
            j.bits = j.bits << l
            j.cnt -= l
            return i64(t.vals[i])
        }
    }
    -1
}

// ---------- IDCT ----------
// libjpeg's accurate integer inverse DCT (jidctint.c: Loeffler, Ligtenberg and Moschytz with
// 13-bit constants): dequantises blk (natural order) with q and writes the 8x8 samples to
// out[at..], stride bytes per row
priv fn jidct(blk: []i32, q: []u16, out: []u8, at: i64, stride: i64) {
    ws: [64]i64
    for c in 0..8 {
        if blk[8 + c] == 0 && blk[16 + c] == 0 && blk[24 + c] == 0 && blk[32 + c] == 0 &&
            blk[40 + c] == 0 && blk[48 + c] == 0 && blk[56 + c] == 0 {
            dcv := i64(blk[c]) * i64(q[c]) << 2
            for r in 0..8 {
                ws[r * 8 + c] = dcv
            }
            continue
        }
        z2 := i64(blk[16 + c]) * i64(q[16 + c])
        z3 := i64(blk[48 + c]) * i64(q[48 + c])
        z1 := (z2 + z3) * 4433
        t2 := z1 - z3 * 15137
        t3 := z1 + z2 * 6270
        z2 = i64(blk[c]) * i64(q[c])
        z3 = i64(blk[32 + c]) * i64(q[32 + c])
        t0 := (z2 + z3) << 13
        t1 := (z2 - z3) << 13
        t10 := t0 + t3
        t13 := t0 - t3
        t11 := t1 + t2
        t12 := t1 - t2
        o0 := i64(blk[56 + c]) * i64(q[56 + c])
        o1 := i64(blk[40 + c]) * i64(q[40 + c])
        o2 := i64(blk[24 + c]) * i64(q[24 + c])
        o3 := i64(blk[8 + c]) * i64(q[8 + c])
        z1 = o0 + o3
        z2 = o1 + o2
        z3 = o0 + o2
        z4 := o1 + o3
        z5 := (z3 + z4) * 9633
        o0 *= 2446
        o1 *= 16819
        o2 *= 25172
        o3 *= 12299
        z1 *= -7373
        z2 *= -20995
        z3 = z3 * -16069 + z5
        z4 = z4 * -3196 + z5
        o0 += z1 + z3
        o1 += z2 + z4
        o2 += z2 + z3
        o3 += z1 + z4
        ws[c] = (t10 + o3 + 1024) >> 11
        ws[56 + c] = (t10 - o3 + 1024) >> 11
        ws[8 + c] = (t11 + o2 + 1024) >> 11
        ws[48 + c] = (t11 - o2 + 1024) >> 11
        ws[16 + c] = (t12 + o1 + 1024) >> 11
        ws[40 + c] = (t12 - o1 + 1024) >> 11
        ws[24 + c] = (t13 + o0 + 1024) >> 11
        ws[32 + c] = (t13 - o0 + 1024) >> 11
    }
    for r in 0..8 {
        w := r * 8
        o := at + r * stride
        row := out[o..o + 8]
        if ws[w + 1] == 0 && ws[w + 2] == 0 && ws[w + 3] == 0 && ws[w + 4] == 0 &&
            ws[w + 5] == 0 && ws[w + 6] == 0 && ws[w + 7] == 0 {
            v := jclamp(((ws[w] + 16) >> 5) + 128)
            fill(row, v)
            continue
        }
        z2 := ws[w + 2]
        z3 := ws[w + 6]
        z1 := (z2 + z3) * 4433
        t2 := z1 - z3 * 15137
        t3 := z1 + z2 * 6270
        t0 := (ws[w] + ws[w + 4]) << 13
        t1 := (ws[w] - ws[w + 4]) << 13
        t10 := t0 + t3
        t13 := t0 - t3
        t11 := t1 + t2
        t12 := t1 - t2
        o0 := ws[w + 7]
        o1 := ws[w + 5]
        o2 := ws[w + 3]
        o3 := ws[w + 1]
        z1 = o0 + o3
        z2 = o1 + o2
        z3 = o0 + o2
        z4 := o1 + o3
        z5 := (z3 + z4) * 9633
        o0 *= 2446
        o1 *= 16819
        o2 *= 25172
        o3 *= 12299
        z1 *= -7373
        z2 *= -20995
        z3 = z3 * -16069 + z5
        z4 = z4 * -3196 + z5
        o0 += z1 + z3
        o1 += z2 + z4
        o2 += z2 + z3
        o3 += z1 + z4
        row[0] = jclamp(((t10 + o3 + 131072) >> 18) + 128)
        row[7] = jclamp(((t10 - o3 + 131072) >> 18) + 128)
        row[1] = jclamp(((t11 + o2 + 131072) >> 18) + 128)
        row[6] = jclamp(((t11 - o2 + 131072) >> 18) + 128)
        row[2] = jclamp(((t12 + o1 + 131072) >> 18) + 128)
        row[5] = jclamp(((t12 - o1 + 131072) >> 18) + 128)
        row[3] = jclamp(((t13 + o0 + 131072) >> 18) + 128)
        row[4] = jclamp(((t13 - o0 + 131072) >> 18) + 128)
    }
}

priv inline fn jclamp(v: i64) -> u8 {
    if u64(v) <= 255 {
        return u8(v)
    }
    if v < 0 { 0 } else { 255 }
}

// ---------- entropy decoding of one block ----------
// sequential: all 64 coefficients into blk (zeroed by the caller); returns the number of AC
// coefficients that were set, -1 for a bad code
priv fn jblock_seq(j: *JDec, c: *JComp, blk: []i32) -> i64 {
    s := jdecode(j, &j.dc[c.td])
    if s < 0 {
        return -1
    }
    if s != 0 {
        c.pred += jextend(jbits(j, s), s)
    }
    blk[0] = i32(c.pred)
    act := &j.ac[c.ta]
    k := 1
    nac := 0
    while k < 64 {
        rs := jdecode(j, act)
        if rs < 0 {
            return -1
        }
        r := rs >> 4
        s = rs & 15
        if s == 0 {
            if r != 15 {
                break
            }
            k += 16
            continue
        }
        k += r
        if k > 63 {
            return -1
        }
        blk[ZIGZAG[k]] = i32(jextend(jbits(j, s), s))
        nac += 1
        k += 1
    }
    nac
}

// the samples of a block whose AC coefficients are all zero: what jidct computes for it
priv fn jidct_dc(dc: i64, q: i64, out: []u8, at: i64, stride: i64) {
    v := jclamp((((dc * q) << 2) + 16 >> 5) + 128)
    for r in 0..8 {
        fill(out[at + r * stride..at + r * stride + 8], v)
    }
}

// progressive, first DC scan: the DC coefficient, shifted left by al
priv fn jblock_dc_first(j: *JDec, c: *JComp, blk: []i16, al: i64) -> bool {
    s := jdecode(j, &j.dc[c.td])
    if s < 0 {
        return false
    }
    if s != 0 {
        c.pred += jextend(jbits(j, s), s)
    }
    blk[0] = i16(c.pred << al)
    true
}

// progressive, first AC scan of the band ss..se
priv fn jblock_ac_first(j: *JDec, c: *JComp, blk: []i16, ss: i64, se: i64, al: i64) -> bool {
    if j.eobrun > 0 {
        j.eobrun -= 1
        return true
    }
    act := &j.ac[c.ta]
    k := ss
    while k <= se {
        rs := jdecode(j, act)
        if rs < 0 {
            return false
        }
        r := rs >> 4
        s := rs & 15
        if s == 0 {
            if r < 15 {
                // this block and the next 2^r - 1 + (r more bits) blocks end here
                j.eobrun = (1 << r) - 1
                if r > 0 {
                    j.eobrun += jbits(j, r)
                }
                break
            }
            k += 16
            continue
        }
        k += r
        if k > 63 {
            return false
        }
        blk[ZIGZAG[k]] = i16(jextend(jbits(j, s), s) << al)
        k += 1
    }
    true
}

// a correction bit for the coefficient blk[z], which is not zero
priv inline fn jrefine(j: *JDec, blk: []i16, z: i64, p1: i16) {
    if jbits(j, 1) != 0 && blk[z] & p1 == 0 {
        if blk[z] >= 0 {
            blk[z] += p1
        } else {
            blk[z] -= p1
        }
    }
}

// progressive, refining AC scan (libjpeg's decode_mcu_AC_refine)
priv fn jblock_ac_refine(j: *JDec, c: *JComp, blk: []i16, ss: i64, se: i64, al: i64) -> bool {
    p1 := i16(1 << al)
    k := ss
    if j.eobrun == 0 {
        act := &j.ac[c.ta]
        while k <= se {
            rs := jdecode(j, act)
            if rs < 0 {
                return false
            }
            r := rs >> 4
            s := rs & 15
            v: i16 = 0
            if s != 0 {
                if s != 1 {
                    return false
                }
                v = if jbits(j, 1) != 0 { p1 } else { -p1 }
            } else if r != 15 {
                j.eobrun = 1 << r
                if r > 0 {
                    j.eobrun += jbits(j, r)
                }
                break
            }
            // skip r coefficients that are still zero; the nonzero ones passed get a correction bit
            while k <= se {
                z := i64(ZIGZAG[k])
                if blk[z] != 0 {
                    jrefine(j, blk, z, p1)
                } else {
                    if r == 0 {
                        break
                    }
                    r -= 1
                }
                k += 1
            }
            if s != 0 {
                if k > 63 {
                    return false
                }
                blk[ZIGZAG[k]] = v
            }
            k += 1
        }
    }
    if j.eobrun > 0 {
        // the rest of the band only refines the coefficients that are already nonzero
        while k <= se {
            z := i64(ZIGZAG[k])
            if blk[z] != 0 {
                jrefine(j, blk, z, p1)
            }
            k += 1
        }
        j.eobrun -= 1
    }
    true
}

// ---------- scans ----------
// expects the restart marker RSTn (n = num & 7) and resets the decoder state after it
priv fn jrestart(j: *JDec, num: i64, sc: []i64) -> bool {
    if joverrun(j) {
        return false
    }
    d := j.d
    p := j.pos
    // the bytes before the marker can only be the padding of the last byte
    while p < len(d) && d[p] != 0xFF {
        p += 1
    }
    while p + 1 < len(d) && d[p + 1] == 0xFF {
        p += 1
    }
    if p + 1 >= len(d) || i64(d[p + 1]) != 0xD0 + (num & 7) {
        return false
    }
    j.pos = p + 2
    j.bits = 0
    j.cnt = 0
    j.fake = 0
    j.eobrun = 0
    for ci in sc {
        j.comps[ci].pred = 0
    }
    true
}

// the 64 coefficients of block (xb, yb) of a progressive component
priv inline fn jcoefs(c: *JComp, xb: i64, yb: i64) -> []i16 {
    o := (yb * c.bw + xb) * 64
    c.coefs[o..o + 64]
}

// decodes one block of component c at block position (xb, yb)
priv fn jblock(j: *JDec, c: *JComp, xb: i64, yb: i64, ss: i64, se: i64, ah: i64, al: i64, blk: []i32) -> bool {
    if !j.progressive {
        fill(blk, 0)
        nac := jblock_seq(j, c, blk)
        if nac < 0 {
            return false
        }
        stride := c.bw * 8
        at := yb * 8 * stride + xb * 8
        if nac == 0 {
            jidct_dc(i64(blk[0]), i64(c.q[0]), c.plane, at, stride)
        } else {
            jidct(blk, c.q[..], c.plane, at, stride)
        }
        return true
    }
    b := jcoefs(c, xb, yb)
    if ss == 0 {
        if ah == 0 {
            return jblock_dc_first(j, c, b, al)
        }
        if jbits(j, 1) != 0 {
            b[0] |= i16(1 << al)
        }
        return true
    }
    if ah == 0 {
        return jblock_ac_first(j, c, b, ss, se, al)
    }
    jblock_ac_refine(j, c, b, ss, se, al)
}

// decodes the entropy-coded data of a scan of the components sc, starting at j.pos
priv fn jscan(j: *JDec, sc: []i64, ss: i64, se: i64, ah: i64, al: i64) -> bool {
    j.bits = 0
    j.cnt = 0
    j.fake = 0
    j.eobrun = 0
    for ci in sc {
        j.comps[ci].pred = 0
    }
    blk: [64]i32
    nx := j.mcux
    ny := j.mcuy
    if len(sc) == 1 {
        // a scan of one component codes its blocks one by one, without the padding of MCUs
        c := &j.comps[sc[0]]
        nx = (c.cw + 7) / 8
        ny = (c.ch + 7) / 8
    }
    left := j.ri
    rst := 0
    for my in 0..ny {
        for mx in 0..nx {
            if j.ri > 0 {
                if left == 0 {
                    if !jrestart(j, rst, sc) {
                        return false
                    }
                    rst += 1
                    left = j.ri
                }
                left -= 1
            }
            if len(sc) == 1 {
                if !jblock(j, &j.comps[sc[0]], mx, my, ss, se, ah, al, blk[..]) {
                    return false
                }
            } else {
                for ci in sc {
                    c := &j.comps[ci]
                    for v in 0..c.v {
                        for h in 0..c.h {
                            if !jblock(j, c, mx * c.h + h, my * c.v + v, ss, se, ah, al, blk[..]) {
                                return false
                            }
                        }
                    }
                }
            }
            if joverrun(j) {
                return false
            }
        }
    }
    true
}

// ---------- markers ----------
// reads a frame header (SOF0 / SOF1 / SOF2) and allocates the component buffers
priv fn jframe(j: *JDec, s: []u8) -> bool {
    if j.ncomp != 0 || len(s) < 6 || s[0] != 8 {
        return false
    }
    j.h = be16_at(s, 1)
    j.w = be16_at(s, 3)
    n := i64(s[5])
    if j.w == 0 || j.h == 0 || (n != 1 && n != 3 && n != 4) || len(s) != 6 + 3 * n {
        return false
    }
    j.ncomp = n
    j.hmax = 1
    j.vmax = 1
    for i in 0..n {
        c := &j.comps[i]
        c.id = i64(s[6 + 3 * i])
        c.h = i64(s[7 + 3 * i] >> 4)
        c.v = i64(s[7 + 3 * i] & 15)
        c.tq = i64(s[8 + 3 * i])
        if c.h < 1 || c.h > 4 || c.v < 1 || c.v > 4 || c.tq > 3 {
            return false
        }
        for k in 0..i {
            if j.comps[k].id == c.id {
                return false
            }
        }
        if n == 1 {
            // a single component is never interleaved: its sampling factors do not matter
            c.h = 1
            c.v = 1
        }
        j.hmax = max(j.hmax, c.h)
        j.vmax = max(j.vmax, c.v)
    }
    j.mcux = (j.w + 8 * j.hmax - 1) / (8 * j.hmax)
    j.mcuy = (j.h + 8 * j.vmax - 1) / (8 * j.vmax)
    channels := if n == 1 { 1 } else { 3 }
    if j.w * j.h * channels > MAX_BYTES {
        return false
    }
    // every block is coded in at least one bit: data too short for the size is rejected before
    // anything is allocated
    coded := 0
    stored := 0
    for i in 0..n {
        c := &j.comps[i]
        if j.hmax % c.h != 0 || j.vmax % c.v != 0 {
            return false
        }
        c.cw = (j.w * c.h + j.hmax - 1) / j.hmax
        c.ch = (j.h * c.v + j.vmax - 1) / j.vmax
        c.bw = j.mcux * c.h
        c.bh = j.mcuy * c.v
        coded += (c.cw + 7) / 8 * ((c.ch + 7) / 8)
        stored += c.bw * c.bh
    }
    if coded > len(j.d) * 8 || stored * 64 > MAX_BYTES {
        return false
    }
    for i in 0..n {
        c := &j.comps[i]
        c.plane = alloc[u8](c.bw * c.bh * 64)
        if j.progressive {
            c.coefs = alloc[i16](c.bw * c.bh * 64)
        }
    }
    true
}

priv inline fn be16_at(d: []u8, i: i64) -> i64 {
    i64(d[i]) << 8 | i64(d[i + 1])
}

priv fn jtables_huff(j: *JDec, s: []u8) -> bool {
    p := 0
    while p < len(s) {
        if p + 17 > len(s) {
            return false
        }
        tc := i64(s[p] >> 4)
        th := i64(s[p] & 15)
        total := 0
        for i in 1..17 {
            total += i64(s[p + i])
        }
        if tc > 1 || th > 3 || total > 256 || p + 17 + total > len(s) {
            return false
        }
        syms := s[p + 17..p + 17 + total]
        t := if tc == 0 { &j.dc[th] } else { &j.ac[th] }
        if tc == 0 {
            for x in syms {
                if x > 15 {
                    return false
                }
            }
        }
        if !jhuff_build(t, s[p + 1..p + 17], syms) {
            return false
        }
        p += 17 + total
    }
    true
}

priv fn jtables_quant(j: *JDec, s: []u8) -> bool {
    p := 0
    while p < len(s) {
        pq := i64(s[p] >> 4)
        tq := i64(s[p] & 15)
        size := if pq == 0 { 64 } else { 128 }
        if pq > 1 || tq > 3 || p + 1 + size > len(s) {
            return false
        }
        for k in 0..64 {
            v := if pq == 0 { i64(s[p + 1 + k]) } else { be16_at(s, p + 1 + 2 * k) }
            j.qt[tq][ZIGZAG[k]] = u16(v)
        }
        j.qdef[tq] = true
        p += 1 + size
    }
    true
}

// reads a scan header and decodes the scan; j.pos is then at the end of its data
priv fn jsos(j: *JDec, s: []u8) -> bool {
    if j.ncomp == 0 || len(s) < 1 {
        return false
    }
    ns := i64(s[0])
    if ns < 1 || ns > j.ncomp || len(s) != 4 + 2 * ns {
        return false
    }
    sc: [4]i64
    blocks := 0
    for i in 0..ns {
        id := i64(s[1 + 2 * i])
        ci := -1
        for k in 0..j.ncomp {
            if j.comps[k].id == id {
                ci = k
            }
        }
        for k in 0..i {
            if sc[k] == ci {
                return false
            }
        }
        if ci < 0 {
            return false
        }
        sc[i] = ci
        c := &j.comps[ci]
        c.td = i64(s[2 + 2 * i] >> 4)
        c.ta = i64(s[2 + 2 * i] & 15)
        if c.td > 3 || c.ta > 3 {
            return false
        }
        blocks += c.h * c.v
    }
    ss := i64(s[1 + 2 * ns])
    se := i64(s[2 + 2 * ns])
    ah := i64(s[3 + 2 * ns] >> 4)
    al := i64(s[3 + 2 * ns] & 15)
    if ns > 1 && blocks > 10 {
        return false
    }
    if j.progressive {
        if (ss == 0 && se != 0) || (ss != 0 && (se < ss || se > 63 || ns != 1)) || al > 13 || (ah != 0 && ah != al + 1) {
            return false
        }
    }
    for i in 0..ns {
        c := &j.comps[sc[i]]
        needs_dc := !j.progressive || (ss == 0 && ah == 0)
        needs_ac := !j.progressive || ss != 0
        if (needs_dc && !j.dc[c.td].defined) || (needs_ac && !j.ac[c.ta].defined) {
            return false
        }
        if !c.latched {
            if !j.qdef[c.tq] {
                return false
            }
            c.q = j.qt[c.tq]
            c.latched = true
        }
        j.scanned[sc[i]] = true
    }
    jscan(j, sc[..ns], ss, se, ah, al)
}

// the samples of component c for output row y, scaled to the full width w (libjpeg's fancy
// upsampling for 2x horizontal and / or vertical subsampling, replication for other factors)
priv fn jupsample(j: *JDec, c: *JComp, y: i64, tmp: []u8, sums: []i64) -> []u8 {
    stride := c.bw * 8
    w := j.w
    hf := j.hmax / c.h
    vf := j.vmax / c.v
    if hf == 1 && vf == 1 {
        return c.plane[y * stride..y * stride + w]
    }
    p := c.plane
    last := c.cw - 1
    if vf == 2 && (hf == 1 || hf == 2) {
        // the nearer source row counts 3 times, the other one (above for the upper output row) once
        r := y >> 1
        o := if y & 1 == 0 { max(r - 1, 0) } else { min(r + 1, c.ch - 1) }
        a := r * stride
        b := o * stride
        if hf == 1 {
            bias := if y & 1 == 0 { 1 } else { 2 }
            for x in 0..w {
                tmp[x] = u8((3 * i64(p[a + x]) + i64(p[b + x]) + bias) >> 2)
            }
            return tmp[..w]
        }
        for x in 0..=last {
            sums[x] = 3 * i64(p[a + x]) + i64(p[b + x])
        }
        // then horizontally: two outputs per column sum (tmp has room for 2 * cw >= w samples)
        t := sums[0]
        tmp[0] = u8((4 * t + 8) >> 4)
        for i in 0..last {
            n := sums[i + 1]
            tmp[2 * i + 1] = u8((3 * t + n + 7) >> 4)
            tmp[2 * i + 2] = u8((3 * n + t + 8) >> 4)
            t = n
        }
        tmp[2 * last + 1] = u8((4 * t + 7) >> 4)
        return tmp[..w]
    }
    a := y / vf * stride
    if hf == 2 && vf == 1 {
        t := i64(p[a])
        tmp[0] = u8(t)
        for i in 0..last {
            n := i64(p[a + i + 1])
            tmp[2 * i + 1] = u8((3 * t + n + 2) >> 2)
            tmp[2 * i + 2] = u8((3 * n + t + 1) >> 2)
            t = n
        }
        tmp[2 * last + 1] = u8(t)
        return tmp[..w]
    }
    for x in 0..w {
        tmp[x] = p[a + x / hf]
    }
    tmp[..w]
}

// libjpeg's fixed-point YCbCr -> RGB conversion (jdcolor.c)
priv inline fn jycc_rgb(y: u8, cb: u8, cr: u8) -> (u8, u8, u8) {
    l := i64(y)
    b := i64(cb) - 128
    r := i64(cr) - 128
    (jclamp(l + ((91881 * r + 32768) >> 16)), jclamp(l + ((-22554 * b - 46802 * r + 32768) >> 16)), jclamp(l + ((116130 * b + 32768) >> 16)))
}

// converts the component rows of one output row into pixels
priv fn jconvert(j: *JDec, rows: [4][]u8, out: []u8) {
    w := j.w
    if j.ncomp == 1 {
        copy(out, rows[0])
        return
    }
    y := rows[0]
    cb := rows[1]
    cr := rows[2]
    if j.ncomp == 3 {
        rgb := if j.adobe { j.transform == 0 } else { !j.jfif && j.comps[0].id == 'R' && j.comps[1].id == 'G' && j.comps[2].id == 'B' }
        if rgb {
            for x in 0..w {
                out[3 * x] = y[x]
                out[3 * x + 1] = cb[x]
                out[3 * x + 2] = cr[x]
            }
            return
        }
        for x in 0..w {
            l := i64(y[x])
            b := i64(cb[x]) - 128
            r := i64(cr[x]) - 128
            px := out[3 * x..3 * x + 3]
            px[0] = jclamp(l + ((91881 * r + 32768) >> 16))
            px[1] = jclamp(l + ((-22554 * b - 46802 * r + 32768) >> 16))
            px[2] = jclamp(l + ((116130 * b + 32768) >> 16))
        }
        return
    }
    // CMYK, or YCCK (Adobe transform 2): YCbCr-coded 255 - C, 255 - M, 255 - Y, then K. The
    // values are taken as Adobe writes them (inverted), so a channel is C * K / 255.
    k := rows[3]
    ycck := j.adobe && j.transform != 0
    for x in 0..w {
        o := x * 3
        c0 := i64(y[x])
        c1 := i64(cb[x])
        c2 := i64(cr[x])
        if ycck {
            r, g, b := jycc_rgb(y[x], cb[x], cr[x])
            c0 = 255 - i64(r)
            c1 = 255 - i64(g)
            c2 = 255 - i64(b)
        }
        kk := i64(k[x])
        out[o] = u8((c0 * kk + 127) / 255)
        out[o + 1] = u8((c1 * kk + 127) / 255)
        out[o + 2] = u8((c2 * kk + 127) / 255)
    }
}

// The width, height and component count from the frame header; false if there is no
// supported frame header before the first scan.
priv fn jpeg_frame_size(d: []u8) -> (i64, i64, i64, bool) {
    n := len(d)
    if n < 4 || d[0] != 0xFF || d[1] != 0xD8 {
        return (0, 0, 0, false)
    }
    p := 2
    while p + 4 <= n {
        if d[p] != 0xFF {
            return (0, 0, 0, false)
        }
        m := d[p + 1]
        if m == 0xFF {
            p += 1
            continue
        }
        l := be16_at(d, p + 2)
        if m == 0xC0 || m == 0xC1 || m == 0xC2 {
            if l < 8 || p + 2 + l > n {
                return (0, 0, 0, false)
            }
            return (be16_at(d, p + 7), be16_at(d, p + 5), i64(d[p + 9]), true)
        }
        if m == 0xDA || m == 0xD9 || l < 2 {
            return (0, 0, 0, false)
        }
        p += 2 + l
    }
    (0, 0, 0, false)
}

// Decodes a JPEG file held in memory: baseline and extended sequential (SOF0 / SOF1) and
// progressive (SOF2) Huffman-coded images with 8-bit samples, restart intervals, greyscale,
// YCbCr with any whole-number subsampling (4:4:4, 4:2:2, 4:2:0, 4:4:0, 4:1:1, ...), RGB, CMYK
// and YCCK (Adobe). The image has 1 channel (greyscale) or 3 (RGB). Returns false for
// anything malformed or unsupported (arithmetic coding, lossless, hierarchical, 12-bit, a
// file cut short or without its end marker). Allocates only the pixels.
fn jpeg_decode(data: []u8) -> (Image, bool) {
    none: Image
    fw, fh, fn_, found := jpeg_frame_size(data)
    if !found || fw == 0 || fh == 0 || (fn_ != 1 && fn_ != 3 && fn_ != 4) || fw * fh * 3 > MAX_BYTES {
        return (none, false)
    }
    m0 := mark()
    img := image_new(fw, fh, if fn_ == 1 { 1 } else { 3 })
    m := mark()
    j := new[JDec]()
    j.d = data
    ok := jpeg_run(j)
    if ok {
        // check that the frame header that was decoded is the one the image was made for
        ok = j.w == fw && j.h == fh && j.ncomp == fn_
    }
    if ok {
        jpeg_output(j, img)
    }
    release(m)
    if !ok {
        release(m0)
        return (none, false)
    }
    (img, true)
}

// reads all markers and scans up to the end marker
priv fn jpeg_run(j: *JDec) -> bool {
    d := j.d
    n := len(d)
    pos := 2
    loop {
        if pos + 2 > n || d[pos] != 0xFF {
            return false
        }
        while pos + 1 < n && d[pos + 1] == 0xFF {
            pos += 1
        }
        if pos + 2 > n {
            return false
        }
        mk := i64(d[pos + 1])
        pos += 2
        if mk == 0xD9 {
            break
        }
        if (mk >= 0xD0 && mk <= 0xD7) || mk == 0x01 {
            // a stray restart marker or TEM: no segment
            continue
        }
        if mk == 0xD8 || mk == 0 || pos + 2 > n {
            return false
        }
        l := be16_at(d, pos)
        if l < 2 || pos + l > n {
            return false
        }
        s := d[pos + 2..pos + l]
        pos += l
        if mk == 0xC0 || mk == 0xC1 || mk == 0xC2 {
            j.progressive = mk == 0xC2
            if !jframe(j, s) {
                return false
            }
        } else if mk == 0xC4 {
            if !jtables_huff(j, s) {
                return false
            }
        } else if mk == 0xDB {
            if !jtables_quant(j, s) {
                return false
            }
        } else if mk == 0xDD {
            if len(s) != 2 {
                return false
            }
            j.ri = be16_at(s, 0)
        } else if mk == 0xDA {
            j.pos = pos
            if !jsos(j, s) {
                return false
            }
            // the entropy-coded data ends at the next marker (restart markers are inside it)
            pos = j.pos
            while pos + 1 < n && !(d[pos] == 0xFF && d[pos + 1] != 0 && (d[pos + 1] < 0xD0 || d[pos + 1] > 0xD7)) {
                pos += 1
            }
        } else if mk == 0xE0 {
            if len(s) >= 5 && s[..5] == "JFIF\0" {
                j.jfif = true
            }
        } else if mk == 0xEE {
            if len(s) >= 12 && s[..5] == "Adobe" {
                j.adobe = true
                j.transform = i64(s[11])
            }
        } else if mk >= 0xC0 && mk <= 0xCF && mk != 0xC8 && mk != 0xCC {
            // another kind of frame: lossless, hierarchical or arithmetic-coded
            return false
        } else if mk == 0xDC || mk == 0xDE || mk == 0xDF {
            // DNL, DHP, EXP
            return false
        }
        // anything else (APPn, COM, DAC, JPG extensions) is skipped
    }
    if j.ncomp == 0 {
        return false
    }
    for i in 0..j.ncomp {
        if !j.scanned[i] {
            return false
        }
    }
    true
}

// the IDCT of a progressive image, then upsampling and colour conversion into img
priv fn jpeg_output(j: *JDec, img: Image) {
    if j.progressive {
        blk: [64]i32
        for i in 0..j.ncomp {
            c := &j.comps[i]
            stride := c.bw * 8
            for yb in 0..c.bh {
                for xb in 0..c.bw {
                    b := jcoefs(c, xb, yb)
                    nz: i16 = 0
                    for k in 0..64 {
                        blk[k] = i32(b[k])
                        if k > 0 {
                            nz |= b[k]
                        }
                    }
                    at := yb * 8 * stride + xb * 8
                    if nz == 0 {
                        jidct_dc(i64(blk[0]), i64(c.q[0]), c.plane, at, stride)
                    } else {
                        jidct(blk[..], c.q[..], c.plane, at, stride)
                    }
                }
            }
        }
    }
    rows: [4][]u8
    tmp: [4][]u8
    sums := alloc[i64](j.w + 8)
    for i in 0..j.ncomp {
        tmp[i] = alloc[u8](j.w + 16)
    }
    ch := img.channels
    for y in 0..j.h {
        for i in 0..j.ncomp {
            rows[i] = jupsample(j, &j.comps[i], y, tmp[i], sums)
        }
        jconvert(j, rows, img.pix[y * j.w * ch..(y + 1) * j.w * ch])
    }
}

// Loads a JPEG file (see jpeg_decode). Allocates the pixels; the file's bytes stay in the arena too.
fn jpeg_load(path: str) -> (Image, bool) {
    data, ok := read_file(path)
    if !ok {
        none: Image
        return (none, false)
    }
    jpeg_decode(data)
}

// ---------- encoder ----------
// the example tables of the JPEG standard (Annex K), natural order
priv const STD_LUMA = [64]u8{
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
    14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
}
priv const STD_CHROMA = [64]u8{
    17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
}
priv const DC_LUMA_BITS = [16]u8{0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0}
priv const DC_CHROMA_BITS = [16]u8{0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0}
priv const DC_VALS = [12]u8{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}
priv const AC_LUMA_BITS = [16]u8{0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D}
priv const AC_LUMA_VALS = [162]u8{
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
    0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
    0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
    0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
    0xF9, 0xFA,
}
priv const AC_CHROMA_BITS = [16]u8{0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77}
priv const AC_CHROMA_VALS = [162]u8{
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
    0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
    0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
    0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
    0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
    0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
    0xF9, 0xFA,
}

// a Huffman code for encoding: code and length per symbol
priv struct JCode { code: [256]u16, size: [256]u8 }

priv fn jcode_build(t: *JCode, counts: []u8, syms: []u8) {
    code := 0
    k := 0
    for l in 1..=16 {
        for i in 0..i64(counts[l - 1]) {
            t.code[syms[k]] = u16(code)
            t.size[syms[k]] = u8(l)
            code += 1
            k += 1
        }
        code = code << 1
    }
}

priv struct JWriter {
    out: Vec[u8]
    acc: u64
    cnt: i64
}

// appends the low n bits of v (MSB first), with a 0 byte after every 0xFF
priv inline fn jput(w: *JWriter, v: i64, n: i64) {
    w.acc = w.acc << n | u64(v) & ((u64(1) << n) - 1)
    w.cnt += n
    while w.cnt >= 8 {
        w.cnt -= 8
        b := u8(w.acc >> w.cnt)
        w.out.push(b)
        if b == 0xFF {
            w.out.push(0)
        }
    }
}

priv fn jput16(o: *Vec[u8], v: i64) {
    o.push(u8(v >> 8))
    o.push(u8(v))
}

// libjpeg's accurate integer forward DCT (jfdctint.c) of 8x8 samples centred on 0; the
// results are 8 times the true coefficients
priv fn jfdct(d: []i64) {
    for r in 0..8 {
        p := d[r * 8..r * 8 + 8]
        t0 := p[0] + p[7]
        t7 := p[0] - p[7]
        t1 := p[1] + p[6]
        t6 := p[1] - p[6]
        t2 := p[2] + p[5]
        t5 := p[2] - p[5]
        t3 := p[3] + p[4]
        t4 := p[3] - p[4]
        t10 := t0 + t3
        t13 := t0 - t3
        t11 := t1 + t2
        t12 := t1 - t2
        p[0] = (t10 + t11) << 2
        p[4] = (t10 - t11) << 2
        z1 := (t12 + t13) * 4433
        p[2] = (z1 + t13 * 6270 + 1024) >> 11
        p[6] = (z1 - t12 * 15137 + 1024) >> 11
        z1 = t4 + t7
        z2 := t5 + t6
        z3 := t4 + t6
        z4 := t5 + t7
        z5 := (z3 + z4) * 9633
        t4 *= 2446
        t5 *= 16819
        t6 *= 25172
        t7 *= 12299
        z1 *= -7373
        z2 *= -20995
        z3 = z3 * -16069 + z5
        z4 = z4 * -3196 + z5
        p[7] = (t4 + z1 + z3 + 1024) >> 11
        p[5] = (t5 + z2 + z4 + 1024) >> 11
        p[3] = (t6 + z2 + z3 + 1024) >> 11
        p[1] = (t7 + z1 + z4 + 1024) >> 11
    }
    for c in 0..8 {
        t0 := d[c] + d[56 + c]
        t7 := d[c] - d[56 + c]
        t1 := d[8 + c] + d[48 + c]
        t6 := d[8 + c] - d[48 + c]
        t2 := d[16 + c] + d[40 + c]
        t5 := d[16 + c] - d[40 + c]
        t3 := d[24 + c] + d[32 + c]
        t4 := d[24 + c] - d[32 + c]
        t10 := t0 + t3
        t13 := t0 - t3
        t11 := t1 + t2
        t12 := t1 - t2
        d[c] = (t10 + t11 + 2) >> 2
        d[32 + c] = (t10 - t11 + 2) >> 2
        z1 := (t12 + t13) * 4433
        d[16 + c] = (z1 + t13 * 6270 + 16384) >> 15
        d[48 + c] = (z1 - t12 * 15137 + 16384) >> 15
        z1 = t4 + t7
        z2 := t5 + t6
        z3 := t4 + t6
        z4 := t5 + t7
        z5 := (z3 + z4) * 9633
        t4 *= 2446
        t5 *= 16819
        t6 *= 25172
        t7 *= 12299
        z1 *= -7373
        z2 *= -20995
        z3 = z3 * -16069 + z5
        z4 = z4 * -3196 + z5
        d[56 + c] = (t4 + z1 + z3 + 16384) >> 15
        d[40 + c] = (t5 + z2 + z4 + 16384) >> 15
        d[24 + c] = (t6 + z2 + z3 + 16384) >> 15
        d[8 + c] = (t7 + z1 + z4 + 16384) >> 15
    }
}

// number of bits of |v| (the JPEG magnitude category)
priv inline fn jcategory(v: i64) -> i64 {
    a := abs(v)
    if a == 0 { 0 } else { 64 - i64(clz(u64(a))) }
}

// transforms, quantises and writes the 8x8 block of samples at plane[at..] (stride per row)
priv fn jencode_block(w: *JWriter, plane: []u8, at: i64, stride: i64, q: []i64, pred: *i64, dct: *JCode, act: *JCode) {
    d: [64]i64
    for r in 0..8 {
        for c in 0..8 {
            d[r * 8 + c] = i64(plane[at + r * stride + c]) - 128
        }
    }
    jfdct(d[..])
    zz: [64]i64
    for k in 0..64 {
        z := ZIGZAG[k]
        v := d[z]
        dv := q[z]
        zz[k] = if v < 0 { -((-v + (dv >> 1)) / dv) } else { (v + (dv >> 1)) / dv }
    }
    diff := zz[0] - *pred
    *pred = zz[0]
    n := jcategory(diff)
    jput(w, i64(dct.code[n]), i64(dct.size[n]))
    if n > 0 {
        jput(w, if diff < 0 { diff - 1 } else { diff }, n)
    }
    run := 0
    for k in 1..64 {
        v := zz[k]
        if v == 0 {
            run += 1
            continue
        }
        while run >= 16 {
            jput(w, i64(act.code[0xF0]), i64(act.size[0xF0]))
            run -= 16
        }
        n = jcategory(v)
        sym := run << 4 | n
        jput(w, i64(act.code[sym]), i64(act.size[sym]))
        jput(w, if v < 0 { v - 1 } else { v }, n)
        run = 0
    }
    if run > 0 {
        jput(w, i64(act.code[0]), i64(act.size[0]))
    }
}

// the quantisation table for a quality 1..100, scaled from a standard one as libjpeg does
priv fn jquant(base: [64]u8, quality: i64, out: []u8) {
    scale := if quality < 50 { 5000 / quality } else { 200 - quality * 2 }
    for i in 0..64 {
        out[i] = u8(max(1, min(255, (i64(base[i]) * scale + 50) / 100)))
    }
}

priv fn jput_huff_table(o: *Vec[u8], class_id: u8, bits: []u8, vals: []u8) {
    o.push(class_id)
    o.extend(bits)
    o.extend(vals)
}

// Encodes an image as a baseline JPEG file in memory (allocates the result). quality is 1..100
// (clamped; 75 is a usual choice) and scales the example quantisation tables of the standard
// as libjpeg does; the Huffman tables are the standard's too. 1- and 2-channel images are
// written as greyscale, 3- and 4-channel ones as YCbCr, with the colour subsampled 2x2 (4:2:0)
// below quality 90 and kept at full resolution (4:4:4) from 90 on. Alpha is dropped. The
// image must not be empty and at most 65535 pixels wide and high.
fn jpeg_encode(img: Image, quality: i64) -> []u8 {
    assert img.w > 0 && img.h > 0 && img.w <= 65535 && img.h <= 65535, "jpeg_encode: empty or too large image"
    // everything is built in a region of its own; only the finished file is copied out
    r := region()
    enter(&r)
    data := jencode(img, max(1, min(100, quality)))
    leave()
    out := clone(data)
    region_free(&r)
    out
}

priv fn jencode(img: Image, quality: i64) -> []u8 {
    grey := img.channels <= 2
    sub := if grey || quality >= 90 { 1 } else { 2 }   // luma block columns / rows per MCU
    ncomp := if grey { 1 } else { 3 }
    ntab := if grey { 1 } else { 2 }    // luma tables, and chroma tables for colour
    o: Vec[u8]
    o.reserve(img.w * img.h / 2 + 1024)
    o.extend("\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00")
    ql: [64]u8
    qc: [64]u8
    jquant(STD_LUMA, quality, ql[..])
    jquant(STD_CHROMA, quality, qc[..])
    o.extend("\xFF\xDB")
    jput16(&o, 2 + 65 * ntab)
    for t in 0..ntab {
        o.push(u8(t))
        for k in 0..64 {
            o.push(if t == 0 { ql[ZIGZAG[k]] } else { qc[ZIGZAG[k]] })
        }
    }
    o.extend("\xFF\xC0")
    jput16(&o, 8 + 3 * ncomp)
    o.push(8)
    jput16(&o, img.h)
    jput16(&o, img.w)
    o.push(u8(ncomp))
    for c in 0..ncomp {
        o.push(u8(c + 1))
        o.push(if c == 0 { u8(sub << 4 | sub) } else { 0x11 })
        o.push(if c == 0 { 0 } else { 1 })
    }
    o.extend("\xFF\xC4")
    jput16(&o, 2 + (17 + 12 + 17 + 162) * ntab)
    jput_huff_table(&o, 0x00, DC_LUMA_BITS[..], DC_VALS[..])
    jput_huff_table(&o, 0x10, AC_LUMA_BITS[..], AC_LUMA_VALS[..])
    if !grey {
        jput_huff_table(&o, 0x01, DC_CHROMA_BITS[..], DC_VALS[..])
        jput_huff_table(&o, 0x11, AC_CHROMA_BITS[..], AC_CHROMA_VALS[..])
    }
    o.extend("\xFF\xDA")
    jput16(&o, 6 + 2 * ncomp)
    o.push(u8(ncomp))
    for c in 0..ncomp {
        o.push(u8(c + 1))
        o.push(if c == 0 { 0x00 } else { 0x11 })
    }
    o.push(0)
    o.push(63)
    o.push(0)
    codes := alloc[JCode](4)
    jcode_build(&codes[0], DC_LUMA_BITS[..], DC_VALS[..])
    jcode_build(&codes[1], AC_LUMA_BITS[..], AC_LUMA_VALS[..])
    jcode_build(&codes[2], DC_CHROMA_BITS[..], DC_VALS[..])
    jcode_build(&codes[3], AC_CHROMA_BITS[..], AC_CHROMA_VALS[..])
    // divisors for the coefficients, which jfdct leaves scaled by 8
    qd: [128]i64
    for i in 0..64 {
        qd[i] = i64(ql[i]) * 8
        qd[64 + i] = i64(qc[i]) * 8
    }
    // the planes, padded to whole MCUs by repeating the last column and row
    mw := 8 * sub
    mcux := (img.w + mw - 1) / mw
    mcuy := (img.h + mw - 1) / mw
    pw := mcux * mw
    ph := mcuy * mw
    planes: [3][]u8
    for c in 0..ncomp {
        planes[c] = alloc[u8](pw * ph)
    }
    ch := img.channels
    for y in 0..ph {
        sy := min(y, img.h - 1)
        for x in 0..pw {
            i := (sy * img.w + min(x, img.w - 1)) * ch
            if grey {
                planes[0][y * pw + x] = img.pix[i]
                continue
            }
            r := i64(img.pix[i])
            g := i64(img.pix[i + 1])
            b := i64(img.pix[i + 2])
            // libjpeg's fixed-point RGB -> YCbCr (jccolor.c)
            planes[0][y * pw + x] = u8((19595 * r + 38470 * g + 7471 * b + 32768) >> 16)
            planes[1][y * pw + x] = u8((-11059 * r - 21709 * g + 32768 * b + (128 << 16) + 32767) >> 16)
            planes[2][y * pw + x] = u8((32768 * r - 27439 * g - 5329 * b + (128 << 16) + 32767) >> 16)
        }
    }
    cw := pw
    if sub == 2 {
        // 2x2 averages for the chroma, with libjpeg's alternating rounding
        cw = pw / 2
        for c in 1..3 {
            half := alloc[u8](cw * (ph / 2))
            p := planes[c]
            for y in 0..ph / 2 {
                for x in 0..cw {
                    a := (2 * y) * pw + 2 * x
                    s := i64(p[a]) + i64(p[a + 1]) + i64(p[a + pw]) + i64(p[a + pw + 1])
                    half[y * cw + x] = u8((s + 1 + (x & 1)) >> 2)
                }
            }
            planes[c] = half
        }
    }
    w: JWriter
    w.out = o
    preds: [3]i64
    for my in 0..mcuy {
        for mx in 0..mcux {
            for v in 0..sub {
                for h in 0..sub {
                    at := (my * mw + v * 8) * pw + mx * mw + h * 8
                    jencode_block(&w, planes[0], at, pw, qd[..64], &preds[0], &codes[0], &codes[1])
                }
            }
            for c in 1..ncomp {
                at := my * 8 * cw + mx * 8
                jencode_block(&w, planes[c], at, cw, qd[64..], &preds[c], &codes[2], &codes[3])
            }
        }
    }
    // pad the last byte with 1 bits
    if w.cnt > 0 {
        jput(&w, 0x7F, 8 - w.cnt)
    }
    w.out.extend("\xFF\xD9")
    w.out.items()
}

// writes the image as a JPEG file of the given quality (see jpeg_encode); false if the file
// cannot be written (leaves nothing in the arena)
fn jpeg_save(path: str, img: Image, quality: i64) -> bool {
    m := mark()
    ok := write_file(path, jpeg_encode(img, quality))
    release(m)
    ok
}
