// checks with a call between them are not merged (checkmerge_or): the call runs, then the
// check after it fails
noinline fn h(x: u32) -> u32 {
    return x
}

noinline fn g(x: u64) -> u64 {
    print("g", x)
    return x + 1
}

noinline fn call(r: *[16]u64, w: u32) {
    a := (w >> 8) & 0xFF
    b := (w >> 16) & 0xFF
    t := g(r[b])
    r[a] = t
}

fn main() {
    r: [16]u64
    r[1] = 4
    call(&r, h(0x00010300))
    print(r[3])
    call(&r, h(0x00011000))
    print("not reached")
}
