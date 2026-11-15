// Files on Windows: what only Windows has. Paths with `\`, drives (absolute, relative to the
// drive's directory, the root of the current drive), extended-length paths (`\\?\`), device
// names, names that differ in case or end in a dot or space, characters no name may have,
// files that another handle has open, read-only and hidden files, the program's own file.
// (What every target has is in std/os_files and std/portable_files.)
use std.os

extern "kernel32.dll" fn CreateFileA(name: *u8, access: u32, share: u32, security: i64, disposition: u32, flags: u32, template: i64) -> i64
extern "kernel32.dll" fn CloseHandle(h: i64) -> i32
extern "kernel32.dll" fn SetFileAttributesA(name: *u8, attrs: u32) -> i32
extern "kernel32.dll" fn GetFileAttributesA(name: *u8) -> u32

const GENERIC_READ: u32 = 0x80000000
const OPEN_EXISTING: u32 = 3
const READONLY: u32 = 1
const HIDDEN: u32 = 2
const SYSTEM: u32 = 4
const NORMAL: u32 = 0x80

fn why() -> str { error_text(io_error()) }

fn main() {
    cwd := current_dir()
    drive := cwd[..2]
    d := fmt("tmp\\win_files_", process_id())

    // ---- separators
    print("backslashes", make_dir(fmt(d, "\\a\\b")), is_dir(fmt(d, "/a/b")), is_dir(fmt(d, "\\a/b\\")), list_dir(d), list_dir(fmt(d, "\\")), list_dir(fmt(d, "\\a\\")))
    f := fmt(d, "\\a\\f.txt")
    print("mixed", write_file(f, "x"), read_file(fmt(d, "/a/f.txt")), read_file(fmt(d, "\\a/f.txt")), read_file(fmt(d, "\\\\a\\\\f.txt")), file_size(fmt(d, "/a\\f.txt")))
    print("built", path_join(d, "a") == fmt(d, "/a"), read_file(path_join(path_join(d, "a"), "f.txt")), path_dir(f) == fmt(d, "\\a"), path_base(f), path_ext(f), path_stem(f))

    // ---- drives
    abs := fmt(cwd, "\\", d)
    print("current_dir", len(cwd) > 2 && is_alpha(cwd[0]) && cwd[1] == ':' && cwd[2] == '\\', !ends_with(cwd, "\\") || len(cwd) == 3, find(cwd, "/") < 0)
    print("absolute", is_dir(abs), is_dir(replace(abs, "\\", "/")), read_file(fmt(abs, "\\a\\f.txt")), read_file(fmt(to_lower(drive), abs[2..], "/a/f.txt")))
    print("relative to the drive's directory", is_dir(fmt(drive, d)), list_dir(fmt(drive, d)), read_file(fmt(drive, d, "\\a\\f.txt")), read_file(path_join(drive, fmt(d, "/a/f.txt"))))
    print("the current drive's root", is_dir(cwd[2..]), is_dir(fmt(cwd[2..], "\\", d)), read_file(fmt(replace(cwd[2..], "\\", "/"), "/", d, "/a/f.txt")))
    print("a drive's root", is_dir(fmt(drive, "\\")), is_dir(fmt(drive, "/")), is_dir(drive), len(list_dir(fmt(drive, "\\"))) > 0, len(list_dir(drive)) > 0, file_size(fmt(drive, "\\")) >= 0, read_file(fmt(drive, "\\")), why())
    print("the system drive", is_dir("C:\\"), is_dir("c:/"), contains(list_dir("C:\\"), "windows") || contains(list_dir("C:\\"), "Windows"))
    print("no such drive", is_dir("Q:\\"), file_exists("Q:\\x"), list_dir("Q:\\"), why(), read_file("Q:\\x"), why(), write_file("Q:\\x", "x"), why(), make_dir("Q:\\x\\y"), why())
    print("roots", path_join("C:", "x"), path_join("C:\\", "x"), path_join("a", "C:\\x"), path_join("a", "\\x"), path_join("a\\", "b"), path_join("\\\\srv\\share", "x"), path_join("\\\\srv\\share\\", "x"), path_join("a", "\\\\srv\\share\\x"))
    print("root parts", path_dir("C:\\x"), path_dir("C:x"), path_dir("C:\\"), path_dir("\\\\srv\\share\\x"), path_dir("\\\\srv\\share\\d\\x"), path_base("C:x"), path_base("C:\\"), path_base("\\\\srv\\share\\"), path_base("\\\\srv\\share\\x.y"), path_dir("a\\b/c"), path_base("a/b\\c.d"), path_ext("a.b\\c"), path_stem("a\\b.c.d"))

    // ---- extended-length paths: taken as written by Windows; the `/` of path_join works too
    ext := fmt("\\\\?\\", abs)
    print("extended", is_dir(ext), list_dir(ext), read_file(fmt(ext, "\\a\\f.txt")), read_file(fmt(ext, "/a/f.txt")), read_file(path_join(path_join(ext, "a"), "f.txt")), write_file(path_join(ext, "a/g.txt"), "g"), list_dir(path_join(ext, "a")), rename(path_join(ext, "a/g.txt"), path_join(ext, "a/h.txt")), remove_file(path_join(ext, "a/h.txt")))
    print("extended parts", path_dir("\\\\?\\C:\\x") == "\\\\?\\C:\\", path_base("\\\\?\\C:\\d\\x"), path_join("\\\\?\\C:\\d", "x") == "\\\\?\\C:\\d/x")
    // a path of more than 260 characters, written out in full after \\?\: every Windows takes it
    long := ext
    for i in 0..8 { long = fmt(long, "\\", repeat(fmt(i), 40)) }
    print("long extended path", len(long) > 300, make_dir(long), is_dir(long), write_file(fmt(long, "\\leaf.txt"), "leaf"), read_file(path_join(long, "leaf.txt")), list_dir(long), file_size(fmt(long, "\\leaf.txt")), modified_time(fmt(long, "\\leaf.txt")) > 0)
    // the same path without \\?\ (absolute and relative): Windows takes it only with long
    // paths enabled (LongPathsEnabled in the registry and the program's manifest); it fails
    // with "file name too long" or "no such file or directory" otherwise
    plain := long[4..]
    rel := d
    for i in 0..8 { rel = fmt(rel, "/", repeat(fmt(i), 40)) }
    t1, ok1 := read_file(fmt(plain, "\\leaf.txt"))
    e1 := io_error()
    t2, ok2 := read_file(fmt(rel, "/leaf.txt"))
    e2 := io_error()
    print("long plain path", len(plain) > 300, len(rel) > 300, (ok1 && t1 == "leaf") || e1 == 36 || e1 == 2, (ok2 && t2 == "leaf") || e2 == 36 || e2 == 2, ok1 == ok2)
    eprint(fmt("long paths without \\\\?\\: ", if ok1 { "work" } else { fmt("fail (", error_text(e1), ")") }))
    print("long cleanup", remove_file(fmt(long, "\\leaf.txt")))
    for i in 0..8 {
        remove_dir(long)
        long = path_dir(long)
    }
    print("long removed", long == ext, list_dir(d))
    // a name of more than 255 characters
    print("long name", write_file(fmt(d, "/", repeat("n", 300)), "x"), why(), make_dir(fmt(d, "/", repeat("n", 300))), why(), read_file(fmt(d, "/", repeat("n", 256))), why(), write_file(fmt(d, "/", repeat("n", 255)), "x"), why(), remove_file(fmt(d, "/", repeat("n", 255))))

    // ---- devices
    print("NUL", read_file("NUL"), write_file("NUL", "gone"), write_file("nul", "gone"), read_file("\\\\.\\NUL"), is_dir("NUL"), write_file(fmt(d, "/NUL"), "gone"), list_dir(d))

    // ---- names: case, dots and spaces at the end, characters that no name has
    c := fmt(d, "/Case.TXT")
    print("case", write_file(c, "1"), file_exists(fmt(d, "/case.txt")), read_file(fmt(d, "/CASE.txt")), list_dir(d), write_file(fmt(d, "/CASE.TXT"), "2"), list_dir(d), read_file(c), is_dir(fmt(d, "/A/B")), remove_file(fmt(d, "/cAsE.tXt")), list_dir(d))
    print("case of a rename", write_file(fmt(d, "/one"), ""), write_file(fmt(d, "/TWO"), "2"), rename(fmt(d, "/TWO"), fmt(d, "/ONE")), len(list_dir(d)), read_file(fmt(d, "/one")), remove_file(fmt(d, "/One")))
    print("dot and space at the end", write_file(fmt(d, "/dot."), "1"), write_file(fmt(d, "/space "), "2"), list_dir(d), read_file(fmt(d, "/dot")), read_file(fmt(d, "/space")), remove_file(fmt(d, "/dot")), remove_file(fmt(d, "/space.")), list_dir(d))
    for bad in []str{"a?b", "a*b", "a<b", "a>b", "a|b", "a\"b", "a\x01b", "a\tb"} {
        put(write_file(fmt(d, "/", bad), "x"), ":", io_error(), " ")
    }
    print(list_dir(d))
    print("invalid UTF-8 becomes U+FFFD", write_file(fmt(d, "/bad\xffutf"), "x"), list_dir(d) == []str{"a", "bad\xef\xbf\xbdutf"}, read_file(fmt(d, "/bad\xef\xbf\xbdutf")), remove_file(fmt(d, "/bad\xfeutf")))

    // ---- a file that another handle has open
    u := fmt(d, "\\used.txt")
    o := fmt(d, "\\other.txt")
    write_file(u, "used")
    write_file(o, "other")
    // without sharing: nobody else reads, writes, deletes or renames it
    h := CreateFileA(cstr(u), GENERIC_READ, 0, 0, OPEN_EXISTING, NORMAL, 0)
    print("open without sharing", h != -1, read_file(u), why(), write_file(u, "y"), why(), remove_file(u), why(), rename(u, fmt(d, "\\u2")), why())
    print("still there", file_exists(u), is_dir(u), file_size(u), modified_time(u) > 0, list_dir(d))
    busy := rename(o, u)
    print("rename over it", busy, io_error() == 13 || io_error() == 16)
    CloseHandle(h)
    // shared for reading: it can be read
    h = CreateFileA(cstr(u), GENERIC_READ, 1, 0, OPEN_EXISTING, NORMAL, 0)
    print("open for shared reading", read_file(u), why(), write_file(u, "y"), why(), remove_file(u), why())
    CloseHandle(h)
    // shared for everything (as read_file and write_file open files): a deleted file is gone
    // when the handle is closed, its name is free at once for a rename over it
    h = CreateFileA(cstr(u), GENERIC_READ, 7, 0, OPEN_EXISTING, NORMAL, 0)
    print("open with full sharing", read_file(u), write_file(u, "new"), read_file(u), rename(o, u), read_file(u), remove_file(u))
    CloseHandle(h)
    print("closed", file_exists(u), write_file(u, "again"), read_file(u), remove_file(u), list_dir(d))
    // the program's own file: it cannot be deleted or written while it runs, but renamed
    exe := args()[0]
    if !ends_with(to_lower(exe), ".exe") { exe = fmt(exe, ".exe") }
    print("the running program", file_exists(exe), remove_file(exe), why(), write_file(exe, "x"), io_error() == 16 || io_error() == 13, len(read_bytes(exe).0) > 1000, rename(exe, fmt(exe, ".moved")), rename(fmt(exe, ".moved"), exe))

    // ---- read-only, hidden and system files
    r := fmt(d, "\\readonly.txt")
    write_file(r, "r")
    print("read-only", SetFileAttributesA(cstr(r), READONLY) != 0, read_file(r), file_size(r), write_file(r, "z"), why(), remove_file(r), why(), rename(r, fmt(d, "\\ro2")), list_dir(d))
    write_file(o, "o")
    print("rename over read-only", rename(o, fmt(d, "\\ro2")), why(), read_file(fmt(d, "\\ro2")), list_dir(d))
    print("writable again", SetFileAttributesA(cstr(fmt(d, "\\ro2")), NORMAL) != 0, write_file(fmt(d, "\\ro2"), "z"), rename(o, fmt(d, "\\ro2")), read_file(fmt(d, "\\ro2")), remove_file(fmt(d, "\\ro2")), list_dir(d))
    // write_file replaces a hidden or system file, and it stays hidden (CreateFileW alone refuses)
    hd := fmt(d, "\\hidden.txt")
    write_file(hd, "h")
    SetFileAttributesA(cstr(hd), HIDDEN)
    print("hidden", write_file(hd, "h2"), why(), read_file(hd), GetFileAttributesA(cstr(hd)) & HIDDEN != 0, list_dir(d))
    SetFileAttributesA(cstr(hd), HIDDEN | SYSTEM)
    print("hidden system", write_file(hd, "h3"), why(), read_file(hd), GetFileAttributesA(cstr(hd)) & (HIDDEN | SYSTEM) == HIDDEN | SYSTEM, file_size(hd), rename(hd, fmt(d, "\\h2")), remove_file(fmt(d, "\\h2")))
    SetFileAttributesA(cstr(r), NORMAL)

    // ---- a directory takes the place of no directory, not even an empty one
    make_dir(fmt(d, "\\e"))
    print("a directory over a directory", rename(fmt(d, "\\a\\b"), fmt(d, "\\e")), why(), list_dir(d), rename(fmt(d, "\\e"), fmt(d, "\\e2")), remove_dir(fmt(d, "\\e2")))

    print("cleanup", remove_file(f), remove_dir(fmt(d, "\\a\\b")), remove_dir(fmt(d, "/a")), list_dir(d), remove_dir(d), file_exists(d))
}
