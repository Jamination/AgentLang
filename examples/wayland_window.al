// A window that talks to the Wayland compositor directly, with std.wayland (and std.os for the
// shared memory of the buffers): an xdg_toplevel showing a test pattern from wl_shm buffers,
// server-side decorations where the compositor offers them, keyboard (xkbcommon), pointer with
// a themed cursor, resize, fullscreen.
// Every input event is printed. Escape or the compositor's close action quits; F toggles
// fullscreen, M maximized, H hides / shows the pointer.
//
// It connects to $WAYLAND_DISPLAY like any client: `WAYLAND_DISPLAY=<socket> ./examples/wayland_window`.
// The test pattern: red top left, green top right, blue bottom left, white bottom right, a grey
// ramp along the top edge (black at the left), a yellow cross at the pointer.
use std.wayland
use std.os

struct Buffer {
    buffer: *WlBuffer
    pixels: []u32           // WL_SHM_FORMAT_XRGB8888: one u32 0x00RRGGBB per pixel
    width: i64
    height: i64
    busy: bool              // attached and not yet released by the compositor
}

struct App {
    display: *WlDisplay
    compositor: *WlCompositor
    shm: *WlShm
    wm_base: *XdgWmBase
    seat: *WlSeat
    decoration_manager: *ZxdgDecorationManagerV1
    surface: *WlSurface
    xdg_surface: *XdgSurface
    toplevel: *XdgToplevel
    decoration: *ZxdgToplevelDecorationV1
    pointer: *WlPointer
    keyboard: *WlKeyboard
    cursor_theme: *WlCursorTheme
    cursor_surface: *WlSurface
    xkb: *XkbContext
    keymap: *XkbKeymap
    xkb_state: *XkbState
    buffers: [2]Buffer
    width: i64              // the size the window is drawn at
    height: i64
    pending_w: i64          // what the last xdg_toplevel.configure proposed (0: our choice)
    pending_h: i64
    fullscreen: bool
    maximized: bool
    configured: bool
    dirty: bool
    running: bool
    cursor_hidden: bool
    enter_serial: u32       // of the last wl_pointer.enter, for set_cursor
    mouse_x: f64
    mouse_y: f64
}

app: App

// ---- shm buffers ----

fn buffer_create(b: *Buffer, width: i64, height: i64) -> bool {
    size := width * height * 4
    fd, ok := shm_create(size)
    if !ok {
        return false
    }
    mem, mapped := map_shared(fd, size)
    if !mapped {
        close_fd(fd)
        return false
    }
    pool := wl_shm_create_pool(app.shm, i32(fd), i32(size))
    b.buffer = wl_shm_pool_create_buffer(pool, 0, i32(width), i32(height), i32(width * 4), WL_SHM_FORMAT_XRGB8888)
    wl_shm_pool_destroy(pool)                           // the buffer keeps the memory alive
    close_fd(fd)                                        // the compositor has its own copy
    b.pixels = mkslice[u32](cast[*u32](ptr(mem)), width * height)
    b.width = width
    b.height = height
    b.busy = false
    wl_buffer_add_listener(b.buffer, &buffer_listener, cast[*u8](b))
    true
}

fn buffer_destroy(b: *Buffer) {
    if b.buffer != nil {
        wl_buffer_destroy(b.buffer)
        unmap(mkslice[u8](cast[*u8](ptr(b.pixels)), b.width * b.height * 4))
    }
    *b = Buffer{}
}

fn on_buffer_release(data: *u8, buffer: *WlBuffer) {
    cast[*Buffer](data).busy = false
}

// ---- drawing ----

fn paint(b: *Buffer) {
    w := b.width
    h := b.height
    for y in 0..h {
        row := b.pixels[y * w..(y + 1) * w]
        for x in 0..w {
            c: u32 = if y < h / 2 {
                if x < w / 2 { 0xFF0000 } else { 0x00FF00 }
            } else {
                if x < w / 2 { 0x0000FF } else { 0xFFFFFF }
            }
            if y < 16 {
                g := u32(x * 255 / max(w - 1, 1))
                c = g << 16 | g << 8 | g
            }
            row[x] = c
        }
    }
    mx := i64(app.mouse_x)
    my := i64(app.mouse_y)
    for d in -10..=10 {
        if mx + d >= 0 && mx + d < w && my >= 0 && my < h {
            b.pixels[my * w + mx + d] = 0xFFFF00
        }
        if my + d >= 0 && my + d < h && mx >= 0 && mx < w {
            b.pixels[(my + d) * w + mx] = 0xFFFF00
        }
    }
}

// Draws into a free buffer and commits it. Never waits: if both buffers are still held by the
// compositor, the frame is drawn when one comes back (wl_buffer.release).
fn redraw() {
    for i in 0..2 {
        b := &app.buffers[i]
        if b.buffer != nil && (b.width != app.width || b.height != app.height) && !b.busy {
            buffer_destroy(b)
        }
    }
    for i in 0..2 {
        b := &app.buffers[i]
        if b.busy {
            continue
        }
        if b.buffer == nil && !buffer_create(b, app.width, app.height) {
            eprint("cannot create a shm buffer")
            app.running = false
            return
        }
        paint(b)
        wl_surface_attach(app.surface, b.buffer, 0, 0)
        wl_surface_damage_buffer(app.surface, 0, 0, i32(b.width), i32(b.height))
        wl_surface_commit(app.surface)
        b.busy = true
        app.dirty = false
        return
    }
}

// ---- globals ----

fn on_global(data: *u8, registry: *WlRegistry, name: u32, interface: *u8, version: u32) {
    match from_cstr(interface) {
        "wl_compositor" => app.compositor = cast[*WlCompositor](wl_registry_bind(registry, name, &wl_compositor_interface, min(version, 4)))
        "wl_shm" => app.shm = cast[*WlShm](wl_registry_bind(registry, name, &wl_shm_interface, 1))
        "xdg_wm_base" => app.wm_base = cast[*XdgWmBase](wl_registry_bind(registry, name, xdg_wm_base_interface(), min(version, 2)))
        "wl_seat" => {
            if app.seat == nil {
                // version 5: wl_pointer.frame and wl_keyboard.repeat_info, not yet "repeated" keys
                app.seat = cast[*WlSeat](wl_registry_bind(registry, name, &wl_seat_interface, min(version, 5)))
            }
        }
        "zxdg_decoration_manager_v1" => app.decoration_manager = cast[*ZxdgDecorationManagerV1](
            wl_registry_bind(registry, name, zxdg_decoration_manager_v1_interface(), 1))
        _ => {}
    }
}

fn on_ping(data: *u8, wm_base: *XdgWmBase, serial: u32) {
    xdg_wm_base_pong(wm_base, serial)
}

// ---- the window ----

fn on_toplevel_configure(data: *u8, toplevel: *XdgToplevel, width: i32, height: i32, states: *WlArray) {
    app.pending_w = i64(width)
    app.pending_h = i64(height)
    app.fullscreen = contains(wl_array_u32(states), XDG_TOPLEVEL_STATE_FULLSCREEN)
    app.maximized = contains(wl_array_u32(states), XDG_TOPLEVEL_STATE_MAXIMIZED)
}

// The end of a configure sequence: take the proposed size (0 means: choose), acknowledge, draw.
fn on_surface_configure(data: *u8, xdg_surface: *XdgSurface, serial: u32) {
    xdg_surface_ack_configure(xdg_surface, serial)
    w := if app.pending_w > 0 { app.pending_w } else { 640 }
    h := if app.pending_h > 0 { app.pending_h } else { 480 }
    if w != app.width || h != app.height || !app.configured {
        print("configure:", w, h, if app.fullscreen { "fullscreen" } else if app.maximized { "maximized" } else { "windowed" })
    }
    app.width = w
    app.height = h
    app.configured = true
    app.dirty = true
}

fn on_close(data: *u8, toplevel: *XdgToplevel) {
    print("close requested")
    app.running = false
}

fn on_decoration_configure(data: *u8, decoration: *ZxdgToplevelDecorationV1, mode: u32) {
    print("decorations:", if mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE { "server-side" } else { "client-side (none drawn)" })
}

// ---- input ----

fn on_seat_capabilities(data: *u8, seat: *WlSeat, caps: u32) {
    if caps & WL_SEAT_CAPABILITY_POINTER != 0 && app.pointer == nil {
        app.pointer = wl_seat_get_pointer(seat)
        wl_pointer_add_listener(app.pointer, &pointer_listener, nil)
    }
    if caps & WL_SEAT_CAPABILITY_KEYBOARD != 0 && app.keyboard == nil {
        app.keyboard = wl_seat_get_keyboard(seat)
        wl_keyboard_add_listener(app.keyboard, &keyboard_listener, nil)
    }
}

// Shows the theme's arrow, or nothing while hidden.
fn apply_cursor() {
    if app.pointer == nil {
        return
    }
    if app.cursor_hidden || app.cursor_theme == nil {
        wl_pointer_set_cursor(app.pointer, app.enter_serial, nil, 0, 0)
        return
    }
    cursor := wl_cursor_theme_get_cursor(app.cursor_theme, ptr("left_ptr"))
    if cursor == nil {
        cursor = wl_cursor_theme_get_cursor(app.cursor_theme, ptr("default"))
    }
    if cursor == nil {
        return
    }
    image := cursor.images[0]
    wl_surface_attach(app.cursor_surface, wl_cursor_image_get_buffer(image), 0, 0)
    wl_surface_damage_buffer(app.cursor_surface, 0, 0, i32(image.width), i32(image.height))
    wl_surface_commit(app.cursor_surface)
    wl_pointer_set_cursor(app.pointer, app.enter_serial, app.cursor_surface, i32(image.hotspot_x), i32(image.hotspot_y))
}

fn on_pointer_enter(data: *u8, pointer: *WlPointer, serial: u32, surface: *WlSurface, x: i32, y: i32) {
    app.enter_serial = serial
    app.mouse_x = wl_fixed_to_double(x)
    app.mouse_y = wl_fixed_to_double(y)
    print("pointer enter", app.mouse_x, app.mouse_y)
    apply_cursor()
    app.dirty = true
}

fn on_pointer_leave(data: *u8, pointer: *WlPointer, serial: u32, surface: *WlSurface) {
    print("pointer leave")
}

fn on_pointer_motion(data: *u8, pointer: *WlPointer, time: u32, x: i32, y: i32) {
    app.mouse_x = wl_fixed_to_double(x)
    app.mouse_y = wl_fixed_to_double(y)
    print("pointer motion", app.mouse_x, app.mouse_y)
    app.dirty = true
}

// Linux evdev button codes (BTN_LEFT, ...).
fn button_name(button: u32) -> str {
    match button {
        0x110 => "left"
        0x111 => "right"
        0x112 => "middle"
        0x113 => "side"
        0x114 => "extra"
        _ => fmt("0x", hex(u64(button)))
    }
}

fn on_pointer_button(data: *u8, pointer: *WlPointer, serial: u32, time: u32, button: u32, state: u32) {
    print("button", button_name(button), if state == WL_POINTER_BUTTON_STATE_PRESSED { "down" } else { "up" },
        "at", app.mouse_x, app.mouse_y)
}

// value: the scroll distance in surface pixels; positive means down / right.
fn on_pointer_axis(data: *u8, pointer: *WlPointer, time: u32, axis: u32, value: i32) {
    print("axis", if axis == WL_POINTER_AXIS_VERTICAL_SCROLL { "vertical" } else { "horizontal" }, wl_fixed_to_double(value))
}

fn on_keymap(data: *u8, keyboard: *WlKeyboard, format: u32, fd: i32, size: u32) {
    if format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 {
        close_fd(i64(fd))
        return
    }
    text, ok := map_readonly(i64(fd), i64(size))       // the keymap text, NUL-terminated
    close_fd(i64(fd))
    if !ok {
        return
    }
    keymap := xkb_keymap_new_from_string(app.xkb, ptr(text), XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS)
    unmap(text)
    if keymap == nil {
        return
    }
    if app.xkb_state != nil {
        xkb_state_unref(app.xkb_state)
        xkb_keymap_unref(app.keymap)
    }
    app.keymap = keymap
    app.xkb_state = xkb_state_new(keymap)
}

fn on_keyboard_enter(data: *u8, keyboard: *WlKeyboard, serial: u32, surface: *WlSurface, keys: *WlArray) {
    print("focus in, keys held:", len(wl_array_u32(keys)))
}

fn on_keyboard_leave(data: *u8, keyboard: *WlKeyboard, serial: u32, surface: *WlSurface) {
    print("focus out")
}

fn on_modifiers(data: *u8, keyboard: *WlKeyboard, serial: u32, depressed: u32, latched: u32, locked: u32, group: u32) {
    if app.xkb_state != nil {
        xkb_state_update_mask(app.xkb_state, depressed, latched, locked, 0, 0, group)
    }
}

fn mod_active(name: str) -> bool {
    xkb_state_mod_name_is_active(app.xkb_state, ptr(name), XKB_STATE_MODS_EFFECTIVE) == 1
}

fn on_key(data: *u8, keyboard: *WlKeyboard, serial: u32, time: u32, key: u32, state: u32) {
    if app.xkb_state == nil {
        return
    }
    code := key + 8                                     // evdev code -> xkb key code
    sym := xkb_state_key_get_one_sym(app.xkb_state, code)
    name: [64]u8
    xkb_keysym_get_name(sym, ptr(name), 64)
    text: [16]u8
    n := xkb_state_key_get_utf8(app.xkb_state, code, ptr(text), 16)
    pressed := state == WL_KEYBOARD_KEY_STATE_PRESSED
    mods := vec[str]()
    if mod_active(XKB_MOD_NAME_SHIFT) { mods.push("shift") }
    if mod_active(XKB_MOD_NAME_CTRL) { mods.push("ctrl") }
    if mod_active(XKB_MOD_NAME_ALT) { mods.push("alt") }
    if mod_active(XKB_MOD_NAME_LOGO) { mods.push("super") }
    print("key", if pressed { "down" } else { "up" }, from_cstr(ptr(name)), fmt("0x", hex(u64(sym))),
        "evdev", key, "text", fmt("\"", if n > 0 && text[0] >= 0x20 { text[..n] } else { "" }, "\""), "mods", join(mods[..], "+"))
    if !pressed {
        return
    }
    match sym {
        0xFF1B => app.running = false                   // Escape
        0x66, 0x46 => {                                 // f, F
            if app.fullscreen {
                xdg_toplevel_unset_fullscreen(app.toplevel)
            } else {
                xdg_toplevel_set_fullscreen(app.toplevel, nil)
            }
        }
        0x6D, 0x4D => {                                 // m, M
            if app.maximized {
                xdg_toplevel_unset_maximized(app.toplevel)
            } else {
                xdg_toplevel_set_maximized(app.toplevel)
            }
        }
        0x68, 0x48 => {                                 // h, H
            app.cursor_hidden = !app.cursor_hidden
            print("cursor", if app.cursor_hidden { "hidden" } else { "shown" })
            apply_cursor()
        }
        _ => {}
    }
}

fn on_repeat_info(data: *u8, keyboard: *WlKeyboard, rate: i32, delay: i32) {
    print("key repeat (done by the client, not here):", rate, "per second after", delay, "ms")
}

// Listeners must outlive the objects: globals. Unset fields ignore their events.
registry_listener := WlRegistryListener{global: on_global}
wm_base_listener := XdgWmBaseListener{ping: on_ping}
xdg_surface_listener := XdgSurfaceListener{configure: on_surface_configure}
toplevel_listener := XdgToplevelListener{configure: on_toplevel_configure, close: on_close}
decoration_listener := ZxdgToplevelDecorationV1Listener{configure: on_decoration_configure}
buffer_listener := WlBufferListener{release: on_buffer_release}
seat_listener := WlSeatListener{capabilities: on_seat_capabilities}
pointer_listener := WlPointerListener{enter: on_pointer_enter, leave: on_pointer_leave, motion: on_pointer_motion,
    button: on_pointer_button, axis: on_pointer_axis}
keyboard_listener := WlKeyboardListener{keymap: on_keymap, enter: on_keyboard_enter, leave: on_keyboard_leave,
    key: on_key, modifiers: on_modifiers, repeat_info: on_repeat_info}

fn main() -> i64 {
    app.display = wl_display_connect(nil)               // $WAYLAND_DISPLAY
    if app.display == nil {
        eprint("cannot connect to a Wayland compositor (is WAYLAND_DISPLAY set?)")
        return 1
    }
    registry := wl_display_get_registry(app.display)
    wl_registry_add_listener(registry, &registry_listener, nil)
    wl_display_roundtrip(app.display)
    if app.compositor == nil || app.shm == nil || app.wm_base == nil {
        eprint("the compositor lacks wl_compositor, wl_shm or xdg_wm_base")
        wl_display_disconnect(app.display)
        return 1
    }
    xdg_wm_base_add_listener(app.wm_base, &wm_base_listener, nil)
    app.xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS)
    app.cursor_theme = wl_cursor_theme_load(nil, 24, app.shm)
    app.cursor_surface = wl_compositor_create_surface(app.compositor)
    if app.seat != nil {
        wl_seat_add_listener(app.seat, &seat_listener, nil)
    }

    app.surface = wl_compositor_create_surface(app.compositor)
    app.xdg_surface = xdg_wm_base_get_xdg_surface(app.wm_base, app.surface)
    xdg_surface_add_listener(app.xdg_surface, &xdg_surface_listener, nil)
    app.toplevel = xdg_surface_get_toplevel(app.xdg_surface)
    xdg_toplevel_add_listener(app.toplevel, &toplevel_listener, nil)
    xdg_toplevel_set_title(app.toplevel, "AL on Wayland")
    xdg_toplevel_set_app_id(app.toplevel, "al.example.wayland_window")
    if app.decoration_manager != nil {
        app.decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(app.decoration_manager, app.toplevel)
        zxdg_toplevel_decoration_v1_add_listener(app.decoration, &decoration_listener, nil)
        zxdg_toplevel_decoration_v1_set_mode(app.decoration, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE)
    } else {
        print("decorations: the compositor has no xdg-decoration: no title bar")
    }
    wl_surface_commit(app.surface)                      // no buffer: asks for the first configure

    app.running = true
    while app.running {
        if app.configured && app.dirty {
            redraw()
        }
        flush()                                         // the printed events, now
        if wl_display_dispatch(app.display) < 0 {       // flushes, then waits for events
            eprint("the connection to the compositor was lost")
            break
        }
    }

    // tear down: children before parents, then the connection
    for i in 0..2 {
        buffer_destroy(&app.buffers[i])
    }
    if app.decoration != nil {
        zxdg_toplevel_decoration_v1_destroy(app.decoration)
    }
    xdg_toplevel_destroy(app.toplevel)
    xdg_surface_destroy(app.xdg_surface)
    wl_surface_destroy(app.surface)
    if app.pointer != nil {
        wl_pointer_release(app.pointer)
    }
    if app.keyboard != nil {
        wl_keyboard_release(app.keyboard)
    }
    if app.xkb_state != nil {
        xkb_state_unref(app.xkb_state)
        xkb_keymap_unref(app.keymap)
    }
    xkb_context_unref(app.xkb)
    wl_surface_destroy(app.cursor_surface)
    if app.cursor_theme != nil {
        wl_cursor_theme_destroy(app.cursor_theme)
    }
    if app.decoration_manager != nil {
        zxdg_decoration_manager_v1_destroy(app.decoration_manager)
    }
    if app.seat != nil {
        wl_seat_release(app.seat)
    }
    xdg_wm_base_destroy(app.wm_base)
    wl_shm_destroy(app.shm)
    wl_compositor_destroy(app.compositor)
    wl_registry_destroy(registry)
    wl_display_disconnect(app.display)
    0
}
