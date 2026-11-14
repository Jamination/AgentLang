// Prints every event a window receives (keys with code, name, modifiers and repeat flag; text;
// mouse; wheel; focus; size; close) and the changes of gamepad 0. Works the same on Linux (X11)
// and Windows (Win32): the way to check what a keyboard, mouse or pad delivers on a machine.
//
//   alc run examples/win32_input.al                     Linux
//   alc build --target windows examples/win32_input.al  then run win32_input.exe on Windows
//
// F11 toggles fullscreen, F2 toggles the mouse pointer, Escape or closing the window quits.
// The window shows a 64 x 36 framebuffer through `present`; the white cross is drawn at
// `mouse_in_frame`, so it must sit under the pointer at any window size.
use std.window

const FB_W = 64
const FB_H = 36

fn mods_text(m: u8) -> str {
    parts := vec[str]()
    if m & MOD_SHIFT != 0 {
        parts.push("shift")
    }
    if m & MOD_CTRL != 0 {
        parts.push("ctrl")
    }
    if m & MOD_ALT != 0 {
        parts.push("alt")
    }
    if m & MOD_SUPER != 0 {
        parts.push("super")
    }
    if parts.len == 0 {
        return "-"
    }
    join(parts.items(), "+")
}

fn button_name(b: i64) -> str {
    match b {
        MOUSE_LEFT => "left"
        MOUSE_RIGHT => "right"
        MOUSE_MIDDLE => "middle"
        MOUSE_X1 => "x1"
        MOUSE_X2 => "x2"
        _ => "?"
    }
}

fn describe(e: Event) -> str {
    match e.kind {
        EventKeyDown => fmt("key down  ", key_name(e.key), " (", e.key, ") mods ", mods_text(e.mods), if e.repeat { " repeat" } else { "" })
        EventKeyUp => fmt("key up    ", key_name(e.key), " (", e.key, ") mods ", mods_text(e.mods))
        EventText => {
            buf: [4]u8
            inp: Input
            inp.feed(e)
            fmt("text      U+", to_upper(hex(u64(e.codepoint), 4)), " '", inp.text_utf8(buf[..]), "' mods ", mods_text(e.mods))
        }
        EventMouseMove => fmt("move      ", e.x, " ", e.y)
        EventMouseDown => fmt("button    ", button_name(e.key), " down at ", e.x, " ", e.y, " mods ", mods_text(e.mods))
        EventMouseUp => fmt("button    ", button_name(e.key), " up at ", e.x, " ", e.y, " mods ", mods_text(e.mods))
        EventWheel => fmt("wheel     ", e.x, " ", e.y, " mods ", mods_text(e.mods))
        EventResize => fmt("resize    ", e.x, " x ", e.y)
        EventFocus => "focus"
        EventUnfocus => "unfocus"
        EventClose => "close requested"
        EventMinimize => "minimized"
        EventRestore => "restored"
        EventNone => "none"
    }
}

fn render(fb: []u8, w: *Window) {
    for y in 0..FB_H {
        for x in 0..FB_W {
            i := (y * FB_W + x) * 4
            fb[i] = u8(x * 4)
            fb[i + 1] = u8(y * 7)
            fb[i + 2] = if w.input.focused { 160 } else { 60 }
            fb[i + 3] = 255
        }
    }
    m := w.mouse_in_frame(FB_W, FB_H)
    mx := i64(floor(m.x))
    my := i64(floor(m.y))
    for k in -2..=2 {
        for p in [2](i64, i64){(mx + k, my), (mx, my + k)} {
            if p.0 >= 0 && p.0 < FB_W && p.1 >= 0 && p.1 < FB_H {
                i := (p.1 * FB_W + p.0) * 4
                fb[i] = 255
                fb[i + 1] = 255
                fb[i + 2] = 255
            }
        }
    }
}

fn main() {
    w, ok := window_open(WindowDesc{title: "AL input events", width: 640, height: 360, resizable: true})
    if !ok {
        eprint("cannot open a window (no display?)")
        exit(1)
    }
    width, height := w.size()
    print("window", width, "x", height)
    pad := &w.input.pad
    print("gamepad 0:", if gamepad_open(pad, 0) { "connected" } else { "none" })
    last_axes := pad.axes
    fb := alloc[u8](FB_W * FB_H * 4)
    while !w.should_close() {
        w.poll()
        loop {
            e, more := w.next_event()
            if !more {
                break
            }
            print(describe(e))
        }
        if w.events.dropped > 0 {
            print("dropped", w.events.dropped, "events")
            w.events.dropped = 0
        }
        if pad.connected && !gamepad_poll(pad) {
            print("gamepad 0 disconnected")
        }
        for b in 0..PAD_BUTTON_COUNT {
            if pad.pad_pressed(b) {
                print("pad       button", b, "down")
            }
            if pad.pad_released(b) {
                print("pad       button", b, "up")
            }
        }
        for a in 0..PAD_AXIS_COUNT {
            if fabs(pad.axes[a] - last_axes[a]) >= 0.1 {
                print("pad       axis", a, fmtf(f64(pad.axes[a]), 2))
                last_axes[a] = pad.axes[a]
            }
        }
        if w.input.key_pressed(KEY_ESCAPE) {
            w.closing = true
        }
        if w.input.key_pressed(KEY_F11) {
            w.set_fullscreen(!w.fullscreen)
        }
        if w.input.key_pressed(KEY_F2) {
            w.set_cursor_visible(w.cursor_hidden)
        }
        render(fb, w)
        w.present(fb, FB_W, FB_H)
        flush()
        sleep_ms(8)
    }
    w.close()
}
