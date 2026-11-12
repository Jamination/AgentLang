// std.wayland against a real compositor. The program starts its own `weston --backend=headless`
// (it shows nothing) on a private socket named after its process id, connects to that socket by
// name (never to $WAYLAND_DISPLAY), binds the globals, shows an xdg_toplevel with shm buffers,
// goes fullscreen and back, provokes a protocol error on a second connection, opens and closes
// windows in a loop, and stops the compositor again.
use std.wayland
use std.os

// ---- what the event handlers record ----
struct State {
    display: *WlDisplay
    compositor: *WlCompositor
    shm: *WlShm
    wm_base: *XdgWmBase
    output: *WlOutput
    globals: i64
    xrgb: bool              // wl_shm.format announced XRGB8888
    mode_w: i32
    mode_h: i32
    geometry_ok: bool
    output_done: bool
    synced: bool
    // the window
    surface: *WlSurface
    xdg_surface: *XdgSurface
    toplevel: *XdgToplevel
    configures: i64
    conf_w: i32
    conf_h: i32
    fullscreen: bool
    frames: i64
    released: i64
}

fn on_global(data: *u8, registry: *WlRegistry, name: u32, interface: *u8, version: u32) {
    st := cast[*State](data)
    st.globals += 1
    match from_cstr(interface) {
        "wl_compositor" => st.compositor = cast[*WlCompositor](wl_registry_bind(registry, name, &wl_compositor_interface, min(version, 4)))
        "wl_shm" => st.shm = cast[*WlShm](wl_registry_bind(registry, name, &wl_shm_interface, 1))
        "xdg_wm_base" => st.wm_base = cast[*XdgWmBase](wl_registry_bind(registry, name, xdg_wm_base_interface(), min(version, 2)))
        "wl_output" => {
            if st.output == nil {
                st.output = cast[*WlOutput](wl_registry_bind(registry, name, &wl_output_interface, min(version, 2)))
            }
        }
        _ => {}
    }
}

fn on_shm_format(data: *u8, shm: *WlShm, format: u32) {
    if format == WL_SHM_FORMAT_XRGB8888 {
        cast[*State](data).xrgb = true
    }
}

// ten parameters: four of them arrive on the stack
fn on_output_geometry(data: *u8, output: *WlOutput, x: i32, y: i32, physical_width: i32, physical_height: i32,
    subpixel: i32, make: *u8, model: *u8, transform: i32) {
    st := cast[*State](data)
    st.geometry_ok = output == st.output && x == 0 && y == 0 && len(from_cstr(make)) > 0 &&
        len(from_cstr(model)) > 0 && transform == WL_OUTPUT_TRANSFORM_NORMAL
}

fn on_output_mode(data: *u8, output: *WlOutput, flags: u32, width: i32, height: i32, refresh: i32) {
    st := cast[*State](data)
    if flags & WL_OUTPUT_MODE_CURRENT != 0 {
        st.mode_w = width
        st.mode_h = height
    }
}

fn on_output_done(data: *u8, output: *WlOutput) {
    cast[*State](data).output_done = true
}

fn on_ping(data: *u8, wm_base: *XdgWmBase, serial: u32) {
    xdg_wm_base_pong(wm_base, serial)
}

fn on_surface_configure(data: *u8, xdg_surface: *XdgSurface, serial: u32) {
    xdg_surface_ack_configure(xdg_surface, serial)
    cast[*State](data).configures += 1
}

fn on_toplevel_configure(data: *u8, toplevel: *XdgToplevel, width: i32, height: i32, states: *WlArray) {
    st := cast[*State](data)
    st.conf_w = width
    st.conf_h = height
    st.fullscreen = contains(wl_array_u32(states), XDG_TOPLEVEL_STATE_FULLSCREEN)
}

fn on_frame(data: *u8, callback: *WlCallback, time: u32) {
    cast[*State](data).frames += 1
    wl_callback_destroy(callback)
}

fn on_sync(data: *u8, callback: *WlCallback, serial: u32) {
    cast[*State](data).synced = true
    wl_callback_destroy(callback)
}

fn on_buffer_release(data: *u8, buffer: *WlBuffer) {
    cast[*State](data).released += 1
}

// The listeners are globals: libwayland keeps pointers to them. Events without a handler
// (wl_registry.global_remove, wl_output.scale, xdg_toplevel.close, ...) are ignored.
registry_listener := WlRegistryListener{global: on_global}
shm_listener := WlShmListener{format: on_shm_format}
output_listener := WlOutputListener{geometry: on_output_geometry, mode: on_output_mode, done: on_output_done}
wm_base_listener := XdgWmBaseListener{ping: on_ping}
xdg_surface_listener := XdgSurfaceListener{configure: on_surface_configure}
toplevel_listener := XdgToplevelListener{configure: on_toplevel_configure}
frame_listener := WlCallbackListener{done: on_frame}
sync_listener := WlCallbackListener{done: on_sync}
buffer_listener := WlBufferListener{release: on_buffer_release}

// ---- a wl_shm buffer: an anonymous file, mapped here and handed to the compositor ----
struct Buffer {
    buffer: *WlBuffer
    pixels: []u32           // XRGB8888: 0x00RRGGBB
    width: i64
    height: i64
}

fn buffer_new(shm: *WlShm, width: i64, height: i64) -> (Buffer, bool) {
    size := width * height * 4
    fd := syscall(319, ptr("al-wayland-test"), 1)       // memfd_create(name, MFD_CLOEXEC)
    if fd < 0 {
        return (Buffer{}, false)
    }
    if syscall(77, fd, size) < 0 {                      // ftruncate
        syscall(3, fd)
        return (Buffer{}, false)
    }
    mem := syscall(9, 0, size, 3, 1, fd, 0)             // mmap(PROT_READ | PROT_WRITE, MAP_SHARED)
    if mem < 0 && mem > -4096 {
        syscall(3, fd)
        return (Buffer{}, false)
    }
    pool := wl_shm_create_pool(shm, i32(fd), i32(size))
    b := Buffer{pixels: mkslice[u32](cast[*u32](mem), width * height), width: width, height: height}
    b.buffer = wl_shm_pool_create_buffer(pool, 0, i32(width), i32(height), i32(width * 4), WL_SHM_FORMAT_XRGB8888)
    // the buffer keeps the pool's memory alive; the compositor has its own copy of the fd
    wl_shm_pool_destroy(pool)
    syscall(3, fd)
    (b, true)
}

fn buffer_free(b: *Buffer) {
    wl_buffer_destroy(b.buffer)
    syscall(11, ptr(b.pixels), b.width * b.height * 4)  // munmap
    *b = Buffer{}
}

fn paint(b: *Buffer, seed: i64) {
    for y in 0..b.height {
        for x in 0..b.width {
            b.pixels[y * b.width + x] = u32((x * 255 / b.width) << 16 | (y * 255 / b.height) << 8 | seed & 0xFF)
        }
    }
}

// Attaches a buffer to the window's surface and commits.
fn show(st: *State, b: *Buffer) {
    wl_surface_attach(st.surface, b.buffer, 0, 0)
    wl_surface_damage_buffer(st.surface, 0, 0, i32(b.width), i32(b.height))
    wl_surface_commit(st.surface)
}

// Connects, with the listeners on the registry, the shm and the first output.
fn connect(st: *State, socket: str) -> bool {
    m := mark()
    st.display = wl_display_connect(cstr(socket))
    release(m)
    if st.display == nil {
        return false
    }
    registry := wl_display_get_registry(st.display)
    wl_registry_add_listener(registry, &registry_listener, cast[*u8](st))
    wl_display_roundtrip(st.display)                    // the globals
    if st.compositor == nil || st.shm == nil || st.wm_base == nil {
        return false
    }
    wl_shm_add_listener(st.shm, &shm_listener, cast[*u8](st))
    xdg_wm_base_add_listener(st.wm_base, &wm_base_listener, cast[*u8](st))
    if st.output != nil {
        wl_output_add_listener(st.output, &output_listener, cast[*u8](st))
    }
    wl_display_roundtrip(st.display)                    // what the globals announce
    wl_registry_destroy(registry)
    true
}

// Creates the surface with its roles and waits for the first configure.
fn window_open(st: *State, title: str) -> bool {
    st.surface = wl_compositor_create_surface(st.compositor)
    st.xdg_surface = xdg_wm_base_get_xdg_surface(st.wm_base, st.surface)
    xdg_surface_add_listener(st.xdg_surface, &xdg_surface_listener, cast[*u8](st))
    st.toplevel = xdg_surface_get_toplevel(st.xdg_surface)
    xdg_toplevel_add_listener(st.toplevel, &toplevel_listener, cast[*u8](st))
    xdg_toplevel_set_title(st.toplevel, title)
    xdg_toplevel_set_app_id(st.toplevel, "al.test.wayland")
    wl_surface_commit(st.surface)                       // no buffer yet: asks for the configure
    wl_display_roundtrip(st.display)
    st.configures > 0
}

fn window_close(st: *State) {
    xdg_toplevel_destroy(st.toplevel)
    xdg_surface_destroy(st.xdg_surface)
    wl_surface_destroy(st.surface)
    st.toplevel = nil
    st.xdg_surface = nil
    st.surface = nil
}

fn disconnect(st: *State) {
    if st.output != nil {
        wl_output_destroy(st.output)
    }
    xdg_wm_base_destroy(st.wm_base)
    wl_shm_destroy(st.shm)
    wl_compositor_destroy(st.compositor)
    wl_display_disconnect(st.display)
    *st = State{}
}

// Dispatches until `*flag` differs from `was`, at most two seconds; never blocks longer than
// 20 ms at a time.
fn wait_change(st: *State, flag: *i64, was: i64) -> bool {
    deadline := clock_ns() + 2_000_000_000
    while *flag == was && clock_ns() < deadline {
        if wl_display_poll(st.display, 20) < 0 {
            return false
        }
    }
    *flag != was
}

fn open_fds() -> i64 {
    m := mark()
    n := len(list_dir("/proc/self/fd"))
    release(m)
    n
}

// libxkbcommon on a keymap of three keys, as a compositor would send it with wl_keyboard.keymap.
const KEYMAP = `xkb_keymap {
    xkb_keycodes { <ESC> = 9; <AD01> = 24; <LFSH> = 50; };
    xkb_types {
        type "ONE_LEVEL" { modifiers = none; map[None] = Level1; level_name[Level1] = "Any"; };
        type "ALPHABETIC" { modifiers = Shift + Lock; map[Shift] = Level2; map[Lock] = Level2;
            level_name[Level1] = "Base"; level_name[Level2] = "Caps"; };
    };
    xkb_compatibility { interpret Shift_L { action = SetMods(modifiers = Shift); }; };
    xkb_symbols {
        key <ESC> { [ Escape ] };
        key <AD01> { type = "ALPHABETIC", [ q, Q ] };
        key <LFSH> { [ Shift_L ] };
        modifier_map Shift { <LFSH> };
    };
};`

fn keyboard_check() {
    context := xkb_context_new(XKB_CONTEXT_NO_FLAGS)
    print("keymap from garbage:", xkb_keymap_new_from_string(context, ptr("not a keymap"), XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS) != nil)
    keymap := xkb_keymap_new_from_buffer(context, ptr(KEYMAP), u64(len(KEYMAP)), XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS)
    if keymap == nil {
        print("the keymap does not compile")
        exit(1)
    }
    state := xkb_state_new(keymap)
    text: [8]u8
    name: [32]u8
    n := xkb_state_key_get_utf8(state, 24, ptr(text), 8)
    xkb_keysym_get_name(xkb_state_key_get_one_sym(state, 9), ptr(name), 32)
    print("keys:", hex(u64(xkb_state_key_get_one_sym(state, 9))), from_cstr(ptr(name)), xkb_state_key_get_one_sym(state, 24),
        text[..n], xkb_state_mod_name_is_active(state, ptr(XKB_MOD_NAME_SHIFT), XKB_STATE_MODS_EFFECTIVE),
        "repeats:", xkb_keymap_key_repeats(keymap, 24))
    // what wl_keyboard.modifiers reports while Shift is held: depressed = bit 0
    xkb_state_update_mask(state, 1, 0, 0, 0, 0, 0)
    n = xkb_state_key_get_utf8(state, 24, ptr(text), 8)
    print("shifted:", xkb_state_key_get_one_sym(state, 24), text[..n], xkb_state_key_get_utf32(state, 24),
        xkb_state_mod_name_is_active(state, ptr(XKB_MOD_NAME_SHIFT), XKB_STATE_MODS_EFFECTIVE),
        xkb_state_mod_name_is_active(state, ptr(XKB_MOD_NAME_CTRL), XKB_STATE_MODS_EFFECTIVE), xkb_keysym_to_utf32(0x51))
    xkb_state_unref(state)
    xkb_keymap_unref(keymap)
    xkb_context_unref(context)
}

fn main() {
    runtime, has := env_get("XDG_RUNTIME_DIR")
    if !has {
        print("XDG_RUNTIME_DIR is not set")
        exit(1)
    }
    keyboard_check()
    socket := fmt("al-wl-test-", process_id())
    path := path_join(runtime, socket)
    // weston in the background (std.os only runs programs to their end, so a shell starts it);
    // `timeout` ends it even if this program is killed before it can
    script := fmt("env -u WAYLAND_DISPLAY -u DISPLAY timeout 50 weston --backend=headless --socket=", socket,
        " --width=800 --height=600 --no-config >/dev/null 2>&1 & echo $!")
    out, status := run_capture([]str{"sh", "-c", script})
    pid, pid_ok := parse_i64(trim(out))
    if status != 0 || !pid_ok {
        print("cannot start weston")
        exit(1)
    }
    st := new[State]()
    connected := false
    for attempt in 0..500 {
        if file_exists(path) && connect(st, socket) {
            connected = true
            break
        }
        sleep_ns(20_000_000)
    }
    print("connect:", connected)
    if !connected {
        syscall(62, pid, 15)
        exit(1)
    }
    fds := open_fds()
    print("globals:", st.globals > 3, "compositor shm wm_base output:", st.compositor != nil, st.shm != nil,
        st.wm_base != nil, st.output != nil)
    print("shm xrgb8888:", st.xrgb, "output mode:", st.mode_w, st.mode_h, "geometry:", st.geometry_ok, "done:", st.output_done)
    print("versions:", wl_compositor_get_version(st.compositor), wl_shm_get_version(st.shm), wl_output_get_version(st.output),
        "class:", from_cstr(wl_proxy_get_class(cast[*u8](st.shm))), "interface:", from_cstr(xdg_toplevel_interface().name),
        xdg_toplevel_interface().version)

    // a wrong socket name fails without touching anything else
    print("wrong socket:", wl_display_connect(ptr("al-wl-test-no-such-socket")) == nil)

    // wl_display.sync, user data
    wl_callback_add_listener(wl_display_sync(st.display), &sync_listener, cast[*u8](st))
    wl_display_roundtrip(st.display)
    wl_shm_set_user_data(st.shm, cast[*u8](st))
    print("sync:", st.synced, "user data:", wl_shm_get_user_data(st.shm) == cast[*u8](st), "error:", wl_display_get_error(st.display))

    // libwayland-cursor: the arrow of the cursor theme (a built-in one if no theme is installed)
    theme := wl_cursor_theme_load(nil, 24, st.shm)
    cursor := wl_cursor_theme_get_cursor(theme, ptr("left_ptr"))
    if cursor == nil {
        cursor = wl_cursor_theme_get_cursor(theme, ptr("default"))
    }
    image := cursor.images[0]
    print("cursor:", cursor.image_count > 0, image.width > 0 && image.hotspot_x < image.width,
        wl_cursor_image_get_buffer(image) != nil, wl_cursor_frame(cursor, 0))
    wl_cursor_theme_destroy(theme)

    // the window: configure, first buffer, a frame callback
    print("window:", window_open(st, "AL wayland test \xc3\xa9"), "fullscreen:", st.fullscreen)
    small, ok1 := buffer_new(st.shm, 320, 240)
    wl_buffer_add_listener(small.buffer, &buffer_listener, cast[*u8](st))
    paint(&small, 1)
    wl_callback_add_listener(wl_surface_frame(st.surface), &frame_listener, cast[*u8](st))
    show(st, &small)
    print("buffer:", ok1, "frame:", wait_change(st, &st.frames, 0))

    // fullscreen: the compositor answers with the size of the output; a buffer of that size
    configures := st.configures
    xdg_toplevel_set_fullscreen(st.toplevel, nil)
    wl_surface_commit(st.surface)
    print("configure:", wait_change(st, &st.configures, configures), "fullscreen:", st.fullscreen, st.conf_w, st.conf_h)
    big, ok2 := buffer_new(st.shm, i64(st.conf_w), i64(st.conf_h))
    paint(&big, 2)
    wl_callback_add_listener(wl_surface_frame(st.surface), &frame_listener, cast[*u8](st))
    frames := st.frames
    show(st, &big)
    print("buffer:", ok2, "frame:", wait_change(st, &st.frames, frames), "first buffer released:", st.released > 0 || wait_change(st, &st.released, 0))

    // windowed again, title change, size limits
    configures = st.configures
    xdg_toplevel_unset_fullscreen(st.toplevel)
    xdg_toplevel_set_title(st.toplevel, "renamed")
    xdg_toplevel_set_min_size(st.toplevel, 320, 240)
    xdg_toplevel_set_max_size(st.toplevel, 320, 240)
    wl_surface_commit(st.surface)
    print("configure:", wait_change(st, &st.configures, configures), "fullscreen:", st.fullscreen)
    show(st, &small)
    print("roundtrip:", wl_display_roundtrip(st.display) >= 0, "poll:", wl_display_poll(st.display, 0) >= 0)

    // close and reopen on the same connection
    window_close(st)
    buffer_free(&small)
    buffer_free(&big)
    st.configures = 0
    print("reopen:", window_open(st, "second"), wl_display_get_error(st.display))
    window_close(st)
    wl_display_roundtrip(st.display)

    // a protocol error, on a second connection: a stride that does not fit the width
    bad := new[State]()
    print("second connection:", connect(bad, socket))
    {
        fd := syscall(319, ptr("al-wayland-test"), 1)
        syscall(77, fd, 4096)
        pool := wl_shm_create_pool(bad.shm, i32(fd), 4096)
        syscall(3, fd)
        wl_shm_pool_create_buffer(pool, 0, 16, 16, 3, WL_SHM_FORMAT_XRGB8888)
        failed := wl_display_roundtrip(bad.display) < 0
        interface: *WlInterface
        id: u32
        code := wl_display_get_protocol_error(bad.display, &interface, &id)
        print("protocol error:", failed, wl_display_get_error(bad.display), from_cstr(interface.name), code == WL_SHM_ERROR_INVALID_STRIDE,
            "poll:", wl_display_poll(bad.display, 0))
        wl_display_disconnect(bad.display)
    }

    // connect, show a window, tear everything down: 20 times, no file descriptor may stay open
    disconnect(st)
    cycles := 0
    for i in 0..20 {
        if !connect(st, socket) || !window_open(st, "cycle") {
            break
        }
        b, ok := buffer_new(st.shm, 64, 64)
        if !ok {
            break
        }
        paint(&b, i)
        show(st, &b)
        if wl_display_roundtrip(st.display) < 0 {
            break
        }
        window_close(st)
        buffer_free(&b)
        disconnect(st)
        cycles += 1
    }
    print("cycles:", cycles, "descriptors left open:", open_fds() - (fds - 1))

    // the compositor goes away while a client is connected: dispatching reports it
    print("last connection:", connect(st, socket))
    syscall(62, pid, 15)                                // SIGTERM
    lost := false
    for attempt in 0..250 {
        if wl_display_poll(st.display, 20) < 0 {
            lost = true
            break
        }
    }
    print("connection lost:", lost, wl_display_get_error(st.display) != 0)
    disconnect(st)
    gone := false
    for attempt in 0..250 {
        // (kill with signal 0 only asks whether the process exists)
        if !file_exists(path) && !file_exists(concat(path, ".lock")) && syscall(62, pid, 0) == -3 {
            gone = true
            break
        }
        sleep_ns(20_000_000)
    }
    print("compositor stopped, socket removed:", gone)
}
