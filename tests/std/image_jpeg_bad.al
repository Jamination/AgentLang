// Every file listed in tests/std/data/jpeg_bad.txt is malformed or unsupported in one way (cut
// short, missing marker, bad Huffman or quantisation table, absurd dimensions, bad scan
// parameters, lost restart marker, arithmetic coding, ...): jpeg_decode and image_decode must
// return false without faulting. Then every proper prefix of a baseline and of a progressive
// file, and many files with damaged bytes, are decoded (which must not fault).
use std.image

fn main() {
    list, ok := read_file("tests/std/data/jpeg_bad.txt")
    assert ok, "fixture list missing"
    for name in lines(list) {
        data, found := read_file(concat("tests/std/data/", name))
        assert found, name
        _, good := jpeg_decode(data)
        _, any := image_decode(data)
        print(name, good || any)
    }
    for name in []str{"jpeg_420.jpg", "jpeg_prog_420.jpg", "jpeg_rst.jpg"} {
        data, found := read_file(concat("tests/std/data/", name))
        assert found, name
        accepted := 0
        for n in 0..len(data) {
            m := mark()
            _, good := jpeg_decode(data[..n])
            if good {
                accepted += 1
            }
            release(m)
        }
        print(name, "prefixes accepted:", accepted)
    }
    // damaged copies: one to four bytes changed at pseudo-random places
    names := []str{"jpeg_420.jpg", "jpeg_444.jpg", "jpeg_prog_420.jpg", "jpeg_prog_rst.jpg", "jpeg_rst3.jpg", "jpeg_ycck.jpg", "jpeg_411.jpg"}
    seed: u64 = 12345
    decoded := 0
    tried := 0
    for name in names {
        data, found := read_file(concat("tests/std/data/", name))
        assert found, name
        copy_ := alloc[u8](len(data))
        for t in 0..400 {
            copy(copy_, data)
            seed = seed * 6364136223846793005 + 1442695040888963407
            k := i64(seed >> 62) + 1
            for i in 0..k {
                seed = seed * 6364136223846793005 + 1442695040888963407
                at := i64((seed >> 33) % u64(len(data)))
                copy_[at] = u8(seed >> 13)
            }
            m := mark()
            img, good := jpeg_decode(copy_)
            if good {
                decoded += 1
                assert len(img.pix) == img.w * img.h * img.channels
            }
            tried += 1
            release(m)
        }
    }
    print("damaged files decoded without a fault:", tried)
}
