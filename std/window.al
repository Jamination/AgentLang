// std.window: one native window with an event queue, per-frame input state (std.input) and
// software presentation of an RGBA8 framebuffer. The window system is in the OS layer:
// std/window_linux.al (X11, links libX11.so.6) or std/window_windows.al (Win32: user32, gdi32).
// The layer provides `struct WindowOs` and window_open(WindowDesc), set_title, poll,
// set_cursor_visible, set_cursor_locked, set_fullscreen, present, close and its native handles.
use std.input

// How to create a window. Zero fields mean: untitled, 640x480, fixed size, windowed, the
// display named by $DISPLAY (Linux; Windows has no display to choose).
struct WindowDesc {
    title: str
    width: i64
    height: i64
    resizable: bool
    fullscreen: bool
    display: str
}

// An open window. `input` is the state for the current frame, `events` what the last poll
// received; `os` holds the native handles and should be read through the accessors.
// `minimized` is true between an EventMinimize and the next EventRestore; `cursor_locked`
// after set_cursor_locked(w, true).
struct Window {
    input: Input
    events: EventQueue
    width: i64
    height: i64
    closing: bool
    fullscreen: bool
    minimized: bool
    cursor_hidden: bool
    cursor_locked: bool
    os: WindowOs
}

// ---- pure helpers (no display needed) ----

// The largest centered rectangle (x, y, w, h) with the aspect ratio sw:sh inside dw x dh.
fn fit_rect(dw: i64, dh: i64, sw: i64, sh: i64) -> (i64, i64, i64, i64) {
    if dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0 {
        return (0, 0, 0, 0)
    }
    w := dw
    h := dw * sh / sw
    if h > dh {
        h = dh
        w = dh * sw / sh
    }
    w = max(w, 1)
    h = max(h, 1)
    ((dw - w) / 2, (dh - h) / 2, w, h)
}

// Scales the RGBA8 image `src` (sw x sh) into the 32-bit pixel buffer `dst` (dw x dh),
// nearest neighbour, aspect preserved and centered, the rest black. Pixels are written as
// 0x00RRGGBB when swap_rb is set (the usual X11 layout and that of a Windows DIB), else as
// 0x00BBGGRR.
fn blit_fit(dst: []u32, dw: i64, dh: i64, src: []u8, sw: i64, sh: i64, swap_rb: bool) {
    rx, ry, rw, rh := fit_rect(dw, dh, sw, sh)
    assert len(dst) >= dw * dh && len(src) >= sw * sh * 4, "blit_fit: buffer too small"
    if rw == 0 {
        return
    }
    pix := mkslice[u32](ptr(src), sw * sh)
    fill(dst[..ry * dw], 0)
    fill(dst[(ry + rh) * dw..dw * dh], 0)
    step := (sw << 16) / rw
    for y in 0..rh {
        row := dst[(ry + y) * dw..(ry + y + 1) * dw]
        line := pix[(y * sh / rh) * sw..(y * sh / rh + 1) * sw]
        fill(row[..rx], 0)
        fill(row[rx + rw..], 0)
        fx := 0
        if swap_rb {
            for x in 0..rw {
                p := line[fx >> 16]
                row[rx + x] = p & 0xFF00 | p >> 16 & 0xFF | (p & 0xFF) << 16
                fx += step
            }
        } else {
            for x in 0..rw {
                row[rx + x] = line[fx >> 16] & 0xFFFFFF
                fx += step
            }
        }
    }
}

// ---- window ----

// Opens a fixed-size window with a title on the default display; false if there is no display.
fn window_open(title: str, width: i64, height: i64) -> (*Window, bool) {
    window_open(WindowDesc{title: title, width: width, height: height})
}

// Removes and returns the oldest event received by the last poll; false when there is none.
fn next_event(w: *Window) -> (Event, bool) {
    next_event(&w.events)
}

// True once the user asked to close the window (or after close). Set `w.closing = true` to
// leave the main loop from game code.
fn should_close(w: *Window) -> bool {
    w.closing
}

// Current size of the drawable area in pixels: (width, height).
fn size(w: *Window) -> (i64, i64) {
    (w.width, w.height)
}

// The mouse position in framebuffer pixels of a `pw` x `ph` image shown with `present`
// (outside 0..pw / 0..ph when the pointer is over the bars).
fn mouse_in_frame(w: *Window, pw: i64, ph: i64) -> vec2 {
    rx, ry, rw, rh := fit_rect(w.width, w.height, pw, ph)
    if rw == 0 {
        return vec2(0.0)
    }
    (mouse_pos(&w.input) - vec2(f32(rx), f32(ry))) * vec2(f32(pw) / f32(rw), f32(ph) / f32(rh))
}

// the OS layer of the target
when TARGET_OS == Windows {
    use std.window_windows
} else {
    use std.window_linux
}
