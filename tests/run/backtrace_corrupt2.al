// a stack overwritten with numbers that are no addresses
noinline fn smash(fill: i64) {
    x: [2]i64
    p := ptr(x)
    for i in 0..40 {
        p[i] = fill + i
    }
    panic("smashed")
}

noinline fn level(fill: i64) -> i64 {
    pad: [64]i64
    pad[fill & 63] = 1
    smash(fill)
    return pad[3]
}

fn main() {
    print("start")
    print(level(0x4141414141414141 + len(args())))
}
