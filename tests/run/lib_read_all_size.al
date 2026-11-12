// read_file of a small regular file allocates about its size (it took 64 KiB first); /proc files
// (size 0) and large files still read completely
fn main() {
    write_file("/tmp/al_lib_read_all_size", "hello")
    m := mark()
    d, ok := read_file("/tmp/al_lib_read_all_size")
    print(d, ok, mark() - m)
    m = mark()
    e, ok2 := read_file("/proc/self/status")
    print(len(e) > 100, ok2, mark() - m < 20000)
    big := repeat("x", 100000)
    write_file("/tmp/al_lib_read_all_size", big)
    m = mark()
    f, ok3 := read_file("/tmp/al_lib_read_all_size")
    print(f == big, ok3, mark() - m)
    syscall(87, ptr("/tmp/al_lib_read_all_size"))
}
