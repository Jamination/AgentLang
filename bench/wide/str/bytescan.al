// [codegen] byte scanning over a 16 MB buffer: count newlines, strlen of NUL-terminated
// pieces, find every 'q' with a memchr-like loop
inline fn lcg(s: u64) -> u64 { s * 6364136223846793005 + 1442695040888963407 }

fn gen(n: i64) -> []u8 {
    buf := alloc[u8](n)
    seed: u64 = 12345
    for i in 0..n {
        seed = lcg(seed)
        r := (seed >> 33) % 200
        buf[i] = if r < 3 { '\n' } else if r == 3 { 0 } else { u8(97 + (seed >> 45) % 26) }
    }
    buf
}

fn count_nl(s: []u8) -> i64 {
    n := 0
    for c in s {
        if c == '\n' { n += 1 }
    }
    n
}

// sum over NUL-terminated pieces of piece length * (index & 7)
fn strlens(s: []u8) -> i64 {
    n := len(s)
    total := 0
    k := 0
    i := 0
    while i < n {
        j := i
        while j < n && s[j] != 0 { j += 1 }
        total += (j - i) * (k & 7)
        k += 1
        i = j + 1
    }
    total
}

fn find_byte(s: []u8, from: i64, c: u8) -> i64 {
    for i in from..len(s) {
        if s[i] == c { return i }
    }
    -1
}

fn count_q(s: []u8) -> i64 {
    n := 0
    sum := 0
    i := find_byte(s, 0, 'q')
    while i >= 0 {
        n += 1
        sum += i & 1023
        i = find_byte(s, i + 1, 'q')
    }
    n * 1000003 + sum
}

fn main() {
    buf := gen(16 << 20)
    a := 0
    b := 0
    c := 0
    for r in 0..12 {
        a += count_nl(buf)
        b += strlens(buf)
        c += count_q(buf)
        buf[r * 1000] = '\n'
    }
    print(a, b, c)
}
