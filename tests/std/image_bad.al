// Every file listed in tests/std/data/img_bad.txt is malformed in one way (bad checksum, cut
// short, invalid header field, invalid deflate stream, ...): the decoders must return false.
use std.image

fn main() {
    list, ok := read_file("tests/std/data/img_bad.txt")
    assert ok, "fixture list missing"
    for name in lines(list) {
        data, found := read_file(concat("tests/std/data/", name))
        assert found, name
        _, good := if ends_with(name, ".png") { png_decode(data) } else { bmp_decode(data) }
        _, any := image_decode(data)
        print(name, good || any)
    }
}
