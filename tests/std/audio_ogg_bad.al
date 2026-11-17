// std.audio: damaged Ogg Vorbis files never stop the program. Truncated files and changed
// bytes are refused by the page layer (lengths, CRC); changed bytes with the page CRCs
// recomputed reach the Vorbis headers and audio packets, where every value from the file is
// checked: decoding succeeds or fails, nothing faults. Whole-file decoding, streaming and
// seeking are run on every damaged file.
use std.audio

// CRC of an Ogg page (polynomial 0x04C11DB7, bit by bit; the CRC field counts as zero)
fn page_crc(p: []u8) -> u32 {
    crc: u32 = 0
    for i in 0..len(p) {
        b := if i >= 22 && i < 26 { u8(0) } else { p[i] }
        crc ^= u32(b) << 24
        for k in 0..8 {
            crc = if crc & 0x80000000 != 0 { (crc << 1) ^ 0x04C11DB7 } else { crc << 1 }
        }
    }
    crc
}

// recomputes the CRC of every page that is still well-formed
fn fix_crcs(d: []u8) {
    p := 0
    while p + 27 <= len(d) && d[p] == 'O' && d[p + 1] == 'g' && d[p + 2] == 'g' && d[p + 3] == 'S' {
        nseg := i64(d[p + 26])
        if p + 27 + nseg > len(d) {
            return
        }
        size := 27 + nseg
        for i in 0..nseg {
            size += i64(d[p + 27 + i])
        }
        if p + size > len(d) {
            return
        }
        crc := page_crc(d[p..p + size])
        for i in 0..4 {
            d[p + 22 + i] = u8(crc >> u32(8 * i))
        }
        p += size
    }
}

// the offsets of all packet bytes (page bodies)
fn page_bodies(d: str) -> []i64 {
    out := vec[i64]()
    p := 0
    while p + 27 <= len(d) {
        nseg := i64(d[p + 26])
        size := 0
        for i in 0..nseg {
            size += i64(d[p + 27 + i])
        }
        for i in p + 27 + nseg..p + 27 + nseg + size {
            out.push(i)
        }
        p += 27 + nseg + size
    }
    out.items()
}

rng: u64 = 0x2545F4914F6CDD1D

fn rand_below(n: i64) -> i64 {
    rng ^= rng << 13
    rng ^= rng >> 7
    rng ^= rng << 17
    i64(rng % u64(n))
}

// decodes whole, streams in pieces with seeks; returns (whole ok, frames)
fn exercise(d: str) -> (bool, i64) {
    s, ok := ogg_decode(d)
    st, sok := ogg_open(d)
    if sok {
        buf := alloc[f32](300 * st.channels)
        for i in 0..4 {
            ogg_read(st, buf, 300)
        }
        ogg_seek(st, st.frames / 2)
        while ogg_read(st, buf, 300) == 300 {}
        ogg_rewind(st)
        ogg_read(st, buf, 300)
    }
    (ok, frames(s))
}

fn main() {
    for name in []str{"stereo", "mono", "6ch"} {
        data, ok := read_file(fmt("tests/std/data/ogg_", name, ".ogg"))
        assert ok, "fixture missing"
        full, _ := ogg_decode(data)
        // every truncation (in steps): a cut inside a page fails, a cut at a page boundary
        // gives the frames of the pages before it
        cut_ok := 0
        cut_bad := 0
        shorter := true
        for n in 0..len(data) by 37 {
            m := mark()
            ok, f := exercise(data[..n])
            if ok {
                cut_ok += 1
                shorter = shorter && f <= frames(full)
            } else {
                cut_bad += 1
            }
            release(m)
        }
        // changed bytes: the CRC check refuses them
        crc_bad := 0
        tries := 0
        for i in 0..200 {
            m := mark()
            d := clone(data)
            at := rand_below(len(d))
            d[at] ^= u8(1 + rand_below(255))
            ok, _ := exercise(d)
            tries += 1
            if !ok {
                crc_bad += 1
            }
            release(m)
        }
        // changed bytes with valid CRCs: the Vorbis layer sees them (half of the cases change
        // only packet data, the others also page headers)
        bodies := page_bodies(data)
        fuzz_ok := 0
        fuzz_bad := 0
        for i in 0..600 {
            m := mark()
            d := clone(data)
            for k in 0..1 + rand_below(4) {
                at := rand_below(len(d))
                if i % 2 == 0 {
                    at = bodies[rand_below(len(bodies))]
                }
                d[at] = u8(rand_below(256))
            }
            fix_crcs(d)
            ok, _ := exercise(d)
            if ok {
                fuzz_ok += 1
            } else {
                fuzz_bad += 1
            }
            release(m)
        }
        print(name, "truncated:", cut_ok, "decoded,", cut_bad, "refused,", shorter, "| changed:", crc_bad, "of", tries, "refused | fuzzed:", fuzz_ok, "decoded,", fuzz_bad, "refused")
    }
    // the headers alone: a valid stream without audio
    data, _ := read_file("tests/std/data/ogg_stereo.ogg")
    p := 0
    for page in 0..2 {
        nseg := i64(data[p + 26])
        size := 27 + nseg
        for i in 0..nseg {
            size += i64(data[p + 27 + i])
        }
        p += size
    }
    s, ok := ogg_decode(data[..p])
    print("headers only:", ok, frames(s), ogg_error())
    _, ok2 := ogg_decode(data[..p - 1])
    print("headers cut:", ok2, ogg_error())
}
