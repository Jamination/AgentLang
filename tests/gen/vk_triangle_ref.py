#!/usr/bin/env python3
"""Reference image for tests/sys/vk_triangle.al, computed without a GPU.

    python3 tests/gen/vk_triangle_ref.py                 write tests/sys/data/vk_triangle.ref
    python3 tests/gen/vk_triangle_ref.py --compare X.bmp compare a 24-bit BMP written by
                                                         examples/vk_triangle.al with it

The image is 256x256 RGBA8 (raw, row 0 = top). A triangle with the vertices and colours used by
the test is rasterised at pixel centres with barycentric interpolation, over the clear colour.
The comparison uses the tolerance of the test: a pixel differs if any channel is off by more
than 8, and at most 0.5% of the pixels may differ.
"""
import os
import struct
import sys

SIZE = 256
CLEAR = (51, 51, 102, 255)                       # 0.2, 0.2, 0.4, 1.0
# (x, y) in normalised device coordinates (y down), (r, g, b)
VERTS = [((0.0, -0.75), (1.0, 0.0, 0.0)),
         ((0.75, 0.75), (0.0, 1.0, 0.0)),
         ((-0.75, 0.75), (0.0, 0.0, 1.0))]
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REF = os.path.join(ROOT, "tests", "sys", "data", "vk_triangle.ref")


def edge(a, b, p):
    return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])


def render():
    pts = [((x + 1.0) * SIZE / 2, (y + 1.0) * SIZE / 2) for (x, y), _ in VERTS]
    area = edge(pts[0], pts[1], pts[2])
    out = bytearray()
    for y in range(SIZE):
        for x in range(SIZE):
            p = (x + 0.5, y + 0.5)
            w = [edge(pts[1], pts[2], p) / area, edge(pts[2], pts[0], p) / area,
                 edge(pts[0], pts[1], p) / area]
            if min(w) > 0.0:                     # no pixel centre lies exactly on an edge
                rgb = [sum(w[i] * VERTS[i][1][c] for i in range(3)) for c in range(3)]
                out += bytes(int(v * 255.0 + 0.5) for v in rgb) + b"\xff"
            else:
                out += bytes(CLEAR)
    return bytes(out)


def read_bmp(path):
    data = open(path, "rb").read()
    offset, = struct.unpack_from("<I", data, 10)
    width, height, _, bpp = struct.unpack_from("<iiHH", data, 18)
    assert (width, height, bpp) == (SIZE, SIZE, 24), "expected a 256x256 24-bit BMP"
    out = bytearray()
    for y in range(SIZE):
        row = offset + (SIZE - 1 - y) * SIZE * 3  # rows are stored bottom-up, pixels as BGR
        for x in range(SIZE):
            b, g, r = data[row + x * 3: row + x * 3 + 3]
            out += bytes((r, g, b, 255))
    return bytes(out)


def main():
    ref = render()
    if len(sys.argv) == 3 and sys.argv[1] == "--compare":
        got = read_bmp(sys.argv[2])
        bad = sum(1 for i in range(0, len(ref), 4)
                  if any(abs(ref[i + c] - got[i + c]) > 8 for c in range(4)))
        worst = max(abs(a - b) for a, b in zip(ref, got))
        limit = SIZE * SIZE // 200
        print("differing pixels: %d (limit %d), largest channel difference: %d" % (bad, limit, worst))
        sys.exit(0 if bad <= limit else 1)
    with open(REF, "wb") as f:
        f.write(ref)
    covered = sum(1 for i in range(0, len(ref), 4) if ref[i:i + 4] != bytes(CLEAR))
    print("wrote %s: %d bytes, %d covered pixels" % (os.path.relpath(REF, ROOT), len(ref), covered))


if __name__ == "__main__":
    main()
