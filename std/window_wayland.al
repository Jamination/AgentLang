// std.window, Linux layer, Wayland backend (EXPERIMENTAL: opt-in, not yet run on a real
// Wayland session): the window is an xdg_toplevel of the compositor, through std.wayland.
// Included by std/window_linux.al, which chooses it in window_open only on request (see
// window_systems) and hands every call on a Wayland window to the functions here.
//
// Nothing here links a library: libwayland-client.so.0 (wl_client_lib of std.wayland),
// libxkbcommon.so.0 and libwayland-cursor.so.0 are loaded with dlopen when a window is opened
// on Wayland, so a program that uses std.window starts on a system without them and an X11
// window needs only what it needed before. Wayland is not used (window_open goes on with X11)
// when libwayland-client or libxkbcommon is missing; without libwayland-cursor the window sets
// no pointer image.
use std.wayland

// (libdl.so.2 holds these before glibc 2.34, the C library itself since)
priv extern "libdl.so.2" fn dlopen(path: *u8, flags: i32) -> *u8
priv extern "libdl.so.2" fn dlsym(handle: *u8, name: *u8) -> *u8

priv const WL_OUTPUT_CAP = 8
priv const WL_BUFFER_CAP = 3
priv const XKB_MOD_INVALID: u32 = 0xFFFFFFFF
priv const XKB_LAYOUT_INVALID: u32 = 0xFFFFFFFF
priv const XKB_COMPOSE_FEED_ACCEPTED: i32 = 1
priv const XKB_COMPOSE_COMPOSING: i32 = 1
priv const XKB_COMPOSE_COMPOSED: i32 = 2
priv const XKB_COMPOSE_CANCELLED: i32 = 3
// most repeats of a held key sent by one poll (a program that stalled gets no burst)
priv const WL_REPEAT_BURST = 4

// ---- Wayland helpers (no compositor needed) ----

// Which window systems window_open tries: only X11 (`x11`), only Wayland (`wayland`), or
// both: then X11, and Wayland only if no X display can be opened. The names are the X display
// and the Wayland socket ("" for the default, $DISPLAY / $WAYLAND_DISPLAY).
struct WindowSystems {
    wayland: bool
    x11: bool
    wayland_name: str
    x11_name: str
}

// For WindowDesc.display and the values of $WAYLAND_DISPLAY and $ALC_WINDOW. `display` "":
// X11 as always; Wayland (experimental) only when `alc_window` is "wayland", or as a last
// resort when no X display can be opened and $WAYLAND_DISPLAY is set (not empty);
// `alc_window` "x11" rules that out too (other values are ignored). "wayland": only Wayland;
// "wayland:NAME": only Wayland, the socket NAME ("wayland-1", or an absolute path); "x11":
// only X11; anything else is an X display name, as it always was (":1", "host:0.0"). A display
// named by the program is not changed by $ALC_WINDOW.
fn window_systems(display: str, wayland_display: str, alc_window: str) -> WindowSystems {
    if display == "" {
        return match alc_window {
            "wayland" => WindowSystems{wayland: true}
            "x11" => WindowSystems{x11: true}
            _ => WindowSystems{x11: true, wayland: wayland_display != ""}
        }
    }
    if display == "x11" {
        return WindowSystems{x11: true}
    }
    if display == "wayland" {
        return WindowSystems{wayland: true}
    }
    if starts_with(display, "wayland:") && display.len > len("wayland:") {
        return WindowSystems{wayland: true, wayland_name: display[len("wayland:")..]}
    }
    WindowSystems{x11: true, x11_name: display}
}

// MOUSE_* for a Linux evdev button code of wl_pointer.button (BTN_LEFT is 0x110); -1 for
// buttons without a code.
fn button_from_evdev(code: u32) -> i64 {
    match code {
        0x110 => MOUSE_LEFT
        0x111 => MOUSE_RIGHT
        0x112 => MOUSE_MIDDLE
        0x113, 0x116 => MOUSE_X1                 // BTN_SIDE, BTN_BACK
        0x114, 0x115 => MOUSE_X2                 // BTN_EXTRA, BTN_FORWARD
        _ => -1
    }
}

// The event of a wl_pointer.button at (x, y): a MOUSE_* press / release, kind EventNone for
// buttons without a code.
fn event_from_wl_button(code: u32, pressed: bool, x: i64, y: i64, mods: u8) -> Event {
    b := button_from_evdev(code)
    if b < 0 {
        return Event{}
    }
    Event{kind: if pressed { EventMouseDown } else { EventMouseUp }, key: b, x: x, y: y, mods: mods}
}

// Event.mods bits (MOD_*) for an xkb modifier mask (depressed | latched | locked of
// wl_keyboard.modifiers) and the indices of the modifiers Shift, Control, Mod1 and Mod4 in the
// keymap (32 or more: the keymap has no such modifier).
fn mods_from_xkb(mask: u32, shift: u32, ctrl: u32, alt: u32, logo: u32) -> u8 {
    fn on(mask: u32, index: u32) -> bool { index < 32 && mask >> index & 1 != 0 }
    m: u8 = 0
    if on(mask, shift) {
        m |= MOD_SHIFT
    }
    if on(mask, ctrl) {
        m |= MOD_CTRL
    }
    if on(mask, alt) {
        m |= MOD_ALT
    }
    if on(mask, logo) {
        m |= MOD_SUPER
    }
    m
}

// Wheel steps of one axis. `v120` is scrolling in 120ths of a step: wl_pointer.axis_value120,
// axis_discrete * 120, or wheel_v120_from_axis of a continuous axis value (touchpads). It is added to
// the remainder `*acc` (which starts over when the direction changes); the whole steps in it
// are returned (toward zero) and taken out.
fn wheel_steps(acc: *i64, v120: i64) -> i64 {
    if (v120 > 0 && *acc < 0) || (v120 < 0 && *acc > 0) {
        *acc = 0
    }
    *acc += v120
    n := *acc / 120
    *acc -= n * 120
    n
}

// A continuous wl_pointer.axis value (wl_fixed_t, surface pixels) in 120ths of a wheel step:
// 10 pixels are one step.
fn wheel_v120_from_axis(value: i32) -> i64 {
    i64(value) * 12 / 256
}

// How many auto-repeats of a key are due at `now_ns` and not yet sent (`sent` of them were):
// the key went down at `down_ns`, repeats start `delay_ms` later and come `rate` times a
// second (wl_keyboard.repeat_info; a rate of 0 or less: no repeat).
fn repeats_due(now_ns: i64, down_ns: i64, delay_ms: i64, rate: i64, sent: i64) -> i64 {
    if rate <= 0 {
        return 0
    }
    t := now_ns - down_ns - delay_ms * 1_000_000
    if t < 0 {
        return 0
    }
    max(1 + t * rate / 1_000_000_000 - sent, 0)
}

// The buffer scale for a window from the scales of outputs: the largest, at least 1.
fn scale_from_outputs(scales: []i64) -> i64 {
    s := 1
    for x in scales {
        s = max(s, x)
    }
    s
}

// The size in surface units (the compositor's logical pixels) that shows `pixels` buffer
// pixels at buffer scale `scale`: rounded up, since a buffer must be a whole multiple of its
// scale; at least 1.
fn surface_size_for_pixels(pixels: i64, scale: i64) -> i64 {
    max((pixels + scale - 1) / scale, 1)
}

// A surface coordinate of a pointer event (wl_fixed_t, surface units) in buffer pixels at
// buffer scale `scale`, rounded down.
fn pixels_from_wl_fixed(f: i32, scale: i64) -> i64 {
    v := i64(f) * scale
    if v >= 0 { v / 256 } else { -((255 - v) / 256) }
}

// The surface size (units) after an xdg_toplevel.configure that proposed `conf_w` x `conf_h`
// (0: the client chooses): the proposal where the window follows it (`follow`: resizable,
// maximized, fullscreen or tiled), otherwise the size that shows `want_w` x `want_h` pixels at
// `scale`.
fn size_after_configure(conf_w: i64, conf_h: i64, follow: bool, want_w: i64, want_h: i64, scale: i64) -> (i64, i64) {
    w := if follow && conf_w > 0 { conf_w } else { surface_size_for_pixels(want_w, scale) }
    h := if follow && conf_h > 0 { conf_h } else { surface_size_for_pixels(want_h, scale) }
    (w, h)
}

// ---- libxkbcommon.so.0 and libwayland-cursor.so.0, loaded at run time ----

priv struct XkbFns {
    context_new: fn(i32) -> *XkbContext
    context_unref: fn(*XkbContext)
    keymap_new_from_string: fn(*XkbContext, *u8, i32, i32) -> *XkbKeymap
    keymap_unref: fn(*XkbKeymap)
    keymap_key_repeats: fn(*XkbKeymap, u32) -> i32
    keymap_mod_get_index: fn(*XkbKeymap, *u8) -> u32
    keymap_key_get_syms_by_level: fn(*XkbKeymap, u32, u32, u32, **u32) -> i32
    state_new: fn(*XkbKeymap) -> *XkbState
    state_unref: fn(*XkbState)
    state_update_mask: fn(*XkbState, u32, u32, u32, u32, u32, u32) -> i32
    state_key_get_one_sym: fn(*XkbState, u32) -> u32
    state_key_get_utf8: fn(*XkbState, u32, *u8, u64) -> i32
    state_key_get_layout: fn(*XkbState, u32) -> u32
    // compose sequences and dead keys (xkbcommon 0.5); `compose` is false without them
    compose: bool
    compose_table_new_from_locale: fn(*XkbContext, *u8, i32) -> *u8
    compose_table_unref: fn(*u8)
    compose_state_new: fn(*u8, i32) -> *u8
    compose_state_unref: fn(*u8)
    compose_state_feed: fn(*u8, u32) -> i32
    compose_state_reset: fn(*u8)
    compose_state_get_status: fn(*u8) -> i32
    compose_state_get_utf8: fn(*u8, *u8, u64) -> i32
}

priv struct CursorFns {
    theme_load: fn(*u8, i32, *WlShm) -> *WlCursorTheme
    theme_destroy: fn(*WlCursorTheme)
    theme_get_cursor: fn(*WlCursorTheme, *u8) -> *WlCursor
    image_get_buffer: fn(*WlCursorImage) -> *WlBuffer
}

priv xkb: XkbFns
priv xkb_state_loaded: i64                  // 0: not tried, 1: loaded, -1: not available
priv cursor: CursorFns
priv cursor_state_loaded: i64

priv fn wl_sym(lib: *u8, name: *u8, missing: *bool) -> *u8 {
    p := dlsym(lib, name)
    if p == nil {
        *missing = true
    }
    p
}

// libxkbcommon.so.0, loaded on the first call; false if it is not installed.
priv fn wl_xkb_load() -> bool {
    if xkb_state_loaded == 0 {
        xkb_state_loaded = -1
        lib := dlopen(ptr("libxkbcommon.so.0"), 2)              // RTLD_NOW
        if lib == nil {
            return false
        }
        m := false
        x := &xkb
        x.context_new = cast[fn(i32) -> *XkbContext](wl_sym(lib, ptr("xkb_context_new"), &m))
        x.context_unref = cast[fn(*XkbContext)](wl_sym(lib, ptr("xkb_context_unref"), &m))
        x.keymap_new_from_string = cast[fn(*XkbContext, *u8, i32, i32) -> *XkbKeymap](wl_sym(lib, ptr("xkb_keymap_new_from_string"), &m))
        x.keymap_unref = cast[fn(*XkbKeymap)](wl_sym(lib, ptr("xkb_keymap_unref"), &m))
        x.keymap_key_repeats = cast[fn(*XkbKeymap, u32) -> i32](wl_sym(lib, ptr("xkb_keymap_key_repeats"), &m))
        x.keymap_mod_get_index = cast[fn(*XkbKeymap, *u8) -> u32](wl_sym(lib, ptr("xkb_keymap_mod_get_index"), &m))
        x.keymap_key_get_syms_by_level = cast[fn(*XkbKeymap, u32, u32, u32, **u32) -> i32](wl_sym(lib, ptr("xkb_keymap_key_get_syms_by_level"), &m))
        x.state_new = cast[fn(*XkbKeymap) -> *XkbState](wl_sym(lib, ptr("xkb_state_new"), &m))
        x.state_unref = cast[fn(*XkbState)](wl_sym(lib, ptr("xkb_state_unref"), &m))
        x.state_update_mask = cast[fn(*XkbState, u32, u32, u32, u32, u32, u32) -> i32](wl_sym(lib, ptr("xkb_state_update_mask"), &m))
        x.state_key_get_one_sym = cast[fn(*XkbState, u32) -> u32](wl_sym(lib, ptr("xkb_state_key_get_one_sym"), &m))
        x.state_key_get_utf8 = cast[fn(*XkbState, u32, *u8, u64) -> i32](wl_sym(lib, ptr("xkb_state_key_get_utf8"), &m))
        x.state_key_get_layout = cast[fn(*XkbState, u32) -> u32](wl_sym(lib, ptr("xkb_state_key_get_layout"), &m))
        if m {
            return false
        }
        c := false
        x.compose_table_new_from_locale = cast[fn(*XkbContext, *u8, i32) -> *u8](wl_sym(lib, ptr("xkb_compose_table_new_from_locale"), &c))
        x.compose_table_unref = cast[fn(*u8)](wl_sym(lib, ptr("xkb_compose_table_unref"), &c))
        x.compose_state_new = cast[fn(*u8, i32) -> *u8](wl_sym(lib, ptr("xkb_compose_state_new"), &c))
        x.compose_state_unref = cast[fn(*u8)](wl_sym(lib, ptr("xkb_compose_state_unref"), &c))
        x.compose_state_feed = cast[fn(*u8, u32) -> i32](wl_sym(lib, ptr("xkb_compose_state_feed"), &c))
        x.compose_state_reset = cast[fn(*u8)](wl_sym(lib, ptr("xkb_compose_state_reset"), &c))
        x.compose_state_get_status = cast[fn(*u8) -> i32](wl_sym(lib, ptr("xkb_compose_state_get_status"), &c))
        x.compose_state_get_utf8 = cast[fn(*u8, *u8, u64) -> i32](wl_sym(lib, ptr("xkb_compose_state_get_utf8"), &c))
        x.compose = !c
        xkb_state_loaded = 1
    }
    xkb_state_loaded > 0
}

// libwayland-cursor.so.0, loaded on the first call; false if it is not installed.
priv fn wl_cursor_load() -> bool {
    if cursor_state_loaded == 0 {
        cursor_state_loaded = -1
        lib := dlopen(ptr("libwayland-cursor.so.0"), 2)
        if lib == nil {
            return false
        }
        m := false
        c := &cursor
        c.theme_load = cast[fn(*u8, i32, *WlShm) -> *WlCursorTheme](wl_sym(lib, ptr("wl_cursor_theme_load"), &m))
        c.theme_destroy = cast[fn(*WlCursorTheme)](wl_sym(lib, ptr("wl_cursor_theme_destroy"), &m))
        c.theme_get_cursor = cast[fn(*WlCursorTheme, *u8) -> *WlCursor](wl_sym(lib, ptr("wl_cursor_theme_get_cursor"), &m))
        c.image_get_buffer = cast[fn(*WlCursorImage) -> *WlBuffer](wl_sym(lib, ptr("wl_cursor_image_get_buffer"), &m))
        if m {
            return false
        }
        cursor_state_loaded = 1
    }
    cursor_state_loaded > 0
}

// ---- the window ----

// An output (monitor) of the compositor and whether the window is on it.
struct WaylandOutput {
    name: u32
    output: *WlOutput
    scale: i64
    entered: bool
}

// A wl_shm buffer of the software presenter: XRGB8888, one u32 0x00RRGGBB per pixel.
struct WaylandBuffer {
    buffer: *WlBuffer
    pixels: []u32
    width: i64
    height: i64
    busy: bool                   // attached and not yet released by the compositor
}

// The state of a window on Wayland (WindowOs.wl; nil for an X11 window). Read the handles
// through wayland_display / wayland_surface.
struct WaylandWindow {
    display: *WlDisplay
    registry: *WlRegistry
    compositor: *WlCompositor
    shm: *WlShm
    wm_base: *XdgWmBase
    seat: *WlSeat
    decoration_manager: *ZxdgDecorationManagerV1
    relative_manager: *ZwpRelativePointerManagerV1
    constraints: *ZwpPointerConstraintsV1
    outputs: [WL_OUTPUT_CAP]WaylandOutput
    output_len: i64
    surface: *WlSurface
    xdg_surface: *XdgSurface
    toplevel: *XdgToplevel
    decoration: *ZxdgToplevelDecorationV1
    pointer: *WlPointer
    keyboard: *WlKeyboard
    relative: *ZwpRelativePointerV1      // while the pointer is locked
    locked: *ZwpLockedPointerV1
    lock_active: bool                    // the compositor has activated the lock
    cursor_theme: *WlCursorTheme
    cursor_theme_scale: i64
    cursor_surface: *WlSurface
    enter_serial: u32                    // of the last wl_pointer.enter (for set_cursor)
    pointer_in: bool
    pointer_x: i32                       // last pointer position, wl_fixed_t surface units
    pointer_y: i32
    last_px: i64                         // the last pointer position in pixels (locked pointer without the protocols)
    last_py: i64
    xkb: *XkbContext
    keymap: *XkbKeymap
    xkb_state: *XkbState
    compose_table: *u8
    compose_state: *u8
    mod_shift: u32
    mod_ctrl: u32
    mod_alt: u32
    mod_logo: u32
    mods_mask: u32                       // depressed | latched | locked
    repeat_rate: i64                     // wl_keyboard.repeat_info
    repeat_delay: i64
    repeat_key: u32                      // xkb key code of the key that repeats, 0: none
    repeat_since: i64
    repeat_sent: i64
    scale: i64                           // buffer scale of the window's pixels
    scale_wanted: i64                    // what the compositor prefers now
    preferred_scale: i64                 // wl_surface.preferred_buffer_scale, 0: not sent
    committed_scale: i64                 // the buffer scale set on the surface
    follows_scale: bool                  // present was called: scale changes are applied
    logical_w: i64                       // size in surface units
    logical_h: i64
    want_w: i64                          // the pixel size when not maximized / fullscreen / tiled
    want_h: i64
    resizable: bool
    conf_w: i64                          // the last xdg_toplevel.configure
    conf_h: i64
    conf_states: u32                     // 1 << XDG_TOPLEVEL_STATE_*
    configured: bool
    wm_fullscreen: bool
    buffers: [WL_BUFFER_CAP]WaylandBuffer
    wheel_v120: [2]i64                   // the wheel in the current wl_pointer.frame
    wheel_cont: [2]i64
    wheel_has120: [2]bool
    wheel_acc: [2]i64
    virt_x: i64                          // locked pointer: the virtual position
    virt_y: i64
    raw_x: f64
    raw_y: f64
    early: EventQueue                    // events received outside poll (in window_open)
    in_poll: bool
    broken: bool                         // the connection failed
}

priv fn wl_win(data: *u8) -> *Window { cast[*Window](data) }

priv fn wl_emit(w: *Window, e: Event) {
    s := w.os.wl
    if s.in_poll {
        push_event(&w.events, e)
        feed(&w.input, e)
    } else {
        push_event(&s.early, e)
    }
}

// A mouse move of the locked pointer: a run of them is kept as one event (the newest).
priv fn wl_emit_motion(w: *Window, e: Event) {
    q := &w.events
    if w.os.wl.in_poll && q.len > 0 {
        last := &q.items[(q.head + q.len - 1) % EVENT_QUEUE_CAP]
        if last.kind == EventMouseMove {
            *last = e
            feed(&w.input, e)
            return
        }
    }
    wl_emit(w, e)
}

priv fn wl_mods(s: *WaylandWindow) -> u8 {
    mods_from_xkb(s.mods_mask, s.mod_shift, s.mod_ctrl, s.mod_alt, s.mod_logo)
}

priv fn wl_flush(s: *WaylandWindow) {
    if s.display != nil && !s.broken {
        wl_client_lib().display_flush(s.display)
    }
}

// The pixel size from the surface size; EventResize when it changed.
priv fn wl_update_size(w: *Window) {
    s := w.os.wl
    pw := s.logical_w * s.scale
    ph := s.logical_h * s.scale
    if pw != w.width || ph != w.height {
        w.width = pw
        w.height = ph
        wl_emit(w, Event{kind: EventResize, x: pw, y: ph})
    }
}

priv fn wl_state(s: *WaylandWindow, state: i64) -> bool { s.conf_states >> u32(state) & 1 != 0 }

// The window follows the compositor's size: resizable, or maximized, fullscreen or tiled.
priv fn wl_follows_size(s: *WaylandWindow) -> bool {
    s.resizable || wl_state(s, XDG_TOPLEVEL_STATE_MAXIMIZED) || wl_state(s, XDG_TOPLEVEL_STATE_FULLSCREEN) ||
        s.conf_states & (u32(0xF) << u32(XDG_TOPLEVEL_STATE_TILED_LEFT)) != 0
}

// The scale the compositor prefers: wl_surface.preferred_buffer_scale, else the largest scale
// of the outputs the window is on.
priv fn wl_update_scale(s: *WaylandWindow) {
    if s.preferred_scale > 0 {
        s.scale_wanted = s.preferred_scale
        return
    }
    scales: [WL_OUTPUT_CAP]i64
    n := 0
    for i in 0..s.output_len {
        if s.outputs[i].entered {
            scales[n] = s.outputs[i].scale
            n += 1
        }
    }
    if n > 0 {
        s.scale_wanted = scale_from_outputs(scales[..n])
    }
}

// A new scale takes effect (only for a window that presents with `present`, which commits
// buffers of the new size itself; a GPU swapchain keeps the scale of window_open): a window
// of its own size keeps its pixel size.
priv fn wl_apply_scale(w: *Window) {
    s := w.os.wl
    if !s.follows_scale || s.scale_wanted == s.scale {
        return
    }
    // (a maximized / fullscreen / tiled window keeps the compositor's size in units: its
    // pixels change; a window of its own size keeps its pixels)
    s.scale = s.scale_wanted
    if !wl_follows_size(s) {
        s.logical_w = surface_size_for_pixels(s.want_w, s.scale)
        s.logical_h = surface_size_for_pixels(s.want_h, s.scale)
        if !s.resizable {
            xdg_toplevel_set_min_size(s.toplevel, i32(s.logical_w), i32(s.logical_h))
            xdg_toplevel_set_max_size(s.toplevel, i32(s.logical_w), i32(s.logical_h))
        }
    }
    wl_update_size(w)
    wl_apply_cursor(w)
}

// ---- event handlers ----

priv fn wl_on_global(data: *u8, registry: *WlRegistry, name: u32, interface: *u8, version: u32) {
    w := wl_win(data)
    s := w.os.wl
    match from_cstr(interface) {
        "wl_compositor" => s.compositor = cast[*WlCompositor](wl_registry_bind(registry, name, wl_client_interface("wl_compositor"), min(version, 6)))
        "wl_shm" => s.shm = cast[*WlShm](wl_registry_bind(registry, name, wl_client_interface("wl_shm"), 1))
        "xdg_wm_base" => {
            s.wm_base = cast[*XdgWmBase](wl_registry_bind(registry, name, xdg_wm_base_interface(), min(version, 6)))
            xdg_wm_base_add_listener(s.wm_base, &wl_wm_base_listener, data)
        }
        "wl_seat" => {
            if s.seat == nil {
                // up to 8: axis_value120; from 10 the compositor would repeat keys itself
                s.seat = cast[*WlSeat](wl_registry_bind(registry, name, wl_client_interface("wl_seat"), min(version, 8)))
                wl_seat_add_listener(s.seat, &wl_seat_listener, data)
            }
        }
        "wl_output" => {
            if s.output_len < WL_OUTPUT_CAP && version >= 2 {
                o := cast[*WlOutput](wl_registry_bind(registry, name, wl_client_interface("wl_output"), min(version, 3)))
                s.outputs[s.output_len] = WaylandOutput{name: name, output: o, scale: 1}
                s.output_len += 1
                wl_output_add_listener(o, &wl_output_listener, data)
            }
        }
        "zxdg_decoration_manager_v1" => s.decoration_manager = cast[*ZxdgDecorationManagerV1](
            wl_registry_bind(registry, name, zxdg_decoration_manager_v1_interface(), 1))
        "zwp_relative_pointer_manager_v1" => s.relative_manager = cast[*ZwpRelativePointerManagerV1](
            wl_registry_bind(registry, name, zwp_relative_pointer_manager_v1_interface(), 1))
        "zwp_pointer_constraints_v1" => s.constraints = cast[*ZwpPointerConstraintsV1](
            wl_registry_bind(registry, name, zwp_pointer_constraints_v1_interface(), 1))
        _ => {}
    }
}

priv fn wl_output_free(o: *WlOutput) {
    if wl_output_get_version(o) >= 3 {
        wl_output_release(o)
    } else {
        wl_output_destroy(o)
    }
}

// An output went away (a monitor unplugged).
priv fn wl_on_global_remove(data: *u8, registry: *WlRegistry, name: u32) {
    s := wl_win(data).os.wl
    for i in 0..s.output_len {
        if s.outputs[i].name == name {
            wl_output_free(s.outputs[i].output)
            s.output_len -= 1
            s.outputs[i] = s.outputs[s.output_len]
            wl_update_scale(s)
            return
        }
    }
}

priv fn wl_on_output_scale(data: *u8, output: *WlOutput, factor: i32) {
    s := wl_win(data).os.wl
    for i in 0..s.output_len {
        if s.outputs[i].output == output {
            s.outputs[i].scale = max(i64(factor), 1)
        }
    }
    wl_update_scale(s)
}

priv fn wl_surface_on_output(data: *u8, output: *WlOutput, entered: bool) {
    s := wl_win(data).os.wl
    for i in 0..s.output_len {
        if s.outputs[i].output == output {
            s.outputs[i].entered = entered
        }
    }
    wl_update_scale(s)
}

priv fn wl_on_surface_enter(data: *u8, surface: *WlSurface, output: *WlOutput) { wl_surface_on_output(data, output, true) }
priv fn wl_on_surface_leave(data: *u8, surface: *WlSurface, output: *WlOutput) { wl_surface_on_output(data, output, false) }

priv fn wl_on_preferred_scale(data: *u8, surface: *WlSurface, factor: i32) {
    s := wl_win(data).os.wl
    s.preferred_scale = max(i64(factor), 1)
    wl_update_scale(s)
}

priv fn wl_on_ping(data: *u8, wm_base: *XdgWmBase, serial: u32) {
    xdg_wm_base_pong(wm_base, serial)
}

priv fn wl_on_toplevel_configure(data: *u8, toplevel: *XdgToplevel, width: i32, height: i32, states: *WlArray) {
    s := wl_win(data).os.wl
    s.conf_w = i64(width)
    s.conf_h = i64(height)
    bits: u32 = 0
    for st in wl_array_u32(states) {
        if st < 32 {
            bits |= u32(1) << st
        }
    }
    s.conf_states = bits
}

// The end of a configure sequence: acknowledge it and take the size and the states. The
// buffer of the new size comes with the next commit (present, or the swapchain).
priv fn wl_on_surface_configure(data: *u8, xdg_surface: *XdgSurface, serial: u32) {
    w := wl_win(data)
    s := w.os.wl
    xdg_surface_ack_configure(xdg_surface, serial)
    follow := wl_follows_size(s)
    lw, lh := size_after_configure(s.conf_w, s.conf_h, follow, s.want_w, s.want_h, s.scale)
    floating := !wl_state(s, XDG_TOPLEVEL_STATE_MAXIMIZED) && !wl_state(s, XDG_TOPLEVEL_STATE_FULLSCREEN) &&
        s.conf_states & (u32(0xF) << u32(XDG_TOPLEVEL_STATE_TILED_LEFT)) == 0
    if s.resizable && floating && s.conf_w > 0 && s.conf_h > 0 {
        // the user resized the window: its own size from now on
        s.want_w = lw * s.scale
        s.want_h = lh * s.scale
    }
    s.logical_w = lw
    s.logical_h = lh
    wl_update_size(w)
    fs := wl_state(s, XDG_TOPLEVEL_STATE_FULLSCREEN)
    // (only a change of the compositor's state overrides what set_fullscreen asked for)
    if fs != s.wm_fullscreen {
        s.wm_fullscreen = fs
        w.fullscreen = fs
    }
    suspended := wl_state(s, XDG_TOPLEVEL_STATE_SUSPENDED)
    if suspended != w.minimized {
        w.minimized = suspended
        wl_emit(w, Event{kind: if suspended { EventMinimize } else { EventRestore }})
    }
    s.configured = true
}

priv fn wl_on_close(data: *u8, toplevel: *XdgToplevel) {
    w := wl_win(data)
    w.closing = true
    wl_emit(w, Event{kind: EventClose})
}

priv fn wl_on_seat_capabilities(data: *u8, seat: *WlSeat, caps: u32) {
    w := wl_win(data)
    s := w.os.wl
    if caps & WL_SEAT_CAPABILITY_POINTER != 0 && s.pointer == nil {
        s.pointer = wl_seat_get_pointer(seat)
        wl_pointer_add_listener(s.pointer, &wl_pointer_listener, data)
        if w.cursor_locked {
            wl_lock_start(w)
        }
    } else if caps & WL_SEAT_CAPABILITY_POINTER == 0 && s.pointer != nil {
        wl_lock_stop(s)
        if wl_pointer_get_version(s.pointer) >= 3 {
            wl_pointer_release(s.pointer)
        } else {
            wl_pointer_destroy(s.pointer)
        }
        s.pointer = nil
        s.pointer_in = false
    }
    if caps & WL_SEAT_CAPABILITY_KEYBOARD != 0 && s.keyboard == nil {
        s.keyboard = wl_seat_get_keyboard(seat)
        wl_keyboard_add_listener(s.keyboard, &wl_keyboard_listener, data)
    } else if caps & WL_SEAT_CAPABILITY_KEYBOARD == 0 && s.keyboard != nil {
        if wl_keyboard_get_version(s.keyboard) >= 3 {
            wl_keyboard_release(s.keyboard)
        } else {
            wl_keyboard_destroy(s.keyboard)
        }
        s.keyboard = nil
        s.repeat_key = 0
    }
}

// ---- pointer ----

// Shows the theme's arrow, or nothing while the cursor is hidden or locked.
priv fn wl_apply_cursor(w: *Window) {
    s := w.os.wl
    if s.pointer == nil || !s.pointer_in {
        return
    }
    if w.cursor_hidden || w.cursor_locked {
        wl_pointer_set_cursor(s.pointer, s.enter_serial, nil, 0, 0)
        return
    }
    if s.cursor_surface == nil {
        return                     // no libwayland-cursor: the compositor's choice of image
    }
    if s.cursor_theme == nil || s.cursor_theme_scale != s.scale {
        if s.cursor_theme != nil {
            cursor.theme_destroy(s.cursor_theme)
        }
        m := mark()
        size := 24
        text, ok := env_get("XCURSOR_SIZE")
        if ok {
            n, good := parse_i64(text)
            if good && n > 0 && n <= 256 {
                size = n
            }
        }
        name, named := env_get("XCURSOR_THEME")
        s.cursor_theme = cursor.theme_load(if named && name != "" { cstr(name) } else { nil }, i32(size * s.scale), s.shm)
        release(m)
        s.cursor_theme_scale = s.scale
    }
    if s.cursor_theme == nil {
        return
    }
    c := cursor.theme_get_cursor(s.cursor_theme, ptr("left_ptr"))
    if c == nil {
        c = cursor.theme_get_cursor(s.cursor_theme, ptr("default"))
    }
    if c == nil || c.image_count == 0 {
        return
    }
    image := c.images[0]
    scale := s.scale
    if i64(image.width) % scale != 0 || i64(image.height) % scale != 0 {
        scale = 1
    }
    wl_surface_set_buffer_scale(s.cursor_surface, i32(scale))
    wl_surface_attach(s.cursor_surface, cursor.image_get_buffer(image), 0, 0)
    wl_surface_damage_buffer(s.cursor_surface, 0, 0, i32(image.width), i32(image.height))
    wl_surface_commit(s.cursor_surface)
    wl_pointer_set_cursor(s.pointer, s.enter_serial, s.cursor_surface, i32(i64(image.hotspot_x) / scale), i32(i64(image.hotspot_y) / scale))
}

// The pointer at (x, y) (wl_fixed_t surface units): a mouse move, or with a locked pointer
// that has no lock of the compositor, the motion of the pointer moves the virtual position.
priv fn wl_pointer_to(w: *Window, x: i32, y: i32) {
    s := w.os.wl
    s.pointer_x = x
    s.pointer_y = y
    px := pixels_from_wl_fixed(x, s.scale)
    py := pixels_from_wl_fixed(y, s.scale)
    dx := px - s.last_px
    dy := py - s.last_py
    s.last_px = px
    s.last_py = py
    if !w.cursor_locked {
        wl_emit(w, Event{kind: EventMouseMove, x: px, y: py})
    } else if s.locked == nil && w.input.focused && (dx != 0 || dy != 0) {
        s.virt_x += dx
        s.virt_y += dy
        wl_emit(w, Event{kind: EventMouseMove, x: s.virt_x, y: s.virt_y})
    }
}

priv fn wl_on_pointer_enter(data: *u8, pointer: *WlPointer, serial: u32, surface: *WlSurface, x: i32, y: i32) {
    w := wl_win(data)
    s := w.os.wl
    if surface != s.surface {
        return
    }
    s.enter_serial = serial
    s.pointer_in = true
    wl_apply_cursor(w)
    s.last_px = pixels_from_wl_fixed(x, s.scale)
    s.last_py = pixels_from_wl_fixed(y, s.scale)
    wl_pointer_to(w, x, y)
}

priv fn wl_on_pointer_leave(data: *u8, pointer: *WlPointer, serial: u32, surface: *WlSurface) {
    s := wl_win(data).os.wl
    if surface == s.surface {
        s.pointer_in = false
    }
}

priv fn wl_on_pointer_motion(data: *u8, pointer: *WlPointer, time: u32, x: i32, y: i32) {
    w := wl_win(data)
    if w.os.wl.pointer_in {
        wl_pointer_to(w, x, y)
    }
}

priv fn wl_on_pointer_button(data: *u8, pointer: *WlPointer, serial: u32, time: u32, button: u32, state: u32) {
    w := wl_win(data)
    s := w.os.wl
    x := pixels_from_wl_fixed(s.pointer_x, s.scale)
    y := pixels_from_wl_fixed(s.pointer_y, s.scale)
    if w.cursor_locked {
        x = s.virt_x
        y = s.virt_y
    }
    e := event_from_wl_button(button, state == WL_POINTER_BUTTON_STATE_PRESSED, x, y, wl_mods(s))
    if e.kind != EventNone {
        wl_emit(w, e)
    }
}

// The wheel of a frame (or of one axis event without frames): one EventWheel.
priv fn wl_wheel_flush(w: *Window) {
    s := w.os.wl
    steps: [2]i64
    for a in 0..2 {
        v := if s.wheel_has120[a] { s.wheel_v120[a] } else { s.wheel_cont[a] * 12 / 256 }   // as wheel_v120_from_axis
        if v != 0 {
            steps[a] = wheel_steps(&s.wheel_acc[a], v)
        }
        s.wheel_v120[a] = 0
        s.wheel_cont[a] = 0
        s.wheel_has120[a] = false
    }
    // Wayland: positive is down / right; EventWheel: y > 0 away from the user
    if steps[0] != 0 || steps[1] != 0 {
        wl_emit(w, Event{kind: EventWheel, x: steps[1], y: -steps[0], mods: wl_mods(s)})
    }
}

priv fn wl_on_pointer_axis(data: *u8, pointer: *WlPointer, time: u32, axis: u32, value: i32) {
    w := wl_win(data)
    s := w.os.wl
    if axis > 1 {
        return
    }
    s.wheel_cont[axis] += i64(value)
    if wl_pointer_get_version(pointer) < 5 {
        wl_wheel_flush(w)                   // no frame events
    }
}

priv fn wl_on_pointer_frame(data: *u8, pointer: *WlPointer) {
    wl_wheel_flush(wl_win(data))
}

priv fn wl_on_axis_discrete(data: *u8, pointer: *WlPointer, axis: u32, discrete: i32) {
    s := wl_win(data).os.wl
    if axis <= 1 {
        s.wheel_v120[axis] += i64(discrete) * 120
        s.wheel_has120[axis] = true
    }
}

priv fn wl_on_axis_value120(data: *u8, pointer: *WlPointer, axis: u32, value120: i32) {
    s := wl_win(data).os.wl
    if axis <= 1 {
        s.wheel_v120[axis] += i64(value120)
        s.wheel_has120[axis] = true
    }
}

// Unaccelerated relative motion moves the virtual position of a locked pointer (counts of the
// device, as libinput reports them; fractions accumulate).
priv fn wl_on_relative_motion(data: *u8, relative: *ZwpRelativePointerV1, utime_hi: u32, utime_lo: u32,
    dx: i32, dy: i32, dx_unaccel: i32, dy_unaccel: i32) {
    w := wl_win(data)
    s := w.os.wl
    if !w.cursor_locked || !s.lock_active || !w.input.focused {
        return
    }
    s.raw_x += wl_fixed_to_double(dx_unaccel)
    s.raw_y += wl_fixed_to_double(dy_unaccel)
    x := i64(floor(s.raw_x))
    y := i64(floor(s.raw_y))
    if x == s.virt_x && y == s.virt_y {
        return
    }
    s.virt_x = x
    s.virt_y = y
    wl_emit_motion(w, Event{kind: EventMouseMove, x: x, y: y})
}

priv fn wl_on_locked(data: *u8, locked: *ZwpLockedPointerV1) { wl_win(data).os.wl.lock_active = true }
priv fn wl_on_unlocked(data: *u8, locked: *ZwpLockedPointerV1) { wl_win(data).os.wl.lock_active = false }

// Locks the pointer with pointer-constraints and reads relative-pointer motion, where the
// compositor has both protocols (else the motion of the pointer moves the virtual position).
priv fn wl_lock_start(w: *Window) {
    s := w.os.wl
    if s.pointer == nil || s.constraints == nil || s.relative_manager == nil || s.locked != nil {
        return
    }
    data := cast[*u8](w)
    s.relative = zwp_relative_pointer_manager_v1_get_relative_pointer(s.relative_manager, s.pointer)
    zwp_relative_pointer_v1_add_listener(s.relative, &wl_relative_listener, data)
    s.locked = zwp_pointer_constraints_v1_lock_pointer(s.constraints, s.surface, s.pointer, nil,
        ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT)
    zwp_locked_pointer_v1_add_listener(s.locked, &wl_locked_listener, data)
}

priv fn wl_lock_stop(s: *WaylandWindow) {
    if s.locked != nil {
        zwp_locked_pointer_v1_destroy(s.locked)
        s.locked = nil
    }
    if s.relative != nil {
        zwp_relative_pointer_v1_destroy(s.relative)
        s.relative = nil
    }
    s.lock_active = false
}

// ---- keyboard ----

priv fn wl_utf8_next(buf: []u8, pos: *i64) -> u32 {
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

priv fn wl_free_keymap(s: *WaylandWindow) {
    if s.xkb_state != nil {
        xkb.state_unref(s.xkb_state)
        s.xkb_state = nil
    }
    if s.keymap != nil {
        xkb.keymap_unref(s.keymap)
        s.keymap = nil
    }
}

// The locale for compose sequences: $LC_ALL, $LC_CTYPE, $LANG, else "C" (a C string; call
// between mark and release).
priv fn wl_locale() -> *u8 {
    for name in [3]str{"LC_ALL", "LC_CTYPE", "LANG"} {
        v, ok := env_get(name)
        if ok && v != "" {
            return cstr(v)
        }
    }
    ptr("C")
}

priv fn wl_on_keymap(data: *u8, keyboard: *WlKeyboard, format: u32, fd: i32, size: u32) {
    s := wl_win(data).os.wl
    if format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 || s.xkb == nil {
        syscall(3, i64(fd))
        return
    }
    // mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0): the keymap text, NUL-terminated
    addr := syscall(9, 0, i64(size), 1, 2, i64(fd), 0)
    syscall(3, i64(fd))
    if addr < 0 && addr > -4096 {
        return
    }
    keymap := xkb.keymap_new_from_string(s.xkb, cast[*u8](addr), XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS)
    syscall(11, addr, i64(size))
    if keymap == nil {
        return
    }
    wl_free_keymap(s)
    s.keymap = keymap
    s.xkb_state = xkb.state_new(keymap)
    s.mod_shift = xkb.keymap_mod_get_index(keymap, ptr(XKB_MOD_NAME_SHIFT))
    s.mod_ctrl = xkb.keymap_mod_get_index(keymap, ptr(XKB_MOD_NAME_CTRL))
    s.mod_alt = xkb.keymap_mod_get_index(keymap, ptr(XKB_MOD_NAME_ALT))
    s.mod_logo = xkb.keymap_mod_get_index(keymap, ptr(XKB_MOD_NAME_LOGO))
    s.mods_mask = 0
    s.repeat_key = 0
    if xkb.compose && s.compose_table == nil {
        m := mark()
        s.compose_table = xkb.compose_table_new_from_locale(s.xkb, wl_locale(), 0)
        release(m)
        if s.compose_table != nil {
            s.compose_state = xkb.compose_state_new(s.compose_table, 0)
        }
    }
}

// KEY_* of a key: the unshifted symbol (level 0) of the key in the active layout, or in the
// first layout if that one has no key code for it (W, A, S, D of a Latin layout while a
// Cyrillic one is active).
priv fn wl_key_code(s: *WaylandWindow, code: u32) -> i64 {
    layout := xkb.state_key_get_layout(s.xkb_state, code)
    for l in [2]u32{layout, 0} {
        if l == XKB_LAYOUT_INVALID {
            continue
        }
        syms: *u32 = nil
        if xkb.keymap_key_get_syms_by_level(s.keymap, code, l, 0, &syms) > 0 && syms != nil {
            k := key_from_keysym(u64(syms[0]))
            if k != KEY_UNKNOWN {
                return k
            }
        }
        if l == 0 {
            break
        }
    }
    KEY_UNKNOWN
}

// A key press (xkb key code), or an auto-repeat of it: the key event, then its text (after
// compose sequences and dead keys; no control characters).
priv fn wl_key_press(w: *Window, code: u32, repeat: bool) {
    s := w.os.wl
    key := wl_key_code(s, code)
    mods := wl_mods(s)
    rep := repeat || (s.in_poll && key_down(&w.input, key))
    wl_emit(w, Event{kind: EventKeyDown, key: key, mods: mods, repeat: rep})
    buf: [64]u8
    n := 0
    composed := false
    if s.compose_state != nil {
        sym := xkb.state_key_get_one_sym(s.xkb_state, code)
        if xkb.compose_state_feed(s.compose_state, sym) == XKB_COMPOSE_FEED_ACCEPTED {
            match xkb.compose_state_get_status(s.compose_state) {
                XKB_COMPOSE_COMPOSING => composed = true
                XKB_COMPOSE_COMPOSED => {
                    n = i64(xkb.compose_state_get_utf8(s.compose_state, ptr(buf), 64))
                    xkb.compose_state_reset(s.compose_state)
                    composed = true
                }
                XKB_COMPOSE_CANCELLED => {
                    xkb.compose_state_reset(s.compose_state)
                    composed = true
                }
                _ => {}
            }
        }
    }
    if !composed {
        n = i64(xkb.state_key_get_utf8(s.xkb_state, code, ptr(buf), 64))
    }
    n = min(max(n, 0), 63)
    pos := 0
    while pos < n {
        c := wl_utf8_next(buf[..n], &pos)
        if c >= 0x20 && c != 0x7F {
            wl_emit(w, Event{kind: EventText, codepoint: c, mods: mods})
        }
    }
}

priv fn wl_on_key(data: *u8, keyboard: *WlKeyboard, serial: u32, time: u32, key: u32, state: u32) {
    w := wl_win(data)
    s := w.os.wl
    if s.xkb_state == nil {
        return
    }
    code := key + 8                                          // evdev code -> xkb key code
    if state == WL_KEYBOARD_KEY_STATE_PRESSED {
        wl_key_press(w, code, false)
        if xkb.keymap_key_repeats(s.keymap, code) != 0 {
            s.repeat_key = code
            s.repeat_since = clock_ns()
            s.repeat_sent = 0
        }
        return
    }
    if s.repeat_key == code {
        s.repeat_key = 0
    }
    wl_emit(w, Event{kind: EventKeyUp, key: wl_key_code(s, code), mods: wl_mods(s)})
}

priv fn wl_on_modifiers(data: *u8, keyboard: *WlKeyboard, serial: u32, depressed: u32, latched: u32, locked: u32, group: u32) {
    s := wl_win(data).os.wl
    if s.xkb_state != nil {
        xkb.state_update_mask(s.xkb_state, depressed, latched, locked, 0, 0, group)
    }
    s.mods_mask = depressed | latched | locked
}

priv fn wl_on_repeat_info(data: *u8, keyboard: *WlKeyboard, rate: i32, delay: i32) {
    s := wl_win(data).os.wl
    s.repeat_rate = i64(rate)
    s.repeat_delay = i64(delay)
}

priv fn wl_on_keyboard_enter(data: *u8, keyboard: *WlKeyboard, serial: u32, surface: *WlSurface, keys: *WlArray) {
    wl_emit(wl_win(data), Event{kind: EventFocus})
}

priv fn wl_on_keyboard_leave(data: *u8, keyboard: *WlKeyboard, serial: u32, surface: *WlSurface) {
    w := wl_win(data)
    s := w.os.wl
    s.repeat_key = 0
    if s.compose_state != nil {
        xkb.compose_state_reset(s.compose_state)
    }
    wl_emit(w, Event{kind: EventUnfocus})
}

priv fn wl_on_buffer_release(data: *u8, buffer: *WlBuffer) {
    cast[*WaylandBuffer](data).busy = false
}

// Listeners must stay in place as long as their objects: globals. They are filled by
// wl_listeners_init (from wayland_window_open), not by initializers: a global's initializer is
// compiled into every program that includes std.window, and with it every handler, so a
// program that never opens a window would carry the whole backend (and --target linux-arm64,
// which refuses this module's x86-64 system calls, could not build it).
priv wl_registry_listener: WlRegistryListener
priv wl_output_listener: WlOutputListener
priv wl_wm_base_listener: XdgWmBaseListener
priv wl_surface_listener: WlSurfaceListener
priv wl_xdg_surface_listener: XdgSurfaceListener
priv wl_toplevel_listener: XdgToplevelListener
priv wl_seat_listener: WlSeatListener
priv wl_pointer_listener: WlPointerListener
priv wl_keyboard_listener: WlKeyboardListener
priv wl_relative_listener: ZwpRelativePointerV1Listener
priv wl_locked_listener: ZwpLockedPointerV1Listener
priv wl_buffer_listener: WlBufferListener

priv fn wl_listeners_init() {
    wl_registry_listener = WlRegistryListener{global: wl_on_global, global_remove: wl_on_global_remove}
    wl_output_listener = WlOutputListener{scale: wl_on_output_scale}
    wl_wm_base_listener = XdgWmBaseListener{ping: wl_on_ping}
    wl_surface_listener = WlSurfaceListener{enter: wl_on_surface_enter, leave: wl_on_surface_leave,
        preferred_buffer_scale: wl_on_preferred_scale}
    wl_xdg_surface_listener = XdgSurfaceListener{configure: wl_on_surface_configure}
    wl_toplevel_listener = XdgToplevelListener{configure: wl_on_toplevel_configure, close: wl_on_close}
    wl_seat_listener = WlSeatListener{capabilities: wl_on_seat_capabilities}
    wl_pointer_listener = WlPointerListener{enter: wl_on_pointer_enter, leave: wl_on_pointer_leave,
        motion: wl_on_pointer_motion, button: wl_on_pointer_button, axis: wl_on_pointer_axis, frame: wl_on_pointer_frame,
        axis_discrete: wl_on_axis_discrete, axis_value120: wl_on_axis_value120}
    wl_keyboard_listener = WlKeyboardListener{keymap: wl_on_keymap, enter: wl_on_keyboard_enter,
        leave: wl_on_keyboard_leave, key: wl_on_key, modifiers: wl_on_modifiers, repeat_info: wl_on_repeat_info}
    wl_relative_listener = ZwpRelativePointerV1Listener{relative_motion: wl_on_relative_motion}
    wl_locked_listener = ZwpLockedPointerV1Listener{locked: wl_on_locked, unlocked: wl_on_unlocked}
    wl_buffer_listener = WlBufferListener{release: wl_on_buffer_release}
}

// ---- shm buffers ----

priv fn wl_buffer_free(b: *WaylandBuffer) {
    if b.buffer != nil {
        wl_buffer_destroy(b.buffer)
        syscall(11, cast[i64](ptr(b.pixels)), b.width * b.height * 4)    // munmap
    }
    *b = WaylandBuffer{}
}

// A buffer of width x height pixels in a memfd shared with the compositor (zero: black).
priv fn wl_buffer_make(s: *WaylandWindow, b: *WaylandBuffer, width: i64, height: i64) -> bool {
    size := width * height * 4
    if size <= 0 || size > 0x7FFFFFFF {
        return false
    }
    fd := syscall(319, ptr("al-window"), 1)                   // memfd_create, MFD_CLOEXEC
    if fd < 0 {
        return false
    }
    if syscall(77, fd, size) < 0 {                            // ftruncate
        syscall(3, fd)
        return false
    }
    addr := syscall(9, 0, size, 3, 1, fd, 0)                   // mmap PROT_READ|WRITE, MAP_SHARED
    if addr < 0 && addr > -4096 {
        syscall(3, fd)
        return false
    }
    pool := wl_shm_create_pool(s.shm, i32(fd), i32(size))
    b.buffer = wl_shm_pool_create_buffer(pool, 0, i32(width), i32(height), i32(width * 4), WL_SHM_FORMAT_XRGB8888)
    wl_shm_pool_destroy(pool)                                 // the buffer keeps the memory
    syscall(3, fd)
    b.pixels = mkslice[u32](cast[*u32](addr), width * height)
    b.width = width
    b.height = height
    b.busy = false
    wl_buffer_add_listener(b.buffer, &wl_buffer_listener, cast[*u8](b))
    true
}

// A free buffer of the window's size (made or remade as needed); nil if all are held by the
// compositor or none can be made.
priv fn wl_free_buffer(w: *Window) -> *WaylandBuffer {
    s := w.os.wl
    for i in 0..WL_BUFFER_CAP {
        b := &s.buffers[i]
        if !b.busy && b.buffer != nil && b.width == w.width && b.height == w.height {
            return b
        }
    }
    for i in 0..WL_BUFFER_CAP {
        b := &s.buffers[i]
        if !b.busy {
            wl_buffer_free(b)
            if wl_buffer_make(s, b, w.width, w.height) {
                return b
            }
            return nil
        }
    }
    nil
}

priv fn wl_commit_buffer(w: *Window, b: *WaylandBuffer) {
    s := w.os.wl
    if s.committed_scale != s.scale {
        wl_surface_set_buffer_scale(s.surface, i32(s.scale))
        s.committed_scale = s.scale
    }
    wl_surface_attach(s.surface, b.buffer, 0, 0)
    wl_surface_damage_buffer(s.surface, 0, 0, i32(b.width), i32(b.height))
    wl_surface_commit(s.surface)
    b.busy = true
    wl_flush(s)
}

// ---- the public calls on a Wayland window (from std/window_linux.al) ----

// Everything the window holds, children before parents, then the connection.
priv fn wl_teardown(w: *Window) {
    s := w.os.wl
    for i in 0..WL_BUFFER_CAP {
        wl_buffer_free(&s.buffers[i])
    }
    wl_lock_stop(s)
    if s.cursor_theme != nil {
        cursor.theme_destroy(s.cursor_theme)
        s.cursor_theme = nil
    }
    if s.cursor_surface != nil {
        wl_surface_destroy(s.cursor_surface)
    }
    if s.decoration != nil {
        zxdg_toplevel_decoration_v1_destroy(s.decoration)
    }
    if s.toplevel != nil {
        xdg_toplevel_destroy(s.toplevel)
    }
    if s.xdg_surface != nil {
        xdg_surface_destroy(s.xdg_surface)
    }
    if s.surface != nil {
        wl_surface_destroy(s.surface)
    }
    if s.pointer != nil {
        if wl_pointer_get_version(s.pointer) >= 3 { wl_pointer_release(s.pointer) } else { wl_pointer_destroy(s.pointer) }
    }
    if s.keyboard != nil {
        if wl_keyboard_get_version(s.keyboard) >= 3 { wl_keyboard_release(s.keyboard) } else { wl_keyboard_destroy(s.keyboard) }
    }
    if s.seat != nil {
        if wl_seat_get_version(s.seat) >= 5 { wl_seat_release(s.seat) } else { wl_seat_destroy(s.seat) }
    }
    for i in 0..s.output_len {
        wl_output_free(s.outputs[i].output)
    }
    if s.relative_manager != nil {
        zwp_relative_pointer_manager_v1_destroy(s.relative_manager)
    }
    if s.constraints != nil {
        zwp_pointer_constraints_v1_destroy(s.constraints)
    }
    if s.decoration_manager != nil {
        zxdg_decoration_manager_v1_destroy(s.decoration_manager)
    }
    if s.wm_base != nil {
        xdg_wm_base_destroy(s.wm_base)
    }
    if s.shm != nil {
        wl_shm_destroy(s.shm)
    }
    if s.compositor != nil {
        wl_compositor_destroy(s.compositor)
    }
    if s.registry != nil {
        wl_registry_destroy(s.registry)
    }
    if s.compose_state != nil {
        xkb.compose_state_unref(s.compose_state)
    }
    if s.compose_table != nil {
        xkb.compose_table_unref(s.compose_table)
    }
    wl_free_keymap(s)
    if s.xkb != nil {
        xkb.context_unref(s.xkb)
    }
    wl_client_lib().display_disconnect(s.display)
    early := s.early
    *s = WaylandWindow{}
    s.early = early
}

// The name of the program (for xdg_toplevel.set_app_id): the file name of args()[0].
priv fn wl_app_id() -> str {
    a := args()
    if a.len == 0 || a[0] == "" {
        return "al"
    }
    p := a[0]
    return p[rfind(p, "/") + 1..]
}

// Opens a window on the Wayland display `name` ("": $WAYLAND_DISPLAY); (nil, false) if the
// libraries are missing, the display cannot be reached or lacks wl_compositor 4, wl_shm or
// xdg_wm_base, or the window gets no configure.
fn wayland_window_open(d: WindowDesc, name: str) -> (*Window, bool) {
    lib := wl_client_lib()
    if lib == nil || !wl_xkb_load() {
        return (nil, false)
    }
    wl_listeners_init()
    top := mark()
    cname: *u8 = nil
    if name != "" {
        cname = cstr(name)
    }
    display := lib.display_connect(cname)
    release(top)
    if display == nil {
        return (nil, false)
    }
    w := new[Window]()
    s := new[WaylandWindow]()
    w.os.wl = s
    s.display = display
    data := cast[*u8](w)
    s.xkb = xkb.context_new(XKB_CONTEXT_NO_FLAGS)
    s.registry = wl_display_get_registry(display)
    wl_registry_add_listener(s.registry, &wl_registry_listener, data)
    // the globals, then their first events (output scales, seat capabilities)
    ok := lib.display_roundtrip(display) >= 0 && lib.display_roundtrip(display) >= 0
    if !ok || s.compositor == nil || wl_compositor_get_version(s.compositor) < 4 || s.shm == nil || s.wm_base == nil {
        wl_teardown(w)
        release(top)
        return (nil, false)
    }
    scales: [WL_OUTPUT_CAP]i64
    for i in 0..s.output_len {
        scales[i] = s.outputs[i].scale
    }
    s.scale = scale_from_outputs(scales[..s.output_len])
    s.scale_wanted = s.scale
    s.committed_scale = s.scale
    s.resizable = d.resizable
    s.want_w = if d.width > 0 { d.width } else { 640 }
    s.want_h = if d.height > 0 { d.height } else { 480 }
    s.logical_w = surface_size_for_pixels(s.want_w, s.scale)
    s.logical_h = surface_size_for_pixels(s.want_h, s.scale)
    w.width = s.logical_w * s.scale
    w.height = s.logical_h * s.scale
    s.surface = wl_compositor_create_surface(s.compositor)
    wl_surface_add_listener(s.surface, &wl_surface_listener, data)
    wl_surface_set_buffer_scale(s.surface, i32(s.scale))
    if wl_cursor_load() {
        s.cursor_surface = wl_compositor_create_surface(s.compositor)
    }
    s.xdg_surface = xdg_wm_base_get_xdg_surface(s.wm_base, s.surface)
    xdg_surface_add_listener(s.xdg_surface, &wl_xdg_surface_listener, data)
    s.toplevel = xdg_surface_get_toplevel(s.xdg_surface)
    xdg_toplevel_add_listener(s.toplevel, &wl_toplevel_listener, data)
    xdg_toplevel_set_app_id(s.toplevel, wl_app_id())
    xdg_toplevel_set_title(s.toplevel, d.title)
    if !d.resizable {
        xdg_toplevel_set_min_size(s.toplevel, i32(s.logical_w), i32(s.logical_h))
        xdg_toplevel_set_max_size(s.toplevel, i32(s.logical_w), i32(s.logical_h))
    }
    if d.fullscreen {
        xdg_toplevel_set_fullscreen(s.toplevel, nil)
        w.fullscreen = true
        s.wm_fullscreen = true
    }
    if s.decoration_manager != nil {
        s.decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(s.decoration_manager, s.toplevel)
        zxdg_toplevel_decoration_v1_set_mode(s.decoration, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE)
    }
    wl_surface_commit(s.surface)                               // no buffer: asks for the first configure
    for i in 0..20 {
        if s.configured || lib.display_roundtrip(display) < 0 {
            break
        }
    }
    if !s.configured {
        wl_teardown(w)
        release(top)
        return (nil, false)
    }
    // map the window with a black buffer, as an X11 window shows its background
    b := wl_free_buffer(w)
    if b != nil {
        wl_commit_buffer(w, b)
    }
    wl_flush(s)
    (w, true)
}

fn wayland_poll(w: *Window) {
    s := w.os.wl
    if s == nil {
        return
    }
    // what arrived outside poll (while window_open waited for the compositor)
    loop {
        e, more := next_event(&s.early)
        if !more {
            break
        }
        push_event(&w.events, e)
        feed(&w.input, e)
    }
    if s.display == nil || s.broken {
        return
    }
    s.in_poll = true
    defer { s.in_poll = false }
    lib := wl_client_lib()
    d := s.display
    // read what has arrived, never wait (a fast mouse fills more than one read)
    for round in 0..64 {
        // events already queued are dispatched first; prepare_read succeeds once there are none
        prepared := false
        for k in 0..64 {
            if lib.display_prepare_read(d) == 0 {
                prepared = true
                break
            }
            if lib.display_dispatch_pending(d) < 0 {
                break
            }
        }
        if !prepared {
            break
        }
        lib.display_flush(d)
        pfd := [2]i32{lib.display_get_fd(d), 1}               // struct pollfd, POLLIN
        ready := 0
        loop {
            ready = syscall(7, ptr(pfd), 1, 0)
            if ready != -4 {
                break
            }
        }
        if ready <= 0 {
            lib.display_cancel_read(d)
            break
        }
        if lib.display_read_events(d) < 0 || lib.display_dispatch_pending(d) < 0 {
            break
        }
    }
    lib.display_dispatch_pending(d)
    if lib.display_get_error(d) != 0 {
        // the compositor is gone or ended the connection
        s.broken = true
        w.closing = true
        return
    }
    wl_apply_scale(w)
    if s.repeat_key != 0 && w.input.focused && s.xkb_state != nil {
        n := repeats_due(clock_ns(), s.repeat_since, s.repeat_delay, s.repeat_rate, s.repeat_sent)
        s.repeat_sent += n
        for i in 0..min(n, WL_REPEAT_BURST) {
            wl_key_press(w, s.repeat_key, true)
        }
    }
    lib.display_flush(d)
}

fn wayland_set_title(w: *Window, title: str) {
    s := w.os.wl
    if s == nil || s.display == nil {
        return
    }
    xdg_toplevel_set_title(s.toplevel, title)
    wl_flush(s)
}

fn wayland_set_cursor_visible(w: *Window, visible: bool) {
    s := w.os.wl
    if s == nil || s.display == nil || visible != w.cursor_hidden {
        return
    }
    w.cursor_hidden = !visible
    wl_apply_cursor(w)
    wl_flush(s)
}

fn wayland_set_cursor_locked(w: *Window, locked: bool) {
    s := w.os.wl
    if s == nil || s.display == nil || locked == w.cursor_locked {
        return
    }
    w.cursor_locked = locked
    px := pixels_from_wl_fixed(s.pointer_x, s.scale)
    py := pixels_from_wl_fixed(s.pointer_y, s.scale)
    if locked {
        // the virtual position starts at the real one (also the first motion counts in mouse_delta)
        s.virt_x = px
        s.virt_y = py
        s.raw_x = f64(px)
        s.raw_y = f64(py)
        s.last_px = px
        s.last_py = py
        w.input.mouse_x = f32(px)
        w.input.mouse_y = f32(py)
        w.input.mouse_seen = true
        wl_lock_start(w)
    } else {
        // a locked pointer has not moved: it is where it was; continue from there
        wl_lock_stop(s)
        w.input.mouse_x = f32(px)
        w.input.mouse_y = f32(py)
    }
    wl_apply_cursor(w)
    wl_flush(s)
}

fn wayland_set_fullscreen(w: *Window, on: bool) {
    s := w.os.wl
    if s == nil || s.display == nil || on == w.fullscreen {
        return
    }
    if on {
        xdg_toplevel_set_fullscreen(s.toplevel, nil)
    } else {
        xdg_toplevel_unset_fullscreen(s.toplevel)
    }
    wl_flush(s)
    w.fullscreen = on
}

fn wayland_present(w: *Window, pixels: []u8, pw: i64, ph: i64) -> bool {
    s := w.os.wl
    if s == nil || s.display == nil || s.broken || w.width <= 0 || w.height <= 0 {
        return false
    }
    s.follows_scale = true
    b := wl_free_buffer(w)
    if b == nil {
        return true                // every buffer is still on screen: this frame is dropped
    }
    blit_fit(b.pixels, b.width, b.height, pixels, pw, ph, true)
    wl_commit_buffer(w, b)
    true
}

fn wayland_close(w: *Window) {
    w.closing = true
    s := w.os.wl
    if s == nil || s.display == nil {
        return
    }
    wl_teardown(w)
}

// The `wl_display*` of a window on Wayland (for VkWaylandSurfaceCreateInfoKHR.display, and
// std.wayland); nil for an X11 window and after close.
fn wayland_display(w: *Window) -> *u8 {
    if w.os.wl == nil { nil } else { cast[*u8](w.os.wl.display) }
}

// The `wl_surface*` of a window on Wayland (for VkWaylandSurfaceCreateInfoKHR.surface); nil
// for an X11 window and after close.
fn wayland_surface(w: *Window) -> *u8 {
    if w.os.wl == nil { nil } else { cast[*u8](w.os.wl.surface) }
}
