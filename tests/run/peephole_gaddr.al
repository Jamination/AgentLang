// Addresses of globals used in loops: kept in a register from before a loop without calls
// (with an index and an offset), made at each use in a loop with calls.
const ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
table := [16]i64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
grid: [8][8]i32

noinline fn enc(src: []u8, dst: []u8) {
    for i in 0..len(src) {
        v := u32(src[i])
        dst[2 * i] = ALPHA[v >> 2]
        dst[2 * i + 1] = ALPHA[(v * 7) & 63]
    }
}

noinline fn bump(n: i64) -> i64 {
    s := 0
    for i in 0..n {
        k := i & 15
        table[k] += i
        s += table[(k + 3) & 15] + table[15 - k]
        for j in 0..8 {
            grid[k & 7][j] += i32(j * i)
        }
    }
    s
}

noinline fn noisy(n: i64) -> i64 {
    s := 0
    for i in 0..n {
        s += table[i & 15]
        if i % 5 == 0 { put(table[(i + 1) & 15], " ") }
    }
    put("\n")
    s
}

fn main() {
    src := []u8{0, 1, 63, 64, 127, 128, 200, 255}
    dst := alloc[u8](16)
    enc(src, dst)
    put(str(dst), "\n")
    put(bump(1000), " ", table, "\n")
    for r in grid { put(r, "\n") }
    put(noisy(23), "\n")
}
