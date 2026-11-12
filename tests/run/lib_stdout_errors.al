// Standard output that cannot be written stops the program with a message (it used to drop
// the output silently); a non-blocking standard output that is full is waited for.
fn child(fd: i64, nonblock: bool) {
    flush()
    pid := syscall(57)
    if pid == 0 {
        if fd >= 0 {
            syscall(33, fd, 1)              // dup2(fd, 1)
        } else {
            syscall(3, 1)                   // close(1)
        }
        if nonblock {
            syscall(72, 1, 4, 0x800)        // fcntl(1, F_SETFL, O_NONBLOCK)
        }
        for i in 0..100000 {
            print("line", i)
        }
        exit(0)
    }
    if nonblock {
        ts := [2]i64{0, 50_000_000}
        syscall(35, ptr(ts), 0)             // let the pipe fill up
        syscall(3, fd)
        print("bytes", len(read_all(fd - 1)))
    }
    status: i32
    syscall(61, pid, &status, 0, 0)
    print("exit status", (status >> 8) & 255)
}

fn main() {
    full := syscall(2, ptr("/dev/full"), 1, 0)
    child(full, false)
    child(-1, false)
    p: [2]i32
    syscall(22, ptr(p), 0)                  // pipe: p[0] read end, p[1] write end
    assert p[1] == p[0] + 1
    child(i64(p[1]), true)
}
