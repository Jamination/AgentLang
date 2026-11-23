// match and if-chains on integers that the optimiser turns into Switch terminators and the
// back ends into jump tables, bit tests, binary searches and compare chains: every function is
// probed at its keys, next to them and at the extremes of its type

const MAX = 0x7FFF_FFFF_FFFF_FFFF

// dense: a jump table
fn dense(x: i64) -> i64 {
    match x {
        0 => 100
        1 => 101
        2 => 102
        3 => 103
        4 => 104
        5 => 105
        6 => 106
        7 => 107
        9 => 109
        10 => 110
        11 => 111
        12 => 112
        13 => 113
        15 => 115
        _ => -1
    }
}

// sparse, negative and extreme keys: a binary search down to compares
fn sparse(x: i64) -> i64 {
    match x {
        -1000000 => 1
        -5 => 2
        1 => 3
        100 => 4
        1000 => 5
        10000 => 6
        1 << 40 => 7
        MAX => 8
        -MAX - 1 => 9
        _ => 0
    }
}

// dense clusters at both ends of i64: x - lo wraps
fn extremes(x: i64) -> i64 {
    match x {
        MAX => 1
        MAX - 1 => 2
        MAX - 2 => 3
        MAX - 4 => 4
        -MAX - 1 => 5
        -MAX => 6
        -MAX + 1 => 7
        -MAX + 3 => 8
        _ => 0
    }
}

// character classes of a lexer: a table with few targets, white space as a bit test
fn class(c: u8) -> i64 {
    match c {
        ' ', '\t', '\r', '\n' => 1
        'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r',
            's', 't', 'u', 'v', 'w', 'x', 'y', 'z', '_' => 2
        '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => 3
        '(', ')', '{', '}', '[', ']' => 4
        '+', '-', '*', '/' => 5
        200, 255 => 6
        _ => 0
    }
}

// bit tests with two and three targets
fn bits2(c: u8) -> i64 {
    match c {
        'a', 'c', 'e', 'g', 'i' => 1
        'b', 'd', 'f', 'h', 'j', 'k' => 2
        _ => 0
    }
}

fn bits3(x: i32) -> i64 {
    match x {
        -3, 0, 3, 6, 9 => 1
        -2, 1, 4, 7, 10 => 2
        -1, 2, 5, 8, 11 => 3
        _ => 0
    }
}

// signed narrow values with negative keys
fn small(x: i8) -> i64 {
    match x {
        -128 => 1
        -127 => 2
        -2 => 3
        -1 => 4
        0 => 5
        1 => 6
        2 => 7
        126 => 8
        127 => 9
        _ => 0
    }
}

fn i16s(x: i16) -> i64 {
    match x {
        -10 => 1
        -9 => 2
        -7 => 3
        -6 => 4
        -3 => 5
        0 => 6
        4 => 7
        8 => 8
        _ => 0
    }
}

// unsigned keys at the top of their type (negative when canonical)
fn u32top(x: u32) -> i64 {
    match x {
        0xFFFF_FFF0 => 1
        0xFFFF_FFF1 => 2
        0xFFFF_FFF3 => 3
        0xFFFF_FFF7 => 4
        0xFFFF_FFFE => 5
        0xFFFF_FFFF => 6
        0x7FFF_FFFF => 7
        0x8000_0000 => 8
        _ => 0
    }
}

fn u16top(x: u16) -> i64 {
    match x {
        65535 => 1
        65534 => 2
        65533 => 3
        65530 => 4
        32767 => 5
        32768 => 6
        0 => 7
        _ => 0
    }
}

// an if-chain on one value
fn chain(x: i64) -> i64 {
    if x == 7 {
        return 1
    } else if x == 3 {
        return 2
    } else if x == 9 {
        return 3
    } else if x == 4 {
        return 4
    } else if x == 8 {
        return 5
    }
    return 0
}

// one and two cases
fn one(x: i64) -> i64 {
    match x {
        42 => 1
        _ => 0
    }
}

fn two(x: i64) -> i64 {
    match x {
        42 => 1
        -42 => 2
        _ => 0
    }
}

// the same value tested again inside an arm
fn nested(x: i64, y: i64) -> i64 {
    match x {
        1 => match x {
            1 => 10 + y
            _ => -1
        }
        2 => if x == 2 { 20 } else { -2 }
        3 => match y {
            0 => 30
            1 => 31
            2 => 32
            3 => 33
            _ => 39
        }
        4 => if x != 4 { -4 } else { 40 }
        _ => 0
    }
}

// a value that flows from several arms into one
fn merge(x: i64, a: i64, b: i64) -> i64 {
    r := 0
    match x {
        0, 5, 10 => r = a
        1, 6, 11 => r = b
        2, 7 => r = a + b
        3 => r = a - b
        _ => r = a * b
    }
    return r * 2 + 1
}

enum Op {
    Push(i64)
    Add
    Sub
    Mul
    Dup
    Swap
    Neg
    Jz(i64)
    Halt
}

// enum tags with payloads
fn run(code: []Op) -> i64 {
    st: [16]i64
    sp := 0
    pc := 0
    steps := 0
    loop {
        steps += 1
        if steps > 1000 {
            return -1
        }
        op := code[pc]
        pc += 1
        match op {
            Push(v) => {
                st[sp] = v
                sp += 1
            }
            Add => {
                sp -= 1
                st[sp - 1] += st[sp]
            }
            Sub => {
                sp -= 1
                st[sp - 1] -= st[sp]
            }
            Mul => {
                sp -= 1
                st[sp - 1] *= st[sp]
            }
            Dup => {
                st[sp] = st[sp - 1]
                sp += 1
            }
            Swap => {
                t := st[sp - 1]
                st[sp - 1] = st[sp - 2]
                st[sp - 2] = t
            }
            Neg => st[sp - 1] = -st[sp - 1]
            Jz(t) => {
                sp -= 1
                if st[sp] == 0 {
                    pc = t
                }
            }
            Halt => return st[sp - 1]
        }
    }
}

priv fn probes() -> Vec[i64] {
    p := vec[i64]()
    for k in -20..300 {
        p.push(k)
    }
    for k in []i64{-42, -1000001, -1000000, -999999, 999, 1000, 1001, 9999, 10000, 10001, 1 << 40, (1 << 40) - 1, (1 << 40) + 1,
        MAX, MAX - 1, MAX - 2, MAX - 3, MAX - 4, MAX - 5, -MAX - 1, -MAX, -MAX + 1, -MAX + 2, -MAX + 3, -MAX + 4,
        32766, 32767, 32768, 65529, 65530, 65531, 65533, 65534, 65535, 65536,
        0x7FFF_FFFE, 0x7FFF_FFFF, 0x8000_0000, 0x8000_0001, 0xFFFF_FFEF, 0xFFFF_FFF0, 0xFFFF_FFF1, 0xFFFF_FFF2,
        0xFFFF_FFF3, 0xFFFF_FFF7, 0xFFFF_FFFE, 0xFFFF_FFFF, 0x1_0000_0000} {
        p.push(k)
    }
    return p
}

// the results of f over the probes, as a short hash and the number of non-zero results
priv fn show(name: str, rs: *Vec[i64]) {
    h: u64 = 1469598103934665603
    nz := 0
    for r in rs {
        h = (h ^ u64(r)) * 1099511628211
        if r != 0 {
            nz += 1
        }
    }
    put(name, " ", nz, " ", h, "\n")
}

fn main() {
    ps := probes()
    rs := vec[i64]()
    for p in ps {
        rs.push(dense(p))
    }
    show("dense", &rs)
    rs.clear()
    for p in ps {
        rs.push(sparse(p))
    }
    show("sparse", &rs)
    rs.clear()
    for p in ps {
        rs.push(extremes(p))
    }
    show("extremes", &rs)
    rs.clear()
    for p in ps {
        rs.push(class(u8(p)))
    }
    show("class", &rs)
    rs.clear()
    for p in ps {
        rs.push(bits2(u8(p)))
    }
    show("bits2", &rs)
    rs.clear()
    for p in ps {
        rs.push(bits3(i32(p)))
    }
    show("bits3", &rs)
    rs.clear()
    for p in ps {
        rs.push(small(i8(p)))
    }
    show("small", &rs)
    rs.clear()
    for p in ps {
        rs.push(i16s(i16(p)))
    }
    show("i16s", &rs)
    rs.clear()
    for p in ps {
        rs.push(u32top(u32(p)))
    }
    show("u32top", &rs)
    rs.clear()
    for p in ps {
        rs.push(u16top(u16(p)))
    }
    show("u16top", &rs)
    rs.clear()
    for p in ps {
        rs.push(chain(p))
    }
    show("chain", &rs)
    rs.clear()
    for p in ps {
        rs.push(one(p) + 2 * two(p))
    }
    show("one_two", &rs)
    rs.clear()
    for p in ps {
        rs.push(nested(p & 7, p >> 3 & 7))
    }
    show("nested", &rs)
    rs.clear()
    for p in ps {
        rs.push(merge(p % 13, p, 3))
    }
    show("merge", &rs)
    // the arms one by one (a readable check of the plain cases)
    for c in "a_Z0(+ \n\x01" {
        put(class(c), " ")
    }
    put("\n")
    for k in []i64{-1, 0, 7, 8, 15, 16} {
        put(dense(k), " ")
    }
    put("\n")
    code := []Op{Push(10), Push(0), Jz(4), Halt, Dup, Push(1), Sub, Dup, Jz(10), Swap, Neg, Push(3), Mul, Halt}
    put(run(code), "\n")
    code2 := []Op{Push(6), Push(7), Mul, Push(2), Add, Halt}
    put(run(code2), "\n")
}
