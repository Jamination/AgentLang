// error propagation through a call chain in a hot loop: (value, ok) tuples and Opt

fn digit(c: u8) -> (i64, bool) {
    if c >= '0' && c <= '9' { return (i64(c - '0'), true) }
    (0, false)
}

fn mul_add(acc: i64, d: i64) -> (i64, bool) {
    if acc > 92233720368547757 { return (0, false) }        // acc * 10 + d would overflow
    (acc * 10 + d, true)
}

// parses digits at text[*pos..] up to ',' ; consumes the separator
fn parse_num(text: str, pos: *i64) -> (i64, bool) {
    acc := 0
    n := 0
    ok := true
    while *pos < len(text) && text[*pos] != ',' {
        d, good := digit(text[*pos])
        *pos += 1
        if !good { ok = false; continue }
        v, fits := mul_add(acc, d)
        if !fits { ok = false; continue }
        acc = v
        n += 1
    }
    *pos += 1
    if n == 0 { return (0, false) }
    (acc, ok)
}

fn scaled(text: str, pos: *i64, limit: i64) -> Opt[i64] {
    v, ok := parse_num(text, pos)
    if !ok { return None }
    if v > limit { return None }
    Some(v * 3 + 1)
}

fn checksum(text: str, limit: i64) -> (i64, i64) {
    pos := 0
    sum := 0
    errors := 0
    while pos < len(text) {
        match scaled(text, &pos, limit) {
            Some(v) => { sum = sum * 31 + v }
            None => { errors += 1 }
        }
    }
    (sum, errors)
}

fn main() {
    n := 4000000
    text := alloc[u8](n)
    seed: u64 = 99
    for i in 0..n {
        seed = seed * 6364136223846793005 + 1442695040888963407
        r := (seed >> 33) % 100
        text[i] = if r < 12 { ',' } else if r < 13 { 'x' } else { u8('0' + r % 10) }
    }
    total := 0
    errs := 0
    for r in 0..36 {
        s, e := checksum(text, 1000000000000 + r)
        total = total * 7 + s
        errs += e
    }
    put(total, " ", errs, "\n")
}
