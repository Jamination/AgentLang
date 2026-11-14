// a failure inside a bundled module (`use std.image`): its frames are shown like the program's,
// so the trace tells how the call failed inside the module (the always-loaded library's are not)
use std.image

fn thumbnail(w: i64) -> Image {
    return image_new(w, 16, 4)
}

fn main() {
    print("start")
    img := thumbnail(16 - 17 * (len(args()) - 2))
    print(img.w)
}
