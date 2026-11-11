// io_error(): the OS error number of the most recent failed file operation; error_text(e)
fn report(what str, ok bool) {
    print(what, ok, io_error(), error_text(io_error()))
}

fn can_read(path str) bool {
    data, ok := read_file(path)
    return ok && len(data) >= 0
}

fn main() {
    print(io_error(), error_text(io_error()))
    data, ok := read_file("tests/run/data/const_embed.txt")
    report("read", ok)
    print(len(data))
    report("read missing", can_read("tests/run/data/no_such_file.txt"))
    // the number stays until the next file operation
    x := fmt(1, 2, 3)
    print(x, io_error())
    d, ok2 := read_file("tests/run/data")
    report("read directory", ok2)
    print(len(d))
    report("read below a file", can_read("tests/run/data/const_embed.txt/x"))
    report("read empty path", can_read(""))
    // a success resets it
    report("read again", can_read("tests/run/data/const_embed.txt"))
    report("write into missing directory", write_file("tests/run/no_such_dir/x.txt", "x"))
    report("write to a directory", write_file("tests/run/data", "x"))
    path := fmt("/tmp/al_io_error_", syscall(39), ".txt")
    report("write", write_file(path, "hello"))
    back, ok3 := read_file(path)
    report("read back", ok3)
    print(back)
    syscall(87, cstr(path))
    report("read removed", can_read(path))
    // read_all on a bad descriptor
    junk := read_all(987)
    print(len(junk), io_error(), error_text(io_error()))
    for e in ([]i64{0, 1, 2, 5, 9, 12, 13, 17, 20, 21, 22, 24, 28, 30, 36, 39, 40, 77, 4095, -3}) {
        print(e, error_text(e))
    }
}
