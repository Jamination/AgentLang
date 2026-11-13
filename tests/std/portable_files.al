// Files, directories, paths, I/O errors and standard input through std.asset and the prelude,
// with the same output on every target (also run by `tests/run.sh --target windows`)
use std.os

fn why() -> str { error_text(io_error()) }

fn main() {
    d := fmt("tmp/portable_files_", process_id())
    a := path_join(d, "a")
    print("make_dir:", make_dir(path_join(d, "a/b")), is_dir(d), is_dir(path_join(a, "b")), make_dir(a))
    f := path_join(a, "x.txt")
    print("write:", write_file(f, "h\xc3\xa9llo\nw\xc3\xb6rld\n"), file_size(f), file_exists(f), is_dir(f))
    t, ok := read_file(f)
    print("read:", ok, t == "h\xc3\xa9llo\nw\xc3\xb6rld\n", len(t), io_error())
    b, okb := read_bytes(f)
    print("read_bytes:", okb, len(b))
    print("write_bytes:", write_bytes(path_join(a, "empty"), ""), file_size(path_join(a, "empty")))
    e, oke := read_file(path_join(a, "empty"))
    print("empty:", oke, len(e))
    print("mtime:", modified_time(f) > 1_600_000_000 * 1_000_000_000, modified_time(path_join(d, "nope")))
    print("list:", list_dir(a))
    print("rename:", rename(f, path_join(a, "y.txt")), file_exists(f), list_dir(a))
    print("replace:", write_file(path_join(a, "z.txt"), "z"), rename(path_join(a, "z.txt"), path_join(a, "y.txt")), read_file(path_join(a, "y.txt")))
    big := alloc[u8](300000)
    fill(big, 'q')
    print("big:", write_file(path_join(a, "big"), big), file_size(path_join(a, "big")), len(read_file(path_join(a, "big")).0))

    _, ok1 := read_file(path_join(d, "missing.txt"))
    print("missing:", ok1, io_error(), why())
    _, ok2 := read_file(a)
    print("directory:", ok2, io_error(), why())
    print("write into a missing directory:", write_file(path_join(d, "no/x"), "x"), io_error(), why())
    print("write a directory:", write_file(a, "x"), io_error(), why())
    print("remove a full directory:", remove_dir(a), io_error(), why())
    print("remove a missing file:", remove_file(path_join(d, "nope")), io_error(), why())
    print("remove a directory as a file:", remove_file(path_join(a, "b")), io_error(), why())
    print("list a missing directory:", len(list_dir(path_join(d, "nope"))), io_error(), why())
    print("rename a missing file:", rename(path_join(d, "nope"), path_join(d, "nope2")), io_error(), why())
    print("NUL in a path:", read_file("a\x00b"), io_error(), why())

    l := assets_new(a)
    x, okx := l.load("y.txt")
    print("load:", okx, x, l.changed("y.txt"), l.changed("never-loaded"))

    print("cleanup:", remove_file(path_join(a, "y.txt")), remove_file(path_join(a, "empty")), remove_file(path_join(a, "big")), remove_dir(path_join(a, "b")), remove_dir(a), remove_dir(d), file_exists(d))

    print(path_join("a", "b"), path_join("a/", "b"), path_join("", "b"), path_join("a", ""), path_join("a", "/b"))
    print(path_dir("a/b/c.png"), path_base("a/b/c.png"), path_ext("x.tar.gz"), path_stem("x.tar.gz"), path_dir("/c"), path_dir("c"), path_base("/"))

    s := read_all(0)
    print("stdin:", len(s), io_error(), lines(s).len)
}
