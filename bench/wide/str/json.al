// [codegen] hand-written JSON tokenizer over generated text (same loops in C)
inline fn lcg(s: u64) -> u64 { s * 6364136223846793005 + 1442695040888963407 }

struct Buf { b: []u8, n: i64 }

fn putb(o: *Buf, c: u8) {
    o.b[o.n] = c
    o.n += 1
}

fn puts(o: *Buf, s: str) {
    for c in s { putb(o, c) }
}

fn puti(o: *Buf, v: i64) {
    if v < 0 {
        putb(o, '-')
        v = -v
    }
    tmp: [20]u8
    k := 0
    loop {
        tmp[k] = u8(48 + v % 10)
        k += 1
        v = v / 10
        if v == 0 { break }
    }
    while k > 0 {
        k -= 1
        putb(o, tmp[k])
    }
}

fn gen(nrec: i64) -> []u8 {
    o := Buf{alloc[u8](nrec * 160), 0}
    seed: u64 = 99
    puts(&o, "[\n")
    for r in 0..nrec {
        seed = lcg(seed)
        puts(&o, "  {\"id\": ")
        puti(&o, r)
        puts(&o, ", \"name\": \"")
        nl := 3 + i64((seed >> 40) % 12)
        for j in 0..nl {
            seed = lcg(seed)
            c := u8(97 + (seed >> 50) % 26)
            if (seed >> 33) % 23 == 0 {
                putb(&o, '\\')
                putb(&o, 'n')
            } else {
                putb(&o, c)
            }
        }
        puts(&o, "\", \"score\": ")
        seed = lcg(seed)
        puti(&o, i64((seed >> 40) % 200000) - 100000)
        putb(&o, '.')
        puti(&o, i64((seed >> 20) % 1000))
        puts(&o, ", \"tags\": [")
        nt := i64((seed >> 10) % 4)
        for t in 0..nt {
            if t > 0 { puts(&o, ", ") }
            seed = lcg(seed)
            puti(&o, i64((seed >> 35) % 1000))
        }
        puts(&o, "], \"ok\": ")
        puts(&o, if (seed & 4) != 0 { "true" } else { "false" })
        puts(&o, ", \"next\": null}")
        if r + 1 < nrec { putb(&o, ',') }
        putb(&o, '\n')
    }
    puts(&o, "]\n")
    o.b[..o.n]
}

struct Stats { tokens: i64, strings: i64, strbytes: i64, numsum: i64, depth: i64, maxdepth: i64, lits: i64 }

fn tokenize(s: []u8, st: *Stats) -> bool {
    n := len(s)
    i := 0
    while i < n {
        c := s[i]
        match c {
            ' ', '\t', '\n', '\r' => { i += 1 }
            '{', '[' => {
                st.depth += 1
                if st.depth > st.maxdepth { st.maxdepth = st.depth }
                st.tokens += 1
                i += 1
            }
            '}', ']' => {
                st.depth -= 1
                st.tokens += 1
                i += 1
            }
            ':', ',' => {
                st.tokens += 1
                i += 1
            }
            '"' => {
                i += 1
                start := i
                while i < n && s[i] != '"' {
                    if s[i] == '\\' { i += 1 }
                    i += 1
                }
                if i >= n { return false }
                st.strbytes += i - start
                st.strings += 1
                st.tokens += 1
                i += 1
            }
            '-', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                neg := c == '-'
                if neg { i += 1 }
                v := 0
                while i < n && s[i] >= '0' && s[i] <= '9' {
                    v = v * 10 + i64(s[i] - '0')
                    i += 1
                }
                if i < n && s[i] == '.' {
                    i += 1
                    while i < n && s[i] >= '0' && s[i] <= '9' {
                        v = v * 10 + i64(s[i] - '0')
                        i += 1
                    }
                }
                st.numsum += if neg { -v } else { v }
                st.tokens += 1
            }
            't', 'n' => {
                i += 4
                st.lits += 1
                st.tokens += 1
            }
            'f' => {
                i += 5
                st.lits += 1
                st.tokens += 1
            }
            _ => { return false }
        }
    }
    true
}

fn main() {
    text := gen(200000)
    st: Stats
    ok := true
    for r in 0..25 {
        ok = ok && tokenize(text, &st)
    }
    print(len(text), ok, st.tokens, st.strings, st.strbytes, st.numsum, st.maxdepth, st.lits)
}
