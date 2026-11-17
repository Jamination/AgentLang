// Long paths that are short as written: from a deep working directory (about 210 units, made
// here, so the test does not depend on where the checkout is), relative paths of 40 to 70
// units reach 248 (the limit of CreateDirectoryW) or 260 (MAX_PATH) once Windows makes them
// absolute. The file functions must take them as extended-length paths all the same.
// (Long paths as written and `\\?\` paths are in sys/win_files.)
use std.os

extern "kernel32.dll" fn SetCurrentDirectoryA(path: *u8) -> i32

fn why() -> str { error_text(io_error()) }

fn main() {
    root := current_dir()
    base := fmt("tmp\\win_long_cwd_", process_id())
    // the working directory: base, then directories of up to 40 units until it is 210 long
    // (Windows sets no working directory of 258 units or more without LongPathsEnabled)
    deep := base
    k := 0
    while len(root) + 1 + len(deep) < 210 {
        deep = fmt(deep, "\\", repeat(fmt(k % 10), max(1, min(40, 210 - (len(root) + 2 + len(deep))))))
        k += 1
    }
    print("deep", make_dir(deep), SetCurrentDirectoryA(cstr(deep)) != 0)
    cwd := current_dir()
    print("cwd", len(cwd) >= 210 && len(cwd) < 258, cwd == fmt(root, "\\", deep))
    drive := cwd[..2]

    // a directory whose absolute path is 248 to 259 units: CreateDirectoryW's limit
    dn := repeat("d", 248 - len(cwd))
    print("make_dir at 248", len(cwd) + 1 + len(dn) >= 248 && len(cwd) + 1 + len(dn) < 260, make_dir(dn), why(), is_dir(dn), list_dir(dn), list_dir(".") == []str{dn})
    // a file of more than 260 units below it, and one beside it
    f := fmt(dn, "\\", repeat("f", 30))
    g := repeat("g", 70)
    print("write", len(cwd) + 1 + len(f) > 260, len(cwd) + 1 + len(g) > 260, write_file(f, "deep"), why(), write_file(g, "beside"), why())
    print("read", read_file(f), read_file(g), file_exists(f), is_dir(f), file_size(g), modified_time(f) > 0)
    print("list", list_dir(dn) == []str{repeat("f", 30)}, len(list_dir(".")), list_dir(fmt(".\\", dn)) == list_dir(dn))
    // the same files through `.\`, `..\` and `C:name` (relative to the current drive's directory)
    up := fmt("..\\", path_base(cwd), "\\", g)
    print("forms", read_file(fmt(".\\", f)), read_file(up), read_file(fmt(drive, g)), read_file(fmt(drive, f)), file_size(fmt(to_lower(drive), dn, "/", repeat("f", 30))))
    // rename and remove
    h := repeat("h", 70)
    print("rename", rename(g, h), why(), file_exists(g), read_file(h), rename(f, fmt(dn, "\\", repeat("e", 40))), list_dir(dn) == []str{repeat("e", 40)})
    print("remove", remove_file(h), remove_file(fmt(dn, "\\", repeat("e", 40))), why(), remove_dir(dn), why(), list_dir("."))
    // a device stays a device
    print("NUL", write_file("NUL", "gone"), read_file("NUL"), is_dir("NUL"))

    // back to the root, then remove the working directory
    print("back", SetCurrentDirectoryA(cstr(root)) != 0, current_dir() == root)
    for i in 0..k + 1 {
        remove_dir(deep)
        deep = path_dir(deep)
    }
    print("cleanup", file_exists(base))
}
