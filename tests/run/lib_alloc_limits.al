// Allocation sizes that are negative or do not fit stop the program instead of handing out a
// slice that is longer than its memory (each case runs in a child process).
fn child(f: fn()) {
    flush()
    pid := syscall(57)
    if pid == 0 {
        f()
        print("not stopped")
        exit(0)
    }
    status: i32
    syscall(61, pid, &status, 0, 0)
    print("exit status", (status >> 8) & 255)
}

fn main() {
    keep := alloc[i64](8)
    keep[7] = 42
    child(fn() {
        first := alloc[i64](1)
        xs := alloc[i64](0x2000_0000_0000_0000)
        xs[3] = 1
    })
    child(fn() { s := alloc[u8](0x7FFF_FFFF_FFFF_FFF8) })
    child(fn() { v := vec_fill(-100, 5) })
    child(fn() { v := vec_fill(0x2000_0000_0000_0000, 5) })
    child(fn() {
        v := vec[i64]()
        v.reserve(0x2000_0000_0000_0000)
        v.buf[3] = 55
    })
    child(fn() { s := repeat("abcd", 0x4000_0000_0000_0001) })
    child(fn() {
        v := vec_of([]i64{1, 2, 3})
        v.resize(-2, 0)
    })
    // the empty string repeated any number of times is empty, at once
    print(len(repeat("", 0x4000_0000_0000_0000)), keep[7])
}
