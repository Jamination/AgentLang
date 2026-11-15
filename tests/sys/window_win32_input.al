// The input path of std.window on Windows without a display (Wine's null driver, as
// tests/run.sh --target windows sets it up): the translation of raw mouse records (synthetic
// RAWINPUT records: relative, absolute, several devices), a locked pointer read as raw input
// (the mouse moves through SendInput, which makes WM_INPUT), a mouse that reports thousands
// of times between two polls, focus loss and return, a click on the window's frame, a modal
// move loop, key state after the focus came back, system keys, text against key events, and
// the input method editor.
use std.window

extern "user32.dll" fn PostMessageW(hwnd: *u8, msg: u32, wparam: u64, lparam: i64) -> i32
extern "user32.dll" fn SendMessageW(hwnd: *u8, msg: u32, wparam: u64, lparam: i64) -> i64
extern "user32.dll" fn SendInput(n: u32, inputs: *HwInput, size: i32) -> u32
extern "user32.dll" fn GetCursor() -> *u8
extern "user32.dll" fn GetCursorPos(p: *[2]i32) -> i32
extern "user32.dll" fn SetCursorPos(x: i32, y: i32) -> i32
extern "user32.dll" fn ScreenToClient(hwnd: *u8, p: *[2]i32) -> i32
extern "user32.dll" fn ClientToScreen(hwnd: *u8, p: *[2]i32) -> i32
extern "user32.dll" fn GetClipCursor(rect: *[4]i32) -> i32
extern "user32.dll" fn ShowWindow(hwnd: *u8, cmd: i32) -> i32
extern "imm32.dll" fn ImmGetContext(hwnd: *u8) -> *u8
extern "imm32.dll" fn ImmReleaseContext(hwnd: *u8, context: *u8) -> i32

// INPUT (40 bytes): `kind` 0 with a MOUSEINPUT (dx, dy, data, flags), 1 with a KEYBDINPUT
// (vk and scan in `dx`, flags in `dy`)
struct HwInput {
    kind: u32
    align: u32
    dx: i32
    dy: i32
    data: u32
    flags: u32
    time: u32
    extra: u64
}

// the mouse moves by (dx, dy) counts (below 6: Wine applies the pointer acceleration of
// SendInput above that)
fn mouse(dx: i32, dy: i32) {
    m := HwInput{kind: 0, dx: dx, dy: dy, flags: 1}                  // MOUSEEVENTF_MOVE
    SendInput(1, &m, i32(sizeof[HwInput]()))
}

fn button(flags: u32) {
    m := HwInput{kind: 0, flags: flags}
    SendInput(1, &m, i32(sizeof[HwInput]()))
}

fn keys(list: [](i32, i32, i32)) {
    for k in list {
        // (vk, scan, KEYEVENTF flags)
        m := HwInput{kind: 1, dx: k.0 | k.1 << 16, dy: k.2}
        SendInput(1, &m, i32(sizeof[HwInput]()))
    }
}

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
            EventText => print(" ", e.kind, e.codepoint)
            EventMouseMove, EventMouseDown, EventMouseUp => print(" ", e.kind, e.key, e.x, e.y)
            _ => print(" ", e.kind)
        }
    }
}

// where the pointer is (client pixels), whether it is confined to that one pixel, and its shape
fn pointer(w: *Window) -> str {
    h := win32_hwnd(w)
    cur: [2]i32
    GetCursorPos(&cur)
    clip: [4]i32
    GetClipCursor(&clip)
    held := clip[2] - clip[0] == 1 && clip[3] - clip[1] == 1 && clip[0] == cur[0] && clip[1] == cur[1]
    ScreenToClient(h, &cur)
    SendMessageW(h, 0x20, u64(cast[i64](h)), 0x02000001)             // WM_SETCURSOR, HTCLIENT
    fmt("at ", cur, if held { " held" } else { " free" }, if GetCursor() == nil { " hidden" } else { " shown" })
}

fn translation() {
    print("raw mouse records")
    print(sizeof[RawInputMouse]())
    s: RawMotion
    mouse_a := cast[*u8](0x10001)
    tablet := cast[*u8](0x10002)
    remote := cast[*u8](0x10003)
    // a mouse: counts, as they are
    put(motion_from_raw_mouse(&s, &RawInputMouse{device: mouse_a, last_x: 5, last_y: -3}, 0, 0), " ")
    put(motion_from_raw_mouse(&s, &RawInputMouse{device: mouse_a, last_x: -32000, last_y: 32000}, 0, 0), " ")
    print(motion_from_raw_mouse(&s, &RawInputMouse{device: mouse_a, buttons: 1}, 0, 0))
    // a tablet on a 1920 x 1080 primary monitor: positions 0..65535, differenced in pixels
    put(motion_from_raw_mouse(&s, &RawInputMouse{device: tablet, flags: 1, last_x: 32768, last_y: 32768}, 1920, 1080), " ")
    put(motion_from_raw_mouse(&s, &RawInputMouse{device: tablet, flags: 1, last_x: 34133, last_y: 32768}, 1920, 1080), " ")
    put(motion_from_raw_mouse(&s, &RawInputMouse{device: tablet, flags: 1, last_x: 0, last_y: 65535}, 1920, 1080), " ")
    // the mouse in between does not disturb it
    put(motion_from_raw_mouse(&s, &RawInputMouse{device: mouse_a, last_x: 7, last_y: 7}, 0, 0), " ")
    print(motion_from_raw_mouse(&s, &RawInputMouse{device: tablet, flags: 1, last_x: 65535, last_y: 65535}, 1920, 1080))
    // remote desktop: positions on the virtual desktop (3840 x 1080 here); another device
    // starts again without a jump
    put(motion_from_raw_mouse(&s, &RawInputMouse{device: remote, flags: 3, last_x: 100, last_y: 100}, 3840, 1080), " ")
    put(motion_from_raw_mouse(&s, &RawInputMouse{device: remote, flags: 3, last_x: 1124, last_y: 100}, 3840, 1080), " ")
    print(motion_from_raw_mouse(&s, &RawInputMouse{device: tablet, flags: 1, last_x: 0, last_y: 0}, 1920, 1080))
    // small steps add up to the distance between the ends: nothing is lost to rounding
    sum := 0
    t: RawMotion
    for x in 0..=1000 {
        dx, _ := motion_from_raw_mouse(&t, &RawInputMouse{flags: 1, last_x: i32(1000 + x * 7)}, 1920, 1080)
        sum += dx
    }
    print(sum, 8000 * 1920 / 65535 - 1000 * 1920 / 65535)
    // a keyboard record is no motion
    print(motion_from_raw_mouse(&s, &RawInputMouse{kind: 1, last_x: 9, last_y: 9}, 0, 0))
}

fn main() {
    translation()
    w, ok := window_open(WindowDesc{title: "AL input", width: 320, height: 200})
    if !ok {
        print("cannot open a window")
        exit(1)
    }
    h := win32_hwnd(w)
    w.poll()
    SetCursorPos(40, 60)
    w.poll()
    before: [2]i32
    GetCursorPos(&before)

    print("locked pointer")
    print(pointer(w))
    w.set_cursor_locked(true)
    print("locked:", w.cursor_locked, pointer(w))
    start := w.input.mouse_pos()
    mouse(5, 3)
    show(w)
    print("delta:", w.input.mouse_delta(), "moved:", w.input.mouse_pos() - start, pointer(w))
    // a run of records between two polls is one event; the events around it keep their place
    mouse(-2, 4)
    mouse(-2, 4)
    keys([](i32, i32, i32){(0x41, 0x1E, 0)})                          // A down
    mouse(1, 1)
    PostMessageW(h, 0x200, 0, 0x00100010)                             // WM_MOUSEMOVE: not the mouse
    button(0x2)                                                       // left button down, up
    button(0x4)
    mouse(3, -1)
    mouse(1, -1)
    keys([](i32, i32, i32){(0x41, 0x1E, 2)})
    show(w)
    print("delta:", w.input.mouse_delta(), "moved:", w.input.mouse_pos() - start, "clicked:", w.input.mouse_pressed(MOUSE_LEFT))
    show(w)
    print("delta:", w.input.mouse_delta(), pointer(w))

    print("a fast mouse")
    // 6000 reports between two polls (PENDING_CAP is 1024, EVENT_QUEUE_CAP 256)
    for i in 0..3000 {
        mouse(1, 0)
        mouse(0, -1)
    }
    w.poll()
    print("delta:", w.input.mouse_delta(), "events:", w.events.len, "dropped:", w.events.dropped)
    w.poll()
    print("delta:", w.input.mouse_delta(), "events:", w.events.len)

    print("focus lost and back")
    PostMessageW(h, 0x100, 0x44, 0x00200001)                          // D held
    show(w)
    SendMessageW(h, 0x08, 0, 0)                                       // WM_KILLFOCUS
    print("before poll:", w.input.key_down(KEY_D), pointer(w))
    mouse(5, 5)
    show(w)
    print("held:", w.input.key_down(KEY_D), "released:", w.input.key_released(KEY_D), "locked:", w.cursor_locked, "delta:", w.input.mouse_delta())
    SendMessageW(h, 0x07, 0, 0)                                       // WM_SETFOCUS
    show(w)
    print(pointer(w))
    // the key is still held: its auto-repeat counts as a press
    PostMessageW(h, 0x100, 0x44, 0x40200001)
    PostMessageW(h, 0x100, 0x44, 0x40200001)
    mouse(2, 2)
    show(w)
    print("held:", w.input.key_down(KEY_D), "pressed:", w.input.key_pressed(KEY_D), "delta:", w.input.mouse_delta())
    PostMessageW(h, 0x101, 0x44, 0xC0200001)
    show(w)

    print("click on the frame")
    SendMessageW(h, 0x08, 0, 0)
    show(w)
    button(0x2)                                                       // MOUSEEVENTF_LEFTDOWN
    w.poll()
    // WM_MOUSEACTIVATE with HTCAPTION, then the focus: the user took the title bar
    SendMessageW(h, 0x21, u64(cast[i64](h)), 0x02010002)
    SendMessageW(h, 0x07, 0, 0)
    w.poll()
    print("button held:", pointer(w), "focused:", w.input.focused)
    button(0x4)                                                       // MOUSEEVENTF_LEFTUP
    w.poll()
    print("button up:", pointer(w))

    print("window menu")
    SendMessageW(h, 0x211, 0, 0)                                      // WM_ENTERMENULOOP
    w.poll()
    mouse(3, 3)
    w.poll()
    print("open:", pointer(w), "delta:", w.input.mouse_delta())
    SendMessageW(h, 0x212, 0, 0)                                      // WM_EXITMENULOOP
    w.poll()
    print("closed:", pointer(w))

    print("minimized")
    ShowWindow(h, 6)                                                  // SW_MINIMIZE
    w.poll()
    clip: [4]i32
    GetClipCursor(&clip)
    print("minimized:", w.minimized, "confined:", clip[2] - clip[0] == 1)
    ShowWindow(h, 9)                                                  // SW_RESTORE
    w.poll()
    w.poll()
    print("restored:", !w.minimized, pointer(w))

    print("unlocked")
    w.set_cursor_locked(false)
    cur: [2]i32
    GetCursorPos(&cur)
    print("locked:", w.cursor_locked, "back:", cur == before, pointer(w))
    mouse(4, 4)
    w.poll()
    GetCursorPos(&cur)
    print("the pointer moves:", cur[0] - before[0], cur[1] - before[1])

    print("system keys")
    // Alt+Enter (the game's fullscreen key), F10, Alt alone: key events, no menu mode
    keys([](i32, i32, i32){(0xA4, 0x38, 0), (0x0D, 0x1C, 0), (0x0D, 0x1C, 2), (0xA4, 0x38, 2),
        (0x79, 0x44, 0), (0x79, 0x44, 2), (0xA4, 0x38, 0), (0xA4, 0x38, 2)})
    show(w)
    show(w)
    print("alt held:", w.input.alt_down(), "closing:", w.should_close())

    print("text and keys")
    // a, shift+a, ctrl+a: every press is a key event; only the first two type
    keys([](i32, i32, i32){(0x41, 0x1E, 0), (0x41, 0x1E, 2), (0xA0, 0x2A, 0), (0x41, 0x1E, 0), (0x41, 0x1E, 2),
        (0xA0, 0x2A, 2), (0xA2, 0x1D, 0), (0x41, 0x1E, 0), (0x41, 0x1E, 2), (0xA2, 0x1D, 2)})
    show(w)
    buf: [16]u8
    print("text:", w.input.text_utf8(buf[..]))
    // WM_UNICHAR: a program that sends UTF-32 asks first (0xFFFF), then sends
    print("takes WM_UNICHAR:", SendMessageW(h, 0x109, 0xFFFF, 0))
    for c in []u64{0x1F600, 'z', 0x08, 0xD800, 0x110000} {
        PostMessageW(h, 0x109, c, 1)
    }
    show(w)

    print("input method editor")
    fn ime(h: *u8) -> bool {
        c := ImmGetContext(h)
        if c != nil {
            ImmReleaseContext(h, c)
        }
        c != nil
    }
    print("attached:", ime(h), w.text_input)
    w.set_text_input(true)
    print("attached:", ime(h), w.text_input)
    w.set_text_input(false)
    print("attached:", ime(h), w.text_input)

    print("alt+f4")
    keys([](i32, i32, i32){(0xA4, 0x38, 0), (0x73, 0x3E, 0), (0x73, 0x3E, 2), (0xA4, 0x38, 2)})
    show(w)
    print("closing:", w.should_close())
    w.set_cursor_locked(true)
    w.close()
    GetClipCursor(&clip)
    print("closed; confined:", clip[2] - clip[0] == 1)
}
