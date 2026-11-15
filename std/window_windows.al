// std.window, Windows layer: the window is a Win32 window (user32.dll), `present` draws with
// GDI (gdi32.dll), imm32.dll switches the input method editor. Loaded by `use std.window` for
// --target windows; the public API is in std/window.al.
//
// - The process is made per-monitor DPI aware (v2) when the first window opens: sizes are
//   physical pixels, as on X11, and a window keeps its client size in pixels when it moves to
//   a monitor of another scale.
// - The window procedure only records events (in the window's pending queue); `poll` pumps
//   the messages and then applies the recorded events in order, so events caused by calls
//   between two polls (set_fullscreen, a swapchain) arrive at the next poll, as on X11.
// - Message pumping runs on a fiber of its own. While the user drags or resizes the window,
//   or a window menu is open, Windows runs a modal loop inside DispatchMessageW; a timer in
//   that loop switches back to the program's fiber, so `poll` returns (and the game keeps
//   running) during the drag. Without fibers (ConvertThreadToFiber failed) `poll` pumps
//   directly and such a loop pauses the program.
// - A locked pointer (set_cursor_locked) is read as raw input: while the window holds the
//   pointer the mouse (HID usage page 1, usage 2) is registered with RegisterRawInputDevices
//   and the WM_INPUT records move a virtual position. Buttons and the wheel stay on the
//   normal messages.
// - No input method editor is attached to the window until set_text_input(w, true).
// All Win32 declarations are file-private: std.dx12 declares some of the same names.

priv extern "kernel32.dll" fn GetModuleHandleW(name: *u16) -> *u8
priv extern "kernel32.dll" fn GetProcAddress(module: *u8, name: *u8) -> *u8
priv extern "kernel32.dll" fn GetProcessHeap() -> *u8
priv extern "kernel32.dll" fn HeapAlloc(heap: *u8, flags: u32, bytes: u64) -> *u8
priv extern "kernel32.dll" fn HeapFree(heap: *u8, flags: u32, p: *u8) -> i32
priv extern "kernel32.dll" fn ConvertThreadToFiber(param: *u8) -> *u8
priv extern "kernel32.dll" fn ConvertFiberToThread() -> i32
priv extern "kernel32.dll" fn CreateFiberEx(commit: u64, reserve: u64, flags: u32, start: fn(*u8), param: *u8) -> *u8
priv extern "kernel32.dll" fn SwitchToFiber(fiber: *u8)

priv extern "user32.dll" fn RegisterClassExW(class: *W32WndClass) -> u16
priv extern "user32.dll" fn CreateWindowExW(ex_style: u32, class_name: *u16, title: *u16, style: u32, x: i32, y: i32, width: i32, height: i32, parent: *u8, menu: *u8, instance: *u8, param: *u8) -> *u8
priv extern "user32.dll" fn DefWindowProcW(hwnd: *u8, msg: u32, wparam: u64, lparam: i64) -> i64
priv extern "user32.dll" fn ShowWindow(hwnd: *u8, cmd: i32) -> i32
priv extern "user32.dll" fn DestroyWindow(hwnd: *u8) -> i32
priv extern "user32.dll" fn PeekMessageW(msg: *W32Msg, hwnd: *u8, filter_min: u32, filter_max: u32, remove: u32) -> i32
priv extern "user32.dll" fn TranslateMessage(msg: *W32Msg) -> i32
priv extern "user32.dll" fn DispatchMessageW(msg: *W32Msg) -> i64
priv extern "user32.dll" fn SendMessageW(hwnd: *u8, msg: u32, wparam: u64, lparam: i64) -> i64
priv extern "user32.dll" fn GetMessageTime() -> i32
priv extern "user32.dll" fn LoadCursorW(instance: *u8, name: *u16) -> *u8
priv extern "user32.dll" fn LoadIconW(instance: *u8, name: *u16) -> *u8
priv extern "user32.dll" fn SetCursor(cursor: *u8) -> *u8
priv extern "user32.dll" fn GetCursorPos(p: *W32Point) -> i32
priv extern "user32.dll" fn ScreenToClient(hwnd: *u8, p: *W32Point) -> i32
priv extern "user32.dll" fn ClientToScreen(hwnd: *u8, p: *W32Point) -> i32
priv extern "user32.dll" fn SetCursorPos(x: i32, y: i32) -> i32
priv extern "user32.dll" fn ClipCursor(rect: *W32Rect) -> i32
priv extern "user32.dll" fn WindowFromPoint(p: W32Point) -> *u8
priv extern "user32.dll" fn AdjustWindowRectEx(rect: *W32Rect, style: u32, menu: i32, ex_style: u32) -> i32
priv extern "user32.dll" fn GetClientRect(hwnd: *u8, rect: *W32Rect) -> i32
priv extern "user32.dll" fn GetWindowRect(hwnd: *u8, rect: *W32Rect) -> i32
priv extern "user32.dll" fn SetWindowTextW(hwnd: *u8, text: *u16) -> i32
priv extern "user32.dll" fn GetWindowLongPtrW(hwnd: *u8, index: i32) -> i64
priv extern "user32.dll" fn SetWindowLongPtrW(hwnd: *u8, index: i32, value: i64) -> i64
priv extern "user32.dll" fn SetWindowPos(hwnd: *u8, after: *u8, x: i32, y: i32, cx: i32, cy: i32, flags: u32) -> i32
priv extern "user32.dll" fn MonitorFromWindow(hwnd: *u8, flags: u32) -> *u8
priv extern "user32.dll" fn GetMonitorInfoW(monitor: *u8, info: *W32MonitorInfo) -> i32
priv extern "user32.dll" fn GetDC(hwnd: *u8) -> *u8
priv extern "user32.dll" fn ReleaseDC(hwnd: *u8, dc: *u8) -> i32
priv extern "user32.dll" fn ValidateRect(hwnd: *u8, rect: *W32Rect) -> i32
priv extern "user32.dll" fn SetCapture(hwnd: *u8) -> *u8
priv extern "user32.dll" fn ReleaseCapture() -> i32
priv extern "user32.dll" fn GetKeyState(vk: i32) -> i16
priv extern "user32.dll" fn MapVirtualKeyW(code: u32, map_type: u32) -> u32
priv extern "user32.dll" fn SetTimer(hwnd: *u8, id: u64, ms: u32, func: fn(*u8, u32, u64, u32)) -> u64
priv extern "user32.dll" fn KillTimer(hwnd: *u8, id: u64) -> i32
priv extern "user32.dll" fn PostMessageW(hwnd: *u8, msg: u32, wparam: u64, lparam: i64) -> i32
priv extern "user32.dll" fn SetProcessDPIAware() -> i32
priv extern "user32.dll" fn RegisterRawInputDevices(devices: *W32RawInputDevice, n: u32, size: u32) -> i32
priv extern "user32.dll" fn GetRawInputData(input: i64, cmd: u32, data: *u8, size: *u32, header_size: u32) -> u32
priv extern "user32.dll" fn GetSystemMetrics(index: i32) -> i32
priv extern "user32.dll" fn GetAsyncKeyState(vk: i32) -> i16

priv extern "imm32.dll" fn ImmAssociateContextEx(hwnd: *u8, context: *u8, flags: u32) -> i32

priv extern "gdi32.dll" fn StretchDIBits(dc: *u8, x: i32, y: i32, w: i32, h: i32, sx: i32, sy: i32, sw: i32, sh: i32, bits: *u8, info: *W32BitmapInfo, usage: u32, rop: u32) -> i32
priv extern "gdi32.dll" fn GetStockObject(which: i32) -> *u8

// MSG
priv struct W32Msg {
    hwnd: *u8
    message: u32
    wparam: u64
    lparam: i64
    time: u32
    pt_x: i32
    pt_y: i32
    private: u32
}

// WNDCLASSEXW
priv struct W32WndClass {
    size: u32
    style: u32
    proc: fn(*u8, u32, u64, i64) -> i64
    cls_extra: i32
    wnd_extra: i32
    instance: *u8
    icon: *u8
    cursor: *u8
    background: *u8
    menu_name: *u16
    class_name: *u16
    icon_small: *u8
}

priv struct W32Rect {
    left: i32
    top: i32
    right: i32
    bottom: i32
}

priv struct W32Point {
    x: i32
    y: i32
}

// RAWINPUTDEVICE
priv struct W32RawInputDevice {
    usage_page: u16
    usage: u16
    flags: u32
    target: *u8
}

// The RAWINPUT record of a mouse, as WM_INPUT delivers it (48 bytes): RAWINPUTHEADER, RAWMOUSE.
struct RawInputMouse {
    kind: u32                    // RIM_TYPEMOUSE (0)
    size: u32
    device: *u8
    wparam: u64
    flags: u16                   // MOUSE_MOVE_ABSOLUTE (1), MOUSE_VIRTUAL_DESKTOP (2)
    buttons: u32                 // usButtonFlags, usButtonData
    raw_buttons: u32
    last_x: i32                  // motion in device counts, or a position 0..65535 (absolute)
    last_y: i32
    extra: u32
}

// What motion_from_raw_mouse remembers: the last position of the absolute device last seen.
struct RawMotion {
    device: *u8
    abs_seen: bool
    abs_x: i64
    abs_y: i64
}

// MONITORINFO
priv struct W32MonitorInfo {
    size: u32
    monitor: W32Rect
    work: W32Rect
    flags: u32
}

// BITMAPINFO (header + one unused colour entry)
priv struct W32BitmapInfo {
    size: u32
    width: i32
    height: i32
    planes: u16
    bit_count: u16
    compression: u32
    size_image: u32
    x_ppm: i32
    y_ppm: i32
    clr_used: u32
    clr_important: u32
    colors: u32
}

priv const WM_NCCREATE: u32 = 0x81
priv const WM_NCDESTROY: u32 = 0x82
priv const WM_DESTROY: u32 = 0x02
priv const WM_SIZE: u32 = 0x05
priv const WM_SETFOCUS: u32 = 0x07
priv const WM_KILLFOCUS: u32 = 0x08
priv const WM_PAINT: u32 = 0x0F
priv const WM_CLOSE: u32 = 0x10
priv const WM_CANCELMODE: u32 = 0x1F
priv const WM_SETCURSOR: u32 = 0x20
priv const WM_MOUSEACTIVATE: u32 = 0x21
priv const WM_INPUT: u32 = 0xFF
priv const WM_KEYDOWN: u32 = 0x100
priv const WM_KEYUP: u32 = 0x101
priv const WM_CHAR: u32 = 0x102
priv const WM_SYSKEYDOWN: u32 = 0x104
priv const WM_SYSKEYUP: u32 = 0x105
priv const WM_SYSCHAR: u32 = 0x106
priv const WM_UNICHAR: u32 = 0x109
priv const WM_SYSCOMMAND: u32 = 0x112
priv const WM_MOUSEMOVE: u32 = 0x200
priv const WM_LBUTTONDOWN: u32 = 0x201
priv const WM_LBUTTONUP: u32 = 0x202
priv const WM_RBUTTONDOWN: u32 = 0x204
priv const WM_RBUTTONUP: u32 = 0x205
priv const WM_MBUTTONDOWN: u32 = 0x207
priv const WM_MBUTTONUP: u32 = 0x208
priv const WM_MOUSEWHEEL: u32 = 0x20A
priv const WM_XBUTTONDOWN: u32 = 0x20B
priv const WM_XBUTTONUP: u32 = 0x20C
priv const WM_MOUSEHWHEEL: u32 = 0x20E
priv const WM_ENTERMENULOOP: u32 = 0x211
priv const WM_EXITMENULOOP: u32 = 0x212
priv const WM_ENTERSIZEMOVE: u32 = 0x231
priv const WM_EXITSIZEMOVE: u32 = 0x232
priv const WM_DPICHANGED: u32 = 0x2E0

priv const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000
priv const WS_FIXED: u32 = 0x00CA0000            // caption, system menu, minimize box
priv const WS_POPUP: u32 = 0x80000000
priv const WS_VISIBLE: u32 = 0x10000000
priv const GWL_STYLE: i32 = -16
priv const GWLP_USERDATA: i32 = -21
priv const SWP_NOSIZE: u32 = 0x1
priv const SWP_NOMOVE: u32 = 0x2
priv const SWP_NOZORDER: u32 = 0x4
priv const SWP_NOACTIVATE: u32 = 0x10
priv const SWP_FRAMECHANGED: u32 = 0x20
priv const SWP_NOOWNERZORDER: u32 = 0x200
priv const PM_NOREMOVE: u32 = 0
priv const PM_REMOVE: u32 = 1
priv const HTCLIENT = 1
priv const SC_KEYMENU: u64 = 0xF100
priv const MK_BUTTONS: u64 = 0x73                // MK_LBUTTON | MK_RBUTTON | MK_MBUTTON | MK_XBUTTON1 | MK_XBUTTON2
priv const VK_ESCAPE: u64 = 0x1B
priv const MOUSE_MOVE_ABSOLUTE: u16 = 1
priv const MOUSE_VIRTUAL_DESKTOP: u16 = 2
priv const PENDING_CAP = 1024

// The Win32 state of a Window (read the handle through win32_hwnd).
struct WindowOs {
    hwnd: *u8
    style: u32
    client_w: i64                // last client size seen by the window procedure
    client_h: i64
    saved: W32Rect               // window rectangle before fullscreen
    wheel_x: i64                 // wheel motion not yet reported (WHEEL_DELTA = one step)
    wheel_y: i64
    surrogate: u32               // high surrogate of a WM_CHAR pair
    fake_ctrl: bool              // the left Ctrl that Windows sends with AltGr is held
    print_down: bool             // a key-down of Print Screen was seen (usually only key-up comes)
    shift_held: [2]bool          // left / right Shift went down
    dib: *u8                     // window-sized conversion buffer of `present` (process heap)
    dib_w: i64
    dib_h: i64
    pending: [PENDING_CAP]Event  // events recorded by the window procedure, applied by poll
    pending_head: i64
    pending_len: i64
    iconic: bool                 // minimized (WM_SIZE with SIZE_MINIMIZED seen)
    clipped: bool                // the locked pointer is held: raw input on, confined (ClipCursor), hidden
    raw: RawMotion               // locked cursor: state of the raw input translation
    frame_click: bool            // a click on the frame (title bar, border) activated the window and is not over
    virt_x: i64                  // locked cursor: the virtual position reported in events
    virt_y: i64
    unlock_x: i64                // locked cursor: where it was when locked
    unlock_y: i64
}

priv class_atom: u16
priv class_name: [16]u16
priv arrow_cursor: *u8
priv dpi_for_window: *u8         // GetDpiForWindow (Windows 10 1607), else nil
priv adjust_for_dpi: *u8         // AdjustWindowRectExForDpi (Windows 10 1607), else nil
priv main_fiber: *u8
priv pump_fiber: *u8
priv fibers: i64                 // 0: not tried yet, 1: pumping on pump_fiber, -1: directly
priv on_pump: bool               // the pump fiber runs (it was switched to by poll)
priv modal: i64                  // modal loops (move / size / menu) in progress
priv modal_timer: u64            // thread timer that ticks while a modal loop runs

// ---- Win32 helpers (no window needed) ----

priv fn w32_key_from_char(c: u32) -> i64 {
    k := i64(c)
    if k >= 'a' && k <= 'z' {
        return KEY_A + k - 'a'
    }
    if k >= 'A' && k <= 'Z' {
        return KEY_A + k - 'A'
    }
    if k >= '0' && k <= '9' {
        return KEY_0 + k - '0'
    }
    match k {
        0x20 => KEY_SPACE
        0x27 => KEY_APOSTROPHE
        0x2C => KEY_COMMA
        0x2D => KEY_MINUS
        0x2E => KEY_PERIOD
        0x2F => KEY_SLASH
        0x3B => KEY_SEMICOLON
        0x3D => KEY_EQUAL
        0x5B => KEY_LBRACKET
        0x5C => KEY_BACKSLASH
        0x5D => KEY_RBRACKET
        0x60 => KEY_GRAVE
        _ => KEY_UNKNOWN
    }
}

// Key code (KEY_*) for a Windows virtual key. `scan` is the scan code and `extended` the
// extended-key flag of the key message (bits 16..23 and 24 of lParam); `ch` is the unshifted
// character of the key on the current layout (MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR)). Keys that
// type characters are named by that character, as X11 names them by their unshifted keysym;
// letter and digit keys whose character has no key code (AZERTY digits, non-Latin layouts)
// fall back to their virtual key. The navigation keys of the keypad (extended flag clear) are
// KEY_KP_*, whatever the state of Num Lock.
fn key_from_vk(vk: u32, scan: u32, extended: bool, ch: u32) -> i64 {
    v := i64(vk)
    if (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0xBA && v <= 0xC0) || (v >= 0xDB && v <= 0xDF) || v == 0xE2 {
        // (bit 31 of ch marks a dead key)
        k := w32_key_from_char(ch & 0x7FFFFFFF)
        if k != KEY_UNKNOWN {
            return k
        }
        if v <= 0x39 {
            return KEY_0 + v - 0x30
        }
        if v <= 0x5A && v >= 0x41 {
            return KEY_A + v - 0x41
        }
        return KEY_UNKNOWN
    }
    if v >= 0x70 && v <= 0x7B {
        return KEY_F1 + v - 0x70
    }
    if v >= 0x60 && v <= 0x69 {
        return KEY_KP_0 + v - 0x60
    }
    match v {
        0x08 => KEY_BACKSPACE
        0x09 => KEY_TAB
        0x0C => KEY_KP_5
        0x0D => if extended { KEY_KP_ENTER } else { KEY_ENTER }
        0x10 => if scan == 0x36 { KEY_RSHIFT } else { KEY_LSHIFT }
        0x11 => if extended { KEY_RCTRL } else { KEY_LCTRL }
        0x12 => if extended { KEY_RALT } else { KEY_LALT }
        0x13 => KEY_PAUSE
        0x14 => KEY_CAPS_LOCK
        0x1B => KEY_ESCAPE
        0x20 => KEY_SPACE
        0x21 => if extended { KEY_PAGE_UP } else { KEY_KP_9 }
        0x22 => if extended { KEY_PAGE_DOWN } else { KEY_KP_3 }
        0x23 => if extended { KEY_END } else { KEY_KP_1 }
        0x24 => if extended { KEY_HOME } else { KEY_KP_7 }
        0x25 => if extended { KEY_LEFT } else { KEY_KP_4 }
        0x26 => if extended { KEY_UP } else { KEY_KP_8 }
        0x27 => if extended { KEY_RIGHT } else { KEY_KP_6 }
        0x28 => if extended { KEY_DOWN } else { KEY_KP_2 }
        0x2C => KEY_PRINT_SCREEN
        0x2D => if extended { KEY_INSERT } else { KEY_KP_0 }
        0x2E => if extended { KEY_DELETE } else { KEY_KP_DECIMAL }
        0x5B => KEY_LSUPER
        0x5C => KEY_RSUPER
        0x5D => KEY_MENU
        0x6A => KEY_KP_MULTIPLY
        0x6B => KEY_KP_ADD
        0x6C, 0x6E => KEY_KP_DECIMAL
        0x6D => KEY_KP_SUBTRACT
        0x6F => KEY_KP_DIVIDE
        0x90 => KEY_NUM_LOCK
        0x91 => KEY_SCROLL_LOCK
        0xA0 => KEY_LSHIFT
        0xA1 => KEY_RSHIFT
        0xA2 => KEY_LCTRL
        0xA3 => KEY_RCTRL
        0xA4 => KEY_LALT
        0xA5 => KEY_RALT
        _ => KEY_UNKNOWN
    }
}

// Translates a Windows mouse button message (WM_LBUTTONDOWN .. WM_XBUTTONUP; `wparam` tells
// the X button) at client position (x, y) into a MOUSE_* press / release (kind EventNone for
// other messages).
fn event_from_win32_button(msg: u32, wparam: u64, x: i64, y: i64, mods: u8) -> Event {
    xb := if wparam >> 16 & 0xFFFF == 2 { MOUSE_X2 } else { MOUSE_X1 }
    match msg {
        WM_LBUTTONDOWN => Event{kind: EventMouseDown, key: MOUSE_LEFT, x: x, y: y, mods: mods}
        WM_LBUTTONUP => Event{kind: EventMouseUp, key: MOUSE_LEFT, x: x, y: y, mods: mods}
        WM_RBUTTONDOWN => Event{kind: EventMouseDown, key: MOUSE_RIGHT, x: x, y: y, mods: mods}
        WM_RBUTTONUP => Event{kind: EventMouseUp, key: MOUSE_RIGHT, x: x, y: y, mods: mods}
        WM_MBUTTONDOWN => Event{kind: EventMouseDown, key: MOUSE_MIDDLE, x: x, y: y, mods: mods}
        WM_MBUTTONUP => Event{kind: EventMouseUp, key: MOUSE_MIDDLE, x: x, y: y, mods: mods}
        WM_XBUTTONDOWN => Event{kind: EventMouseDown, key: xb, x: x, y: y, mods: mods}
        WM_XBUTTONUP => Event{kind: EventMouseUp, key: xb, x: x, y: y, mods: mods}
        _ => Event{}
    }
}

// The relative motion (dx, dy) of one raw mouse record (the RAWINPUT of a WM_INPUT message):
// its motion in device counts as the mouse reports them, before the pointer speed and
// acceleration of Windows. A device that reports positions (MOUSE_MOVE_ABSOLUTE: tablets,
// remote desktop, some virtual machines) gives the difference to its previous position kept
// in `s`, in pixels of the area its coordinates span: `span_w` x `span_h`, the size of the
// virtual desktop if the record has MOUSE_VIRTUAL_DESKTOP, else of the primary monitor. The
// first position of such a device gives (0, 0), as does a record that is not a mouse's.
fn motion_from_raw_mouse(s: *RawMotion, r: *RawInputMouse, span_w: i64, span_h: i64) -> (i64, i64) {
    if r.kind != 0 {
        return (0, 0)
    }
    x := i64(r.last_x)
    y := i64(r.last_y)
    if r.flags & MOUSE_MOVE_ABSOLUTE == 0 {
        return (x, y)
    }
    x = x * span_w / 65535
    y = y * span_h / 65535
    dx := x - s.abs_x
    dy := y - s.abs_y
    if !s.abs_seen || s.device != r.device {
        dx = 0
        dy = 0
    }
    s.device = r.device
    s.abs_seen = true
    s.abs_x = x
    s.abs_y = y
    (dx, dy)
}

// s as NUL-terminated UTF-16 (allocated; invalid UTF-8 becomes U+FFFD)
priv fn w32_wide(s: str) -> *u16 {
    out := alloc[u16](len(s) + 1)
    k := 0
    i := 0
    while i < len(s) {
        c := u32(s[i])
        i += 1
        more := 0
        if c >= 0xC2 && c < 0xE0 {
            more = 1
            c &= 0x1F
        } else if c >= 0xE0 && c < 0xF0 {
            more = 2
            c &= 0x0F
        } else if c >= 0xF0 && c < 0xF5 {
            more = 3
            c &= 0x07
        } else if c >= 0x80 {
            c = 0xFFFD
        }
        for j in 0..more {
            if i >= len(s) || s[i] & 0xC0 != 0x80 {
                c = 0xFFFD
                break
            }
            c = c << 6 | u32(s[i]) & 0x3F
            i += 1
        }
        if c >= 0x10000 {
            c -= 0x10000
            out[k] = u16(0xD800 + (c >> 10))
            out[k + 1] = u16(0xDC00 + (c & 0x3FF))
            k += 2
        } else {
            out[k] = u16(c)
            k += 1
        }
    }
    out[k] = 0
    ptr(out)
}

// ---- event recording (window procedure) and delivery (poll) ----

priv fn w32_record(w: *Window, e: Event) {
    o := &w.os
    if o.pending_len == PENDING_CAP {
        w.events.dropped += 1
        return
    }
    o.pending[(o.pending_head + o.pending_len) % PENDING_CAP] = e
    o.pending_len += 1
}

// Records the motion of a locked pointer. A run of motion between two polls is kept as one
// event, its newest position: a mouse that reports 8000 times a second never fills the queue.
priv fn w32_record_motion(w: *Window, e: Event) {
    o := &w.os
    if o.pending_len > 0 {
        last := &o.pending[(o.pending_head + o.pending_len - 1) % PENDING_CAP]
        if last.kind == EventMouseMove {
            *last = e
            return
        }
    }
    w32_record(w, e)
}

// Applies the recorded events in order: input state, event queue, size and close state.
priv fn w32_deliver(w: *Window) {
    o := &w.os
    while o.pending_len > 0 {
        e := o.pending[o.pending_head]
        o.pending_head = (o.pending_head + 1) % PENDING_CAP
        o.pending_len -= 1
        match e.kind {
            EventKeyDown => e.repeat = key_down(&w.input, e.key)
            EventResize => {
                w.width = e.x
                w.height = e.y
            }
            EventMinimize => w.minimized = true
            EventRestore => w.minimized = false
            EventClose => w.closing = true
            _ => {}
        }
        push_event(&w.events, e)
        feed(&w.input, e)
    }
}

// (virtual key, key code, modifier bit) of the modifier keys
priv const MOD_KEYS = [8](i32, i64, u8){
    (0xA0, KEY_LSHIFT, MOD_SHIFT), (0xA1, KEY_RSHIFT, MOD_SHIFT), (0xA2, KEY_LCTRL, MOD_CTRL),
    (0xA3, KEY_RCTRL, MOD_CTRL), (0xA4, KEY_LALT, MOD_ALT), (0xA5, KEY_RALT, MOD_ALT),
    (0x5B, KEY_LSUPER, MOD_SUPER), (0x5C, KEY_RSUPER, MOD_SUPER)
}

// The modifiers held before the current message, as X11 reports them: the key of a key
// message itself counts with its previous state `was_down`.
priv fn w32_mods(w: *Window, key: i64, was_down: bool) -> u8 {
    m: u8 = 0
    for t in MOD_KEYS {
        down := if t.1 == key { was_down } else { GetKeyState(t.0) < 0 }
        if t.1 == KEY_LCTRL && w.os.fake_ctrl {
            down = false
        }
        if down {
            m |= t.2
        }
    }
    m
}

// True for the left Ctrl message that Windows sends just before the right Alt of AltGr (same
// time stamp): X11 reports AltGr as one key.
priv fn w32_altgr_ctrl() -> bool {
    next: W32Msg
    if PeekMessageW(&next, nil, 0, 0, PM_NOREMOVE) == 0 {
        return false
    }
    m := next.message
    (m == WM_KEYDOWN || m == WM_SYSKEYDOWN || m == WM_KEYUP || m == WM_SYSKEYUP) &&
        next.wparam == 0x12 && next.lparam & 0x01000000 != 0 && next.time == u32(GetMessageTime())
}

priv fn w32_key_message(w: *Window, msg: u32, wp: u64, lp: i64) {
    o := &w.os
    pressed := msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN
    vk := u32(wp & 0xFFFF)
    ext := lp & 0x01000000 != 0
    if vk == 0x11 && !ext && w32_altgr_ctrl() {
        o.fake_ctrl = pressed
        return
    }
    key := key_from_vk(vk, u32(lp >> 16 & 0xFF), ext, MapVirtualKeyW(vk, 2))
    was := lp & 0x40000000 != 0
    mods := w32_mods(w, key, was)
    if pressed {
        if key == KEY_PRINT_SCREEN {
            o.print_down = true
        }
        if key == KEY_LSHIFT || key == KEY_RSHIFT {
            o.shift_held[key - KEY_LSHIFT] = true
        }
        w32_record(w, Event{kind: EventKeyDown, key: key, mods: mods})
        return
    }
    // Windows sends only the key-up of Print Screen
    if key == KEY_PRINT_SCREEN && !o.print_down {
        w32_record(w, Event{kind: EventKeyDown, key: key, mods: mods})
    }
    if key == KEY_PRINT_SCREEN {
        o.print_down = false
    }
    w32_record(w, Event{kind: EventKeyUp, key: key, mods: mods})
    // with both Shift keys held, releasing the first one sends nothing
    if key == KEY_LSHIFT || key == KEY_RSHIFT {
        side := key - KEY_LSHIFT
        o.shift_held[side] = false
        other := 1 - side
        if o.shift_held[other] && GetKeyState(i32(0xA0 + other)) >= 0 {
            o.shift_held[other] = false
            w32_record(w, Event{kind: EventKeyUp, key: KEY_LSHIFT + other, mods: mods})
        }
    }
}

priv fn w32_char_message(w: *Window, wp: u64) {
    o := &w.os
    u := u32(wp & 0xFFFF)
    if u >= 0xD800 && u < 0xDC00 {
        o.surrogate = u
        return
    }
    c := u
    if u >= 0xDC00 && u < 0xE000 {
        if o.surrogate == 0 {
            return
        }
        c = 0x10000 + ((o.surrogate - 0xD800) << 10) + (u - 0xDC00)
    }
    o.surrogate = 0
    w32_text(w, c)
}

// one typed character (control characters are no text)
priv fn w32_text(w: *Window, c: u32) {
    if c >= 0x20 && c != 0x7F && c <= 0x10FFFF && (c < 0xD800 || c > 0xDFFF) {
        w32_record(w, Event{kind: EventText, codepoint: c, mods: w32_mods(w, -1, false)})
    }
}

// WM_INPUT while the locked pointer is held: the motion of the record moves the virtual position.
priv fn w32_raw_input(w: *Window, input: i64) {
    o := &w.os
    r: RawInputMouse
    size := u32(sizeof[RawInputMouse]())
    // RID_INPUT; a record of another size (no mouse) fails
    if GetRawInputData(input, 0x10000003, cast[*u8](&r), &size, 24) != u32(sizeof[RawInputMouse]()) {
        return
    }
    sw := 0
    sh := 0
    if r.flags & MOUSE_MOVE_ABSOLUTE != 0 {
        // SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN or SM_CXSCREEN, SM_CYSCREEN
        desktop := r.flags & MOUSE_VIRTUAL_DESKTOP != 0
        sw = i64(GetSystemMetrics(if desktop { 78 } else { 0 }))
        sh = i64(GetSystemMetrics(if desktop { 79 } else { 1 }))
    }
    dx, dy := motion_from_raw_mouse(&o.raw, &r, sw, sh)
    if dx == 0 && dy == 0 {
        return
    }
    o.virt_x += dx
    o.virt_y += dy
    w32_record_motion(w, Event{kind: EventMouseMove, x: o.virt_x, y: o.virt_y})
}

// one wheel step per WHEEL_DELTA (120) of motion; smaller motion accumulates
priv fn w32_wheel(w: *Window, acc: *i64, wp: u64, horizontal: bool) {
    *acc += i64(i16(u16(wp >> 16 & 0xFFFF)))
    mods := w32_mods(w, -1, false)
    while *acc >= 120 || *acc <= -120 {
        step := if *acc > 0 { 1 } else { -1 }
        *acc -= step * 120
        if horizontal {
            w32_record(w, Event{kind: EventWheel, x: step, mods: mods})
        } else {
            w32_record(w, Event{kind: EventWheel, y: step, mods: mods})
        }
    }
}

priv fn w32_dpi(hwnd: *u8) -> u32 {
    if dpi_for_window == nil || hwnd == nil {
        return 96
    }
    cast[fn(*u8) -> u32](dpi_for_window)(hwnd)
}

// window size for a client area of cw x ch pixels with this style at this DPI
priv fn w32_outer_size(style: u32, cw: i64, ch: i64, dpi: u32) -> (i64, i64) {
    r := W32Rect{0, 0, i32(cw), i32(ch)}
    if adjust_for_dpi != nil {
        cast[fn(*W32Rect, u32, i32, u32, u32) -> i32](adjust_for_dpi)(&r, style, 0, 0, dpi)
    } else {
        AdjustWindowRectEx(&r, style, 0, 0)
    }
    (i64(r.right - r.left), i64(r.bottom - r.top))
}

priv fn w32_window_proc(hwnd: *u8, msg: u32, wp: u64, lp: i64) -> i64 {
    if msg == WM_NCCREATE {
        // CREATESTRUCTW.lpCreateParams: the Window
        w := cast[*Window](cast[*i64](lp)[0])
        w.os.hwnd = hwnd
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, cast[i64](w))
        return DefWindowProcW(hwnd, msg, wp, lp)
    }
    w := cast[*Window](GetWindowLongPtrW(hwnd, GWLP_USERDATA))
    if w == nil {
        return DefWindowProcW(hwnd, msg, wp, lp)
    }
    o := &w.os
    x := i64(i16(u16(lp & 0xFFFF)))
    y := i64(i16(u16(lp >> 16 & 0xFFFF)))
    match msg {
        WM_KEYDOWN, WM_KEYUP => {
            w32_key_message(w, msg, wp, lp)
            return 0
        }
        WM_SYSKEYDOWN, WM_SYSKEYUP => {
            // DefWindowProcW turns Alt+F4 into WM_CLOSE and Alt+Space into the window menu
            w32_key_message(w, msg, wp, lp)
            return DefWindowProcW(hwnd, msg, wp, lp)
        }
        WM_CHAR => {
            w32_char_message(w, wp)
            return 0
        }
        WM_SYSCHAR => {
            w32_char_message(w, wp)
            return DefWindowProcW(hwnd, msg, wp, lp)
        }
        WM_UNICHAR => {
            // one UTF-32 character from another program; 0xFFFF asks whether the window takes them
            if wp == 0xFFFF {
                return 1
            }
            w32_text(w, u32(wp))
            return 0
        }
        WM_SYSCOMMAND => {
            // no menu mode on F10 / Alt, no beep on Alt+letter: only Alt+Space opens the menu
            if wp & 0xFFF0 == SC_KEYMENU && lp != 0x20 {
                return 0
            }
        }
        WM_MOUSEMOVE => {
            // (a locked pointer moves by raw input only: WM_INPUT)
            if !w.cursor_locked {
                w32_record(w, Event{kind: EventMouseMove, x: x, y: y})
            }
            return 0
        }
        WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN, WM_XBUTTONDOWN, WM_LBUTTONUP, WM_RBUTTONUP, WM_MBUTTONUP, WM_XBUTTONUP => {
            e := event_from_win32_button(msg, wp, x, y, w32_mods(w, -1, false))
            if w.cursor_locked {
                e.x = o.virt_x
                e.y = o.virt_y
            }
            if e.kind == EventMouseDown {
                o.frame_click = false
            }
            // while a button is held the window gets the mouse even outside (as X11 grabs it)
            if e.kind == EventMouseDown {
                SetCapture(hwnd)
            } else if wp & MK_BUTTONS == 0 {
                ReleaseCapture()
            }
            w32_record(w, e)
            return if msg == WM_XBUTTONDOWN || msg == WM_XBUTTONUP { 1 } else { 0 }
        }
        WM_MOUSEWHEEL => {
            w32_wheel(w, &o.wheel_y, wp, false)
            return 0
        }
        WM_MOUSEHWHEEL => {
            w32_wheel(w, &o.wheel_x, wp, true)
            return 0
        }
        WM_MOUSEACTIVATE => {
            // a click on the title bar, a border or a caption button activates the window: a
            // locked pointer is not taken before that click has done its work
            if lp & 0xFFFF != HTCLIENT {
                o.frame_click = true
            }
        }
        WM_INPUT => {
            if o.clipped {
                w32_raw_input(w, lp)
            }
            // (DefWindowProcW releases the record)
        }
        WM_SETCURSOR => {
            if lp & 0xFFFF == HTCLIENT {
                SetCursor(if w.cursor_hidden || o.clipped { nil } else { arrow_cursor })
                return 1
            }
        }
        WM_SIZE => {
            // minimizing keeps the size (as on X11): EventMinimize, then EventRestore when the
            // window is shown again (SIZE_RESTORED or SIZE_MAXIMIZED)
            if wp == 1 {
                if !o.iconic {
                    o.iconic = true
                    w32_record(w, Event{kind: EventMinimize})
                }
            } else {
                if o.iconic && (wp == 0 || wp == 2) {
                    o.iconic = false
                    w32_record(w, Event{kind: EventRestore})
                }
                cw := lp & 0xFFFF
                ch := lp >> 16 & 0xFFFF
                if cw != o.client_w || ch != o.client_h {
                    o.client_w = cw
                    o.client_h = ch
                    w32_record(w, Event{kind: EventResize, x: cw, y: ch})
                }
            }
            return 0
        }
        WM_SETFOCUS => {
            w32_record(w, Event{kind: EventFocus})
            return 0
        }
        WM_KILLFOCUS => {
            w32_release_pointer(w)
            o.fake_ctrl = false
            o.print_down = false
            o.shift_held = [2]bool{false, false}
            o.surrogate = 0
            w32_record(w, Event{kind: EventUnfocus})
            return 0
        }
        WM_CLOSE => {
            w32_record(w, Event{kind: EventClose})
            return 0
        }
        WM_PAINT => {
            // the program draws every frame: nothing to repaint here
            ValidateRect(hwnd, nil)
            return 0
        }
        WM_DPICHANGED => {
            // keep the client size in pixels on a monitor of another scale
            if !w.fullscreen {
                suggested := cast[*W32Rect](lp)
                ow, oh := w32_outer_size(o.style, o.client_w, o.client_h, u32(wp & 0xFFFF))
                SetWindowPos(hwnd, nil, suggested.left, suggested.top, i32(ow), i32(oh), SWP_NOZORDER | SWP_NOACTIVATE)
            }
            return 0
        }
        WM_ENTERSIZEMOVE, WM_ENTERMENULOOP => {
            modal += 1
            if fibers == 1 && modal_timer == 0 {
                modal_timer = SetTimer(nil, 0, 1, w32_modal_tick)
            }
        }
        WM_EXITSIZEMOVE, WM_EXITMENULOOP => {
            modal = max(modal - 1, 0)
            if modal == 0 && modal_timer != 0 {
                KillTimer(nil, modal_timer)
                modal_timer = 0
            }
        }
        WM_NCDESTROY => {
            w32_release_pointer(w)
            o.hwnd = nil
            w.closing = true
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0)
        }
        _ => {}
    }
    DefWindowProcW(hwnd, msg, wp, lp)
}

// the modal loop's timer (a thread timer: DispatchMessageW calls this): let the program run a
// frame; the next poll comes back here
priv fn w32_modal_tick(hwnd: *u8, msg: u32, id: u64, time: u32) {
    if on_pump && modal > 0 {
        on_pump = false
        SwitchToFiber(main_fiber)
    }
}

priv fn w32_pump_messages() {
    msg: W32Msg
    while PeekMessageW(&msg, nil, 0, 0, PM_REMOVE) != 0 {
        TranslateMessage(&msg)
        DispatchMessageW(&msg)
    }
}

priv fn w32_pump_main(param: *u8) {
    loop {
        w32_pump_messages()
        on_pump = false
        SwitchToFiber(main_fiber)
    }
}

// Dispatches every queued message of this thread's windows; returns when the queue is empty
// (or, inside a modal loop, at the next tick of its timer).
priv fn w32_pump() {
    if fibers == 0 {
        fibers = -1
        f := ConvertThreadToFiber(nil)
        if f != nil {
            // FIBER_FLAG_FLOAT_SWITCH; 1 MiB of stack for the window procedures
            p := CreateFiberEx(64 * 1024, 1024 * 1024, 1, w32_pump_main, nil)
            if p != nil {
                main_fiber = f
                pump_fiber = p
                fibers = 1
            } else {
                ConvertFiberToThread()
            }
        }
    }
    if fibers == 1 {
        on_pump = true
        SwitchToFiber(pump_fiber)
        on_pump = false
    } else {
        w32_pump_messages()
    }
}

priv fn w32_init() -> bool {
    if class_atom != 0 {
        return true
    }
    m := mark()
    user32 := GetModuleHandleW(w32_wide("user32.dll"))
    release(m)
    if user32 != nil {
        // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (Windows 10 1703), else system aware (as
        // the executable's manifest says already, src/rsrc.al: then the calls change nothing)
        set_ctx := GetProcAddress(user32, ptr("SetProcessDpiAwarenessContext"))
        if set_ctx == nil || cast[fn(*u8) -> i32](set_ctx)(cast[*u8](i64(-4))) == 0 {
            SetProcessDPIAware()
        }
        dpi_for_window = GetProcAddress(user32, ptr("GetDpiForWindow"))
        adjust_for_dpi = GetProcAddress(user32, ptr("AdjustWindowRectExForDpi"))
    }
    name := "AL window"
    for i in 0..len(name) {
        class_name[i] = u16(name[i])
    }
    arrow_cursor = LoadCursorW(nil, cast[*u16](u64(32512)))      // IDC_ARROW
    wc := W32WndClass{
        size: u32(sizeof[W32WndClass]()),
        proc: w32_window_proc,
        instance: GetModuleHandleW(nil),
        icon: LoadIconW(GetModuleHandleW(nil), cast[*u16](u64(1))), // `alc build --icon` (else nil: the system's)
        cursor: arrow_cursor,
        background: GetStockObject(4),                             // BLACK_BRUSH
        class_name: ptr(class_name),
    }
    class_atom = RegisterClassExW(&wc)
    class_atom != 0
}

// ---- window ----

// Opens a window as described (`display` is not used); (nil, false) if it cannot be created.
// Allocates the Window once (arena); later calls on the window do not allocate from the arena.
fn window_open(d: WindowDesc) -> (*Window, bool) {
    if !w32_init() {
        return (nil, false)
    }
    w := new[Window]()
    o := &w.os
    w.width = if d.width > 0 { d.width } else { 640 }
    w.height = if d.height > 0 { d.height } else { 480 }
    o.client_w = w.width
    o.client_h = w.height
    o.style = if d.resizable { WS_OVERLAPPEDWINDOW } else { WS_FIXED }
    cw_usedefault: i32 = 0x80000000
    m := mark()
    hwnd := CreateWindowExW(0, ptr(class_name), w32_wide(d.title), o.style, cw_usedefault, cw_usedefault,
        i32(w.width), i32(w.height), nil, nil, GetModuleHandleW(nil), cast[*u8](w))
    release(m)
    if hwnd == nil {
        return (nil, false)
    }
    // no input method editor until set_text_input: every key press is a key event
    ImmAssociateContextEx(hwnd, nil, 0)
    ow, oh := w32_outer_size(o.style, w.width, w.height, w32_dpi(hwnd))
    SetWindowPos(hwnd, nil, 0, 0, i32(ow), i32(oh), SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE)
    if d.fullscreen {
        set_fullscreen(w, true)
    }
    ShowWindow(hwnd, 5)                                            // SW_SHOW
    (w, true)
}

// Sets the window title (UTF-8).
fn set_title(w: *Window, title: str) {
    if w.os.hwnd == nil {
        return
    }
    m := mark()
    SetWindowTextW(w.os.hwnd, w32_wide(title))
    release(m)
}

// Starts a new input frame and processes every pending window event: updates `w.input`,
// refills the event queue (events of the previous poll are discarded) and the size / close
// state. Never blocks. Call it once at the top of every frame.
fn poll(w: *Window) {
    begin_frame(&w.input)
    clear_events(&w.events)
    if w.os.hwnd == nil {
        return
    }
    w32_pump()
    w32_deliver(w)
    if w.cursor_locked {
        w32_keep_locked(w)
    }
}

// Gives the pointer the window's shape now if it is over the client area (else it takes it
// when it gets there, through WM_SETCURSOR).
priv fn w32_update_cursor(w: *Window) {
    hwnd := w.os.hwnd
    p: W32Point
    r: W32Rect
    if GetCursorPos(&p) != 0 && WindowFromPoint(p) == hwnd && ScreenToClient(hwnd, &p) != 0 && GetClientRect(hwnd, &r) != 0 &&
        p.x >= r.left && p.x < r.right && p.y >= r.top && p.y < r.bottom {
        SetCursor(if w.cursor_hidden || w.os.clipped { nil } else { arrow_cursor })
    }
}

// Shows or hides the mouse pointer while it is over the window.
fn set_cursor_visible(w: *Window, visible: bool) {
    if w.os.hwnd == nil || visible != w.cursor_hidden {
        return
    }
    w.cursor_hidden = !visible
    w32_update_cursor(w)
}

// Lets the user type text with the input method editor (IME: Chinese, Japanese, Korean, ...)
// while `on`. Off (the default) no IME is attached to the window: every key press arrives as
// a key event, and text still arrives for layouts that type characters directly (dead keys
// included).
fn set_text_input(w: *Window, on: bool) {
    if w.os.hwnd == nil || on == w.text_input {
        return
    }
    w.text_input = on
    // IACE_DEFAULT (0x10): the window's default input context; else none
    ImmAssociateContextEx(w.os.hwnd, nil, if on { 0x10 } else { 0 })
}

// Raw input of the mouse (HID usage page 1, usage 2) on, for the window, or off (RIDEV_REMOVE).
priv fn w32_raw_mouse(hwnd: *u8, on: bool) -> bool {
    d := W32RawInputDevice{usage_page: 1, usage: 2, flags: if on { 0 } else { 1 }, target: hwnd}
    RegisterRawInputDevices(&d, 1, u32(sizeof[W32RawInputDevice]())) != 0
}

// Lets a held pointer go: no raw input, free to leave the window, visible.
priv fn w32_release_pointer(w: *Window) {
    if w.os.clipped {
        w.os.clipped = false
        w32_raw_mouse(nil, false)
        ClipCursor(nil)
        w32_update_cursor(w)
    }
}

// Holds a locked pointer while the window has the focus, is not minimized and the user is
// not working on its frame (a move / size / menu loop, the click on the frame that activated
// it): raw input on, the pointer confined to the pixel in the centre of the client area
// (so it stays put, and clicks land in the window) and hidden. Lets it go otherwise.
priv fn w32_keep_locked(w: *Window) {
    o := &w.os
    hwnd := o.hwnd
    // VK_LBUTTON, VK_RBUTTON, VK_MBUTTON
    if o.frame_click && modal == 0 && GetAsyncKeyState(1) >= 0 && GetAsyncKeyState(2) >= 0 && GetAsyncKeyState(4) >= 0 {
        o.frame_click = false
    }
    if !w.input.focused || w.minimized || modal > 0 || o.frame_click {
        w32_release_pointer(w)
        return
    }
    if !o.clipped {
        if !w32_raw_mouse(hwnd, true) {
            return
        }
        o.raw = RawMotion{}
    }
    // (every frame: the window may have moved, another program may have changed the clip)
    c := W32Point{i32(w.width / 2), i32(w.height / 2)}
    ClientToScreen(hwnd, &c)
    clip := W32Rect{c.x, c.y, c.x + 1, c.y + 1}
    ClipCursor(&clip)
    if !o.clipped {
        o.clipped = true
        w32_update_cursor(w)
    }
}

// Locks the pointer for mouse-look: while the window has the focus the pointer is hidden and
// stays in the centre of the window (ClipCursor), and the mouse is read as raw input
// (WM_INPUT): every motion, in device counts without the pointer acceleration of Windows,
// moves a virtual position without bounds, so `mouse_delta(&w.input)` is the relative motion
// of the frame (positions in mouse events are that virtual position). Unlocking puts the
// pointer back where it was.
fn set_cursor_locked(w: *Window, locked: bool) {
    o := &w.os
    hwnd := o.hwnd
    if hwnd == nil || locked == w.cursor_locked {
        return
    }
    w.cursor_locked = locked
    p: W32Point
    if locked {
        GetCursorPos(&p)
        ScreenToClient(hwnd, &p)
        o.unlock_x = i64(p.x)
        o.unlock_y = i64(p.y)
        // the virtual position starts at the real one (also the first motion counts in mouse_delta)
        o.virt_x = o.unlock_x
        o.virt_y = o.unlock_y
        w.input.mouse_x = f32(o.virt_x)
        w.input.mouse_y = f32(o.virt_y)
        w.input.mouse_seen = true
        w32_keep_locked(w)
        return
    }
    if o.clipped {
        w32_release_pointer(w)
        p = W32Point{i32(o.unlock_x), i32(o.unlock_y)}
        ClientToScreen(hwnd, &p)
        SetCursorPos(p.x, p.y)
    }
    // continue from the real position without a jump in mouse_delta
    GetCursorPos(&p)
    ScreenToClient(hwnd, &p)
    w.input.mouse_x = f32(p.x)
    w.input.mouse_y = f32(p.y)
}

// Makes the window fullscreen (borderless, covering its monitor) or windowed again; the new
// size arrives as an EventResize in a later poll.
fn set_fullscreen(w: *Window, on: bool) {
    o := &w.os
    hwnd := o.hwnd
    if hwnd == nil || on == w.fullscreen {
        return
    }
    visible := u32(GetWindowLongPtrW(hwnd, GWL_STYLE)) & WS_VISIBLE
    w.fullscreen = on
    if on {
        GetWindowRect(hwnd, &o.saved)
        mi := W32MonitorInfo{size: u32(sizeof[W32MonitorInfo]())}
        GetMonitorInfoW(MonitorFromWindow(hwnd, 2), &mi)           // MONITOR_DEFAULTTONEAREST
        r := mi.monitor
        SetWindowLongPtrW(hwnd, GWL_STYLE, i64(WS_POPUP | visible))
        SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_FRAMECHANGED | SWP_NOOWNERZORDER)
    } else {
        r := o.saved
        SetWindowLongPtrW(hwnd, GWL_STYLE, i64(o.style | visible))
        SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_FRAMECHANGED | SWP_NOOWNERZORDER | SWP_NOZORDER)
    }
}

priv fn w32_free_dib(w: *Window) {
    if w.os.dib != nil {
        HeapFree(GetProcessHeap(), 0, w.os.dib)
        w.os.dib = nil
    }
}

// Shows an RGBA8 framebuffer (`pw` x `ph` pixels, 4 bytes each, rows top to bottom) in the
// window: scaled with nearest-neighbour sampling to the largest size that keeps its aspect
// ratio, centered, black bars around it. Alpha is ignored. False if the window is closed. Keeps
// a window-sized conversion buffer (process heap, reallocated only when the window size
// changes) and draws it with StretchDIBits at 1:1.
fn present(w: *Window, pixels: []u8, pw: i64, ph: i64) -> bool {
    o := &w.os
    if o.hwnd == nil || w.width <= 0 || w.height <= 0 {
        return false
    }
    if o.dib == nil || o.dib_w != w.width || o.dib_h != w.height {
        w32_free_dib(w)
        o.dib = HeapAlloc(GetProcessHeap(), 0, u64(w.width * w.height * 4))
        if o.dib == nil {
            return false
        }
        o.dib_w = w.width
        o.dib_h = w.height
    }
    blit_fit(mkslice[u32](o.dib, o.dib_w * o.dib_h), o.dib_w, o.dib_h, pixels, pw, ph, true)
    // 32-bit BI_RGB, top-down (negative height): rows top to bottom, 0x00RRGGBB
    bmi := W32BitmapInfo{size: 40, width: i32(o.dib_w), height: -i32(o.dib_h), planes: 1, bit_count: 32}
    dc := GetDC(o.hwnd)
    if dc == nil {
        return false
    }
    StretchDIBits(dc, 0, 0, i32(o.dib_w), i32(o.dib_h), 0, 0, i32(o.dib_w), i32(o.dib_h), o.dib, &bmi, 0, 0x00CC0020)
    ReleaseDC(o.hwnd, dc)
    true
}

// Destroys the window; the Window stays valid as a closed window (should_close is true, other
// calls do nothing).
fn close(w: *Window) {
    w.closing = true
    o := &w.os
    w32_release_pointer(w)
    w32_free_dib(w)
    o.pending_len = 0
    hwnd := o.hwnd
    if hwnd == nil {
        return
    }
    if modal > 0 && fibers == 1 {
        // end the move / size / menu loop suspended on the pump fiber: WM_CANCELMODE ends
        // menus (and, on Windows, the move / size loop with the capture), Escape ends the
        // move / size loop
        SendMessageW(hwnd, WM_CANCELMODE, 0, 0)
        PostMessageW(hwnd, WM_KEYDOWN, VK_ESCAPE, 0x00010001)
        for i in 0..100 {
            if modal == 0 {
                break
            }
            w32_pump()
        }
    }
    DestroyWindow(hwnd)
    o.hwnd = nil
    o.pending_len = 0
}

// The window's HWND (for DXGI swapchains: IDXGIFactory2.CreateSwapChainForHwnd); nil once
// closed.
fn win32_hwnd(w: *Window) -> *u8 {
    w.os.hwnd
}
