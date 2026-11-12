// ---- the client library (hand-written: tools/wayland_helpers.al) ----
// libwayland-client.so.0 holds the connection and the objects ("proxies") of a client. Every
// protocol object is a pointer to an opaque struct named after its interface (`*WlSurface`,
// `*XdgToplevel`, ...); the functions of this section that work on any object take it as `*u8`:
// `wl_proxy_get_id(cast[*u8](surface))`. A queue (wl_event_queue*) is a `*u8`.

// struct wl_message: one request or event of an interface.
struct WlMessage {
    name: *u8
    signature: *u8
    types: **WlInterface
}

// struct wl_interface: the description of an interface that libwayland works from. Those of the
// core protocol are the library's: `&wl_compositor_interface`; those of the other protocols come
// from the function of that name: `xdg_wm_base_interface()`.
struct WlInterface {
    name: *u8
    version: i32
    method_count: i32
    methods: *WlMessage
    event_count: i32
    events: *WlMessage
}

// struct wl_array: the value of an `array` argument of an event, valid during the handler.
struct WlArray {
    size: u64
    alloc: u64
    data: *u8
}

// flag of wl_proxy_marshal_array_flags: the request destroys the object
const WL_MARSHAL_FLAG_DESTROY: u32 = 1

// Connection. `name` is a C string (`cstr(name)`): the socket in $XDG_RUNTIME_DIR, or an
// absolute path; nil means $WAYLAND_DISPLAY ("wayland-0" if that is not set). nil on failure.
extern "libwayland-client.so.0" fn wl_display_connect(name: *u8) -> *WlDisplay
extern "libwayland-client.so.0" fn wl_display_connect_to_fd(fd: i32) -> *WlDisplay
extern "libwayland-client.so.0" fn wl_display_disconnect(display: *WlDisplay)
extern "libwayland-client.so.0" fn wl_display_get_fd(display: *WlDisplay) -> i32
// Sends the buffered requests. -1 on error (EAGAIN if the socket is full: poll for POLLOUT).
extern "libwayland-client.so.0" fn wl_display_flush(display: *WlDisplay) -> i32
// Flushes, waits until events have arrived and calls their handlers: the number of events
// dispatched, -1 once the connection is broken. Blocks.
extern "libwayland-client.so.0" fn wl_display_dispatch(display: *WlDisplay) -> i32
// Calls the handlers of events that were already read; never reads, never blocks.
extern "libwayland-client.so.0" fn wl_display_dispatch_pending(display: *WlDisplay) -> i32
// Blocks until the compositor has processed every request sent so far, dispatching the events
// that arrive meanwhile; -1 once the connection is broken.
extern "libwayland-client.so.0" fn wl_display_roundtrip(display: *WlDisplay) -> i32
// 0, or the errno that broke the connection (EPROTO 71: a protocol error, see below).
extern "libwayland-client.so.0" fn wl_display_get_error(display: *WlDisplay) -> i32
// After EPROTO: the error code, the interface and the id of the object it was raised on.
extern "libwayland-client.so.0" fn wl_display_get_protocol_error(display: *WlDisplay, interface: **WlInterface, id: *u32) -> u32
// Reading by hand (what wl_display_poll below does): prepare_read returns -1 while events
// are pending (dispatch them, try again); after 0 call exactly one of read_events / cancel_read.
extern "libwayland-client.so.0" fn wl_display_prepare_read(display: *WlDisplay) -> i32
extern "libwayland-client.so.0" fn wl_display_read_events(display: *WlDisplay) -> i32
extern "libwayland-client.so.0" fn wl_display_cancel_read(display: *WlDisplay)

// Event queues: events of the objects assigned to a queue are dispatched only by the
// *_queue functions on that queue.
extern "libwayland-client.so.0" fn wl_display_create_queue(display: *WlDisplay) -> *u8
extern "libwayland-client.so.0" fn wl_event_queue_destroy(queue: *u8)
extern "libwayland-client.so.0" fn wl_display_dispatch_queue(display: *WlDisplay, queue: *u8) -> i32
extern "libwayland-client.so.0" fn wl_display_dispatch_queue_pending(display: *WlDisplay, queue: *u8) -> i32
extern "libwayland-client.so.0" fn wl_display_roundtrip_queue(display: *WlDisplay, queue: *u8) -> i32
extern "libwayland-client.so.0" fn wl_display_prepare_read_queue(display: *WlDisplay, queue: *u8) -> i32

// Proxies. The request functions below are built on wl_proxy_marshal_array_flags: `args` points
// to one 8-byte union wl_argument per argument of the request (integers in the low 4 bytes,
// pointers, 0 for the new object); the result is the new object if the request creates one.
extern "libwayland-client.so.0" fn wl_proxy_marshal_array_flags(proxy: *u8, opcode: u32, interface: *WlInterface, version: u32, flags: u32, args: *u64) -> *u8
// `implementation` points to a table of handlers, one per event in protocol order. -1 if the
// object already has one.
extern "libwayland-client.so.0" fn wl_proxy_add_listener(proxy: *u8, implementation: *u8, data: *u8) -> i32
extern "libwayland-client.so.0" fn wl_proxy_get_listener(proxy: *u8) -> *u8
extern "libwayland-client.so.0" fn wl_proxy_destroy(proxy: *u8)
extern "libwayland-client.so.0" fn wl_proxy_set_user_data(proxy: *u8, data: *u8)
extern "libwayland-client.so.0" fn wl_proxy_get_user_data(proxy: *u8) -> *u8
extern "libwayland-client.so.0" fn wl_proxy_get_version(proxy: *u8) -> u32
extern "libwayland-client.so.0" fn wl_proxy_get_id(proxy: *u8) -> u32
// The interface name of the object, a C string.
extern "libwayland-client.so.0" fn wl_proxy_get_class(proxy: *u8) -> *u8
extern "libwayland-client.so.0" fn wl_proxy_set_queue(proxy: *u8, queue: *u8)
extern "libwayland-client.so.0" fn wl_proxy_create_wrapper(proxy: *u8) -> *u8
extern "libwayland-client.so.0" fn wl_proxy_wrapper_destroy(wrapper: *u8)

// Dispatches what is there without blocking longer than `timeout_ms` (0: not at all, -1:
// until something arrives): flushes the requests, reads the events that have arrived and calls
// their handlers. Returns the number of events dispatched, -1 once the connection is broken
// (the compositor is gone, or a protocol error: wl_display_get_error). The call for a frame
// loop: `if wl_display_poll(display, 0) < 0 { break }`.
fn wl_display_poll(display: *WlDisplay, timeout_ms: i64) -> i64 {
    if wl_display_get_error(display) != 0 {
        return -1
    }
    while wl_display_prepare_read(display) != 0 {
        // events are waiting in the queue: no need to read
        n := wl_display_dispatch_pending(display)
        if n != 0 {
            return i64(n)
        }
    }
    wl_display_flush(display)
    // struct pollfd { int fd; short events; short revents; }, POLLIN = 1
    pfd := [2]i32{wl_display_get_fd(display), 1}
    ready := 0
    loop {
        ready = syscall(7, ptr(pfd), 1, timeout_ms)
        if ready != -4 {
            break
        }
    }
    if ready <= 0 {
        wl_display_cancel_read(display)
        return if ready < 0 { -1 } else { 0 }
    }
    if wl_display_read_events(display) < 0 {
        return -1
    }
    i64(wl_display_dispatch_pending(display))
}

// wl_fixed_t (24.8 fixed point, an i32: surface coordinates of pointer events, axis values).
fn wl_fixed_to_double(f: i32) -> f64 { f64(f) / 256.0 }
fn wl_fixed_from_double(d: f64) -> i32 { i32(d * 256.0) }
fn wl_fixed_to_int(f: i32) -> i32 { f / 256 }
fn wl_fixed_from_int(i: i32) -> i32 { i * 256 }

// The elements of an array argument whose elements are u32 (the states of
// xdg_toplevel.configure, the keys of wl_keyboard.enter); a view, valid during the handler.
fn wl_array_u32(array: *WlArray) -> []u32 {
    mkslice[u32](cast[*u32](array.data), i64(array.size) / 4)
}

// The interface tables of the protocols other than the core one (whose tables libwayland-client
// exports: the extern variables wl_surface_interface, ...). They are built here on first use,
// from the constant tables at the end of this file, with the C layout (struct wl_interface,
// struct wl_message).
priv struct WlInterfaceDesc { name: str, version: i32, requests: i32, events: i32 }
priv struct WlMessageDesc { name: str, signature: str, types: i32 }
priv wl_interface_table: [WL_INTERFACE_COUNT]WlInterface
priv wl_message_table: [WL_MESSAGE_COUNT]WlMessage
priv wl_type_table: [WL_TYPE_COUNT]*WlInterface
priv wl_tables_ready: bool

priv fn wl_interface_at(index: i64) -> *WlInterface {
    if !wl_tables_ready {
        for i, t in WL_TYPES {
            if t >= 0 {
                wl_type_table[i] = &wl_interface_table[t]
            } else if t <= -2 {
                wl_type_table[i] = wl_library_interface(i64(t))
            }
        }
        for i, d in WL_MESSAGES {
            wl_message_table[i] = WlMessage{ptr(d.name), ptr(d.signature), &wl_type_table[d.types]}
        }
        first := 0
        for i, d in WL_INTERFACES {
            f := &wl_interface_table[i]
            f.name = ptr(d.name)
            f.version = d.version
            f.method_count = d.requests
            f.event_count = d.events
            if d.requests > 0 {
                f.methods = &wl_message_table[first]
            }
            if d.events > 0 {
                f.events = &wl_message_table[first + i64(d.requests)]
            }
            first += i64(d.requests + d.events)
        }
        wl_tables_ready = true
    }
    &wl_interface_table[index]
}

// An event handler that does nothing, whatever the arguments of the event are.
priv fn wl_ignore_event() {}
priv struct WlHandler { f: fn() }
priv wl_ignore := WlHandler{f: wl_ignore_event}

// What the `*_add_listener` functions do: every nil field among the `count` handlers of
// `listener` is set to a handler that ignores the event (libwayland would call the nil
// pointer), then the table is registered.
priv fn wl_listen(proxy: *u8, listener: *u8, count: i64, data: *u8) -> i32 {
    slots := mkslice[u8](listener, count * 8)
    for i in 0..count {
        unset := true
        for b in slots[i * 8..i * 8 + 8] {
            if b != 0 {
                unset = false
            }
        }
        if unset {
            memcopy(ptr(slots[i * 8..]), cast[*u8](&wl_ignore), 8)
        }
    }
    wl_proxy_add_listener(proxy, listener, data)
}

// The C string for a string argument that may be null: nil for "".
priv fn wl_cstr_or_nil(s: str) -> *u8 {
    if len(s) == 0 { nil } else { cstr(s) }
}

// ---- libxkbcommon.so.0: what a client needs for the keyboard ----
// wl_keyboard sends the keymap as a file descriptor and keys as evdev codes; xkbcommon turns
// a key into a keysym (the X11 numbers: Escape is 0xFF1B) and into text. The xkb key code is
// the code of wl_keyboard.key + 8.
struct XkbContext {}
struct XkbKeymap {}
struct XkbState {}

const XKB_CONTEXT_NO_FLAGS: i32 = 0
const XKB_KEYMAP_FORMAT_TEXT_V1: i32 = 1         // = WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1
const XKB_KEYMAP_COMPILE_NO_FLAGS: i32 = 0
const XKB_STATE_MODS_EFFECTIVE: i32 = 8          // `kind` of xkb_state_mod_name_is_active
const XKB_MOD_NAME_SHIFT = "Shift"               // pass as ptr(XKB_MOD_NAME_SHIFT)
const XKB_MOD_NAME_CAPS = "Lock"
const XKB_MOD_NAME_CTRL = "Control"
const XKB_MOD_NAME_ALT = "Mod1"
const XKB_MOD_NAME_NUM = "Mod2"
const XKB_MOD_NAME_LOGO = "Mod4"

extern "libxkbcommon.so.0" fn xkb_context_new(flags: i32) -> *XkbContext
extern "libxkbcommon.so.0" fn xkb_context_unref(context: *XkbContext)
// `string` is the NUL-terminated keymap text (the mapped file of wl_keyboard.keymap).
extern "libxkbcommon.so.0" fn xkb_keymap_new_from_string(context: *XkbContext, string: *u8, format: i32, flags: i32) -> *XkbKeymap
extern "libxkbcommon.so.0" fn xkb_keymap_new_from_buffer(context: *XkbContext, buffer: *u8, length: u64, format: i32, flags: i32) -> *XkbKeymap
extern "libxkbcommon.so.0" fn xkb_keymap_unref(keymap: *XkbKeymap)
// 1 if the key repeats while held (the client repeats: see wl_keyboard.repeat_info).
extern "libxkbcommon.so.0" fn xkb_keymap_key_repeats(keymap: *XkbKeymap, key: u32) -> i32
extern "libxkbcommon.so.0" fn xkb_state_new(keymap: *XkbKeymap) -> *XkbState
extern "libxkbcommon.so.0" fn xkb_state_unref(state: *XkbState)
// Call it from wl_keyboard.modifiers with (depressed, latched, locked, 0, 0, group).
extern "libxkbcommon.so.0" fn xkb_state_update_mask(state: *XkbState, depressed_mods: u32, latched_mods: u32, locked_mods: u32, depressed_layout: u32, latched_layout: u32, locked_layout: u32) -> i32
// The keysym of the key with the current modifiers and layout.
extern "libxkbcommon.so.0" fn xkb_state_key_get_one_sym(state: *XkbState, key: u32) -> u32
// The text the key types, as UTF-8 with a NUL into `buffer`; the length without the NUL.
extern "libxkbcommon.so.0" fn xkb_state_key_get_utf8(state: *XkbState, key: u32, buffer: *u8, size: u64) -> i32
extern "libxkbcommon.so.0" fn xkb_state_key_get_utf32(state: *XkbState, key: u32) -> u32
// 1 if the modifier (a C string: ptr(XKB_MOD_NAME_SHIFT)) is active.
extern "libxkbcommon.so.0" fn xkb_state_mod_name_is_active(state: *XkbState, name: *u8, kind: i32) -> i32
extern "libxkbcommon.so.0" fn xkb_keysym_get_name(keysym: u32, buffer: *u8, size: u64) -> i32
extern "libxkbcommon.so.0" fn xkb_keysym_to_utf32(keysym: u32) -> u32

// ---- libwayland-cursor.so.0: pointer images from the cursor theme ----
// On Wayland the client draws the pointer: on wl_pointer.enter attach the buffer of a cursor
// image to a wl_surface of its own and call wl_pointer_set_cursor (a nil surface hides it).
struct WlCursorTheme {}

// struct wl_cursor_image: one frame of a cursor.
struct WlCursorImage {
    width: u32
    height: u32
    hotspot_x: u32
    hotspot_y: u32
    delay: u32
}

// struct wl_cursor: `images[0 .. image_count - 1]` are the frames of its animation.
struct WlCursor {
    image_count: u32
    images: **WlCursorImage
    name: *u8
}

// `name` nil: the default theme; `size` in pixels (24). The theme owns its cursors and buffers.
extern "libwayland-cursor.so.0" fn wl_cursor_theme_load(name: *u8, size: i32, shm: *WlShm) -> *WlCursorTheme
extern "libwayland-cursor.so.0" fn wl_cursor_theme_destroy(theme: *WlCursorTheme)
// The cursor of that name ("left_ptr", "text", ...), nil if the theme has none.
extern "libwayland-cursor.so.0" fn wl_cursor_theme_get_cursor(theme: *WlCursorTheme, name: *u8) -> *WlCursor
// The buffer of an image; it belongs to the theme: do not destroy it.
extern "libwayland-cursor.so.0" fn wl_cursor_image_get_buffer(image: *WlCursorImage) -> *WlBuffer
// The index of the frame of an animated cursor to show at `time` (milliseconds).
extern "libwayland-cursor.so.0" fn wl_cursor_frame(cursor: *WlCursor, time: u32) -> i32
