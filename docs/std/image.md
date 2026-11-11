# std.image

`use std.image`. 8-bit images in memory, PNG and BMP loading and saving, and the pieces they
are made of (inflate / deflate, zlib, CRC-32, Adler-32). Everything is written in AL: no
libpng, no zlib, no libc, so programs using it stay static executables.

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
`window.present` as is.

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
| `image_load(path) -> (Image, bool)` | PNG or BMP, decided by the file's signature |
| `image_decode(data: []u8) -> (Image, bool)` | the same from memory (for `embed(...)`) |
| `png_load` `png_decode` `png_save(path, img) -> bool` `png_encode(img) -> []u8` | |
| `bmp_load` `bmp_decode` `bmp_save(path, img) -> bool` `bmp_encode(img) -> []u8` | |

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
