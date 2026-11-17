#!/usr/bin/env python3
"""Generates the JPEG fixtures of tests/std/data (jpeg_*.jpg, their reference decodes
jpeg_*.png, the lists jpeg.txt and jpeg_bad.txt) for tests/std/image_jpeg*.al.

The encoder and the reference decoder are libjpeg-turbo 2.1.5 (its TurboJPEG DLL, which ships
with Audacity on the machine where the files were made), driven through tests/gen/jpeg_tj.c;
jpeg_gdi.jpg comes from Windows' own encoder (System.Drawing / WIC) through PowerShell. Only
the standard library of Python is used (zlib to write the reference PNGs). Windows:

    gcc -O2 -o tmp/jpeg/jpeg_tj.exe tests/gen/jpeg_tj.c
    python3 tests/gen/jpegs.py tmp/jpeg/jpeg_tj.exe

The reference decodes are libjpeg-turbo's defaults (accurate integer IDCT, fancy upsampling);
a YCCK file is decoded to CMYK and turned into RGB as std.image does (Adobe's inverted CMYK:
channel = C * K / 255, rounded). Malformed files (jpeg_bad_*.jpg) are made by editing valid
ones; each must be rejected.
"""
import os
import struct
import subprocess
import sys
import zlib

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
OUT = os.path.join(ROOT, "tests", "std", "data")
TMP = os.path.join(ROOT, "tmp", "jpeg")
TOOL = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(TMP, "jpeg_tj.exe"))


def picture(w, h, ch, seed=1):
    """deterministic test picture: gradients, a disc with a hard edge, thin lines, some noise"""
    out = bytearray()
    s = seed
    for y in range(h):
        for x in range(w):
            for c in range(ch):
                v = (x * 255 // max(w - 1, 1)) if c % 3 == 0 else (y * 255 // max(h - 1, 1)) if c % 3 == 1 else ((x + y) * 4) & 255
                if (x - w // 3) ** 2 + (y - h // 2) ** 2 < (min(w, h) // 3) ** 2:
                    v = 255 - v if c != 1 else 200
                if x % 11 == 5:
                    v = 20 if c != 2 else 230
                s = (s * 1103515245 + 12345) & 0x7FFFFFFF
                v = max(0, min(255, v + (s >> 16) % 9 - 4))
                out.append(v)
    return bytes(out)


def png(path, w, h, ch, pix):
    ctype = {1: 0, 3: 2, 4: 6}[ch]
    raw = b"".join(b"\0" + pix[y * w * ch:(y + 1) * w * ch] for y in range(h))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    data = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    open(path, "wb").write(data)


def tj_encode(pix, w, h, pf, subsamp, quality, flags=0, env=None):
    raw = os.path.join(TMP, "in.raw")
    out = os.path.join(TMP, "out.jpg")
    open(raw, "wb").write(pix)
    e = dict(os.environ)
    for k in ("TJ_RESTART", "TJ_OPTIMIZE", "TJ_PROGRESSIVE", "TJ_ARITHMETIC"):
        e.pop(k, None)
    e.update(env or {})
    subprocess.check_call([TOOL, "enc", raw, str(w), str(h), str(pf), str(subsamp), str(quality), str(flags), out], env=e)
    return open(out, "rb").read()


def tj_decode(data, pf):
    src = os.path.join(TMP, "dec.jpg")
    out = os.path.join(TMP, "dec.raw")
    open(src, "wb").write(data)
    w, h = map(int, subprocess.check_output([TOOL, "dec", src, str(pf), out]).split())
    return w, h, open(out, "rb").read()


PROG = 16384
good = []


def add(name, data, kind):
    """kind: 'grey', 'rgb' or 'cmyk' (how the reference is decoded)"""
    open(os.path.join(OUT, name + ".jpg"), "wb").write(data)
    if kind == "cmyk":
        w, h, p = tj_decode(data, 11)
        pix = bytearray()
        for i in range(0, len(p), 4):
            k = p[i + 3]
            pix += bytes((p[i + c] * k + 127) // 255 for c in range(3))
        ch = 3
    else:
        ch = 1 if kind == "grey" else 3
        w, h, pix = tj_decode(data, 6 if kind == "grey" else 0)
    png(os.path.join(OUT, name + ".png"), w, h, ch, bytes(pix))
    good.append(name + ".jpg")


def segments(d):
    """(marker, start, end) of each marker segment before the first scan's data, plus the scan"""
    out = []
    p = 2
    while p < len(d):
        m = d[p + 1]
        if m == 0xD9:
            out.append((m, p, p + 2))
            break
        l = struct.unpack(">H", d[p + 2:p + 4])[0]
        end = p + 2 + l
        if m == 0xDA:
            q = end
            while not (d[q] == 0xFF and d[q + 1] != 0 and not 0xD0 <= d[q + 1] <= 0xD7):
                q += 1
            out.append((m, p, q))
            p = q
            continue
        out.append((m, p, end))
        p = end
    return out


def main():
    os.makedirs(TMP, exist_ok=True)
    W, H = 45, 27
    rgb = picture(W, H, 3)
    grey = picture(W, H, 1, seed=7)
    add("jpeg_grey", tj_encode(grey, W, H, 6, 3, 85), "grey")
    add("jpeg_444", tj_encode(rgb, W, H, 0, 0, 90), "rgb")
    add("jpeg_422", tj_encode(rgb, W, H, 0, 1, 80), "rgb")
    add("jpeg_420", tj_encode(rgb, W, H, 0, 2, 75), "rgb")
    add("jpeg_440", tj_encode(rgb, W, H, 0, 4, 80), "rgb")
    add("jpeg_411", tj_encode(rgb, W, H, 0, 5, 80), "rgb")
    add("jpeg_q100", tj_encode(rgb, W, H, 0, 0, 100), "rgb")
    add("jpeg_q5", tj_encode(rgb, W, H, 0, 2, 5), "rgb")
    add("jpeg_opt", tj_encode(rgb, W, H, 0, 2, 75, env={"TJ_OPTIMIZE": "1"}), "rgb")
    add("jpeg_rst", tj_encode(rgb, W, H, 0, 2, 75, env={"TJ_RESTART": "1"}), "rgb")
    add("jpeg_rst3", tj_encode(rgb, W, H, 0, 0, 75, env={"TJ_RESTART": "3B"}), "rgb")
    add("jpeg_prog_420", tj_encode(rgb, W, H, 0, 2, 75, PROG), "rgb")
    add("jpeg_prog_444", tj_encode(rgb, W, H, 0, 0, 92, PROG), "rgb")
    add("jpeg_prog_422", tj_encode(rgb, W, H, 0, 1, 60, PROG), "rgb")
    add("jpeg_prog_grey", tj_encode(grey, W, H, 6, 3, 85, PROG), "grey")
    add("jpeg_prog_rst", tj_encode(rgb, W, H, 0, 2, 75, PROG, env={"TJ_RESTART": "2B"}), "rgb")
    cmyk = picture(W, H, 4, seed=3)
    add("jpeg_ycck", tj_encode(cmyk, W, H, 11, 0, 90), "cmyk")
    add("jpeg_1x1", tj_encode(rgb[:3], 1, 1, 0, 2, 75), "rgb")
    sq = picture(16, 16, 3, seed=5)
    add("jpeg_16x16", tj_encode(sq, 16, 16, 0, 2, 75), "rgb")
    bw, bh = 96, 64
    add("jpeg_prog_96x64",tj_encode(picture(bw, bh, 3, seed=9), bw, bh, 0, 2, 80, PROG), "rgb")
    # SOF1 (extended sequential) is SOF0 with another marker: made by editing a baseline file
    d = bytearray(open(os.path.join(OUT, "jpeg_420.jpg"), "rb").read())
    d[d.index(b"\xff\xc0") + 1] = 0xC1
    add("jpeg_sof1", bytes(d), "rgb")
    # Windows' own encoder (WIC through System.Drawing): a BMP in, quality 80 out
    bmp = os.path.join(TMP, "gdi.bmp")
    row = (W * 3 + 3) & ~3
    body = bytearray()
    for y in range(H - 1, -1, -1):
        r = bytearray()
        for x in range(W):
            i = (y * W + x) * 3
            r += bytes((rgb[i + 2], rgb[i + 1], rgb[i]))
        body += r + b"\0" * (row - len(r))
    open(bmp, "wb").write(b"BM" + struct.pack("<IHHI", 54 + len(body), 0, 0, 54) +
                          struct.pack("<IiiHHIIiiII", 40, W, H, 1, 24, 0, len(body), 2835, 2835, 0, 0) + body)
    gdi = os.path.join(TMP, "gdi.jpg")
    ps = ("Add-Type -AssemblyName System.Drawing; $b = New-Object System.Drawing.Bitmap '%s'; "
          "$c = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }; "
          "$p = New-Object System.Drawing.Imaging.EncoderParameters 1; "
          "$p.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality, [long]80); "
          "$b.Save('%s', $c, $p); $b.Dispose()") % (bmp, gdi)
    subprocess.check_call(["powershell", "-NoProfile", "-Command", ps])
    add("jpeg_gdi", open(gdi, "rb").read(), "rgb")
    open(os.path.join(OUT, "jpeg.txt"), "w", newline="\n").write("\n".join(good) + "\n")

    # for the encoder: libjpeg-turbo's files (accurate DCT, the settings std.image picks for the
    # quality) from source pictures, which are kept as PNG
    enc = []
    for (w, h, ch, q) in ((45, 27, 3, 75), (33, 17, 3, 75), (45, 27, 3, 95), (21, 11, 1, 50), (8, 8, 3, 30)):
        name = "jpeg_enc_%dx%d_%d_q%d" % (w, h, ch, q)
        pix = picture(w, h, ch, seed=w + h)
        png(os.path.join(OUT, name + ".png"), w, h, ch, pix)
        sub = 3 if ch == 1 else 0 if q >= 90 else 2
        open(os.path.join(OUT, name + ".jpg"), "wb").write(tj_encode(pix, w, h, 6 if ch == 1 else 0, sub, q, 4096))
        enc.append("%s %d" % (name, q))
    open(os.path.join(OUT, "jpeg_enc.txt"), "w", newline="\n").write("\n".join(enc) + "\n")

    # ---- malformed files ----
    base = open(os.path.join(OUT, "jpeg_420.jpg"), "rb").read()
    prog = open(os.path.join(OUT, "jpeg_prog_420.jpg"), "rb").read()
    rst = open(os.path.join(OUT, "jpeg_rst.jpg"), "rb").read()
    segs = segments(base)
    bad = []

    def put(name, data):
        open(os.path.join(OUT, "jpeg_bad_%s.jpg" % name), "wb").write(data)
        bad.append("jpeg_bad_%s.jpg" % name)

    def seg(d, m, nth=0):
        s = [x for x in segments(d) if x[0] == m]
        return s[nth]

    def without(d, m):
        out = d
        for (mm, a, b) in reversed(segments(d)):
            if mm == m:
                out = out[:a] + out[b:]
        return out

    def patch(d, at, data):
        return d[:at] + data + d[at + len(data):]

    sof = seg(base, 0xC0)[1]          # offset of FF C0
    sos = seg(base, 0xDA)
    scan_data = sos[1] + 2 + struct.unpack(">H", base[sos[1] + 2:sos[1] + 4])[0]
    dht = seg(base, 0xC4)[1]
    dqt = seg(base, 0xDB)[1]
    put("empty", b"")
    put("soi_only", b"\xff\xd8")
    put("no_soi", base[2:])
    put("cut_3", base[:3])
    put("cut_dqt", base[:dqt + 20])
    put("cut_before_sos", base[:sos[1]])
    put("cut_scan_header", base[:sos[1] + 6])
    put("cut_scan_half", base[:(scan_data + sos[2]) // 2])
    put("cut_scan_end", base[:sos[2] - 3])
    put("no_eoi", base[:-2])
    put("cut_eoi", base[:-1])
    put("prog_cut_half", prog[:len(prog) // 2])
    put("prog_no_eoi", prog[:-2])
    put("no_sof", without(base, 0xC0))
    put("no_dht", without(base, 0xC4))
    put("no_dqt", without(base, 0xDB))
    put("no_sos", without(base, 0xDA))
    put("sof_twice", base[:sof] + base[sof:seg(base, 0xC0)[2]] + base[sof:])
    put("w0", patch(base, sof + 7, b"\0\0"))
    put("h0_dnl", patch(base, sof + 5, b"\0\0"))
    put("dims_huge", patch(base, sof + 5, b"\xff\xff\xff\xff"))
    put("dims_big_short", patch(base, sof + 5, b"\x4e\x20\x4e\x20"))
    put("dims_wide",patch(base, sof + 5, b"\x00\x01\xff\xff"))
    put("precision12", patch(base, sof + 4, b"\x0c"))
    put("ncomp0", patch(base, sof + 9, b"\x00"))
    put("ncomp2", patch(base, sof + 9, b"\x02"))
    put("ncomp5", patch(base, sof + 9, b"\x05"))
    put("sampling0", patch(base, sof + 11, b"\x02"))
    put("sampling5", patch(base, sof + 11, b"\x52"))
    put("sampling_frac", patch(patch(base, sof + 11, b"\x31"), sof + 14, b"\x21"))
    put("tq4", patch(base, sof + 12, b"\x04"))
    put("comp_dup", patch(base, sof + 13, b"\x01"))
    put("sof_len", patch(base, sof + 2, b"\x00\x0e"))
    put("lossless", patch(base, sof, b"\xff\xc3"))
    put("arith", patch(base, sof, b"\xff\xc9"))
    put("hierarchical", patch(base, sof, b"\xff\xc5"))
    # Huffman tables: the first DHT segment of libjpeg holds the luma DC table
    counts = dht + 5
    put("dht_oversub", patch(base, counts, b"\x00\x03"))
    # a table with two 1-bit codes: the second is all 1 bits
    put("dht_all_ones", base[:sos[1]] + b"\xff\xc4\x00\x15\x00\x02" + b"\0" * 15 + b"\x00\x01" + base[sos[1]:])
    put("dht_class", patch(base, dht + 4, b"\x20"))
    put("dht_id", patch(base, dht + 4, b"\x04"))
    put("dht_dc_symbol", patch(base, dht + 5 + 16 + 3, b"\x10"))
    put("dht_short", patch(base, dht + 2, b"\x00\x10"))
    put("dht_count_many", base[:sos[1]] + b"\xff\xc4\x00\x13\x00" + b"\xff" * 16 + base[sos[1]:])
    put("dqt_precision", patch(base, dqt + 4, b"\x20"))
    put("dqt_id", patch(base, dqt + 4, b"\x05"))
    put("dqt_short", patch(base, dqt + 2, b"\x00\x30"))
    # scan header (FF DA len ns  c1 t1  c2 t2  c3 t3  ss se ahal)
    s0 = sos[1]
    put("sos_comp_unknown", patch(base, s0 + 5, b"\x09"))
    put("sos_comp_dup", patch(base, s0 + 7, b"\x01"))
    put("sos_ns0", patch(base, s0 + 4, b"\x00"))
    put("sos_table_id", patch(base, s0 + 6, b"\x44"))
    put("sos_table_undefined", patch(base, s0 + 6, b"\x22"))
    put("sos_before_sof", base[:sof] + base[sos[1]:sos[2]] + base[sof:])
    ps0 = seg(prog, 0xDA)[1]
    put("prog_se", patch(prog, ps0 + 12, b"\x05"))
    put("prog_al", patch(prog, ps0 + 13, b"\x0e"))
    put("prog_ah", patch(prog, ps0 + 13, b"\x31"))
    ps1 = seg(prog, 0xDA, 1)[1]
    put("prog_ss_gt_se", patch(prog, ps1 + 7, b"\x06\x02"))
    put("prog_se64", patch(prog, ps1 + 8, b"\x40"))
    put("prog_ac_interleaved", patch(prog, ps0 + 11, b"\x01\x05"))
    put("data_all_ones", base[:scan_data] + b"\xff\x00" * (sos[2] - scan_data) + base[sos[2]:])
    r0 = rst.index(b"\xff\xd0")
    put("rst_number", patch(rst, r0, b"\xff\xd1"))
    put("rst_missing", rst[:r0] + rst[r0 + 2:])
    dri = seg(rst, 0xDD)[1]
    put("dri_len", patch(rst, dri + 2, b"\x00\x05"))
    put("seg_len_past_end", patch(base, dqt + 2, b"\xff\xff"))
    put("seg_len_1", patch(base, dqt + 2, b"\x00\x01"))
    put("garbage_between", base[:dqt] + b"\x12\x34" + base[dqt:])
    put("soi_twice", base[:dqt] + b"\xff\xd8" + base[dqt:])
    put("dnl", base[:sos[2]] + b"\xff\xdc\x00\x04\x00\x1b" + base[sos[2]:])
    open(os.path.join(OUT, "jpeg_bad.txt"), "w", newline="\n").write("\n".join(bad) + "\n")
    print(len(good), "good files,", len(bad), "bad files")


main()
