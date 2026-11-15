// What Windows makes of an AL executable's image and resources, asked from inside the program
// (tests/pe/run.sh runs it under Wine, built with and without --icon / --version-info):
// where the image was loaded, the settings of the manifest that the system applied, the icon
// and the version information as the system's own functions return them, and the pointers in
// global data, which only work if the loader relocated them.
extern "kernel32.dll" fn GetModuleHandleW(name: *u16) -> i64
extern "kernel32.dll" fn GetACP() -> u32
extern "kernel32.dll" fn GetModuleFileNameW(module: i64, buf: *u16, n: u32) -> u32
extern "kernel32.dll" fn FindResourceW(module: i64, name: i64, kind: i64) -> i64
extern "kernel32.dll" fn SizeofResource(module: i64, res: i64) -> u32
extern "user32.dll" fn LoadIconW(instance: i64, name: i64) -> i64
extern "user32.dll" fn GetThreadDpiAwarenessContext() -> i64
extern "user32.dll" fn AreDpiAwarenessContextsEqual(a: i64, b: i64) -> i32
extern "version.dll" fn GetFileVersionInfoSizeW(name: *u16, handle: *u32) -> u32
extern "version.dll" fn GetFileVersionInfoW(name: *u16, handle: u32, n: u32, data: *u8) -> i32
extern "version.dll" fn VerQueryValueW(block: *u8, sub: *u16, out: *i64, n: *u32) -> i32

struct Named { name: str, f: fn(i64) -> i64 }

fn twice(x: i64) -> i64 { 2 * x }
fn square(x: i64) -> i64 { x * x }

const TABLE = [2]Named{Named{"twice", twice}, Named{"square", square}}
words := [3]str{"alpha", "beta", "gamma"}

// s (ASCII) as NUL-terminated UTF-16
fn wide(s: str) -> *u16 {
    w := alloc[u16](len(s) + 1)
    for i, c in s {
        w[i] = u16(c)
    }
    ptr(w)
}

// the ASCII text of n UTF-16 units ('?' for anything else)
fn narrow(w: *u16, n: i64) -> str {
    v := vec[u8]()
    for i in 0..n {
        v.push(if w[i] < 128 { u8(w[i]) } else { u8('?') })
    }
    v.items()
}

fn main() {
    h := GetModuleHandleW(nil)
    // (the header in memory holds the base the image has now; --verbose prints it)
    print("moved from the preferred base:", h != 0x1_4000_0000)
    if args().len > 1 && args()[1] == "--verbose" {
        print("base", hex(u64(h)))
    }
    for t in TABLE {
        print(t.name, t.f(7))
    }
    print(words[0], words[1], words[2])
    print("active code page:", GetACP())
    print("per-monitor (v2) DPI aware:", AreDpiAwarenessContextsEqual(GetThreadDpiAwarenessContext(), -4) != 0)
    m := FindResourceW(h, 1, 24)
    print("manifest:", m != 0, if m != 0 { SizeofResource(h, m) } else { 0 })
    print("icon:", LoadIconW(h, 1) != 0)
    path: [600]u16
    GetModuleFileNameW(0, &path[0], 600)
    dummy: u32
    n := GetFileVersionInfoSizeW(&path[0], &dummy)
    if n == 0 {
        print("version: none")
        return
    }
    block := alloc[u8](i64(n))
    if GetFileVersionInfoW(&path[0], 0, n, ptr(block)) == 0 {
        print("version: cannot be read")
        return
    }
    for key in []str{"\\", "FileDescription", "ProductName", "CompanyName", "FileVersion", "ProductVersion", "LegalCopyright", "Comments"} {
        p := 0
        k: u32
        sub := if key == "\\" { key } else { concat("\\StringFileInfo\\040904B0\\", key) }
        if VerQueryValueW(ptr(block), wide(sub), &p, &k) == 0 {
            print(fmt("version ", key, ": none"))
        } else if key == "\\" {
            f := cast[*u32](p)
            print(fmt("version numbers: file ", f[2] >> 16, ".", f[2] & 0xFFFF, ".", f[3] >> 16, ".", f[3] & 0xFFFF,
                " product ", f[4] >> 16, ".", f[4] & 0xFFFF, ".", f[5] >> 16, ".", f[5] & 0xFFFF))
        } else {
            print(fmt("version ", key, ": ", narrow(cast[*u16](p), i64(k) - 1)))
        }
    }
}
