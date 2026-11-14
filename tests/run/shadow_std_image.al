// Names of bundled modules reused by the program, declared before the modules are included
// (the `use`s are at the end): std.image keeps its own `Image` and `crc32`, std.input its own
// `KEY_COUNT` and `input_key_names` (a global).

struct Image { title: str, pixels: i64 }    // std.image: struct Image
const crc32 = 1234                          // std.image: fn crc32 (called by png_encode / png_decode)
input_key_names := [1]str{"mine"}           // std.input: a global table (key_name reads it)
const KEY_COUNT = 2                         // std.input: the number of key codes

// an overload next to std.image's image_new(w, h, channels) -> Image
fn image_new(title: str) -> Image {
    return Image{title: title, pixels: len(title)}
}

fn main() {
    mine := image_new("logo")
    print(mine.title, mine.pixels, crc32 + 1, input_key_names[0], KEY_COUNT, len(input_key_names))

    // std.image's Image: built, encoded and decoded by the module
    img := image_new(3, 2, 4)
    img.set(1, 1, vec4(1.0, 0.5, 0.0, 1.0))
    png := png_encode(img)
    back, ok := png_decode(png)
    print(ok, back.w, back.h, back.channels, back.get(1, 1), back.get(0, 0))
    print(png_decode(png[..len(png) - 5]).1)

    // std.input's table and its own KEY_COUNT
    print(key_name(1), key_name(500), key_from_name("space") == key_from_name("SPACE"))
}

use std.image
use std.input
