// N-queens by bitmasks (lowest set bit, masks shifted per row)
fn solve(cols: u32, ld: u32, rd: u32, all: u32) -> i64 {
    if cols == all { return 1 }
    count := 0
    avail := all & ~(cols | ld | rd)
    while avail != 0 {
        bit := avail & (0 - avail)
        avail ^= bit
        count += solve(cols | bit, ((ld | bit) << 1) & all, (rd | bit) >> 1, all)
    }
    count
}

fn main() {
    total := 0
    for n in 4..=15 {
        all := (u32(1) << u32(n)) - 1
        c := solve(0, 0, 0, all)
        total = total * 31 + c
        put(n, " ", c, "\n")
    }
    put(total, "\n")
}
