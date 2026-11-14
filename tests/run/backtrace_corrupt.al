// a stack overwritten with addresses in the code (valid return addresses, nonsense frames):
// the trace stops where a frame cannot be trusted, the program still ends with the message and
// status 1
noinline fn smash(fill: i64) {
    x: [2]i64
    p := ptr(x)
    for i in 0..40 {
        p[i] = fill + 8 * i
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
    print(level(cast[i64](smash) + 16 * (len(args()) - 3)))
}
