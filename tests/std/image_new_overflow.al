// image_new with a size whose byte count w * h * channels wraps around stops with an assertion
// instead of returning an Image whose pixels do not cover w x h (2^32 x 2^32 gave 0 bytes)
use std.image

fn main() {
    a := image_new(3, 2, 4)
    b := image_new(0, 1 << 40, 4)
    print(len(a.pix), len(b.pix))
    c := image_new(1 << 32, 1 << 32, 1)
    print("unreachable", len(c.pix))
}
