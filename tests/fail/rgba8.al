// rgba8 / rgb8 in constants: every byte must fit in u8, and a typed argument must be a u8
const R: i64 = 10
const A = rgba8(256, 0, 0, 255)
const B = rgb8(0, -1, 0)
const C = rgb8(R, 0, 0)

fn main() {
    print(A, B, C, rgb8(300, 0, 0))
}