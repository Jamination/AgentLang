// build.bat while a test run is in progress: the run keeps build\altest.exe open, and Windows
// writes no file of a running program, so `build.bat --quick` (and tests\run.bat, which
// rebuilds the runner every time) failed. The runner is now built under another name and left
// as it is when its bytes did not change (a changed one would replace it, a running one renamed
// away first). Here build\altest.exe is held open as a running program holds it (no writing;
// renaming allowed), and `build.bat --runner` must succeed and leave the runner unchanged.
// (Only the runner is rebuilt: --quick would put a seed-built compiler under the rest of the run.)
use std.os

extern "kernel32.dll" fn CreateFileA(name: *u8, access: u32, share: u32, security: i64, disposition: u32, flags: u32, template: i64) -> i64
extern "kernel32.dll" fn CloseHandle(h: i64) -> i32
extern "kernel32.dll" fn GetModuleHandleA(name: *u8) -> i64
extern "kernel32.dll" fn GetProcAddress(module: i64, name: *u8) -> i64

fn main() {
    if GetProcAddress(GetModuleHandleA(cstr("ntdll.dll")), cstr("wine_get_version")) != 0 {
        print("Wine: build.bat needs the fc and move of Windows")
        exit(77)
    }
    if !file_exists("build/alc.exe") || !file_exists("build/altest.exe") || !file_exists("build.bat") {
        print("no build\\alc.exe or build\\altest.exe (build.bat builds both)")
        exit(77)
    }
    before, _ := read_file("build/altest.exe")
    // GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, OPEN_EXISTING
    h := CreateFileA(cstr("build\\altest.exe"), 0x80000000, 5, 0, 3, 0, 0)
    print("held", h != -1)
    out, st := run_capture_all([]str{"cmd", "/c", ".\\build.bat", "--runner"})
    print("build.bat --runner", st, if len(out) == 0 { "(no output)" } else { out })
    CloseHandle(h)
    after, _ := read_file("build/altest.exe")
    // (unchanged, unless build\alc.exe makes another runner than the one held: then the new
    // one is in its place, and the held one was renamed away)
    print("runner in place", len(after) > 0 && starts_with(after, "MZ"), len(before) > 0)
    print("no new file left", !file_exists("build/altest.new.exe"))
}
