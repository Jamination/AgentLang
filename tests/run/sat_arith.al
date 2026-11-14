// sat_add / sat_sub for every integer type: compared with the exact result clamped to the range
// of the type, exhaustively for the 8-bit types, at the edges for the wider ones
fn check8() -> i64 {
    bad := 0
    for a in -128..128 {
        for b in -128..128 {
            if i64(sat_add(i8(a), i8(b))) != clamp(a + b, -128, 127) || i64(sat_sub(i8(a), i8(b))) != clamp(a - b, -128, 127) {
                bad += 1
            }
        }
    }
    for a in 0..256 {
        for b in 0..256 {
            if i64(sat_add(u8(a), u8(b))) != min(a + b, 255) || i64(sat_sub(u8(a), u8(b))) != max(a - b, 0) {
                bad += 1
            }
        }
    }
    bad
}

fn main() {
    print("8-bit mismatches:", check8())
    print(sat_add(i16(32000), i16(1000)), sat_sub(i16(-32000), i16(1000)), sat_add(u16(65000), u16(1000)), sat_sub(u16(1), u16(2)))
    print(sat_add(i32(0x7FFF_FFFF), i32(1)), sat_sub(i32(-0x7FFF_FFFF), i32(2)), sat_add(u32(0xFFFF_FFFF), u32(1)), sat_sub(u32(0), u32(1)))
    big := 0x7FFF_FFFF_FFFF_FFFF
    print(sat_add(big, 1), sat_add(big, big), sat_add(-big, -2), sat_sub(-big, 2), sat_sub(big, -1), sat_sub(0, -big - 1), sat_add(big, -big))
    print(sat_add(u64(0xFFFF_FFFF_FFFF_FFFF), u64(1)), sat_sub(u64(0), u64(0xFFFF_FFFF_FFFF_FFFF)), sat_add(u64(1), u64(2)), sat_sub(u64(10), u64(3)))
    hp: u8 = 250
    hp = hp.sat_add(10)
    print("method form:", hp, hp.sat_sub(255), sat_add(u8(250), 10))
}
