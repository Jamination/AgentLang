// std.window: one native window (X11 on Linux) with an event queue, per-frame input state
// (std.input) and software presentation of an RGBA8 framebuffer. Using it links libX11.so.6.
use std.x11
use std.input
use std.libc

// How to create a window. Zero fields mean: untitled, 640x480, fixed size, windowed, the
// display named by $DISPLAY.
struct WindowDesc {
    title str
    width i64
    height i64
    resizable bool
    fullscreen bool
    display str
}

// An open window. `input` is the state for the current frame, `events` what the last poll
// received; the other fields are the X11 handles and should be read through the accessors.
struct Window {
    input Input
    events EventQueue
    width i64
    height i64
    closing bool
    fullscreen bool
    cursor_hidden bool
    dpy *u8
    win u64
    screen i32
    depth i32
    visual *u8
    gc *u8
    im *u8
    ic *u8
    wm_protocols u64
    wm_delete u64
    net_wm_state u64
    net_wm_state_fullscreen u64
    net_wm_name u64
    utf8_string u64
    blank_cursor u64
    image *u8
    image_data *u8
    image_w i64
    image_h i64
    swap_rb bool
}

// ---- pure helpers (no display needed) ----

// Key code (KEY_*) for an X11 keysym; KEY_UNKNOWN for keys without a code.
fn key_from_keysym(ks u64) i64 {
    k := i64(ks)
    if k >= 'a' && k <= 'z' {
        return KEY_A + k - 'a'
    }
    if k >= 'A' && k <= 'Z' {
        return KEY_A + k - 'A'
    }
    if k >= '0' && k <= '9' {
        return KEY_0 + k - '0'
    }
    if k >= 0xFFBE && k <= 0xFFC9 {
        return KEY_F1 + k - 0xFFBE
    }
    if k >= 0xFFB0 && k <= 0xFFB9 {
        return KEY_KP_0 + k - 0xFFB0
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
        0xFF08 => KEY_BACKSPACE
        0xFF09 => KEY_TAB
        0xFF0D => KEY_ENTER
        0xFF13 => KEY_PAUSE
        0xFF14 => KEY_SCROLL_LOCK
        0xFF1B => KEY_ESCAPE
        0xFF50 => KEY_HOME
        0xFF51 => KEY_LEFT
        0xFF52 => KEY_UP
        0xFF53 => KEY_RIGHT
        0xFF54 => KEY_DOWN
        0xFF55 => KEY_PAGE_UP
        0xFF56 => KEY_PAGE_DOWN
        0xFF57 => KEY_END
        0xFF61 => KEY_PRINT_SCREEN
        0xFF63 => KEY_INSERT
        0xFF67 => KEY_MENU
        0xFF7F => KEY_NUM_LOCK
        0xFF8D => KEY_KP_ENTER
        0xFF95 => KEY_KP_7
        0xFF96 => KEY_KP_4
        0xFF97 => KEY_KP_8
        0xFF98 => KEY_KP_6
        0xFF99 => KEY_KP_2
        0xFF9A => KEY_KP_9
        0xFF9B => KEY_KP_3
        0xFF9C => KEY_KP_1
        0xFF9D => KEY_KP_5
        0xFF9E => KEY_KP_0
        0xFF9F, 0xFFAC, 0xFFAE => KEY_KP_DECIMAL
        0xFFAA => KEY_KP_MULTIPLY
        0xFFAB => KEY_KP_ADD
        0xFFAD => KEY_KP_SUBTRACT
        0xFFAF => KEY_KP_DIVIDE
        0xFFE1 => KEY_LSHIFT
        0xFFE2 => KEY_RSHIFT
        0xFFE3 => KEY_LCTRL
        0xFFE4 => KEY_RCTRL
        0xFFE5 => KEY_CAPS_LOCK
        0xFFE7, 0xFFE9 => KEY_LALT
        0xFFE8, 0xFFEA, 0xFE03 => KEY_RALT
        0xFFEB => KEY_LSUPER
        0xFFEC => KEY_RSUPER
        0xFFFF => KEY_DELETE
        _ => KEY_UNKNOWN
    }
}

// Event.mods bits (MOD_*) for an X11 modifier state mask.
fn mods_from_x11(state u32) u8 {
    var m u8 = 0
    if state & X_SHIFT_MASK != 0 {
        m |= MOD_SHIFT
    }
    if state & X_CONTROL_MASK != 0 {
        m |= MOD_CTRL
    }
    if state & X_MOD1_MASK != 0 {
        m |= MOD_ALT
    }
    if state & X_MOD4_MASK != 0 {
        m |= MOD_SUPER
    }
    m
}

// Translates an X11 pointer button number into an event at (x, y): a MOUSE_* press / release,
// or a wheel step for buttons 4..7 (kind EventNone for wheel releases and unknown buttons).
fn event_from_x11_button(button i64, pressed bool, x i64, y i64, mods u8) Event {
    kind := if pressed { EventMouseDown } else { EventMouseUp }
    match button {
        1 => Event{kind: kind, key: MOUSE_LEFT, x: x, y: y, mods: mods}
        2 => Event{kind: kind, key: MOUSE_MIDDLE, x: x, y: y, mods: mods}
        3 => Event{kind: kind, key: MOUSE_RIGHT, x: x, y: y, mods: mods}
        8 => Event{kind: kind, key: MOUSE_X1, x: x, y: y, mods: mods}
        9 => Event{kind: kind, key: MOUSE_X2, x: x, y: y, mods: mods}
        4 => Event{kind: if pressed { EventWheel } else { EventNone }, y: 1, mods: mods}
        5 => Event{kind: if pressed { EventWheel } else { EventNone }, y: -1, mods: mods}
        6 => Event{kind: if pressed { EventWheel } else { EventNone }, x: -1, mods: mods}
        7 => Event{kind: if pressed { EventWheel } else { EventNone }, x: 1, mods: mods}
        _ => Event{}
    }
}

// The largest centered rectangle (x, y, w, h) with the aspect ratio sw:sh inside dw x dh.
fn fit_rect(dw i64, dh i64, sw i64, sh i64) (i64, i64, i64, i64) {
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
// 0x00RRGGBB when swap_rb is set (the usual X11 layout), else as 0x00BBGGRR.
fn blit_fit(dst []u32, dw i64, dh i64, src []u8, sw i64, sh i64, swap_rb bool) {
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

fn window_utf8_next(buf []u8, pos *i64) u32 {
    i := *pos
    c := u32(buf[i])
    n := if c < 0x80 { 0 } else if c < 0xE0 { 1 } else if c < 0xF0 { 2 } else { 3 }
    if n == 1 {
        c &= 0x1F
    } else if n == 2 {
        c &= 0x0F
    } else if n == 3 {
        c &= 0x07
    }
    i += 1
    for k in 0..n {
        if i >= len(buf) {
            break
        }
        c = c << 6 | u32(buf[i]) & 0x3F
        i += 1
    }
    *pos = i
    c
}

// ---- window ----

// Opens a fixed-size window with a title on the default display; false if there is no display.
fn window_open(title str, width i64, height i64) (*Window, bool) {
    window_open(WindowDesc{title: title, width: width, height: height})
}

// Opens a window as described; (nil, false) if the display cannot be reached. Allocates the
// Window once (arena); later calls on the window do not allocate from the arena.
fn window_open(d WindowDesc) (*Window, bool) {
    setlocale(X_LC_CTYPE, ptr(""))
    XSetLocaleModifiers(ptr(""))
    m := mark()
    var name *u8 = nil
    if len(d.display) > 0 {
        name = cstr(d.display)
    }
    dpy := XOpenDisplay(name)
    release(m)
    if dpy == nil {
        return (nil, false)
    }
    w := new[Window]()
    w.dpy = dpy
    w.width = if d.width > 0 { d.width } else { 640 }
    w.height = if d.height > 0 { d.height } else { 480 }
    w.screen = XDefaultScreen(dpy)
    w.visual = XDefaultVisual(dpy, w.screen)
    w.depth = XDefaultDepth(dpy, w.screen)
    w.swap_rb = x_visual_red_mask(w.visual) == 0xFF0000
    w.win = XCreateSimpleWindow(dpy, XRootWindow(dpy, w.screen), 0, 0, u32(w.width), u32(w.height), 0, 0, 0)
    w.gc = XCreateGC(dpy, w.win, 0, nil)
    w.wm_protocols = XInternAtom(dpy, ptr("WM_PROTOCOLS"), 0)
    w.wm_delete = XInternAtom(dpy, ptr("WM_DELETE_WINDOW"), 0)
    w.net_wm_state = XInternAtom(dpy, ptr("_NET_WM_STATE"), 0)
    w.net_wm_state_fullscreen = XInternAtom(dpy, ptr("_NET_WM_STATE_FULLSCREEN"), 0)
    w.net_wm_name = XInternAtom(dpy, ptr("_NET_WM_NAME"), 0)
    w.utf8_string = XInternAtom(dpy, ptr("UTF8_STRING"), 0)
    XSetWMProtocols(dpy, w.win, &w.wm_delete, 1)
    XSelectInput(dpy, w.win, X_KEY_PRESS_MASK | X_KEY_RELEASE_MASK | X_BUTTON_PRESS_MASK |
        X_BUTTON_RELEASE_MASK | X_POINTER_MOTION_MASK | X_STRUCTURE_NOTIFY_MASK |
        X_FOCUS_CHANGE_MASK | X_EXPOSURE_MASK)
    XkbSetDetectableAutoRepeat(dpy, 1, nil)
    if !d.resizable {
        var hints XSizeHints
        hints.flags = X_P_MIN_SIZE | X_P_MAX_SIZE
        hints.min_width = i32(w.width)
        hints.max_width = i32(w.width)
        hints.min_height = i32(w.height)
        hints.max_height = i32(w.height)
        XSetWMNormalHints(dpy, w.win, &hints)
    }
    if d.fullscreen {
        XChangeProperty(dpy, w.win, w.net_wm_state, X_ATOM_ATOM, 32, X_PROP_MODE_REPLACE,
            cast[*u8](&w.net_wm_state_fullscreen), 1)
        w.fullscreen = true
    }
    w.im = XOpenIM(dpy, nil, nil, nil)
    if w.im != nil {
        w.ic = XCreateIC(w.im, ptr("inputStyle"), X_IM_PREEDIT_NOTHING | X_IM_STATUS_NOTHING,
            ptr("clientWindow"), w.win, nil)
    }
    set_title(w, d.title)
    XMapWindow(dpy, w.win)
    XFlush(dpy)
    (w, true)
}

// Sets the window title (UTF-8).
fn set_title(w *Window, title str) {
    if w.dpy == nil {
        return
    }
    m := mark()
    XStoreName(w.dpy, w.win, cstr(title))
    release(m)
    XChangeProperty(w.dpy, w.win, w.net_wm_name, w.utf8_string, 8, X_PROP_MODE_REPLACE, ptr(title), i32(len(title)))
    XFlush(w.dpy)
}

fn window_emit(w *Window, e Event) {
    push_event(&w.events, e)
    feed(&w.input, e)
}

fn window_key_event(w *Window, ev *XEvent, pressed bool) {
    key := key_from_keysym(XLookupKeysym(ev, 0))
    mods := mods_from_x11(x_event_state(ev))
    if !pressed {
        window_emit(w, Event{kind: EventKeyUp, key: key, mods: mods})
        return
    }
    window_emit(w, Event{kind: EventKeyDown, key: key, mods: mods, repeat: key_down(&w.input, key)})
    var buf [64]u8
    var ks u64
    n := 0
    utf8 := w.ic != nil
    if utf8 {
        var status i32
        n = i64(Xutf8LookupString(w.ic, ev, ptr(buf), 64, &ks, &status))
        if status != X_LOOKUP_CHARS && status != X_LOOKUP_BOTH {
            n = 0
        }
    } else {
        n = i64(XLookupString(ev, ptr(buf), 64, &ks, nil))
    }
    pos := 0
    while pos < n {
        var c u32
        if utf8 {
            c = window_utf8_next(buf[..n], &pos)
        } else {
            c = u32(buf[pos])
            pos += 1
        }
        if c >= 0x20 && c != 0x7F {
            window_emit(w, Event{kind: EventText, codepoint: c, mods: mods})
        }
    }
}

// Starts a new input frame and processes every pending window event: updates `w.input`,
// refills the event queue (events of the previous poll are discarded) and the size / close
// state. Never blocks. Call it once at the top of every frame.
fn poll(w *Window) {
    begin_frame(&w.input)
    clear_events(&w.events)
    if w.dpy == nil {
        return
    }
    var ev XEvent
    while XPending(w.dpy) > 0 {
        XNextEvent(w.dpy, &ev)
        if XFilterEvent(&ev, 0) != 0 {
            continue
        }
        match x_event_type(&ev) {
            X_KEY_PRESS => window_key_event(w, &ev, true)
            X_KEY_RELEASE => window_key_event(w, &ev, false)
            X_BUTTON_PRESS, X_BUTTON_RELEASE => {
                e := event_from_x11_button(x_event_detail(&ev), x_event_type(&ev) == X_BUTTON_PRESS,
                    x_event_x(&ev), x_event_y(&ev), mods_from_x11(x_event_state(&ev)))
                if e.kind != EventNone {
                    window_emit(w, e)
                }
            }
            X_MOTION_NOTIFY => window_emit(w, Event{kind: EventMouseMove, x: x_event_x(&ev), y: x_event_y(&ev)})
            X_CONFIGURE_NOTIFY => {
                cw := x_event_configure_width(&ev)
                ch := x_event_configure_height(&ev)
                if cw != w.width || ch != w.height {
                    w.width = cw
                    w.height = ch
                    window_emit(w, Event{kind: EventResize, x: cw, y: ch})
                }
            }
            X_FOCUS_IN => {
                if w.ic != nil {
                    XSetICFocus(w.ic)
                }
                window_emit(w, Event{kind: EventFocus})
            }
            X_FOCUS_OUT => {
                if w.ic != nil {
                    XUnsetICFocus(w.ic)
                }
                window_emit(w, Event{kind: EventUnfocus})
            }
            X_CLIENT_MESSAGE => {
                if x_event_message_type(&ev) == w.wm_protocols && x_event_message_data(&ev, 0) == w.wm_delete {
                    w.closing = true
                    window_emit(w, Event{kind: EventClose})
                }
            }
            X_DESTROY_NOTIFY => w.closing = true
            X_MAPPING_NOTIFY => XRefreshKeyboardMapping(&ev)
            _ => {}
        }
    }
}

// Removes and returns the oldest event received by the last poll; false when there is none.
fn next_event(w *Window) (Event, bool) {
    next_event(&w.events)
}

// True once the user asked to close the window (or after close). Set `w.closing = true` to
// leave the main loop from game code.
fn should_close(w *Window) bool {
    w.closing
}

// Current size of the drawable area in pixels: (width, height).
fn size(w *Window) (i64, i64) {
    (w.width, w.height)
}

// Shows or hides the mouse pointer while it is over the window.
fn set_cursor_visible(w *Window, visible bool) {
    if w.dpy == nil || visible != w.cursor_hidden {
        return
    }
    if visible {
        XUndefineCursor(w.dpy, w.win)
    } else {
        if w.blank_cursor == 0 {
            var zero u64
            var color XColor
            pixmap := XCreateBitmapFromData(w.dpy, w.win, cast[*u8](&zero), 1, 1)
            w.blank_cursor = XCreatePixmapCursor(w.dpy, pixmap, pixmap, &color, &color, 0, 0)
            XFreePixmap(w.dpy, pixmap)
        }
        XDefineCursor(w.dpy, w.win, w.blank_cursor)
    }
    w.cursor_hidden = !visible
    XFlush(w.dpy)
}

// Asks the window manager to make the window fullscreen (borderless, covering the screen) or
// windowed again; the new size arrives as an EventResize in a later poll.
fn set_fullscreen(w *Window, on bool) {
    if w.dpy == nil || on == w.fullscreen {
        return
    }
    var ev XEvent
    x_client_message(&ev, w.win, w.net_wm_state, if on { 1 } else { 0 }, w.net_wm_state_fullscreen, 0, 1, 0)
    XSendEvent(w.dpy, XRootWindow(w.dpy, w.screen), 0, X_SUBSTRUCTURE_NOTIFY_MASK | X_SUBSTRUCTURE_REDIRECT_MASK, &ev)
    XFlush(w.dpy)
    w.fullscreen = on
}

fn window_free_image(w *Window) {
    if w.image != nil {
        free(w.image_data)
        XFree(w.image)
        w.image = nil
        w.image_data = nil
    }
}

// Shows an RGBA8 framebuffer (`pw` x `ph` pixels, 4 bytes each, rows top to bottom) in the
// window: scaled with nearest-neighbour sampling to the largest size that keeps its aspect
// ratio, centered, black bars around it. Alpha is ignored. False if the window is closed or the
// display is not a 24/32-bit true-color one. Keeps a window-sized conversion buffer (C heap,
// reallocated only when the window size changes).
fn present(w *Window, pixels []u8, pw i64, ph i64) bool {
    if w.dpy == nil || w.depth < 24 || x_visual_class(w.visual) != X_TRUE_COLOR || w.width <= 0 || w.height <= 0 {
        return false
    }
    if w.image == nil || w.image_w != w.width || w.image_h != w.height {
        window_free_image(w)
        w.image_data = malloc(w.width * w.height * 4)
        if w.image_data == nil {
            return false
        }
        w.image = XCreateImage(w.dpy, w.visual, u32(w.depth), X_Z_PIXMAP, 0, w.image_data, u32(w.width), u32(w.height), 32, 0)
        if w.image == nil {
            free(w.image_data)
            return false
        }
        w.image_w = w.width
        w.image_h = w.height
    }
    blit_fit(mkslice[u32](w.image_data, w.image_w * w.image_h), w.image_w, w.image_h, pixels, pw, ph, w.swap_rb)
    XPutImage(w.dpy, w.win, w.gc, w.image, 0, 0, 0, 0, u32(w.image_w), u32(w.image_h))
    XFlush(w.dpy)
    true
}

// The mouse position in framebuffer pixels of a `pw` x `ph` image shown with `present`
// (outside 0..pw / 0..ph when the pointer is over the bars).
fn mouse_in_frame(w *Window, pw i64, ph i64) vec2 {
    rx, ry, rw, rh := fit_rect(w.width, w.height, pw, ph)
    if rw == 0 {
        return vec2(0.0)
    }
    (mouse_pos(&w.input) - vec2(f32(rx), f32(ry))) * vec2(f32(pw) / f32(rw), f32(ph) / f32(rh))
}

// Destroys the window and disconnects from the display; the Window stays valid as a closed
// window (should_close is true, other calls do nothing).
fn close(w *Window) {
    w.closing = true
    if w.dpy == nil {
        return
    }
    window_free_image(w)
    if w.ic != nil {
        XDestroyIC(w.ic)
    }
    if w.im != nil {
        XCloseIM(w.im)
    }
    if w.blank_cursor != 0 {
        XFreeCursor(w.dpy, w.blank_cursor)
    }
    XFreeGC(w.dpy, w.gc)
    XDestroyWindow(w.dpy, w.win)
    XCloseDisplay(w.dpy)
    w.dpy = nil
    w.ic = nil
    w.im = nil
}

// The Xlib `Display*` of the window (for VkXlibSurfaceCreateInfoKHR.dpy); nil once closed.
fn x11_display(w *Window) *u8 {
    w.dpy
}

// The X11 window id (for VkXlibSurfaceCreateInfoKHR.window).
fn x11_window(w *Window) u64 {
    w.win
}
