// std.x11: raw Xlib bindings (libX11.so.6) for 64-bit Linux. Names, arguments and constants
// follow <X11/Xlib.h>: Display*, GC, Visual*, XIM, XIC and XImage* are `*u8`; Window, Pixmap,
// Cursor, Atom, KeySym and Time are `u64`; Bool / Status / int are `i32`.
// std.window builds the portable window API on top of this.

// ---- constants ----

// event types (XEvent.type)
X_KEY_PRESS :: 2
X_KEY_RELEASE :: 3
X_BUTTON_PRESS :: 4
X_BUTTON_RELEASE :: 5
X_MOTION_NOTIFY :: 6
X_ENTER_NOTIFY :: 7
X_LEAVE_NOTIFY :: 8
X_FOCUS_IN :: 9
X_FOCUS_OUT :: 10
X_EXPOSE :: 12
X_DESTROY_NOTIFY :: 17
X_UNMAP_NOTIFY :: 18
X_MAP_NOTIFY :: 19
X_CONFIGURE_NOTIFY :: 22
X_CLIENT_MESSAGE :: 33
X_MAPPING_NOTIFY :: 34

// event masks (XSelectInput, XSendEvent)
X_KEY_PRESS_MASK :: 0x1
X_KEY_RELEASE_MASK :: 0x2
X_BUTTON_PRESS_MASK :: 0x4
X_BUTTON_RELEASE_MASK :: 0x8
X_ENTER_WINDOW_MASK :: 0x10
X_LEAVE_WINDOW_MASK :: 0x20
X_POINTER_MOTION_MASK :: 0x40
X_EXPOSURE_MASK :: 0x8000
X_STRUCTURE_NOTIFY_MASK :: 0x20000
X_SUBSTRUCTURE_NOTIFY_MASK :: 0x80000
X_SUBSTRUCTURE_REDIRECT_MASK :: 0x100000
X_FOCUS_CHANGE_MASK :: 0x200000

// modifier bits (key / button event state)
X_SHIFT_MASK : u32 : 0x1
X_LOCK_MASK : u32 : 0x2
X_CONTROL_MASK : u32 : 0x4
X_MOD1_MASK : u32 : 0x8
X_MOD4_MASK : u32 : 0x40

// XSizeHints.flags
X_P_SIZE :: 0x8
X_P_MIN_SIZE :: 0x10
X_P_MAX_SIZE :: 0x20

// predefined atoms, property modes, image formats, visual classes
X_ATOM_ATOM : u64 : 4
X_ATOM_CARDINAL : u64 : 6
X_ATOM_STRING : u64 : 31
X_PROP_MODE_REPLACE :: 0
X_Z_PIXMAP :: 2
X_TRUE_COLOR :: 4

// input method styles and Xutf8LookupString status values
X_IM_PREEDIT_NOTHING :: 0x8
X_IM_STATUS_NOTHING :: 0x400
X_LOOKUP_CHARS :: 2
X_LOOKUP_BOTH :: 4

// setlocale category
X_LC_CTYPE :: 0

// ---- structures ----

// XEvent: a 192-byte union, read through the x_event_* accessors below.
XEvent :: struct {
    data: [24]u64
}

// XSizeHints (window size limits for the window manager).
XSizeHints :: struct {
    flags: i64
    x: i32
    y: i32
    width: i32
    height: i32
    min_width: i32
    min_height: i32
    max_width: i32
    max_height: i32
    width_inc: i32
    height_inc: i32
    min_aspect_x: i32
    min_aspect_y: i32
    max_aspect_x: i32
    max_aspect_y: i32
    base_width: i32
    base_height: i32
    win_gravity: i32
}

// XColor.
XColor :: struct {
    pixel: u64
    red: u16
    green: u16
    blue: u16
    flags: u8
    pad: u8
}

x_event_i32 :: (e: *XEvent, offset: i64) -> i32 {
    cast[*i32](cast[i64](e) + offset)[0]
}

// Event type (X_KEY_PRESS, ...): `type`, common to all events.
x_event_type :: (e: *XEvent) -> i64 { i64(x_event_i32(e, 0)) }

// The window an event was reported to (XAnyEvent.window).
x_event_window :: (e: *XEvent) -> u64 { e.data[4] }

// Pointer x of key, button and motion events.
x_event_x :: (e: *XEvent) -> i64 { i64(x_event_i32(e, 64)) }

// Pointer y of key, button and motion events.
x_event_y :: (e: *XEvent) -> i64 { i64(x_event_i32(e, 68)) }

// Modifier and button state mask of key, button and motion events.
x_event_state :: (e: *XEvent) -> u32 { u32(x_event_i32(e, 80)) }

// XKeyEvent.keycode / XButtonEvent.button.
x_event_detail :: (e: *XEvent) -> i64 { i64(x_event_i32(e, 84)) }

// XConfigureEvent.width.
x_event_configure_width :: (e: *XEvent) -> i64 { i64(x_event_i32(e, 56)) }

// XConfigureEvent.height.
x_event_configure_height :: (e: *XEvent) -> i64 { i64(x_event_i32(e, 60)) }

// XClientMessageEvent.message_type.
x_event_message_type :: (e: *XEvent) -> u64 { e.data[5] }

// XClientMessageEvent.data.l[index] (index 0..4).
x_event_message_data :: (e: *XEvent, index: i64) -> u64 { e.data[7 + index] }

// Fills `e` as a format-32 ClientMessage for `window` with five data longs.
x_client_message :: (e: *XEvent, window: u64, message_type: u64, d0: u64, d1: u64, d2: u64, d3: u64, d4: u64) {
    *e = XEvent{}
    e.data[0] = X_CLIENT_MESSAGE
    e.data[4] = window
    e.data[5] = message_type
    e.data[6] = 32
    e.data[7] = d0
    e.data[8] = d1
    e.data[9] = d2
    e.data[10] = d3
    e.data[11] = d4
}

// Visual.red_mask of a Visual* (0xFF0000 on the usual BGRX true-color visuals).
x_visual_red_mask :: (visual: *u8) -> u64 { cast[*u64](visual)[3] }

// Visual.class of a Visual* (X_TRUE_COLOR, ...).
x_visual_class :: (visual: *u8) -> i64 { i64(cast[*i32](visual)[4]) }

// ---- functions ----

extern "libX11.so.6" XOpenDisplay :: (name: *u8) -> *u8
extern "libX11.so.6" XCloseDisplay :: (dpy: *u8) -> i32
extern "libX11.so.6" XDefaultScreen :: (dpy: *u8) -> i32
extern "libX11.so.6" XRootWindow :: (dpy: *u8, screen: i32) -> u64
extern "libX11.so.6" XDefaultVisual :: (dpy: *u8, screen: i32) -> *u8
extern "libX11.so.6" XDefaultDepth :: (dpy: *u8, screen: i32) -> i32
extern "libX11.so.6" XDisplayWidth :: (dpy: *u8, screen: i32) -> i32
extern "libX11.so.6" XDisplayHeight :: (dpy: *u8, screen: i32) -> i32
extern "libX11.so.6" XConnectionNumber :: (dpy: *u8) -> i32
extern "libX11.so.6" XCreateSimpleWindow :: (dpy: *u8, parent: u64, x: i32, y: i32, w: u32, h: u32, border_width: u32, border: u64, background: u64) -> u64
extern "libX11.so.6" XDestroyWindow :: (dpy: *u8, win: u64) -> i32
extern "libX11.so.6" XMapWindow :: (dpy: *u8, win: u64) -> i32
extern "libX11.so.6" XUnmapWindow :: (dpy: *u8, win: u64) -> i32
extern "libX11.so.6" XResizeWindow :: (dpy: *u8, win: u64, w: u32, h: u32) -> i32
extern "libX11.so.6" XMoveWindow :: (dpy: *u8, win: u64, x: i32, y: i32) -> i32
extern "libX11.so.6" XStoreName :: (dpy: *u8, win: u64, name: *u8) -> i32
extern "libX11.so.6" XSelectInput :: (dpy: *u8, win: u64, mask: i64) -> i32
extern "libX11.so.6" XInternAtom :: (dpy: *u8, name: *u8, only_if_exists: i32) -> u64
extern "libX11.so.6" XSetWMProtocols :: (dpy: *u8, win: u64, protocols: *u64, count: i32) -> i32
extern "libX11.so.6" XSetWMNormalHints :: (dpy: *u8, win: u64, hints: *XSizeHints)
extern "libX11.so.6" XChangeProperty :: (dpy: *u8, win: u64, property: u64, kind: u64, format: i32, mode: i32, data: *u8, nelements: i32) -> i32
extern "libX11.so.6" XSendEvent :: (dpy: *u8, win: u64, propagate: i32, mask: i64, event: *XEvent) -> i32
extern "libX11.so.6" XPending :: (dpy: *u8) -> i32
extern "libX11.so.6" XNextEvent :: (dpy: *u8, event: *XEvent) -> i32
extern "libX11.so.6" XFilterEvent :: (event: *XEvent, win: u64) -> i32
extern "libX11.so.6" XFlush :: (dpy: *u8) -> i32
extern "libX11.so.6" XSync :: (dpy: *u8, discard: i32) -> i32
extern "libX11.so.6" XFree :: (data: *u8) -> i32
extern "libX11.so.6" XLookupKeysym :: (key_event: *XEvent, index: i32) -> u64
extern "libX11.so.6" XLookupString :: (key_event: *XEvent, buf: *u8, nbytes: i32, keysym: *u64, compose: *u8) -> i32
extern "libX11.so.6" XRefreshKeyboardMapping :: (mapping_event: *XEvent) -> i32
extern "libX11.so.6" XkbSetDetectableAutoRepeat :: (dpy: *u8, detectable: i32, supported: *i32) -> i32
extern "libX11.so.6" XCreateGC :: (dpy: *u8, drawable: u64, value_mask: u64, values: *u8) -> *u8
extern "libX11.so.6" XFreeGC :: (dpy: *u8, gc: *u8) -> i32
extern "libX11.so.6" XCreateImage :: (dpy: *u8, visual: *u8, depth: u32, format: i32, offset: i32, data: *u8, w: u32, h: u32, bitmap_pad: i32, bytes_per_line: i32) -> *u8
extern "libX11.so.6" XPutImage :: (dpy: *u8, drawable: u64, gc: *u8, image: *u8, src_x: i32, src_y: i32, dst_x: i32, dst_y: i32, w: u32, h: u32) -> i32
extern "libX11.so.6" XCreateBitmapFromData :: (dpy: *u8, drawable: u64, data: *u8, w: u32, h: u32) -> u64
extern "libX11.so.6" XFreePixmap :: (dpy: *u8, pixmap: u64) -> i32
extern "libX11.so.6" XCreatePixmapCursor :: (dpy: *u8, source: u64, mask: u64, fg: *XColor, bg: *XColor, x: u32, y: u32) -> u64
extern "libX11.so.6" XDefineCursor :: (dpy: *u8, win: u64, cursor: u64) -> i32
extern "libX11.so.6" XUndefineCursor :: (dpy: *u8, win: u64) -> i32
extern "libX11.so.6" XFreeCursor :: (dpy: *u8, cursor: u64) -> i32
extern "libX11.so.6" XWarpPointer :: (dpy: *u8, src: u64, dst: u64, src_x: i32, src_y: i32, src_w: u32, src_h: u32, dst_x: i32, dst_y: i32) -> i32
extern "libX11.so.6" XSetLocaleModifiers :: (modifiers: *u8) -> *u8
extern "libX11.so.6" XOpenIM :: (dpy: *u8, db: *u8, res_name: *u8, res_class: *u8) -> *u8
extern "libX11.so.6" XCloseIM :: (im: *u8) -> i32
// XCreateIC is variadic in C; this is the (name, value, name, value, NULL) form.
extern "libX11.so.6" XCreateIC :: (im: *u8, name1: *u8, value1: i64, name2: *u8, value2: u64, end: *u8) -> *u8
extern "libX11.so.6" XDestroyIC :: (ic: *u8)
extern "libX11.so.6" XSetICFocus :: (ic: *u8)
extern "libX11.so.6" XUnsetICFocus :: (ic: *u8)
extern "libX11.so.6" Xutf8LookupString :: (ic: *u8, key_event: *XEvent, buf: *u8, nbytes: i32, keysym: *u64, status: *i32) -> i32
extern "libc.so.6" setlocale :: (category: i32, locale: *u8) -> *u8
