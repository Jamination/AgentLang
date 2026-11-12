// a path with a NUL byte names no file (it used to open the file named by the part before it)
fn main() {
    write_file("/tmp/al_lib_path_nul", "secret")
    d, ok := read_file("/tmp/al_lib_path_nul\0.txt")
    print(len(d), ok, io_error(), write_file("/tmp/al_lib_path_nul\0x", "y"), io_error())
    d2, ok2 := read_file("/tmp/al_lib_path_nul")
    print(d2, ok2)
    syscall(87, ptr("/tmp/al_lib_path_nul"))
}
