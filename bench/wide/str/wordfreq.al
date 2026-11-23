// [library] word frequencies: split + Map[str, i64] (C: hand tokenizer + open-addressing
// table with FNV-1a and memcmp)
inline fn lcg(s: u64) -> u64 { s * 6364136223846793005 + 1442695040888963407 }

fn main() {
    seed: u64 = 7
    nv: u64 = 50000
    vocab := alloc[str](i64(nv))
    for i in 0..i64(nv) {
        seed = lcg(seed)
        l := 2 + i64((seed >> 33) % 11)
        w := alloc[u8](l)
        for j in 0..l {
            seed = lcg(seed)
            w[j] = u8(97 + (seed >> 33) % 26)
        }
        vocab[i] = w
    }
    b := vec[u8]()
    for k in 0..4000000 {
        seed = lcg(seed)
        x := (seed >> 33) % nv
        y := (seed >> 13) % nv
        b.extend(vocab[i64(min(x, y))])
        b.push(' ')
    }
    text := b.items()
    distinct := 0
    total := 0
    check := 0
    for r in 0..3 {
        m := map[str, i64]()
        for w in split(text, ' ') {
            if len(w) == 0 { continue }
            p := m.ptr(w)
            if p == nil {
                m.set(w, 1)
            } else {
                *p += 1
            }
        }
        distinct += m.len
        for k in m.keys() {
            c := m.get_or(k, 0)
            total += c
            check += c * c + len(k)
        }
    }
    print(len(text), distinct, total, check)
}
