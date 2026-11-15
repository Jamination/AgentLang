// a path with a NUL byte names no file (it used to open the file named by the part before it)
use std.os

fn main() {
    make_dir("tmp")
    path := fmt("tmp/al_lib_path_nul_", process_id())
    write_file(path, "secret")
    d, ok := read_file(fmt(path, "\0.txt"))
    print(len(d), ok, io_error(), write_file(fmt(path, "\0x"), "y"), io_error())
    d2, ok2 := read_file(path)
    print(d2, ok2, remove_file(path))
}
