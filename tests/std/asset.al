// std.asset: files, directories, paths, cached loader (works in tmp/asset_test_<pid>)
use std.asset

main :: () {
    // a directory of its own per process, so that concurrent test runs do not collide
    d := fmt("tmp/asset_test_", syscall(39))
    // leftovers of an interrupted run
    remove_file(path_join(d, "ship.txt"))
    remove_file(path_join(d, "level.bin"))
    remove_file(path_join(d, "sub/deep/x"))
    remove_dir(path_join(d, "sub/deep"))
    remove_dir(path_join(d, "sub"))
    remove_dir(d)

    print(file_exists(d), is_dir(d), file_size(d) >= 0, list_dir(d))
    print(make_dir(path_join(d, "sub/deep")), make_dir(d), is_dir(d), is_dir(path_join(d, "sub/deep")), file_exists(d))
    print(file_exists("no/such/file"), is_dir("no/such"), file_size("no/such/file"), modified_time("no/such/file"))

    // write, read back, binary data
    ship := path_join(d, "ship.txt")
    print(write_bytes(ship, "hull=10\n"), file_exists(ship), is_dir(ship), file_size(ship))
    text, ok := read_bytes(ship)
    print(text == "hull=10\n", ok, len(text))
    blob := alloc[u8](70000)
    for i in 0..len(blob) {
        blob[i] = u8(i * 7)
    }
    level := path_join(d, "level.bin")
    print(write_bytes(level, blob), file_size(level))
    back, ok2 := read_bytes(level)
    print(ok2, back == blob)
    floats := []f32{1.5, -2.0, 0.25}
    write_bytes(path_join(d, "sub/deep/x"), as_bytes(floats))
    raw, _ := read_bytes(path_join(d, "sub/deep/x"))
    print(from_bytes[f32](raw))
    none, ok3 := read_bytes(path_join(d, "missing"))
    print(len(none), ok3, write_bytes("no/such/dir/file", "x"), write_bytes(d, "x"))
    print(write_bytes(ship, ""), file_size(ship), read_bytes(ship))
    proc, ok4 := read_bytes("/proc/self/stat")
    print(ok4, len(proc) > 0)
    mt := modified_time(ship)
    print(mt > 1700000000 * 1000000000, mt / 1000000000 - wall_time() < 5, wall_time() - mt / 1000000000 < 60)

    // directories
    print(list_dir(d), list_dir(path_join(d, "sub")), list_dir(ship), list_dir("no/such"))
    long := alloc[u8](5000)
    fill(long, 'a')
    print(file_exists(long), write_bytes(long, "x"), make_dir(long), len(list_dir(long)))

    // paths
    print(path_join("a", "b"), path_join("a/", "b"), path_join("", "b"), path_join("a", "/b"), path_join("a", ""), path_join("a/b", "c/d.e"))
    print(path_dir("a/b/c.png"), len(path_dir("c.png")), path_dir("/c"), path_dir("a/b/"))
    print(path_base("a/b/c.png"), path_base("c"), len(path_base("a/b/")), path_base("/x"))
    print(path_ext("a/b/c.png"), path_ext("x.tar.gz"), len(path_ext("Makefile")), len(path_ext(".hidden")), len(path_ext("a.b/c")), len(path_ext("c.")))
    print(path_stem("a/b/c.png"), path_stem("x.tar.gz"), path_stem("Makefile"), path_stem(".hidden"), path_stem("file."), path_stem("a.b/c"))

    // cached loader with hot-reload polling
    write_bytes(ship, "hull=10\n")
    a := assets_new(d)
    x, okx := a.load("ship.txt")
    y, oky := a.load("ship.txt")
    z, okz := a.load("missing.txt")
    print(x == "hull=10\n", okx, oky, ptr(x) == ptr(y), len(z), okz)
    print(a.changed("ship.txt"), a.changed("missing.txt"), a.changed("level.bin"))
    used := mem_used()
    for i in 0..100 {
        a.changed("ship.txt")
        a.load("ship.txt")
        file_exists(ship)
        modified_time(ship)
    }
    print("polling allocates", mem_used() - used)
    sleep_ms(30)
    write_bytes(ship, "hull=25\n")
    c1 := a.changed("ship.txt")
    stale, _ := a.load("ship.txt")
    fresh, okr := a.reload("ship.txt")
    cached, _ := a.load("ship.txt")
    print(c1, stale == "hull=10\n", fresh == "hull=25\n", okr, a.changed("ship.txt"), ptr(cached) == ptr(fresh))
    nested, okn := a.load("sub/deep/x")
    print(len(nested), okn, a.reload("gone.txt"))
    remove_file(ship)
    gone, okg := a.reload("ship.txt")
    kept, okk := a.load("ship.txt")
    print(len(gone), okg, kept == "hull=25\n", okk, a.changed("ship.txt"))

    // clean up
    print(remove_dir(d), remove_file(ship), remove_file(level), remove_file(path_join(d, "sub/deep/x")))
    print(remove_dir(path_join(d, "sub/deep")), remove_dir(path_join(d, "sub")), remove_dir(d), file_exists(d))
}
