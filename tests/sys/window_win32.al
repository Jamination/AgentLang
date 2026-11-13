// std.window on Windows without a display (Wine's null driver, as tests/run.sh --target windows
// sets it up): a real Win32 window receives posted and synthesized (SendInput) messages, and
// the test checks the events, the input state, sizes, fullscreen, the pointer, the pixels drawn
// by `present` (read back with GetPixel), close requests and a modal move loop that `poll`
// must leave while it runs.
use std.window

extern "user32.dll" fn PostMessageW(hwnd: *u8, msg: u32, wparam: u64, lparam: i64) -> i32
extern "user32.dll" fn SendMessageW(hwnd: *u8, msg: u32, wparam: u64, lparam: i64) -> i64
extern "user32.dll" fn SendInput(n: u32, inputs: *KeyInput, size: i32) -> u32
extern "user32.dll" fn GetWindowTextW(hwnd: *u8, buf: *u16, n: i32) -> i32
extern "user32.dll" fn GetWindowLongPtrW(hwnd: *u8, index: i32) -> i64
extern "user32.dll" fn GetClientRect(hwnd: *u8, rect: *[4]i32) -> i32
extern "user32.dll" fn IsWindow(hwnd: *u8) -> i32
extern "user32.dll" fn GetCursor() -> *u8
extern "user32.dll" fn GetDC(hwnd: *u8) -> *u8
extern "user32.dll" fn ReleaseDC(hwnd: *u8, dc: *u8) -> i32
extern "user32.dll" fn GetThreadDpiAwarenessContext() -> *u8
extern "user32.dll" fn GetAwarenessFromDpiAwarenessContext(ctx: *u8) -> i32
extern "gdi32.dll" fn GetPixel(dc: *u8, x: i32, y: i32) -> u32
extern "user32.dll" fn MapVirtualKeyW(code: u32, map_type: u32) -> u32

// INPUT with a KEYBDINPUT (40 bytes: the union starts at offset 8)
struct KeyInput {
    kind: u32
    align: u32
    vk: u16
    scan: u16
    flags: u32
    time: u32
    extra: u64
    pad: u64
}

// (moving the window under the pointer makes Wine send a WM_MOUSEMOVE at a position that
// depends on where the window opened: not printed in those parts)
print_moves := true

fn show(w: *Window) {
    flush()
    w.poll()
    loop {
        e, more := w.next_event()
        if !more {
            break
        }
        match e.kind {
            EventKeyDown, EventKeyUp => print(" ", e.kind, key_name(e.key), "mods", e.mods, "repeat", e.repeat)
            EventText => print(" ", e.kind, e.codepoint, "mods", e.mods)
            EventMouseMove, EventMouseDown, EventMouseUp => {
                if print_moves || e.kind != EventMouseMove {
                    print(" ", e.kind, e.key, e.x, e.y, "mods", e.mods)
                }
            }
            _ => print(" ", e.kind, e.x, e.y)
        }
    }
}

fn post(w: *Window, msg: u32, wp: u64, lp: i64) {
    PostMessageW(win32_hwnd(w), msg, wp, lp)
}

// a key message as the keyboard driver sends it: scan code, extended flag, previous state
fn key(w: *Window, down: bool, vk: u64, scan: i64, ext: bool) {
    lp := 1 | scan << 16 | (if ext { 0x01000000 } else { 0 })
    if !down {
        lp |= 0xC0000000
    }
    post(w, if down { 0x100 } else { 0x101 }, vk, lp)
}

fn send_keys(keys: []KeyInput) {
    SendInput(u32(len(keys)), ptr(keys), i32(sizeof[KeyInput]()))
}

fn main() {
    w, ok := window_open(WindowDesc{title: "AL \xc3\xa9t\xc3\xa9 \xf0\x9f\x98\x80", width: 320, height: 200})
    print("open:", ok)
    if !ok {
        exit(1)
    }
    h := win32_hwnd(w)
    title: [32]u16
    n := GetWindowTextW(h, ptr(title), 32)
    print("title:", title[..n])
    r: [4]i32
    GetClientRect(h, &r)
    style := GetWindowLongPtrW(h, -16)
    print("client:", r, "size:", w.size(), "resizable:", style & 0x40000 != 0, "per-monitor dpi:", GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext()) == 2)
    print("first poll")
    show(w)

    print("key table")
    // every key code comes from some virtual key on the US layout
    seen: [KEY_COUNT]bool
    for vk in 0..256 {
        for ext in [2]bool{false, true} {
            for scan in [2]u32{0x2A, 0x36} {
                seen[key_from_vk(u32(vk), scan, ext, MapVirtualKeyW(u32(vk), 2))] = true
            }
        }
    }
    missing := 0
    for k in 1..KEY_COUNT {
        if !seen[k] {
            missing += 1
            print("no virtual key for", key_name(k))
        }
    }
    print("unmapped key codes:", missing)
    // other layouts: AZERTY digit row ('&'), German sharp s, a dead circumflex, the dead
    // apostrophe of US-International, a Cyrillic letter on the F key, QWERTZ Z (VK_Z types z)
    for t in [](u32, u32){(0x31, '&'), (0xDB, 0xDF), (0xDC, 0x8000005E), (0xDE, 0x80000027), (0x46, 0x0410), (0x5A, 'Z'), (0xBF, '-')} {
        put(key_name(key_from_vk(t.0, 0, false, t.1)), " ")
    }
    print()
    print(event_from_win32_button(0x20B, 0x20000, 3, 4, MOD_ALT), event_from_win32_button(0x200, 0, 3, 4, 0).kind)

    print("keys (posted)")
    key(w, true, 0x41, 0x1E, false)
    key(w, true, 0x41, 0x1E, false)          // auto-repeat
    key(w, false, 0x41, 0x1E, false)
    key(w, true, 0x10, 0x2A, false)          // left shift
    key(w, false, 0x10, 0x2A, false)
    key(w, true, 0x10, 0x36, false)          // right shift
    key(w, false, 0x10, 0x36, false)
    key(w, true, 0x11, 0x1D, true)           // right ctrl
    key(w, false, 0x11, 0x1D, true)
    key(w, true, 0x25, 0x4B, true)           // left arrow
    key(w, true, 0x25, 0x4B, false)          // keypad 4 without Num Lock
    key(w, true, 0x0D, 0x1C, true)           // keypad enter
    key(w, true, 0x67, 0x47, false)          // keypad 7 with Num Lock
    key(w, true, 0x70, 0x3B, false)          // F1
    key(w, true, 0xBD, 0x0C, false)          // minus (US layout)
    key(w, true, 0x7C, 0x64, false)          // F13: no key code
    key(w, false, 0x2C, 0x37, true)          // Print Screen: only the key-up comes
    post(w, 0x104, 0x12, 0x20380001)         // WM_SYSKEYDOWN left alt
    post(w, 0x105, 0x12, 0xE0380001)         // WM_SYSKEYUP left alt (no menu mode)
    show(w)
    print("held:", w.input.key_down(KEY_LEFT), w.input.key_down(KEY_KP_4), w.input.key_down(KEY_A), "pressed:", w.input.key_pressed(KEY_A), "repeated:", w.input.key_repeated(KEY_A))

    print("text (posted)")
    for c in []u64{'x', 0xE9, 0xD83D, 0xDE00, 0x08, 0x0D, 0x7F, 0x1B, 0xDE00, ' '} {
        post(w, 0x102, c, 1)
    }
    show(w)
    print("text:", w.input.text())

    print("focus lost")
    key(w, true, 0x44, 0x20, false)
    show(w)
    SendMessageW(h, 0x08, 0, 0)              // WM_KILLFOCUS
    print("held before poll:", w.input.key_down(KEY_D))
    show(w)
    print("held after poll:", w.input.key_down(KEY_D), w.input.key_down(KEY_LEFT), "focused:", w.input.focused)
    SendMessageW(h, 0x07, 0, 0)              // WM_SETFOCUS
    show(w)

    print("keys (SendInput)")
    // shift+h, i, shift+1 (Wine's key state does not tell the two Shift keys apart: left only);
    // left ctrl + right ctrl; then release
    send_keys([]KeyInput{
        KeyInput{kind: 1, vk: 0x10, scan: 0x2A}, KeyInput{kind: 1, vk: 0x48, scan: 0x23},
        KeyInput{kind: 1, vk: 0x48, scan: 0x23, flags: 2}, KeyInput{kind: 1, vk: 0x10, scan: 0x2A, flags: 2},
        KeyInput{kind: 1, vk: 0x49, scan: 0x17}, KeyInput{kind: 1, vk: 0x49, scan: 0x17, flags: 2},
        KeyInput{kind: 1, vk: 0xA0, scan: 0x2A}, KeyInput{kind: 1, vk: 0x31, scan: 0x02},
        KeyInput{kind: 1, vk: 0x31, scan: 0x02, flags: 2}, KeyInput{kind: 1, vk: 0xA0, scan: 0x2A, flags: 2},
        KeyInput{kind: 1, vk: 0xA2, scan: 0x1D}, KeyInput{kind: 1, vk: 0xA3, scan: 0x1D, flags: 1},
        KeyInput{kind: 1, vk: 0xA3, scan: 0x1D, flags: 3}, KeyInput{kind: 1, vk: 0xA2, scan: 0x1D, flags: 2}
    })
    show(w)
    buf: [16]u8
    print("text:", w.input.text_utf8(buf[..]))

    print("mouse (posted)")
    post(w, 0x200, 0, 0x00140010)                     // move to 16, 20
    post(w, 0x201, 1, 0x00140010)                     // left down
    post(w, 0x200, 1, 0xFFFBFFF6)                     // dragged outside: -10, -5
    post(w, 0x202, 0, 0xFFFBFFF6)                     // left up
    post(w, 0x204, 2, 0x00010002)                     // right
    post(w, 0x205, 0, 0x00010002)
    post(w, 0x207, 0x10, 0x00030004)                  // middle
    post(w, 0x208, 0, 0x00030004)
    post(w, 0x20B, 0x10020, 0x00050006)               // x1
    post(w, 0x20C, 0x10000, 0x00050006)
    post(w, 0x20B, 0x20040, 0x00070008)               // x2
    post(w, 0x20C, 0x20000, 0x00070008)
    post(w, 0x20A, 120 << 16, 0)                      // wheel: one step away from the user
    post(w, 0x20A, 0xFF100000, 0)                     // -240: two steps towards
    post(w, 0x20A, 60 << 16, 0)                       // half a step: nothing yet
    post(w, 0x20A, 60 << 16, 0)                       // the other half
    post(w, 0x20E, 120 << 16, 0)                      // tilt right
    show(w)
    print("mouse:", w.input.mouse_pos(), w.input.mouse_delta(), "wheel:", w.input.wheel(), "pressed:", w.input.mouse_pressed(MOUSE_X2), "down:", w.input.mouse_down(MOUSE_LEFT))
    print("in frame:", w.mouse_in_frame(64, 64), w.mouse_in_frame(320, 200))

    print("present")
    // 2 x 2 RGBA: red, green / blue, white; shown as 200 x 200 at x = 60
    img := []u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 0}
    print("presented:", w.present(img, 2, 2))
    dc := GetDC(h)
    // GetPixel: 0x00BBGGRR
    for p in [](i32, i32){(10, 10), (61, 1), (259, 99), (61, 199), (259, 100), (300, 150)} {
        put(hex(u64(GetPixel(dc, p.0, p.1)), 6), " ")
    }
    print()
    ReleaseDC(h, dc)

    print("pointer")
    w.set_cursor_visible(false)
    SendMessageW(h, 0x20, u64(cast[i64](h)), 0x02000001)   // WM_SETCURSOR, HTCLIENT
    hidden := GetCursor() == nil
    w.set_cursor_visible(true)
    SendMessageW(h, 0x20, u64(cast[i64](h)), 0x02000001)
    print("hidden:", hidden, "shown:", GetCursor() != nil, w.cursor_hidden)

    print("fullscreen")
    print_moves = false
    w.set_fullscreen(true)
    print("before poll:", w.size())
    show(w)
    fw, fh := w.size()
    GetClientRect(h, &r)
    print("covers the monitor:", fw > 320 && fh > 200 && r[2] == i32(fw) && r[3] == i32(fh), "popup:", GetWindowLongPtrW(h, -16) & 0x80000000 != 0)
    w.set_fullscreen(false)
    show(w)
    print("windowed:", w.size(), "popup:", GetWindowLongPtrW(h, -16) & 0x80000000 != 0)
    w.set_title("renamed")
    n = GetWindowTextW(h, ptr(title), 32)
    print("title:", title[..n])

    print_moves = true
    print("menu key and move loop")
    t0 := clock_ns()
    SendMessageW(h, 0x112, 0xF100, 0)                // SC_KEYMENU from F10 / Alt: ignored
    post(w, 0x112, 0xF010, 0)                        // SC_MOVE: the keyboard move loop
    show(w)
    print("poll returned inside the loop:", IsWindow(h) != 0)
    // Escape ends the loop (the loop reads it; the window does not see it)
    key(w, true, 0x1B, 0x01, false)
    for i in 0..5 {
        w.poll()
    }
    print("quick:", clock_ns() - t0 < 5_000_000_000)

    print("close")
    post(w, 0x10, 0, 0)                              // WM_CLOSE
    show(w)
    print("should_close:", w.should_close(), "still there:", IsWindow(h) != 0)
    w.close()
    print("closed:", IsWindow(h) == 0, w.should_close(), win32_hwnd(w) == nil, w.present(img, 2, 2))
    w.poll()
    w.close()
    print("events after close:", w.events.len)
}
