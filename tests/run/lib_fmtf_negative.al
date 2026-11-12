// a negative number of digits for fmtf / putf is an argument error that names the caller's line
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
    print(fmtf(2.5, 0), fmtf(2.5, 1, 6))
    child(fn() { print(fmtf(1.5, -1)) })
    child(fn() { print(fmtf(1.5, -2, 8)) })
    child(fn() { putf(1.5, -3) })
}
