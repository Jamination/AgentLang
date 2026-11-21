# std.image

`use std.image`. 8-bit images in memory, PNG, BMP and JPEG loading and saving, and the pieces
they are made of (inflate / deflate, zlib, CRC-32, Adler-32). Everything is written in AL: no
libpng, no zlib, no libjpeg, no libc, so programs using it stay static executables.

```
// examples/image_demo.al
use std.image

fn main() {
    img := image_new(256, 128, 4)
    for y in 0..img.h {
        for x in 0..img.w {
            u := f32(x) / f32(img.w - 1)
            v := f32(y) / f32(img.h - 1)
            img.set(x, y, vec4(hsv_to_rgb(vec3(u, 1.0 - v * 0.5, 1.0)), 1.0))
        }
    }
    png_save("tmp/rainbow.png", img)
    back, ok := image_load("tmp/rainbow.png")
    thumb := resize_bilinear(back, 64, 32)
}
```

Output of the full example:

```
loaded: true 256 128 4 identical: true
png is smaller than the raw pixels: true
thumbnail: 64 32 grey channels: 1
crc32 of the pixels: 282c2bf2
```

## Image

```
struct Image { w: i64, h: i64, channels: i64, pix: []u8 }
```

Rows from top to bottom, pixels left to right, `channels` bytes per pixel: 1 = grey,
2 = grey + alpha, 3 = RGB, 4 = RGBA. `pix` can be handed to a GPU upload or to
`window.present` as is. The other way round, a framebuffer of 4-byte pixels can be wrapped
without copying: `Image{w: W, h: H, channels: 4, pix: fb}` (`fb` a `[]u8` of `W * H * 4` bytes), then
`png_save("frame.png", img)` writes a screenshot. Read as a `u32` (`from_bytes[u32](img.pix)`
of a 4-channel image), a pixel is `0xAABBGGRR`: red in the lowest byte.

| Function | |
|----------|---|
| `image_new(w, h, channels) -> Image` | zeroed image (allocates `w * h * channels` bytes) |
| `get(img, x, y, c) -> u8` / `set(&img, x, y, c, v)` | one channel |
| `get(img, x, y) -> vec4` / `set(&img, x, y, vec4)` | a colour, components 0..1 (grey is spread, missing alpha is 1) |
| `convert(img, channels) -> Image` | change the channel count (grey uses weights 77 / 150 / 29) |
| `flip_y(&img)` | in place; use it for APIs with a bottom-left origin |
| `crop(img, x, y, w, h) -> Image` | a copy of a region |
| `blit(&dst, src, x, y)` | copy `src` into `dst`, clipped at the edges |
| `resize_nearest(img, w, h)` `resize_bilinear(img, w, h)` | |
| `premultiply_alpha(&img)` | in place |
| `generate_mipmap(img) -> Image` | half size, box filter |
| `mipmap_chain(img) -> []Image` | the image and every level down to 1 x 1 |

Functions returning an `Image` allocate its pixels from the arena; load inside a
`mark()` / `release()` scope when the image is temporary.

## Files

| Function | |
|----------|---|
| `image_load(path) -> (Image, bool)` | PNG, BMP or JPEG, decided by the file's signature |
| `image_decode(data: []u8) -> (Image, bool)` | the same from memory (for `embed(...)`) |
| `png_load` `png_decode` `png_save(path, img) -> bool` `png_encode(img) -> []u8` | |
| `bmp_load` `bmp_decode` `bmp_save(path, img) -> bool` `bmp_encode(img) -> []u8` | |
| `jpeg_load` `jpeg_decode` `jpeg_save(path, img, quality) -> bool` `jpeg_encode(img, quality) -> []u8` | `quality` 1..100 |

**PNG decoding** covers the whole format: colour types 0 / 2 / 3 / 4 / 6, bit depths 1 to 16
(16-bit samples are reduced to 8), palettes with `tRNS` transparency, colour-key
transparency, all five filters, Adam7 interlacing, any split of the data into IDAT chunks.
The result has 1, 2, 3 or 4 channels according to the file. Chunk CRCs and the zlib
checksum are verified; a malformed or truncated file returns `false` and never reads out of
bounds (`tests/std/image_bad.al` feeds 73 corrupted or unsupported files).

**PNG encoding** writes 8-bit grey, grey + alpha, RGB or RGBA with a per-row choice of filter
and a real deflate compressor (LZ77 with hash chains, dynamic Huffman codes).

**BMP** reads 1 / 4 / 8-bit palettised, 24-bit and 32-bit uncompressed files (32-bit also with
bit-field masks), bottom-up or top-down, with any header version from BITMAPINFOHEADER to V5,
and writes 24-bit and 32-bit files (grey images are written as RGB). 16-bit and compressed
BMPs are rejected.

**JPEG decoding** covers the Huffman-coded processes with 8-bit samples: baseline and
extended sequential (SOF0, SOF1) and progressive (SOF2, with spectral selection and successive
approximation), restart intervals, greyscale, YCbCr with any whole-number subsampling (4:4:4,
4:2:2, 4:2:0, 4:4:0, 4:1:1, ...), RGB, and CMYK / YCCK as Adobe writes them (inverted). The
result has 1 channel (greyscale) or 3 (RGB; CMYK is multiplied out, `C * K / 255`). It follows
libjpeg's default decoding (accurate integer IDCT, "fancy" triangular upsampling of 2x
subsampled chroma, the same fixed-point colour conversion), and its pixels are identical to
libjpeg-turbo's for every test file. Rejected, returning `false`: arithmetic coding, lossless
and hierarchical files, 12-bit samples, a height given only in a DNL marker, fractional
subsampling, and anything malformed, including a file cut short or without its end marker
(`tests/std/image_jpeg_bad.al` feeds 67 such files, every prefix of three valid ones, and 2800
randomly damaged ones; none faults). The JFIF and Adobe markers decide the colour space as in
libjpeg; EXIF orientation is not applied (PNG and BMP have no such notion either) and the
other APPn segments are skipped. A 1920 x 1080 photo-like picture decodes in about the time
its PNG takes (about 22 ms each; 4:4:4 1.1 times and progressive 1.3 to 1.5 times the PNG's
time), from a file a tenth of the PNG's size.

**JPEG encoding** writes baseline files with a JFIF marker: greyscale for 1 and 2 channels,
YCbCr for 3 and 4 (alpha is dropped), with the colour subsampled 2 x 2 (4:2:0) below quality
90 and kept whole (4:4:4) from 90 on. `quality` (clamped to 1..100) scales the example tables
of the standard as libjpeg does; the Huffman tables are the standard's too. Colour conversion,
downsampling, forward DCT (the accurate integer one), quantisation and the padding of partial
MCUs are libjpeg's: the entropy-coded data is byte for byte what libjpeg-turbo writes with
`-dct int` and the same quality and subsampling.

**Acknowledgement.** The JPEG code follows the algorithms of the Independent JPEG Group's
libjpeg (`jidctint.c`, `jfdctint.c`, `jdcolor.c`, `jccolor.c`): this software is based in part
on the work of the Independent JPEG Group. The IJG licence asks the same sentence of a program
distributed as an executable: a game whose executable contains std.image's JPEG code (it calls
`jpeg_*` or `image_load` / `image_decode`) states it in its documentation or credits.

## Compression and checksums

| Function | |
|----------|---|
| `inflate(data) -> ([]u8, bool)` / `deflate(data) -> []u8` | raw deflate streams |
| `zlib_decompress(data) -> ([]u8, bool)` / `zlib_compress(data) -> []u8` | with the zlib header and Adler-32 |
| `inflate_into(data, out) -> (i64, bool)` `zlib_decompress_into(data, out)` | into a buffer you provide (no allocation); returns the length |
| `crc32(data) -> u32` `crc32(prev, data)` | the PNG / zip polynomial; the second form continues a running CRC |
| `adler32(data) -> u32` `adler32(prev, data)` | |

## Tests

`tests/std/image_png.al` and `image_bmp.al` decode every fixture in `tests/std/data/` and
compare size and pixel CRC with values that `tests/gen/images.py` computed independently
when it generated the fixtures. `image_bad.al` feeds corrupted files. `image_ops.al` covers
the encoders (round trips through the decoders), compression bounds and the pixel
operations. Files written by `png_encode` were additionally checked with Python's zlib.

`image_jpeg.al` decodes 22 JPEG files and compares every sample with libjpeg-turbo's decode
of the same file (`jpeg_*.png`). `tests/gen/jpegs.py` made them with libjpeg-turbo 2.1.5
(through `tests/gen/jpeg_tj.c`; all subsamplings, progressive, restart intervals, optimised
Huffman tables, YCCK, sizes 1 x 1 to 96 x 64) and Windows' own encoder (`jpeg_gdi.jpg`); the
extended sequential file is a baseline one with its SOF0 marker changed to SOF1.
`image_jpeg_bad.al` feeds the malformed files, `image_jpeg_enc.al` covers the encoder (every
channel count, sizes 1 to 131, qualities 10 to 100, through the decoder) and compares its
output for five pictures with libjpeg-turbo's files of the same settings (`jpeg_enc_*`).
