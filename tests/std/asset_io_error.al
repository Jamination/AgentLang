// std.asset: io_error() after read_bytes / write_bytes and the directory functions
use std.asset

fn report(what str, ok bool) {
    print(what, ok, io_error(), error_text(io_error()))
}

fn can_read(path str) bool {
    data, ok := read_bytes(path)
    return ok && len(data) >= 0
}

fn main() {
    d := fmt("tmp/asset_io_error_", syscall(39))
    remove_file(path_join(d, "a.txt"))
    remove_file(path_join(d, "sub/b.txt"))
    remove_dir(path_join(d, "sub"))
    remove_dir(d)

    report("make_dir", make_dir(d))
    a := path_join(d, "a.txt")
    report("write", write_bytes(a, "abc"))
    report("read", can_read(a))
    report("read missing", can_read(path_join(d, "missing.txt")))
    report("read directory", can_read(d))
    report("read below a file", can_read(path_join(a, "x")))
    report("read /proc file", can_read("/proc/self/cmdline"))
    report("write into missing directory", write_bytes(path_join(d, "sub/b.txt"), "x"))
    report("write to a directory", write_bytes(d, "x"))
    report("make_dir on a file", make_dir(a))
    report("make_dir sub", make_dir(path_join(d, "sub")))
    report("write", write_bytes(path_join(d, "sub/b.txt"), "x"))
    report("remove_dir not empty", remove_dir(path_join(d, "sub")))
    report("remove_file missing", remove_file(path_join(d, "nope")))
    print(list_dir(path_join(d, "nope")), io_error())
    print(list_dir(d), io_error())
    // the cached loader goes through read_bytes
    assets := assets_new(d)
    _, ok := assets.load("a.txt")
    report("load", ok)
    _, ok2 := assets.load("zzz.txt")
    report("load missing", ok2)
    // a path that is too long for the system call buffer
    long := alloc[u8](5000)
    fill(long, 'x')
    report("read long path", can_read(long))

    report("remove_file", remove_file(path_join(d, "sub/b.txt")))
    report("remove_file", remove_file(a))
    report("remove_dir", remove_dir(path_join(d, "sub")))
    report("remove_dir", remove_dir(d))
    report("remove_dir again", remove_dir(d))
}
