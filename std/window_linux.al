// std.window, Linux layer: the window is an X11 window (libX11.so.6, through std.x11).
// Loaded by `use std.window` for --target linux; the public API is in std/window.al.
use std.x11
use std.libc

// The X11 handles of a Window (read them through x11_display / x11_window).
struct WindowOs {
    dpy: *u8
    win: u64
    screen: i32
    depth: i32
    visual: *u8
    gc: *u8
    im: *u8
    ic: *u8
    wm_protocols: u64
    wm_delete: u64
    net_wm_state: u64
    net_wm_state_fullscreen: u64
    net_wm_name: u64
    utf8_string: u64
    blank_cursor: u64
    image: *u8
    image_data: *u8
    image_w: i64
    image_h: i64
    swap_rb: bool
}

// ---- X11 helpers (no display needed) ----

// Key code (KEY_*) for an X11 keysym; KEY_UNKNOWN for keys without a code.
fn key_from_keysym(ks: u64) -> i64 {
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
fn mods_from_x11(state: u32) -> u8 {
    m: u8 = 0
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
fn event_from_x11_button(button: i64, pressed: bool, x: i64, y: i64, mods: u8) -> Event {
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

priv fn window_utf8_next(buf: []u8, pos: *i64) -> u32 {
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

// Opens a window as described; (nil, false) if the display cannot be reached. Allocates the
// Window once (arena); later calls on the window do not allocate from the arena.
fn window_open(d: WindowDesc) -> (*Window, bool) {
    setlocale(X_LC_CTYPE, ptr(""))
    XSetLocaleModifiers(ptr(""))
    m := mark()
    name: *u8 = nil
    if len(d.display) > 0 {
        name = cstr(d.display)
    }
    dpy := XOpenDisplay(name)
    release(m)
    if dpy == nil {
        return (nil, false)
    }
    w := new[Window]()
    o := &w.os
    o.dpy = dpy
    w.width = if d.width > 0 { d.width } else { 640 }
    w.height = if d.height > 0 { d.height } else { 480 }
    o.screen = XDefaultScreen(dpy)
    o.visual = XDefaultVisual(dpy, o.screen)
    o.depth = XDefaultDepth(dpy, o.screen)
    o.swap_rb = x_visual_red_mask(o.visual) == 0xFF0000
    o.win = XCreateSimpleWindow(dpy, XRootWindow(dpy, o.screen), 0, 0, u32(w.width), u32(w.height), 0, 0, 0)
    o.gc = XCreateGC(dpy, o.win, 0, nil)
    o.wm_protocols = XInternAtom(dpy, ptr("WM_PROTOCOLS"), 0)
    o.wm_delete = XInternAtom(dpy, ptr("WM_DELETE_WINDOW"), 0)
    o.net_wm_state = XInternAtom(dpy, ptr("_NET_WM_STATE"), 0)
    o.net_wm_state_fullscreen = XInternAtom(dpy, ptr("_NET_WM_STATE_FULLSCREEN"), 0)
    o.net_wm_name = XInternAtom(dpy, ptr("_NET_WM_NAME"), 0)
    o.utf8_string = XInternAtom(dpy, ptr("UTF8_STRING"), 0)
    XSetWMProtocols(dpy, o.win, &o.wm_delete, 1)
    XSelectInput(dpy, o.win, X_KEY_PRESS_MASK | X_KEY_RELEASE_MASK | X_BUTTON_PRESS_MASK |
        X_BUTTON_RELEASE_MASK | X_POINTER_MOTION_MASK | X_STRUCTURE_NOTIFY_MASK |
        X_FOCUS_CHANGE_MASK | X_EXPOSURE_MASK)
    XkbSetDetectableAutoRepeat(dpy, 1, nil)
    if !d.resizable {
        hints: XSizeHints
        hints.flags = X_P_MIN_SIZE | X_P_MAX_SIZE
        hints.min_width = i32(w.width)
        hints.max_width = i32(w.width)
        hints.min_height = i32(w.height)
        hints.max_height = i32(w.height)
        XSetWMNormalHints(dpy, o.win, &hints)
    }
    if d.fullscreen {
        XChangeProperty(dpy, o.win, o.net_wm_state, X_ATOM_ATOM, 32, X_PROP_MODE_REPLACE,
            cast[*u8](&o.net_wm_state_fullscreen), 1)
        w.fullscreen = true
    }
    o.im = XOpenIM(dpy, nil, nil, nil)
    if o.im != nil {
        o.ic = XCreateIC(o.im, ptr("inputStyle"), X_IM_PREEDIT_NOTHING | X_IM_STATUS_NOTHING,
            ptr("clientWindow"), o.win, nil)
    }
    set_title(w, d.title)
    XMapWindow(dpy, o.win)
    XFlush(dpy)
    (w, true)
}

// Sets the window title (UTF-8).
fn set_title(w: *Window, title: str) {
    o := &w.os
    if o.dpy == nil {
        return
    }
    m := mark()
    XStoreName(o.dpy, o.win, cstr(title))
    release(m)
    XChangeProperty(o.dpy, o.win, o.net_wm_name, o.utf8_string, 8, X_PROP_MODE_REPLACE, ptr(title), i32(len(title)))
    XFlush(o.dpy)
}

priv fn window_emit(w: *Window, e: Event) {
    push_event(&w.events, e)
    feed(&w.input, e)
}

priv fn window_key_event(w: *Window, ev: *XEvent, pressed: bool) {
    key := key_from_keysym(XLookupKeysym(ev, 0))
    mods := mods_from_x11(x_event_state(ev))
    if !pressed {
        window_emit(w, Event{kind: EventKeyUp, key: key, mods: mods})
        return
    }
    window_emit(w, Event{kind: EventKeyDown, key: key, mods: mods, repeat: key_down(&w.input, key)})
    buf: [64]u8
    ks: u64
    n := 0
    utf8 := w.os.ic != nil
    if utf8 {
        status: i32
        n = i64(Xutf8LookupString(w.os.ic, ev, ptr(buf), 64, &ks, &status))
        if status != X_LOOKUP_CHARS && status != X_LOOKUP_BOTH {
            n = 0
        }
    } else {
        n = i64(XLookupString(ev, ptr(buf), 64, &ks, nil))
    }
    pos := 0
    while pos < n {
        c: u32
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
fn poll(w: *Window) {
    begin_frame(&w.input)
    clear_events(&w.events)
    o := &w.os
    if o.dpy == nil {
        return
    }
    ev: XEvent
    while XPending(o.dpy) > 0 {
        XNextEvent(o.dpy, &ev)
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
                if o.ic != nil {
                    XSetICFocus(o.ic)
                }
                window_emit(w, Event{kind: EventFocus})
            }
            X_FOCUS_OUT => {
                if o.ic != nil {
                    XUnsetICFocus(o.ic)
                }
                window_emit(w, Event{kind: EventUnfocus})
            }
            X_CLIENT_MESSAGE => {
                if x_event_message_type(&ev) == o.wm_protocols && x_event_message_data(&ev, 0) == o.wm_delete {
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

// Shows or hides the mouse pointer while it is over the window.
fn set_cursor_visible(w: *Window, visible: bool) {
    o := &w.os
    if o.dpy == nil || visible != w.cursor_hidden {
        return
    }
    if visible {
        XUndefineCursor(o.dpy, o.win)
    } else {
        if o.blank_cursor == 0 {
            zero: u64
            color: XColor
            pixmap := XCreateBitmapFromData(o.dpy, o.win, cast[*u8](&zero), 1, 1)
            o.blank_cursor = XCreatePixmapCursor(o.dpy, pixmap, pixmap, &color, &color, 0, 0)
            XFreePixmap(o.dpy, pixmap)
        }
        XDefineCursor(o.dpy, o.win, o.blank_cursor)
    }
    w.cursor_hidden = !visible
    XFlush(o.dpy)
}

// Asks the window manager to make the window fullscreen (borderless, covering the screen) or
// windowed again; the new size arrives as an EventResize in a later poll.
fn set_fullscreen(w: *Window, on: bool) {
    o := &w.os
    if o.dpy == nil || on == w.fullscreen {
        return
    }
    ev: XEvent
    x_client_message(&ev, o.win, o.net_wm_state, if on { 1 } else { 0 }, o.net_wm_state_fullscreen, 0, 1, 0)
    XSendEvent(o.dpy, XRootWindow(o.dpy, o.screen), 0, X_SUBSTRUCTURE_NOTIFY_MASK | X_SUBSTRUCTURE_REDIRECT_MASK, &ev)
    XFlush(o.dpy)
    w.fullscreen = on
}

priv fn window_free_image(w: *Window) {
    o := &w.os
    if o.image != nil {
        free(o.image_data)
        XFree(o.image)
        o.image = nil
        o.image_data = nil
    }
}

// Shows an RGBA8 framebuffer (`pw` x `ph` pixels, 4 bytes each, rows top to bottom) in the
// window: scaled with nearest-neighbour sampling to the largest size that keeps its aspect
// ratio, centered, black bars around it. Alpha is ignored. False if the window is closed or the
// display is not a 24/32-bit true-color one. Keeps a window-sized conversion buffer (C heap,
// reallocated only when the window size changes).
fn present(w: *Window, pixels: []u8, pw: i64, ph: i64) -> bool {
    o := &w.os
    if o.dpy == nil || o.depth < 24 || x_visual_class(o.visual) != X_TRUE_COLOR || w.width <= 0 || w.height <= 0 {
        return false
    }
    if o.image == nil || o.image_w != w.width || o.image_h != w.height {
        window_free_image(w)
        o.image_data = malloc(w.width * w.height * 4)
        if o.image_data == nil {
            return false
        }
        o.image = XCreateImage(o.dpy, o.visual, u32(o.depth), X_Z_PIXMAP, 0, o.image_data, u32(w.width), u32(w.height), 32, 0)
        if o.image == nil {
            free(o.image_data)
            return false
        }
        o.image_w = w.width
        o.image_h = w.height
    }
    blit_fit(mkslice[u32](o.image_data, o.image_w * o.image_h), o.image_w, o.image_h, pixels, pw, ph, o.swap_rb)
    XPutImage(o.dpy, o.win, o.gc, o.image, 0, 0, 0, 0, u32(o.image_w), u32(o.image_h))
    XFlush(o.dpy)
    true
}

// Destroys the window and disconnects from the display; the Window stays valid as a closed
// window (should_close is true, other calls do nothing).
fn close(w: *Window) {
    w.closing = true
    o := &w.os
    if o.dpy == nil {
        return
    }
    window_free_image(w)
    if o.ic != nil {
        XDestroyIC(o.ic)
    }
    if o.im != nil {
        XCloseIM(o.im)
    }
    if o.blank_cursor != 0 {
        XFreeCursor(o.dpy, o.blank_cursor)
    }
    XFreeGC(o.dpy, o.gc)
    XDestroyWindow(o.dpy, o.win)
    XCloseDisplay(o.dpy)
    o.dpy = nil
    o.ic = nil
    o.im = nil
}

// The Xlib `Display*` of the window (for VkXlibSurfaceCreateInfoKHR.dpy); nil once closed.
fn x11_display(w: *Window) -> *u8 {
    w.os.dpy
}

// The X11 window id (for VkXlibSurfaceCreateInfoKHR.window).
fn x11_window(w: *Window) -> u64 {
    w.os.win
}
