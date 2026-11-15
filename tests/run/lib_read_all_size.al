// read_file of a small regular file allocates about its size (it took 64 KiB first); files
// whose size the system does not tell (/proc; Windows: the NUL device) and large files still
// read completely
use std.os

fn main() {
    make_dir("tmp")
    // (a name of one length whatever the process id: the copy of the path that read_file
    // makes for the system is part of what it allocates)
    path := concat("tmp/al_ras_", fmti(process_id(), 10, '0'))
    write_file(path, "hello")
    m := mark()
    d, ok := read_file(path)
    print(d, ok, mark() - m)
    m = mark()
    when TARGET_OS == Windows {
        e, ok2 := read_file("NUL")
        print(len(e) == 0, ok2, mark() - m < 70000)
    } else {
        e, ok2 := read_file("/proc/self/status")
        print(len(e) > 100, ok2, mark() - m < 20000)
    }
    big := repeat("x", 100000)
    write_file(path, big)
    m = mark()
    f, ok3 := read_file(path)
    print(f == big, ok3, mark() - m)
    remove_file(path)
}
