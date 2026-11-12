# std.wayland: Wayland client bindings

`use std.wayland` gives a program what it needs to talk to a Wayland compositor itself:
`libwayland-client`, the protocols `wayland` (core), `xdg-shell` and `xdg-decoration-unstable-v1`,
and the parts of `libxkbcommon` (keyboard) and `libwayland-cursor` (pointer image) that a window
needs. It is a binding of the C API, not a window abstraction: `std.window` is the portable
window module (it uses X11, which works on Wayland sessions through XWayland).

A program that uses it links against `libwayland-client.so.0`, and against `libxkbcommon.so.0`
and `libwayland-cursor.so.0` if it calls their functions.

What is bound: 30 interfaces (23 of the core protocol, 5 of `xdg-shell`, 2 of
`xdg-decoration`) with all their 113 requests, 72 events (in 19 listener structs, one per
interface that has events; the two events of `wl_display` are handled inside libwayland) and
305 enum values; 31 functions of libwayland-client, 15 of libxkbcommon, 5 of
libwayland-cursor, and a few helpers.

Complete example: [examples/wayland_window.al](../../examples/wayland_window.al) (a window with
a test pattern, keyboard, pointer and cursor, resizing, fullscreen / maximize, server-side
decorations when offered; it prints every input event).

## From the C API

The protocol part is generated from the protocol XML files by `tools/gen_wayland.al`, the way
`wayland-scanner` generates C headers, so the C documentation of every protocol applies with
these rules (here for `wl_surface`):

| C | AL |
|---|---|
| `struct wl_surface *` | `*WlSurface` (an opaque struct; `nil` is NULL) |
| `wl_surface_attach(s, b, x, y)` | the same name and arguments: one function per request |
| `&wl_surface_interface` | `wl_surface_interface()` (for `wl_registry_bind`) |
| `WL_SURFACE_ERROR_INVALID_SCALE`, `WL_SEAT_CAPABILITY_POINTER`, ... | the same constants |
| `struct wl_surface_listener` + `wl_surface_add_listener(s, &l, data)` | `WlSurfaceListener` + `wl_surface_add_listener(s, &l, data)` |
| `wl_surface_set_user_data`, `_get_user_data`, `_get_version`, `_destroy` | the same |

Arguments: `int`, `fixed` and `fd` are `i32`, `uint` is `u32`, an object is a pointer to its
struct (`*u8` where the protocol names no interface), an array is `*WlArray`. A string is a `str`
in a request (copied for the call) and a C string (`*u8`, read it with `from_cstr`) in an event.
`wl_fixed_to_double` / `wl_fixed_to_int` / `wl_fixed_from_double` / `wl_fixed_from_int` convert
24.8 fixed-point values; `wl_array_u32(a)` views an array of `u32` (the states of
`xdg_toplevel.configure`) as a `[]u32`.

The connection: `wl_display_connect(nil)` (uses `$WAYLAND_DISPLAY`) or with a socket name,
`wl_display_roundtrip`, `wl_display_dispatch` (blocks), `wl_display_dispatch_pending`,
`wl_display_flush`, `wl_display_get_fd`, `wl_display_get_error`, `wl_display_disconnect`, the
event queue functions, and the generic `wl_proxy_*` functions (they take any object as `*u8`).
Added for frame loops: `wl_display_poll(display, timeout_ms) -> i64` flushes, reads what has
arrived without blocking longer than `timeout_ms` (0: not at all, -1: until something
arrives), runs the handlers and returns the number of events, or -1 once the connection is
broken (also after a protocol error: then `wl_display_get_error` is 71, EPROTO, and
`wl_display_get_protocol_error` names the interface and the error code).

The interface tables (`struct wl_interface`, `struct wl_message`) are built in AL with the C
layout, on the first call of an `..._interface()` function, also for the core protocol:
libwayland-client exports `wl_surface_interface` and the others as data symbols, and `extern`
in AL declares functions only.

## Listeners

An event handler is a plain function `fn(data: *u8, object: *WlSurface, <the arguments of the
event>)`; a nested function works too, since it sees no local variables. Fields of a listener
struct that are left `nil` are set to a handler that ignores the event when the listener is
added, so a listener names only the events the program wants:

```
registry_listener := WlRegistryListener{global: on_global}     // global_remove is ignored
```

libwayland keeps the pointer to the listener struct as long as the object lives: make it a
**global variable** (or allocate it), never a local variable. Handlers run inside
`wl_display_dispatch` / `wl_display_roundtrip` / `wl_display_poll`, on the calling thread; the
`data` argument is the pointer given to `..._add_listener`.

## A window, step by step

1. Connect, get the registry, add a `WlRegistryListener` whose `global` handler binds
   `wl_compositor`, `wl_shm`, `xdg_wm_base` (and `wl_seat`, `zxdg_decoration_manager_v1`) with
   `wl_registry_bind(registry, name, <iface>_interface(), version)`; `wl_display_roundtrip`.
2. Answer `xdg_wm_base.ping` with `xdg_wm_base_pong` (a compositor disconnects clients that
   do not).
3. `wl_compositor_create_surface`, `xdg_wm_base_get_xdg_surface`, `xdg_surface_get_toplevel`,
   title and app id, then `wl_surface_commit` without a buffer: that asks for the first
   configure. Answer every `xdg_surface.configure` with `xdg_surface_ack_configure`; the size
   comes with `xdg_toplevel.configure` (0 means "your choice").
4. Draw into a `wl_shm` buffer: an anonymous file (`memfd_create`, `ftruncate`, `mmap`
   through `syscall`), `wl_shm_create_pool`, `wl_shm_pool_create_buffer` with
   `WL_SHM_FORMAT_XRGB8888` (a `u32` per pixel, `0x00RRGGBB`). Attach, damage, commit. Do not
   draw into a buffer the compositor holds: wait for `wl_buffer.release`, or use more than one.
5. Input: `wl_seat.capabilities` tells whether there is a pointer and a keyboard. Keys arrive
   as evdev codes: add 8 for xkb, compile the keymap that `wl_keyboard.keymap` sends with
   `xkb_keymap_new_from_string`, keep an `XkbState` updated from `wl_keyboard.modifiers`, and
   read keysyms (`xkb_state_key_get_one_sym`, the X11 keysym numbers) and text
   (`xkb_state_key_get_utf8`). There is no key repeat from the compositor: a client repeats
   keys itself from `wl_keyboard.repeat_info`. The pointer image is the client's job:
   `wl_cursor_theme_load(nil, 24, shm)`, `wl_cursor_theme_get_cursor(theme, ptr("left_ptr"))`,
   its image's buffer on a surface of its own, `wl_pointer_set_cursor` on every
   `wl_pointer.enter`.
6. Title bar: ask for one with `zxdg_decoration_manager_v1_get_toplevel_decoration` and
   `..._set_mode(SERVER_SIDE)`. Compositors without the protocol (GNOME, weston) draw none; then
   a window has no title bar unless the program draws one.
7. Tear down in the reverse order: buffers, decoration, toplevel, xdg_surface, surface, then
   the globals and `wl_display_disconnect`.

Scale: the bindings have everything for HiDPI (`wl_output.scale`, `wl_surface.enter`,
`wl_surface_set_buffer_scale`), but a client that does nothing draws at scale 1 and the
compositor enlarges the window on a scaled output (blurry, the right size).

Vulkan: `VkWaylandSurfaceCreateInfoKHR` (`std.vk`) takes the display and the surface as `*u8`:
`info.display = cast[*u8](display)`, `info.surface = cast[*u8](surface)`; enable
`VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME` on the instance. Do not attach shm buffers to a
surface that has a swapchain.

## Testing

`tests/sys/wayland` starts its own `weston --backend=headless` (it shows nothing) on a socket
named `al-wl-test-<pid>` and connects to it by name, never to `$WAYLAND_DISPLAY`: globals and
their events (shm formats, output mode, output geometry: a handler of ten arguments), xkbcommon on a
keymap of its own, the cursor theme, a toplevel with configure, shm buffers, frame callbacks,
fullscreen and back, a protocol error on a second connection, 20 connect / window / teardown
cycles without a leaked file descriptor, and the compositor going away under a connected
client; then it checks that the compositor and its socket are gone. It is skipped without
`weston`. `tests/check/wayland.al` (generated with the bindings) uses every public
declaration of the module and is type-checked; `tests/check/wayland_window.al` keeps the
example compiling.

## Regenerating

`./build/alc run tools/gen_wayland.al` (from the repository root) rewrites `std/wayland.al`
and `tests/check/wayland.al` from `/usr/share/wayland/wayland.xml` and the `wayland-protocols`
files (the list `PROTOCOLS` at the top of the generator; add a protocol there to bind it). The
hand-written part (the library functions, xkbcommon, cursor) is `tools/wayland_helpers.al`;
edit it there, not in `std/wayland.al`. With `-- --verify` it also builds a C program from
`wayland-scanner`'s output and an AL program from the bindings, both printing every interface
table, opcode and enum value, and compares them (`tables: no mismatches in 633 lines`).
