// a merged run of checks (checkmerge_or) still fails when only its last index is out of range
noinline fn h(x: u32) -> u32 {
    return x
}

noinline fn add(r: *[16]u64, w: u32) {
    a := (w >> 8) & 0xFF
    b := (w >> 16) & 0xFF
    c := w >> 24
    r[a] = r[b] + r[c]
}

fn main() {
    r: [16]u64
    r[2] = 5
    r[15] = 7
    add(&r, h(0x0F020100))
    print(r[1])
    add(&r, h(0x10020100))
    print("not reached")
}
