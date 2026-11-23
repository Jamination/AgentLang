// Conway's game of life on a flat byte grid with a dead border, two buffers swapped
fn gen(cur: []u8, nxt: []u8, w: i64, h: i64) {
    for y in 1..h - 1 {
        row := y * w
        for x in 1..w - 1 {
            i := row + x
            n := cur[i - w - 1] + cur[i - w] + cur[i - w + 1] + cur[i - 1] + cur[i + 1] + cur[i + w - 1] + cur[i + w] + cur[i + w + 1]
            alive := cur[i]
            nxt[i] = if n == 3 || (n == 2 && alive == 1) { 1 } else { 0 }
        }
    }
}

fn main() {
    w := 514
    h := 514
    a := alloc[u8](w * h)
    b := alloc[u8](w * h)
    seed: u64 = 4242
    for y in 1..h - 1 {
        for x in 1..w - 1 {
            seed = seed * 6364136223846793005 + 1442695040888963407
            a[y * w + x] = u8((seed >> 33) % 3 == 0)
        }
    }
    for g in 0..500 {
        if g % 2 == 0 {
            gen(a, b, w, h)
        } else {
            gen(b, a, w, h)
        }
    }
    live := 0
    hsh: u64 = 0
    for i in 0..w * h {
        live += i64(a[i])
        hsh = hsh * 3 + u64(a[i])
    }
    put(live, " ", hsh, "\n")
}
