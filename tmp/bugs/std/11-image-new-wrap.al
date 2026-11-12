// image_new(1 << 32, 1 << 32, 1): w * h * channels wraps to 0, so the Image claims 2^32 x 2^32
// pixels over an empty pix slice (documented: allocates w * h * channels bytes).
// expected: an assertion   actual (before the fix): prints "unreachable 0"
use std.image
fn main() {
    c := image_new(1 << 32, 1 << 32, 1)
    print("unreachable", len(c.pix))
}
