// The file and directory functions a tool needs (std.asset, loaded by std.os) and the process
// itself, with the same output on every target. Works inside a directory that it creates
// and removes. Names: spaces, dots, non-ASCII text (UTF-8; UTF-16 for Windows), upper and
// lower case; list_dir sorts by byte value.
use std.os

fn why() -> str { error_text(io_error()) }

fn main() {
    root := current_dir()
    when TARGET_OS == Windows {
        // C:\dir
        print(len(root) > 2 && is_alpha(root[0]) && root[1] == ':' && root[2] == '\\', is_dir(root), file_exists(path_join(root, "tests/std/os_files.al")))
    } else {
        print(len(root) > 1 && root[0] == '/', is_dir(root), file_exists(path_join(root, "tests/std/os_files.al")))
    }
    print(process_id() > 1, process_id() == process_id())
    d := fmt("tmp/os_files_", process_id())
    print("make_dir", make_dir(path_join(d, "a/b/c")), is_dir(path_join(d, "a/b")), make_dir(d), io_error())

    // ---- files and directories
    f := path_join(d, "a/one.txt")
    print("write", write_file(f, "hello\n"), file_exists(f), is_dir(f), file_size(f), modified_time(f) > 0)
    print("missing", file_exists(path_join(d, "nope")), is_dir(path_join(d, "nope")), file_size(path_join(d, "nope")), modified_time(path_join(d, "nope")))
    write_file(path_join(d, "a/Two.txt"), "2")
    write_file(path_join(d, "a/.hidden"), "")
    print("list", list_dir(path_join(d, "a")), list_dir(path_join(d, "a/b/c")), io_error())
    print("list missing", list_dir(path_join(d, "zzz")), why())
    print("list a file", list_dir(f), why())
    g := path_join(d, "a/b/moved.txt")
    print("rename", rename(f, g), io_error(), file_exists(f), read_file(g))
    print("rename over a file", rename(path_join(d, "a/Two.txt"), g), read_file(g), list_dir(path_join(d, "a")))
    print("rename missing", rename(f, g), why())
    print("rename into a missing directory", rename(g, path_join(d, "no/x")), why())
    print("rename a directory", rename(path_join(d, "a/b"), path_join(d, "B")), list_dir(d), list_dir(path_join(d, "B")))
    print("rename a directory over a file", rename(path_join(d, "B/c"), path_join(d, "B/moved.txt")), why(), is_dir(path_join(d, "B/c")))
    print("rename a file over a directory", rename(path_join(d, "B/moved.txt"), path_join(d, "B/c")), why(), read_file(path_join(d, "B/moved.txt")))
    print("rename to itself", rename(path_join(d, "B/moved.txt"), path_join(d, "B/moved.txt")), why(), read_file(path_join(d, "B/moved.txt")))
    print("remove_file", remove_file(path_join(d, "B/moved.txt")), io_error(), remove_file(path_join(d, "B/moved.txt")), why())
    print("remove_dir not empty", remove_dir(path_join(d, "B")), why())
    print("remove_dir of a file", remove_dir(path_join(d, "a/.hidden")), why())
    print("remove_dir", remove_dir(path_join(d, "B/c")), remove_dir(path_join(d, "B")), remove_dir(path_join(d, "B")), why())
    print("make_dir below a file", make_dir(path_join(d, "a/.hidden/x")), why())
    print("make_dir on a file", make_dir(path_join(d, "a/.hidden")), why())
    print("write below a file", write_file(path_join(d, "a/.hidden/x"), "x"), why())
    print("read below a file", read_file(path_join(d, "a/.hidden/x")), why())
    print("remove below a file", remove_file(path_join(d, "a/.hidden/x")), why(), remove_dir(path_join(d, "a/.hidden/x")), why())
    print("rename below a file", rename(path_join(d, "a/.hidden/x"), path_join(d, "y")), why(), rename(path_join(d, "a/.hidden"), path_join(d, "a/.hidden/x")), io_error() != 0)
    print("list below a file", list_dir(path_join(d, "a/.hidden/x")), why())
    print("stat below a file", file_exists(path_join(d, "a/.hidden/x")), file_size(path_join(d, "a/.hidden/x")))
    print("a trailing separator", is_dir(fmt(d, "/a/")), list_dir(fmt(d, "/a/")), file_exists(fmt(d, "/a/.hidden/")), read_file(fmt(d, "/a/.hidden/")).1)
    print("empty path", file_exists(""), is_dir(""), read_file(""), why(), write_file("", "x"), why(), make_dir(""), remove_file(""), remove_dir(""), list_dir(""), why())
    print("dot", is_dir("."), is_dir(".."), is_dir(path_join(d, "a/../a/./")), file_exists(path_join(d, "a/../a/./.hidden")))

    // ---- names
    n := path_join(d, "names")
    make_dir(n)
    names := []str{"with space.txt", "\xc3\xa4\xc3\xb6\xc3\xbc.txt", "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e", "\xf0\x9f\x98\x80 smile", "UPPER", "lower", "a.b.c", "Zed", "_under", "~tilde", "#hash", "100%", "semi;colon", "a'b", "(paren)", "[sq]", "{br}", "a,b", "a=b", "a+b", "a&b", "a@b", "a!b", "a$b", "a^b", "a`b", "-dash", "9"}
    made := 0
    for i, name in names {
        if write_file(path_join(n, name), fmt(i)) { made += 1 }
    }
    listed := list_dir(n)
    print("names", made, len(listed))
    for name in listed {
        text, ok := read_file(path_join(n, name))
        i, _ := parse_i64(text)
        if !ok || i < 0 || i >= len(names) || names[i] != name {
            print("FAILED: listed name does not read back:", name)
        }
    }
    print(listed)
    sorted := true
    for i in 1..len(listed) {
        sorted = sorted && cmp(listed[i - 1], listed[i]) < 0
    }
    print("sorted by byte value:", sorted)
    sub := path_join(n, "d\xc3\xafr with space")
    print("directory names", make_dir(path_join(sub, "\xce\xb1/\xce\xb2")), is_dir(path_join(sub, "\xce\xb1/\xce\xb2")), list_dir(sub), list_dir(path_join(sub, "\xce\xb1")), rename(path_join(sub, "\xce\xb1"), path_join(sub, "\xce\xb3")), list_dir(sub))
    print("remove", remove_dir(path_join(sub, "\xce\xb3/\xce\xb2")), remove_dir(path_join(sub, "\xce\xb3")), remove_dir(sub))
    removed := 0
    for name in listed {
        if remove_file(path_join(n, name)) { removed += 1 }
    }
    print("removed", removed, list_dir(n), remove_dir(n))

    // ---- many entries; a long name; a deep tree
    m := path_join(d, "many")
    make_dir(m)
    for i in 0..300 {
        write_file(path_join(m, fmt("f", fmti(i, 3, '0'))), "")
    }
    all := list_dir(m)
    print("many", len(all), all[0], all[150], all[299])
    for name in all { remove_file(path_join(m, name)) }
    long := repeat("n", 200)
    print("long name", write_file(path_join(m, long), "x"), list_dir(m) == []str{long}, remove_file(path_join(m, long)), remove_dir(m))
    deep := d
    for i in 0..20 { deep = path_join(deep, fmt("level", i)) }
    print("deep", make_dir(deep), write_file(path_join(deep, "leaf"), "leaf"), read_file(path_join(deep, "leaf")), len(deep) - len(d))
    remove_file(path_join(deep, "leaf"))
    for i in 0..20 {
        remove_dir(deep)
        deep = path_dir(deep)
    }
    print("deep removed", deep == d, list_dir(d))

    // ---- file content
    bin := alloc[u8](256 * 4)
    for i in 0..len(bin) { bin[i] = u8(i) }
    print("binary", write_bytes(path_join(d, "bin"), bin), read_bytes(path_join(d, "bin")).0 == bin, file_size(path_join(d, "bin")))
    print("text is not translated", write_file(path_join(d, "text"), "a\r\nb\nc\x1ad"), file_size(path_join(d, "text")), read_file(path_join(d, "text")).0 == "a\r\nb\nc\x1ad")
    print("replace by shorter", write_file(path_join(d, "text"), "xy"), read_file(path_join(d, "text")))
    t0 := modified_time(path_join(d, "text"))
    sleep_ms(50)
    write_file(path_join(d, "text"), "later")
    t1 := modified_time(path_join(d, "text"))
    now := wall_time()
    print("modified_time", t1 > t0, (t1 - t0) / 1_000_000 >= 20, (t1 - t0) / 1_000_000 < 10000, t1 / 1_000_000_000 - now <= 2 && now - t1 / 1_000_000_000 <= 60)
    print("directory", modified_time(d) > 0, file_size(path_join(d, "names")) >= -1, read_bytes(d), why())

    // ---- clean up
    for name in list_dir(path_join(d, "a")) { remove_file(path_join(path_join(d, "a"), name)) }
    print("cleanup", remove_file(path_join(d, "bin")), remove_file(path_join(d, "text")), remove_dir(path_join(d, "a")), remove_dir(d), file_exists(d))
}
