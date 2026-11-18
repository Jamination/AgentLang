// rgba8 / rgb8: a u32 colour from bytes, red in the lowest byte (a literal reads 0xAABBGGRR),
// the byte order of color_u32, std.gfx and an RGBA8 image; constants where the bytes are
// (the mistakes are tests/fail/rgba8.al)
const WALL = rgb8(120, 90, 60)                 // brown: 0xFF3C5A78 (0xFF785A3C is a blue)
const GLASS: u32 = rgba8(200, 220, 255, 128)
const PALETTE = [3]u32{rgb8(255, 0, 0), rgb8(0, 255, 0), WALL}
const R: u8 = 17
priv const SHADE = rgb8(R, R * 2, 255 - R)

struct Brick { color: u32, hp: i64 }
const BRICKS = [2]Brick{Brick{rgb8(200, 40, 40), 1}, Brick{color: rgba8(40, 40, 200, 255), hp: 2}}

floor := rgb8(30, 30, 30)                      // a global initialised by a constant

fn main() {
    print(hex(u64(WALL)), hex(u64(GLASS)), hex(u64(PALETTE[0])), hex(u64(PALETTE[1])), hex(u64(SHADE)), hex(u64(floor)))
    print(WALL == color_u32(vec4(120.0, 90.0, 60.0, 255.0) / 255.0), color_vec4(rgb8(255, 0, 0)))
    // at run time: u8 values
    c: u8 = 100
    for i in 0..3 {
        put(hex(u64(rgba8(c + u8(i), 0, u8(i * 50), 255))), " ")
    }
    print()
    pix := [4]u8{120, 90, 60, 255}             // an RGBA8 pixel in memory is the same u32
    print(*cast[*u32](&pix) == WALL, BRICKS[1].color == 0xFFC82828, hex(u64(BRICKS[0].color)))
}
