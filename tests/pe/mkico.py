#!/usr/bin/env python3
"""Writes an icon file (.ico) for the tests of `alc build --icon` and for examples/starter:
the same picture at 16, 32 and 48 pixels (32-bit bitmaps) and at 256 pixels (a PNG).

  mkico.py out.ico [--zero-depth]   --zero-depth: the file's directory says 0 planes and 0 bits
                                    per pixel for every image (some tools write that); alc
                                    then takes both from the images.
"""
import struct
import sys
import zlib


def pixel(u, v):
    """the picture at (u, v) in [0, 1) x [0, 1): (r, g, b, a)"""
    # a rounded square, dark blue to violet from top to bottom
    r = 0.22
    dx = max(abs(u - 0.5) - (0.5 - r), 0.0)
    dy = max(abs(v - 0.5) - (0.5 - r), 0.0)
    if dx * dx + dy * dy > (r - 0.02) ** 2:
        return (0, 0, 0, 0)
    bg = (int(27 + 60 * v), int(42 + 10 * v), int(110 + 60 * v), 255)
    # an orange "A": a triangle with a triangular hole and a bar
    x = abs(u - 0.5)
    y = v - 0.18
    if 0 <= y <= 0.64 and x <= 0.36 * y / 0.64 + 0.03:
        inner = y >= 0.2 and x <= 0.36 * (y - 0.2) / 0.64
        bar = 0.40 <= y <= 0.50
        if not inner or bar:
            return (255, 140 + int(60 * (1 - v)), 26, 255)
    return bg


def render(n):
    """n x n pixels, rows from the top, RGBA, each the mean of 4 x 4 samples"""
    rows = []
    for py in range(n):
        row = []
        for px in range(n):
            acc = [0, 0, 0, 0]
            for sy in range(4):
                for sx in range(4):
                    c = pixel((px + (sx + 0.5) / 4) / n, (py + (sy + 0.5) / 4) / n)
                    # (colour weighted by alpha, so that edges do not darken)
                    acc[0] += c[0] * c[3]
                    acc[1] += c[1] * c[3]
                    acc[2] += c[2] * c[3]
                    acc[3] += c[3]
            a = acc[3]
            row.append((acc[0] // a, acc[1] // a, acc[2] // a, a // 16) if a else (0, 0, 0, 0))
        rows.append(row)
    return rows


def bitmap(n):
    """a 32-bit bitmap without file header: twice the height (colours, then the 1-bit mask)"""
    rows = render(n)
    out = struct.pack("<IiiHHIIiiII", 40, n, 2 * n, 1, 32, 0, 0, 0, 0, 0, 0)
    for row in reversed(rows):
        out += b"".join(struct.pack("<BBBB", b, g, r, a) for (r, g, b, a) in row)
    mask_row = (n + 31) // 32 * 4
    for row in reversed(rows):
        bits = bytearray(mask_row)
        for x, c in enumerate(row):
            if c[3] == 0:
                bits[x // 8] |= 0x80 >> (x % 8)
        out += bytes(bits)
    return out


def png(n):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    raw = b"".join(b"\0" + b"".join(bytes(c) for c in row) for row in render(n))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", stored_zlib(raw)) + chunk(b"IEND", b""))


def stored_zlib(data):
    """a zlib stream of stored (uncompressed) deflate blocks: the same bytes with every zlib
    build (zlib.compress differs between zlib and zlib-ng, and the tests check a CRC of it)"""
    out = b"\x78\x01"
    for i in range(0, len(data), 65535):
        block = data[i:i + 65535]
        last = 1 if i + 65535 >= len(data) else 0
        out += struct.pack("<BHH", last, len(block), len(block) ^ 0xFFFF) + block
    return out + struct.pack(">I", zlib.adler32(data))


def main():
    args = sys.argv[1:]
    zero = "--zero-depth" in args
    args = [a for a in args if a != "--zero-depth"]
    if len(args) != 1:
        print(__doc__)
        sys.exit(2)
    images = [(n, bitmap(n)) for n in (16, 32, 48)] + [(256, png(256))]
    at = 6 + 16 * len(images)
    out = struct.pack("<HHH", 0, 1, len(images))
    for (n, img) in images:
        out += struct.pack("<BBBBHHII", n & 255, n & 255, 0, 0, 0 if zero else 1, 0 if zero else 32, len(img), at)
        at += len(img)
    for (_, img) in images:
        out += img
    open(args[0], "wb").write(out)


if __name__ == "__main__":
    main()
