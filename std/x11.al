// std.x11: raw Xlib bindings (libX11.so.6) for 64-bit Linux. Names, arguments and constants
// follow <X11/Xlib.h>: Display*, GC, Visual*, XIM, XIC and XImage* are `*u8`; Window, Pixmap,
// Cursor, Atom, KeySym and Time are `u64`; Bool / Status / int are `i32`.
// std.window builds the portable window API on top of this.

// ---- constants ----

// event types (XEvent.type)
const X_KEY_PRESS = 2
const X_KEY_RELEASE = 3
const X_BUTTON_PRESS = 4
const X_BUTTON_RELEASE = 5
const X_MOTION_NOTIFY = 6
const X_ENTER_NOTIFY = 7
const X_LEAVE_NOTIFY = 8
const X_FOCUS_IN = 9
const X_FOCUS_OUT = 10
const X_EXPOSE = 12
const X_DESTROY_NOTIFY = 17
const X_UNMAP_NOTIFY = 18
const X_MAP_NOTIFY = 19
const X_CONFIGURE_NOTIFY = 22
const X_CLIENT_MESSAGE = 33
const X_MAPPING_NOTIFY = 34

// event masks (XSelectInput, XSendEvent)
const X_KEY_PRESS_MASK = 0x1
const X_KEY_RELEASE_MASK = 0x2
const X_BUTTON_PRESS_MASK = 0x4
const X_BUTTON_RELEASE_MASK = 0x8
const X_ENTER_WINDOW_MASK = 0x10
const X_LEAVE_WINDOW_MASK = 0x20
const X_POINTER_MOTION_MASK = 0x40
const X_EXPOSURE_MASK = 0x8000
const X_STRUCTURE_NOTIFY_MASK = 0x20000
const X_SUBSTRUCTURE_NOTIFY_MASK = 0x80000
const X_SUBSTRUCTURE_REDIRECT_MASK = 0x100000
const X_FOCUS_CHANGE_MASK = 0x200000

// modifier bits (key / button event state)
const X_SHIFT_MASK u32 = 0x1
const X_LOCK_MASK u32 = 0x2
const X_CONTROL_MASK u32 = 0x4
const X_MOD1_MASK u32 = 0x8
const X_MOD4_MASK u32 = 0x40

// XSizeHints.flags
const X_P_SIZE = 0x8
const X_P_MIN_SIZE = 0x10
const X_P_MAX_SIZE = 0x20

// predefined atoms, property modes, image formats, visual classes
const X_ATOM_ATOM u64 = 4
const X_ATOM_CARDINAL u64 = 6
const X_ATOM_STRING u64 = 31
const X_PROP_MODE_REPLACE = 0
const X_Z_PIXMAP = 2
const X_TRUE_COLOR = 4

// input method styles and Xutf8LookupString status values
const X_IM_PREEDIT_NOTHING = 0x8
const X_IM_STATUS_NOTHING = 0x400
const X_LOOKUP_CHARS = 2
const X_LOOKUP_BOTH = 4

// setlocale category
const X_LC_CTYPE = 0

// ---- structures ----

// XEvent: a 192-byte union, read through the x_event_* accessors below.
struct XEvent {
    data [24]u64
}

// XSizeHints (window size limits for the window manager).
struct XSizeHints {
    flags i64
    x i32
    y i32
    width i32
    height i32
    min_width i32
    min_height i32
    max_width i32
    max_height i32
    width_inc i32
    height_inc i32
    min_aspect_x i32
    min_aspect_y i32
    max_aspect_x i32
    max_aspect_y i32
    base_width i32
    base_height i32
    win_gravity i32
}

// XColor.
struct XColor {
    pixel u64
    red u16
    green u16
    blue u16
    flags u8
    pad u8
}

fn x_event_i32(e *XEvent, offset i64) i32 {
    cast[*i32](cast[i64](e) + offset)[0]
}

// Event type (X_KEY_PRESS, ...): `type`, common to all events.
fn x_event_type(e *XEvent) i64 { i64(x_event_i32(e, 0)) }

// The window an event was reported to (XAnyEvent.window).
fn x_event_window(e *XEvent) u64 { e.data[4] }

// Pointer x of key, button and motion events.
fn x_event_x(e *XEvent) i64 { i64(x_event_i32(e, 64)) }

// Pointer y of key, button and motion events.
fn x_event_y(e *XEvent) i64 { i64(x_event_i32(e, 68)) }

// Modifier and button state mask of key, button and motion events.
fn x_event_state(e *XEvent) u32 { u32(x_event_i32(e, 80)) }

// XKeyEvent.keycode / XButtonEvent.button.
fn x_event_detail(e *XEvent) i64 { i64(x_event_i32(e, 84)) }

// XConfigureEvent.width.
fn x_event_configure_width(e *XEvent) i64 { i64(x_event_i32(e, 56)) }

// XConfigureEvent.height.
fn x_event_configure_height(e *XEvent) i64 { i64(x_event_i32(e, 60)) }

// XClientMessageEvent.message_type.
fn x_event_message_type(e *XEvent) u64 { e.data[5] }

// XClientMessageEvent.data.l[index] (index 0..4).
fn x_event_message_data(e *XEvent, index i64) u64 { e.data[7 + index] }

// Fills `e` as a format-32 ClientMessage for `window` with five data longs.
fn x_client_message(e *XEvent, window u64, message_type u64, d0 u64, d1 u64, d2 u64, d3 u64, d4 u64) {
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
fn x_visual_red_mask(visual *u8) u64 { cast[*u64](visual)[3] }

// Visual.class of a Visual* (X_TRUE_COLOR, ...).
fn x_visual_class(visual *u8) i64 { i64(cast[*i32](visual)[4]) }

// ---- functions ----

extern "libX11.so.6" fn XOpenDisplay(name *u8) *u8
extern "libX11.so.6" fn XCloseDisplay(dpy *u8) i32
extern "libX11.so.6" fn XDefaultScreen(dpy *u8) i32
extern "libX11.so.6" fn XRootWindow(dpy *u8, screen i32) u64
extern "libX11.so.6" fn XDefaultVisual(dpy *u8, screen i32) *u8
extern "libX11.so.6" fn XDefaultDepth(dpy *u8, screen i32) i32
extern "libX11.so.6" fn XDisplayWidth(dpy *u8, screen i32) i32
extern "libX11.so.6" fn XDisplayHeight(dpy *u8, screen i32) i32
extern "libX11.so.6" fn XConnectionNumber(dpy *u8) i32
extern "libX11.so.6" fn XCreateSimpleWindow(dpy *u8, parent u64, x i32, y i32, w u32, h u32, border_width u32, border u64, background u64) u64
extern "libX11.so.6" fn XDestroyWindow(dpy *u8, win u64) i32
extern "libX11.so.6" fn XMapWindow(dpy *u8, win u64) i32
extern "libX11.so.6" fn XUnmapWindow(dpy *u8, win u64) i32
extern "libX11.so.6" fn XResizeWindow(dpy *u8, win u64, w u32, h u32) i32
extern "libX11.so.6" fn XMoveWindow(dpy *u8, win u64, x i32, y i32) i32
extern "libX11.so.6" fn XStoreName(dpy *u8, win u64, name *u8) i32
extern "libX11.so.6" fn XSelectInput(dpy *u8, win u64, mask i64) i32
extern "libX11.so.6" fn XInternAtom(dpy *u8, name *u8, only_if_exists i32) u64
extern "libX11.so.6" fn XSetWMProtocols(dpy *u8, win u64, protocols *u64, count i32) i32
extern "libX11.so.6" fn XSetWMNormalHints(dpy *u8, win u64, hints *XSizeHints)
extern "libX11.so.6" fn XChangeProperty(dpy *u8, win u64, property u64, kind u64, format i32, mode i32, data *u8, nelements i32) i32
extern "libX11.so.6" fn XSendEvent(dpy *u8, win u64, propagate i32, mask i64, event *XEvent) i32
extern "libX11.so.6" fn XPending(dpy *u8) i32
extern "libX11.so.6" fn XNextEvent(dpy *u8, event *XEvent) i32
extern "libX11.so.6" fn XFilterEvent(event *XEvent, win u64) i32
extern "libX11.so.6" fn XFlush(dpy *u8) i32
extern "libX11.so.6" fn XSync(dpy *u8, discard i32) i32
extern "libX11.so.6" fn XFree(data *u8) i32
extern "libX11.so.6" fn XLookupKeysym(key_event *XEvent, index i32) u64
extern "libX11.so.6" fn XLookupString(key_event *XEvent, buf *u8, nbytes i32, keysym *u64, compose *u8) i32
extern "libX11.so.6" fn XRefreshKeyboardMapping(mapping_event *XEvent) i32
extern "libX11.so.6" fn XkbSetDetectableAutoRepeat(dpy *u8, detectable i32, supported *i32) i32
extern "libX11.so.6" fn XCreateGC(dpy *u8, drawable u64, value_mask u64, values *u8) *u8
extern "libX11.so.6" fn XFreeGC(dpy *u8, gc *u8) i32
extern "libX11.so.6" fn XCreateImage(dpy *u8, visual *u8, depth u32, format i32, offset i32, data *u8, w u32, h u32, bitmap_pad i32, bytes_per_line i32) *u8
extern "libX11.so.6" fn XPutImage(dpy *u8, drawable u64, gc *u8, image *u8, src_x i32, src_y i32, dst_x i32, dst_y i32, w u32, h u32) i32
extern "libX11.so.6" fn XCreateBitmapFromData(dpy *u8, drawable u64, data *u8, w u32, h u32) u64
extern "libX11.so.6" fn XFreePixmap(dpy *u8, pixmap u64) i32
extern "libX11.so.6" fn XCreatePixmapCursor(dpy *u8, source u64, mask u64, fg *XColor, bg *XColor, x u32, y u32) u64
extern "libX11.so.6" fn XDefineCursor(dpy *u8, win u64, cursor u64) i32
extern "libX11.so.6" fn XUndefineCursor(dpy *u8, win u64) i32
extern "libX11.so.6" fn XFreeCursor(dpy *u8, cursor u64) i32
extern "libX11.so.6" fn XWarpPointer(dpy *u8, src u64, dst u64, src_x i32, src_y i32, src_w u32, src_h u32, dst_x i32, dst_y i32) i32
extern "libX11.so.6" fn XSetLocaleModifiers(modifiers *u8) *u8
extern "libX11.so.6" fn XOpenIM(dpy *u8, db *u8, res_name *u8, res_class *u8) *u8
extern "libX11.so.6" fn XCloseIM(im *u8) i32
// XCreateIC is variadic in C; this is the (name, value, name, value, NULL) form.
extern "libX11.so.6" fn XCreateIC(im *u8, name1 *u8, value1 i64, name2 *u8, value2 u64, end *u8) *u8
extern "libX11.so.6" fn XDestroyIC(ic *u8)
extern "libX11.so.6" fn XSetICFocus(ic *u8)
extern "libX11.so.6" fn XUnsetICFocus(ic *u8)
extern "libX11.so.6" fn Xutf8LookupString(ic *u8, key_event *XEvent, buf *u8, nbytes i32, keysym *u64, status *i32) i32
extern "libc.so.6" fn setlocale(category i32, locale *u8) *u8
