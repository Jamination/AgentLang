#!/usr/bin/env python3
"""Fixtures and expected output for the std.image tests.

    python3 tests/gen/images.py             write tests/std/data/img_*.{png,bmp}, the lists
                                            img_png.txt / img_bmp.txt / img_bad.txt and
                                            tests/std/image_{png,bmp,bad}.out
    python3 tests/gen/images.py check F...  decode PNG files written by png_encode with this
                                            script's own reader; prints "name w h channels crc"

Only the standard modules zlib and struct are used. The expected pixels are computed here from
the image model (never by decoding), so the AL decoders are checked against an independent
implementation. Each .out line is: file name, width, height, channels, CRC-32 of the pixels.
"""
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.path.join(ROOT, "tests", "std", "data")

_seed = 12345


def rnd():
    """Deterministic 16-bit pseudo-random number."""
    global _seed
    _seed = (_seed * 1103515245 + 12345) & 0x7FFFFFFF
    return _seed >> 15


# ---------------------------------------------------------------- PNG writer
NIN = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))


def pack_row(pixels, depth):
    """Samples of one scanline (a list of tuples) as PNG bytes."""
    samples = [s for px in pixels for s in px]
    if depth == 16:
        return b"".join(struct.pack(">H", s) for s in samples)
    if depth == 8:
        return bytes(samples)
    out = bytearray((len(samples) * depth + 7) // 8)
    for i, s in enumerate(samples):
        out[i * depth >> 3] |= s << (8 - depth - (i * depth & 7))
    return bytes(out)


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def filter_row(ft, cur, prev, bpp):
    out = bytearray([ft])
    for i, v in enumerate(cur):
        a = cur[i - bpp] if i >= bpp else 0
        b = prev[i]
        c = prev[i - bpp] if i >= bpp else 0
        pred = (0, a, b, (a + b) >> 1, paeth(a, b, c))[ft]
        out.append((v - pred) & 255)
    return bytes(out)


def filtered(rows, depth, nin, filters):
    """Scanlines with filter bytes; filters is 'cycle' or one filter type for every row."""
    bpp = max(1, nin * depth // 8)
    out = b""
    prev = None
    for y, pixels in enumerate(rows):
        cur = pack_row(pixels, depth)
        if prev is None:
            prev = bytes(len(cur))
        ft = (y + 1) % 5 if filters == "cycle" else filters
        out += filter_row(ft, cur, prev, bpp)
        prev = cur
    return out


ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]


def raw_image(img, filters="cycle"):
    """The uncompressed IDAT content of an image model."""
    rows, depth, nin = img["rows"], img["depth"], NIN[img["ctype"]]
    if not img.get("interlace"):
        return filtered(rows, depth, nin, filters)
    out = b""
    for xs, ys, dx, dy in ADAM7:
        sub = [row[xs::dx] for row in rows[ys::dy]]
        if sub and sub[0]:
            out += filtered(sub, depth, nin, filters)
    return out


def compress(raw, level=9, strategy=zlib.Z_DEFAULT_STRATEGY):
    c = zlib.compressobj(level, zlib.DEFLATED, 15, 9, strategy)
    return c.compress(raw) + c.flush()


def png_file(img, zdata=None, filters="cycle", level=9, strategy=zlib.Z_DEFAULT_STRATEGY, split=0,
             before=b"", after=b"", ihdr=None):
    """A PNG file for an image model. zdata replaces the compressed stream, split cuts it into
    IDAT chunks of that many bytes, before/after are extra chunks around the IDATs."""
    w, h = len(img["rows"][0]), len(img["rows"])
    if ihdr is None:
        ihdr = struct.pack(">IIBBBBB", w, h, img["depth"], img["ctype"], 0, 0, 1 if img.get("interlace") else 0)
    out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
    if img.get("palette") is not None:
        out += chunk(b"PLTE", bytes(v for rgb in img["palette"] for v in rgb))
    if img.get("trns") is not None:
        t = img["trns"]
        if img["ctype"] == 3:
            out += chunk(b"tRNS", bytes(t))
        else:
            out += chunk(b"tRNS", b"".join(struct.pack(">H", s) for s in t))
    out += before
    if zdata is None:
        zdata = compress(raw_image(img, filters), level, strategy)
    if split:
        for i in range(0, len(zdata), split):
            out += chunk(b"IDAT", zdata[i:i + split])
            if i == 0:
                out += chunk(b"IDAT", b"")
    else:
        out += chunk(b"IDAT", zdata)
    return out + after + chunk(b"IEND", b"")


def expected(img):
    """(channels, pixel bytes) that a decoder must produce for an image model."""
    depth, ctype, trns = img["depth"], img["ctype"], img.get("trns")
    out = bytearray()
    for row in img["rows"]:
        for px in row:
            if ctype == 3:
                out += bytes(img["palette"][px[0]])
                if trns is not None:
                    out.append(trns[px[0]] if px[0] < len(trns) else 255)
                continue
            for s in px:
                out.append(s >> 8 if depth == 16 else s * (255 // ((1 << depth) - 1)) if depth < 8 else s)
            if trns is not None:
                out.append(0 if tuple(px) == tuple(trns) else 255)
    channels = (3 if ctype == 3 else NIN[ctype]) + (1 if trns is not None else 0)
    return channels, bytes(out)


def model(w, h, ctype, depth, interlace=False, noise=3, npal=None):
    """An image model: smooth ramps plus a little noise, every sample within its range."""
    nin = NIN[ctype]
    top = (1 << depth) - 1
    if ctype == 3 and npal is not None:
        top = npal - 1
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            px = []
            for c in range(nin):
                v = (x * (top + 1) // w + y * (top + 1) // (2 * h) + c * (top + 1) // 3 + rnd() % noise) % (top + 1)
                px.append(v)
            row.append(tuple(px))
        rows.append(row)
    img = {"rows": rows, "depth": depth, "ctype": ctype, "interlace": interlace}
    if ctype == 3:
        n = npal if npal is not None else 1 << depth
        img["palette"] = [((i * 37 + 11) & 255, (i * 101 + 7) & 255, (255 - i * 13) & 255) for i in range(n)]
    return img


# ---------------------------------------------------------------- PNG reader (for `check`)
def png_read(data):
    """Decodes the PNG subset that png_encode writes: 8-bit, colour type 0/2/4/6, not interlaced."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "signature"
    pos, idat, hdr = 8, b"", None
    while True:
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        assert struct.unpack(">I", data[pos + 8 + n:pos + 12 + n])[0] == zlib.crc32(kind + body), "crc of %r" % kind
        pos += 12 + n
        if kind == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    assert pos == len(data), "data after IEND"
    w, h, depth, ctype, comp, filt, inter = hdr
    assert depth == 8 and ctype in (0, 2, 4, 6) and (comp, filt, inter) == (0, 0, 0), "header"
    ch = NIN[ctype]
    raw = zlib.decompress(idat)
    stride = w * ch
    assert len(raw) == (stride + 1) * h, "image data size"
    out = bytearray()
    prev = bytes(stride)
    for y in range(h):
        line = raw[y * (stride + 1):(y + 1) * (stride + 1)]
        ft, cur = line[0], bytearray(line[1:])
        assert ft <= 4, "filter type"
        for i in range(stride):
            a = cur[i - ch] if i >= ch else 0
            b = prev[i]
            c = prev[i - ch] if i >= ch else 0
            cur[i] = (cur[i] + (0, a, b, (a + b) >> 1, paeth(a, b, c))[ft]) & 255
        out += cur
        prev = cur
    return w, h, ch, bytes(out)


# ---------------------------------------------------------------- deflate bit streams by hand
class Bits:
    def __init__(self):
        self.acc, self.n, self.out = 0, 0, bytearray()

    def put(self, v, n):
        """n bits of v, least significant first (headers and extra bits)."""
        self.acc |= v << self.n
        self.n += n
        while self.n >= 8:
            self.out.append(self.acc & 255)
            self.acc >>= 8
            self.n -= 8

    def code(self, v, n):
        """A Huffman code of n bits, most significant first."""
        for i in range(n - 1, -1, -1):
            self.put(v >> i & 1, 1)

    def bytes(self):
        if self.n:
            self.put(0, 8 - self.n)
        return bytes(self.out)


def zwrap(raw_deflate, content=b""):
    return b"\x78\x9c" + raw_deflate + struct.pack(">I", zlib.adler32(content))


def bad_streams():
    """Malformed raw deflate streams, by name."""
    out = {}
    out["btype"] = bytes([0x07])                                # block type 3
    b = Bits()                                                  # fixed block: 'a', then a match 4 bytes back
    b.put(1, 1), b.put(1, 2)
    b.code(0x30 + ord("a"), 8), b.code(1, 7), b.code(3, 5), b.code(0, 7)
    out["dist"] = b.bytes()
    b = Bits()                                                  # dynamic block: 19 code length codes of 1 bit
    b.put(1, 1), b.put(2, 2), b.put(0, 5), b.put(0, 5), b.put(15, 4)
    for _ in range(19):
        b.put(1, 3)
    b.put(0, 32)
    out["huff"] = b.bytes()
    out["nlen"] = bytes([0x01, 0x03, 0x00, 0xFF, 0xFF]) + b"abc"   # stored block, LEN / NLEN mismatch
    b = Bits()                                                  # fixed block with the unused length code 286
    b.put(1, 1), b.put(1, 2), b.code(0xC6, 8), b.code(0, 7)
    out["sym286"] = b.bytes()
    b = Bits()                                                  # fixed block with the unused distance code 30
    b.put(1, 1), b.put(1, 2), b.code(0x30 + ord("a"), 8), b.code(1, 7), b.code(30, 5), b.code(0, 7)
    out["dist30"] = b.bytes()
    return out


# ---------------------------------------------------------------- BMP writer
def bmp_file(rows, bpp, top_down=False, hsize=40, comp=0, masks=None, palette=None, clr_used=0,
             pixel=None, planes=1, off=None, width=None):
    """rows: lists of pixel values (palette index, or what `pixel` packs to bytes)."""
    w, h = len(rows[0]), len(rows)
    stride = (w * bpp + 31) // 32 * 4
    body = b""
    for row in (rows if top_down else rows[::-1]):
        if bpp <= 8:
            line = bytearray((w * bpp + 7) // 8)
            for x, v in enumerate(row):
                line[x * bpp >> 3] |= v << (8 - bpp - (x * bpp & 7))
        else:
            line = b"".join(pixel(v) for v in row)
        body += bytes(line) + bytes(stride - len(line))
    hdr = struct.pack("<IiiHHIIiiII", hsize, w if width is None else width, -h if top_down else h, planes, bpp,
                      comp, len(body), 2835, 2835, clr_used, 0)
    extra = b""
    if masks:
        extra = b"".join(struct.pack("<I", m) for m in masks)
    if hsize > 40:
        hdr = (hdr + extra + bytes(hsize))[:hsize]
        if hsize >= 108:
            hdr = hdr[:56] + b"BGRs" + hdr[60:]
        extra = b""
    pal = b"".join(bytes([b, g, r, 0]) for r, g, b in palette) if palette else b""
    offbits = 14 + len(hdr) + len(extra) + len(pal)
    total = offbits + len(body)
    return b"BM" + struct.pack("<IHHI", total, 0, 0, offbits if off is None else off) + hdr + extra + pal + body


def field(v, mask):
    """What bmp_decode makes of the bits of v under mask."""
    sh = (mask & -mask).bit_length() - 1
    m = mask >> sh
    x = (v & mask) >> sh
    return x if m == 255 else (x * 255 + (m >> 1)) // m


def rgb_rows(w, h, alpha=False):
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            px = [(x * 255 // max(w - 1, 1) + rnd() % 5) & 255, (y * 255 // max(h - 1, 1)) & 255, (x * 13 + y * 29) & 255]
            if alpha:
                px.append((x * 40 + y * 17 + 9) & 255)
            row.append(tuple(px))
        rows.append(row)
    return rows


# ---------------------------------------------------------------- the fixture sets
def png_fixtures():
    out = []        # (name, file bytes, model)

    def add(name, img, **kw):
        out.append((name, png_file(img, **kw), img))

    # every colour type and bit depth, plain and interlaced, filters cycling through all five
    for ctype, tag, depths in ((0, "g", (1, 2, 4, 8, 16)), (2, "rgb", (8, 16)), (3, "pal", (1, 2, 4, 8)),
                               (4, "ga", (8, 16)), (6, "rgba", (8, 16))):
        for depth in depths:
            for inter in (False, True):
                add("%s%d%s" % (tag, depth, "i" if inter else ""), model(13, 11, ctype, depth, inter))
    # transparency: colour keys and palette alpha
    for name, ctype, depth, inter in (("trns_g8", 0, 8, False), ("trns_g2i", 0, 2, True), ("trns_g16", 0, 16, False),
                                      ("trns_rgb8i", 2, 8, True), ("trns_rgb16", 2, 16, False)):
        img = model(9, 10, ctype, depth, inter, noise=1)
        img["trns"] = img["rows"][4][3]
        add(name, img)
    for name, depth, npal, ntrns, inter in (("trns_pal8", 8, 200, 200, False), ("trns_pal4", 4, 16, 5, False),
                                            ("trns_pal2i", 2, 4, 4, True), ("trns_pal1", 1, 2, 1, False)):
        img = model(11, 9, 3, depth, inter, npal=npal)
        img["trns"] = [(i * 67 + 30) & 255 for i in range(ntrns)]
        add(name, img)
    # a palette with fewer entries than the bit depth allows
    add("pal8_short", model(12, 12, 3, 8, npal=40))
    # sizes that leave Adam7 passes empty
    for w, h, ctype, depth in ((1, 1, 2, 8), (1, 1, 0, 1), (2, 3, 6, 8), (5, 1, 2, 8), (1, 7, 4, 8), (3, 3, 3, 1),
                               (4, 4, 0, 4), (9, 2, 6, 16)):
        add("tiny_%dx%d_%d_%d" % (w, h, ctype, depth), model(w, h, ctype, depth, True))
    add("tiny_1x1", model(1, 1, 6, 8))
    # one filter type for the whole image
    for ft in range(5):
        add("filter%d" % ft, model(16, 16, 6, 8, noise=40), filters=ft)
        add("filter%d_16" % ft, model(10, 10, 6, 16, noise=1000), filters=ft)
        add("filter%d_g2" % ft, model(21, 6, 0, 2), filters=ft)
    # compressed stream variants
    photo = model(40, 30, 2, 8, noise=7)
    add("z_stored", photo, level=0)
    add("z_fixed", photo, strategy=zlib.Z_FIXED)
    add("z_fast", photo, level=1)
    add("z_best", photo, level=9)
    add("z_huffman", photo, strategy=zlib.Z_HUFFMAN_ONLY)
    add("z_rle", photo, strategy=zlib.Z_RLE)
    add("z_split", photo, split=7)
    text = chunk(b"tEXt", b"Comment\x00std.image test fixture")
    add("z_chunks", photo, before=chunk(b"gAMA", struct.pack(">I", 45455)) + chunk(b"pHYs", struct.pack(">IIB", 2835, 2835, 1)) + text,
        after=text + chunk(b"prIv", b"\x01\x02\x03"))
    # matches that reach far back: noisy rows repeating every 40 rows (24 000 bytes apart)
    tile = model(200, 40, 2, 8, noise=4)
    far = dict(tile, rows=[tile["rows"][y % 40] for y in range(150)])
    add("z_far", far, filters=0)
    # larger images
    add("big_rgba", model(80, 60, 6, 8, noise=5))
    add("big_rgba_i", model(80, 60, 6, 8, True, noise=5))
    add("big_pal", model(150, 70, 3, 8, noise=2))
    add("big_g16", model(64, 64, 0, 16, noise=300))
    flat = model(64, 64, 6, 8, noise=1)
    flat["rows"] = [[(10, 200, 30, 255)] * 64 for _ in range(64)]
    add("flat", flat, filters=0)
    return out


def png_bad():
    out = []        # (name, file bytes)
    base = model(8, 8, 2, 8)
    good = png_file(base)
    raw = raw_image(base)
    pal = model(8, 8, 3, 8, npal=16)

    def add(name, data):
        out.append((name, data))

    def patched(data, at, value):
        return data[:at] + bytes([value]) + data[at + 1:]

    def with_ihdr(w=8, h=8, depth=8, ctype=2, comp=0, filt=0, inter=0):
        return png_file(base, ihdr=struct.pack(">IIBBBBB", w, h, depth, ctype, comp, filt, inter))

    idat = good.index(b"IDAT")
    add("empty", b"")
    add("sig_only", good[:8])
    add("sig", patched(good, 0, 0x88))
    add("crc_ihdr", patched(good, 17, good[17] ^ 1))
    add("crc_idat", patched(good, idat + 9, good[idat + 9] ^ 0x40))
    add("crc_iend", good[:-1] + bytes([good[-1] ^ 1]))
    add("chunk_len", good[:idat - 4] + struct.pack(">I", 100000) + good[idat:])
    add("trunc_half", good[:len(good) // 2])
    add("trunc_iend", good[:-12])
    add("trunc_1", good[:-1])
    z = compress(raw)
    add("adler", png_file(base, zdata=z[:-1] + bytes([z[-1] ^ 1])))
    add("zlib_cut", png_file(base, zdata=z[:len(z) // 2]))
    add("zlib_cut4", png_file(base, zdata=z[:-4]))
    add("zlib_method", png_file(base, zdata=b"\x77\x9d" + z[2:]))
    add("zlib_check", png_file(base, zdata=b"\x78\x9d" + z[2:]))
    add("zlib_dict", png_file(base, zdata=b"\x78\xbb" + z[2:]))
    add("zlib_window", png_file(base, zdata=b"\x88\x1c" + z[2:]))
    add("short", png_file(base, zdata=compress(raw[:-1])))
    add("long", png_file(base, zdata=compress(raw + b"\x00")))
    add("rows_missing", png_file(base, zdata=compress(raw[:25 * 4])))
    add("filter5", png_file(base, zdata=compress(raw[:25] + b"\x05" + raw[26:])))
    add("no_idat", good[:idat - 4] + chunk(b"IEND", b""))
    add("idat_empty", png_file(base, zdata=b""))
    add("depth", with_ihdr(depth=4))
    add("depth3", with_ihdr(depth=3, ctype=0))
    add("depth_pal16", with_ihdr(depth=16, ctype=3))
    add("ctype", with_ihdr(ctype=5))
    add("ctype1", with_ihdr(ctype=1))
    add("w0", with_ihdr(w=0))
    add("h0", with_ihdr(h=0))
    add("w_huge", with_ihdr(w=0x80000000))
    add("compression", with_ihdr(comp=1))
    add("filter_method", with_ihdr(filt=1))
    add("interlace", with_ihdr(inter=2))
    add("bomb", with_ihdr(w=16000, h=16000, ctype=6))
    add("ihdr_len", good[:8] + chunk(b"IHDR", good[16:29] + b"\x00") + good[33:])
    add("ihdr_twice", good[:33] + good[8:33] + good[33:])
    add("ihdr_late", good[:8] + chunk(b"gAMA", struct.pack(">I", 45455)) + good[8:])
    add("critical", png_file(base, before=chunk(b"ABCD", b"x")))
    add("no_plte", png_file(dict(pal, palette=None)))
    add("plte_len", good[:33] + chunk(b"PLTE", b"\x01\x02\x03\x04") + good[33:])
    add("plte_twice", good[:33] + chunk(b"PLTE", b"\x01\x02\x03") * 2 + good[33:])
    add("plte_late", png_file(dict(pal, palette=None), after=chunk(b"PLTE", bytes(48))))
    high = dict(pal, rows=[list(r) for r in pal["rows"]])
    high["rows"][5][2] = (16,)
    add("pal_index", png_file(high))
    add("trns_len", png_file(base, before=chunk(b"tRNS", b"\x00\x01\x00\x02\x00")))
    add("trns_pal_long", png_file(pal, before=chunk(b"tRNS", bytes(17))))
    add("trns_rgba", png_file(model(4, 4, 6, 8), before=chunk(b"tRNS", bytes(6))))
    add("trns_late", png_file(base, after=chunk(b"tRNS", bytes(6))))
    for name, stream in bad_streams().items():
        add("deflate_" + name, png_file(base, zdata=zwrap(stream, raw)))
    return out


def bmp_fixtures():
    out = []        # (name, file bytes, channels, pixel bytes)

    def flat(rows):
        return bytes(v for row in rows for px in row for v in px)

    def bgr(px):
        return bytes([px[2], px[1], px[0]])

    def bgra(px):
        return bytes([px[2], px[1], px[0], px[3]])

    def bgrx(px):
        return bytes([px[2], px[1], px[0], 0])

    rows = rgb_rows(5, 3)
    out.append(("24", bmp_file(rows, 24, pixel=bgr), 3, flat(rows)))
    rows = rgb_rows(7, 4)
    out.append(("24_topdown", bmp_file(rows, 24, top_down=True, pixel=bgr), 3, flat(rows)))
    rows = rgb_rows(1, 1)
    out.append(("24_1x1", bmp_file(rows, 24, pixel=bgr), 3, flat(rows)))
    rows = rgb_rows(6, 5)
    out.append(("24_nopad", bmp_file(rows, 24, pixel=bgr)[:-2], 3, flat(rows)))
    rows = rgb_rows(6, 5, True)
    out.append(("32_alpha", bmp_file(rows, 32, pixel=bgra), 4, flat(rows)))
    opaque = [[px[:3] + (255,) for px in row] for row in rows]
    out.append(("32_noalpha", bmp_file(rows, 32, pixel=bgrx), 4, flat(opaque)))
    out.append(("32_topdown", bmp_file(rows, 32, top_down=True, pixel=bgra), 4, flat(rows)))
    rgb = [[px[:3] for px in row] for row in rows]
    std = (0xFF0000, 0xFF00, 0xFF)
    out.append(("32_bitfields", bmp_file(rows, 32, comp=3, masks=std, pixel=bgrx), 3, flat(rgb)))
    out.append(("32_alphafields", bmp_file(rows, 32, comp=6, masks=std + (0xFF000000,), pixel=bgra), 4, flat(rows)))
    out.append(("32_v2", bmp_file(rows, 32, hsize=52, comp=3, masks=std, pixel=bgrx), 3, flat(rgb)))
    out.append(("32_v3", bmp_file(rows, 32, hsize=56, comp=3, masks=std + (0xFF000000,), pixel=bgra), 4, flat(rows)))
    rgba_order = (0xFF, 0xFF00, 0xFF0000, 0xFF000000)
    out.append(("32_v4", bmp_file(rows, 32, hsize=108, comp=3, masks=rgba_order, pixel=bytes), 4, flat(rows)))
    out.append(("32_v5", bmp_file(rows, 32, hsize=124, comp=3, masks=std + (0xFF000000,), pixel=bgra), 4, flat(rows)))
    out.append(("32_v5_rgb", bmp_file(rows, 32, hsize=124, pixel=bgra), 4, flat(rows)))
    # unusual masks: 10-10-10-2 and 5-6-5 in 32 bits
    deep = (0x3FF00000, 0xFFC00, 0x3FF, 0xC0000000)
    words = [[(rnd() << 16 | rnd()) & 0xFFFFFFFF for _ in range(7)] for _ in range(5)]
    words[0][0] |= 0xC0000000
    pix = bytes(field(v, m) for row in words for v in row for m in deep)
    out.append(("32_10bit", bmp_file(words, 32, hsize=124, comp=3, masks=deep, pixel=lambda v: struct.pack("<I", v)), 4, pix))
    m565 = (0xF800, 0x7E0, 0x1F)
    pix = bytes(field(v, m) for row in words for v in row for m in m565)
    out.append(("32_565", bmp_file(words, 32, comp=3, masks=m565, pixel=lambda v: struct.pack("<I", v)), 3, pix))
    # palettised
    for bpp, w, h, used in ((8, 9, 6, 0), (8, 10, 3, 20), (4, 7, 5, 0), (4, 9, 4, 6), (1, 19, 5, 0), (1, 8, 2, 2)):
        n = used if used else 1 << bpp
        palette = [((i * 53 + 5) & 255, (i * 97 + 1) & 255, (250 - i * 9) & 255) for i in range(n)]
        idx = [[(x * 3 + y * 5 + rnd() % 3) % n for x in range(w)] for y in range(h)]
        pix = bytes(v for row in idx for i in row for v in palette[i])
        name = "pal%d%s" % (bpp, "_used" if used else "")
        out.append((name, bmp_file(idx, bpp, palette=palette, clr_used=used), 3, pix))
        if bpp == 8 and not used:
            out.append(("pal8_topdown", bmp_file(idx, bpp, top_down=True, palette=palette), 3, pix))
    return out


def bmp_bad():
    rows = rgb_rows(6, 5)

    def bgr(px):
        return bytes([px[2], px[1], px[0]])

    good = bmp_file(rows, 24, pixel=bgr)
    palette = [(i, i, i) for i in range(4)]
    idx = [[(x + y) % 4 for x in range(6)] for y in range(4)]
    high = [list(r) for r in idx]
    high[2][3] = 9
    words = [[0x12345678] * 4] * 2

    def word(v):
        return struct.pack("<I", v)

    return [
        ("bmp_empty", b""),
        ("bmp_magic", b"BN" + good[2:]),
        ("bmp_header_cut", good[:40]),
        ("bmp_trunc", good[:-3]),
        ("bmp_trunc_half", good[:len(good) // 2]),
        ("bmp_rle8", bmp_file(idx, 8, comp=1, palette=palette, clr_used=4)),
        ("bmp_16bit", bmp_file([[0] * 4] * 2, 16, pixel=lambda v: b"\x00\x00")),
        ("bmp_w0", bmp_file(rows, 24, pixel=bgr, width=0)),
        ("bmp_w_negative", bmp_file(rows, 24, pixel=bgr, width=-6)),
        ("bmp_w_huge", bmp_file(rows, 24, pixel=bgr, width=0x7FFFFFFF)),
        ("bmp_off", bmp_file(rows, 24, pixel=bgr, off=100000)),
        ("bmp_off_late", bmp_file(rows, 24, pixel=bgr, off=60)),
        ("bmp_core_header", b"BM" + struct.pack("<IHHI", 26 + 3, 0, 0, 26) + struct.pack("<IHHHH", 12, 1, 1, 1, 24) + b"\x00\x00\x00"),
        ("bmp_planes", bmp_file(rows, 24, pixel=bgr, planes=2)),
        ("bmp_mask_split", bmp_file(words, 32, comp=3, masks=(0xFF00FF, 0xFF00, 0xFF), pixel=word)),
        ("bmp_mask_zero", bmp_file(words, 32, comp=3, masks=(0, 0xFF00, 0xFF), pixel=word)),
        ("bmp_pal_index", bmp_file(high, 8, palette=palette, clr_used=4)),
        ("bmp_pal_cut", bmp_file(idx, 8, palette=palette, clr_used=4)[:60]),
        ("bmp_pal_many", bmp_file(idx, 4, palette=palette, clr_used=17)),
    ]


def generate():
    os.makedirs(DATA, exist_ok=True)
    for old in os.listdir(DATA):
        if old.startswith("img_"):
            os.remove(os.path.join(DATA, old))

    def save(name, data):
        with open(os.path.join(DATA, name), "wb") as f:
            f.write(data)

    def text(path, lines):
        with open(path, "w") as f:
            f.write("".join(line + "\n" for line in lines))

    names, lines = [], []
    for name, data, img in png_fixtures():
        channels, pix = expected(img)
        w, h = len(img["rows"][0]), len(img["rows"])
        assert len(pix) == w * h * channels
        save("img_%s.png" % name, data)
        names.append("img_%s.png" % name)
        lines.append("img_%s.png %d %d %d %x" % (name, w, h, channels, zlib.crc32(pix)))
    text(os.path.join(DATA, "img_png.txt"), names)
    text(os.path.join(ROOT, "tests", "std", "image_png.out"), lines)

    names, lines = [], []
    for name, data, channels, pix in bmp_fixtures():
        w, h = struct.unpack("<ii", data[18:26])
        save("img_%s.bmp" % name, data)
        names.append("img_%s.bmp" % name)
        lines.append("img_%s.bmp %d %d %d %x" % (name, w, abs(h), channels, zlib.crc32(pix)))
    text(os.path.join(DATA, "img_bmp.txt"), names)
    text(os.path.join(ROOT, "tests", "std", "image_bmp.out"), lines)

    names = []
    for name, data in png_bad():
        save("img_bad_%s.png" % name, data)
        names.append("img_bad_%s.png" % name)
    for name, data in bmp_bad():
        save("img_bad_%s.bmp" % name, data)
        names.append("img_bad_%s.bmp" % name)
    text(os.path.join(DATA, "img_bad.txt"), names)
    text(os.path.join(ROOT, "tests", "std", "image_bad.out"), [name + " false" for name in names])


def check(paths):
    for path in paths:
        with open(path, "rb") as f:
            w, h, ch, pix = png_read(f.read())
        print(os.path.basename(path), w, h, ch, "%x" % zlib.crc32(pix))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "check":
        check(sys.argv[2:])
    else:
        generate()
