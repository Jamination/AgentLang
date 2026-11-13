# std.window: windows, events and software presentation

`use std.window` opens a native window (X11 on Linux, Win32 on Windows), delivers its events,
keeps the per-frame input state (`std.input`, included automatically) and can show an RGBA
framebuffer without any GPU API. It also hands out the native handles needed to create a
Vulkan surface (Linux) or a DXGI swapchain (Windows). The API and the events are the same on
both systems; the differences are listed in [Windows](#windows).

The window system lives in the module's OS layer: `std/window_linux.al` (X11) or
`std/window_windows.al` (Win32), loaded with `use std.window` for the target.

- **Linux:** a program that calls `window_open` is dynamically linked against `libX11.so.6`
  (and libc). On a Wayland session it runs through XWayland; a program that wants to talk to
  the compositor itself uses the bindings of [std.wayland](wayland.md). The helper functions
  that need no display (`key_from_keysym`, `fit_rect`, `blit_fit`, ...) do not pull the
  library in.
- **Windows:** the program imports `user32.dll`, `gdi32.dll` and `kernel32.dll` (all part of
  Windows); no C run-time library.

## Opening a window

```
w, ok := window_open("My game", 1280, 720)                 // fixed-size window
w, ok := window_open(WindowDesc{title: "My game", width: 1280, height: 720,
                                resizable: true, fullscreen: false})
if !ok { ... no display: run headless or exit ... }
```

| `WindowDesc` field | |
|--------------------|---|
| `title: str` | window title (UTF-8) |
| `width`, `height: i64` | size of the drawable area in pixels; 0 means 640 x 480 |
| `resizable: bool` | let the user resize the window (default: fixed size) |
| `fullscreen: bool` | start fullscreen |
| `display: str` | X display to connect to, e.g. `":1"`; empty means `$DISPLAY` (not used on Windows) |

`window_open` returns `(nil, false)` when the display cannot be reached (no X server,
`DISPLAY` unset; on Windows: the window cannot be created); it never aborts the program for
that. The `Window` is allocated once from the arena; no other window function allocates from
the arena.

## Functions

| Function | |
|----------|---|
| `window_open(title: str, width, height) -> (*Window, bool)` | open a fixed-size window on the default display |
| `window_open(d: WindowDesc) -> (*Window, bool)` | open a window as described |
| `poll(w)` | start a new input frame and process all pending events; never blocks |
| `next_event(w) -> (Event, bool)` | take the next event received by the last `poll` |
| `should_close(w) -> bool` | the user asked to close the window (or it was closed) |
| `size(w) -> (i64, i64)` | current width and height of the drawable area |
| `set_title(w, title: str)` | change the title |
| `set_cursor_visible(w, visible: bool)` | hide / show the mouse pointer over the window |
| `set_fullscreen(w, on: bool)` | switch between fullscreen and windowed |
| `present(w, pixels: []u8, pw, ph) -> bool` | show an RGBA8 framebuffer of `pw` x `ph` pixels |
| `mouse_in_frame(w, pw, ph) -> vec2` | mouse position in pixels of a framebuffer shown with `present` |
| `close(w)` | destroy the window and disconnect |
| `x11_display(w) -> *u8` | Linux: the Xlib `Display*` (nil after `close`) |
| `x11_window(w) -> u64` | Linux: the X11 window id |
| `win32_hwnd(w) -> *u8` | Windows: the `HWND` (nil after `close`) |

Public fields of `Window`: `input` (an `Input`, see [input.md](input.md)), `events` (the
`EventQueue`), `width`, `height`, `closing`, `fullscreen`, `cursor_hidden`. The field `os`
(a `WindowOs`, different per system) holds the backend's handles. The native-handle accessors
exist only on their system, like the backend's helpers below.

### Frames and events

`poll(w)` is the single point where the outside world enters the program. It

1. calls `begin_frame(&w.input)`,
2. reads every pending event from the display, translates it to an `Event`, applies it to
   `w.input` and appends it to `w.events` (the events of the previous `poll` are discarded;
   if more than `EVENT_QUEUE_CAP` arrive in one frame the rest only update `w.input` and are
   counted in `w.events.dropped`),
3. updates `w.width` / `w.height` and sets `w.closing` when the user closes the window.

Most games only query `w.input` (or an `ActionMap`) after `poll`; the event queue is for
things that need the individual events in order (text fields, key-binding menus, reacting to
`EventResize`):

```
w.poll()
loop {
    e, more := w.next_event()
    if !more { break }
    match e.kind {
        EventResize => resize_render_targets(e.x, e.y)
        EventText => insert_char(e.codepoint)
        _ => {}
    }
}
```

Closing is a request: `should_close(w)` becomes true and the window stays open until the
program calls `close(w)`, so the game can save or ask first. To quit from game code set
`w.closing = true`. After `close`, the `Window` remains a valid closed window: `should_close`
is true, `present` returns false and the other calls do nothing.

Keyboard details: key codes come from the unshifted symbol of the key on the user's layout.
Auto-repeat arrives as `EventKeyDown` with `repeat` set (it sets `key_repeated`, not
`key_pressed`). Text arrives separately as `EventText`, already composed by the system's input
method (layout, shift, dead keys, compose sequences / IME) and delivered as Unicode code points;
control characters are filtered out. `mods` of key and mouse events are the modifiers held
before the event (pressing Shift reports no Shift, releasing it does). Mouse wheel motion is
`EventWheel`, not a button.

### Software presentation

`present(w, pixels, pw, ph)` shows a framebuffer of 4 bytes per pixel (R, G, B, A; rows top
to bottom; alpha ignored). The framebuffer does not need to match the window: it is scaled
with nearest-neighbour sampling to the largest size that keeps its aspect ratio, centered,
with black bars. A game can therefore render at a fixed internal resolution (say 320 x 180)
and let the window be any size, including fullscreen; `mouse_in_frame(w, pw, ph)` converts the
pointer position back to framebuffer pixels.

`present` converts into a window-sized buffer and draws it at 1:1: with `XPutImage` on Linux
(C heap; returns false for a display that is not 24/32-bit true color), with GDI's
`StretchDIBits` from a top-down 32-bit DIB on Windows (process heap). The buffer is
reallocated only when the window size changes. The cost is one pass over the window's pixels
plus the transfer: fine for 2D and retro-style rendering, not a replacement for a GPU at 4K.
There is no vertical sync on this path: pace the loop yourself (sleep, as in the example).
`present` returns false for a closed window.

The pure helpers behind it are public: `fit_rect(dw, dh, sw, sh) -> (x, y, w, h)` (the centered
aspect-preserving rectangle) and `blit_fit(dst: []u32, dw, dh, src: []u8, sw, sh, swap_rb)`
(scale + convert RGBA8 to packed 32-bit pixels).

### Vulkan

For `VK_KHR_xlib_surface`, pass `x11_display(w)` as `dpy` and `x11_window(w)` as `window` of
`VkXlibSurfaceCreateInfoKHR`. Recreate the swapchain on `EventResize`. Do not mix `present`
with a GPU swapchain on the same window.

### Direct3D 12 (Windows)

Pass `win32_hwnd(w)` to `IDXGIFactory2.CreateSwapChainForHwnd` ([std.dx12](dx12.md)) and
resize the buffers on `EventResize` (`size(w)` is the client size in pixels). A program that
renders with Direct3D never calls `present`. std.dx12 declares Win32 names publicly (`RECT`,
`MSG`, `CreateWindowExW`, ...); the ones std.window uses are private to it, so a program can use
both modules.

### X11 helpers (Linux)

| Function | |
|----------|---|
| `key_from_keysym(ks: u64) -> i64` | `KEY_*` code for an X11 keysym (`KEY_UNKNOWN` if none) |
| `mods_from_x11(state: u32) -> u8` | `MOD_*` bits for an X11 modifier mask |
| `event_from_x11_button(button, pressed, x, y, mods) -> Event` | mouse / wheel event for an X11 button number |

`std.x11` (included by this module) declares the raw Xlib functions with their C names
(`XOpenDisplay`, `XCreateSimpleWindow`, `XNextEvent`, `XPutImage`, `XInternAtom`, ...), the
structs `XEvent` (an opaque 192-byte block read with `x_event_type`, `x_event_x`,
`x_event_detail`, ... ), `XSizeHints`, `XColor`, and constants with an `X_` prefix
(`X_KEY_PRESS`, `X_STRUCTURE_NOTIFY_MASK`, ...). Use it for anything this module does not
cover; the display and window id of a `Window` are valid arguments for all of it.

### Win32 helpers (Windows)

| Function | |
|----------|---|
| `key_from_vk(vk: u32, scan: u32, extended: bool, ch: u32) -> i64` | `KEY_*` code for a virtual key with the scan code and extended flag of its message and its unshifted character (`MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR)`) |
| `event_from_win32_button(msg: u32, wparam: u64, x, y, mods) -> Event` | mouse press / release for `WM_LBUTTONDOWN` .. `WM_XBUTTONUP` (`EventNone` for other messages) |

## Windows

The same program runs on Windows with the same events; what differs:

- **Pixels and DPI.** The process is made per-monitor DPI aware (v2; system aware before
  Windows 10 1703) when the first window opens. `width`, `height`, `size(w)`, `EventResize` and
  mouse positions are physical pixels, as on X11, and Windows does not rescale the picture. A
  window opens with a client area of the requested pixels and keeps that pixel size when it
  moves to a monitor of another scale, so on a 200 % display it looks half as large as on a
  100 % one; choose the size from the screen or use fullscreen.
- **Fullscreen** is a borderless window covering the monitor the window is on (no change of
  display mode); windowed restores the previous position and size.
- **Keys.** Keys that type a character are named by their unshifted character on the layout,
  as on X11 (on QWERTZ the key right of T is `KEY_Z`). Letter and digit keys whose character
  has no key code (the digit row of AZERTY, non-Latin layouts) fall back to their virtual key:
  `KEY_1`, `KEY_A`, ... (X11 reports `KEY_UNKNOWN` for those it cannot name). The navigation
  keys of the keypad are `KEY_KP_*` whatever the state of Num Lock, as on X11. AltGr is one
  `KEY_RALT` (the left Ctrl that Windows sends with it is dropped). Print Screen, of which
  Windows reports only the release, gives a press and a release when it is released. When both
  Shift keys are held, Windows reports only the last release; the window releases both then.
- **Text** comes from `WM_CHAR` (layout, dead keys, IME); characters outside the BMP arrive as
  one code point. As on X11, Alt+letter also types the letter.
- **Mouse.** While a button is held the window keeps the pointer (positions outside the window,
  as with the X11 grab). One `EventWheel` step per notch (`WHEEL_DELTA`, 120); finer motion of
  touchpads accumulates into steps; `y > 0` away from the user, `x > 0` to the right.
- **System keys.** Alt and F10 do not enter the window-menu mode (which would stop the game);
  Alt+F4 is an `EventClose`, Alt+Space still opens the window menu.
- **Minimizing** keeps the size (no `EventResize` to 0 x 0).
- **Moving and resizing.** While the user drags or resizes the window (or a window menu is
  open), Windows runs a loop of its own inside the message dispatch. `poll` pumps messages on a
  fiber of its own and leaves that loop on a timer, so it returns every 10-16 ms during the drag
  and the game keeps running, with `EventResize` as the size changes.
- **Timing of events.** Events caused by the program's own calls (`set_fullscreen`, creating a
  swapchain) arrive at the next `poll`, as on X11.
- A program built with `--target windows` is a console program: started from Explorer it also
  gets a console window. `alc build --target windows --gui` makes a GUI program that gets none
  (and attaches to the console it is started from: [DETAILS.md](../DETAILS.md#windows)).

`examples/win32_input.al` prints every event it receives on either system: the quickest way
to see what a keyboard, mouse or gamepad delivers.

## Structuring a game on top of it

The example below is a complete program and a recommended skeleton:

- **State is explicit.** Everything the game knows lives in one `Game` struct; functions take
  it as a parameter. No globals: the state can be copied, saved, compared and tested.
- **Input is translated once.** After `poll`, raw keys become game `Controls` through an
  `ActionMap`; the simulation never sees key codes.
- **Fixed timestep.** The simulation advances in steps of constant length regardless of the
  frame rate, so it behaves the same on every machine and is reproducible from the same
  inputs. Real time is accumulated and consumed in whole steps (bounded, so a long pause does
  not cause a burst of catch-up steps); the remainder gives `alpha` for interpolated drawing.
  The core `time` module provides this accumulator as `FixedStep` (`fixed_step(hz)`,
  `advance`, `alpha`) together with `FrameClock` and `sleep_ns`; the example spells the few
  lines out with `clock_ns()` so that it depends only on the modules documented here.
- **Edges are latched.** A frame may run zero or several simulation steps, so "pressed this
  frame" must not be read inside the step. `Controls.beep` is set when the press is seen and
  cleared by the step that acts on it.
- **One place for output.** Rendering reads the state and never changes it; `audio_pump` keeps
  the sound device fed once per frame (see [audio.md](audio.md) for latency).
- **Degrade gracefully.** No display: report and exit (or run headless). No sound device:
  `audio_open` returns nil and the audio calls do nothing. No gamepad: `gamepad_open` is false.

```
// A minimal game loop: window + input + audio + fixed timestep, drawing in software.
// Move the square with WASD / arrow keys (or a gamepad), Space or a click beeps, Escape quits.
use std.window
use std.audio

const FB_W = 320                         // framebuffer size; `present` scales it to the window
const FB_H = 180
const STEP_NS = 1_000_000_000 / 120      // the simulation runs at exactly 120 steps per second
const STEP: f32 = 1.0 / 120.0

const ACT_LEFT = 0
const ACT_RIGHT = 1
const ACT_DOWN = 2
const ACT_UP = 3
const ACT_BEEP = 4
const ACT_QUIT = 5

// What the player wants, sampled once per frame. Edge-triggered actions are latched until a
// simulation step has consumed them, so they are neither lost nor seen twice.
struct Controls {
    dir: vec2
    beep: bool
}

// The whole game state: plain data, no globals.
struct Game {
    pos: vec2
    prev: vec2       // position one step ago, for interpolated drawing
    beeps: i64
}

fn bindings() -> ActionMap {
    m := action_map()
    m.bind_key(ACT_LEFT, KEY_A)
    m.bind_key(ACT_LEFT, KEY_LEFT)
    m.bind_key(ACT_RIGHT, KEY_D)
    m.bind_key(ACT_RIGHT, KEY_RIGHT)
    m.bind_key(ACT_DOWN, KEY_S)
    m.bind_key(ACT_DOWN, KEY_DOWN)
    m.bind_key(ACT_UP, KEY_W)
    m.bind_key(ACT_UP, KEY_UP)
    m.bind_key(ACT_BEEP, KEY_SPACE)
    m.bind_mouse(ACT_BEEP, MOUSE_LEFT)
    m.bind_pad(ACT_BEEP, PAD_A)
    m.bind_key(ACT_QUIT, KEY_ESCAPE)
    m
}

// One fixed simulation step: the only place where the game state changes.
fn step(g: *Game, c: *Controls, mixer: *Mixer, beep: Sound) {
    g.prev = g.pos
    g.pos = g.pos + vec2(c.dir.x, -c.dir.y) * (90.0 * STEP)
    g.pos.x = fmin(fmax(g.pos.x, 0.0), f32(FB_W - 16))
    g.pos.y = fmin(fmax(g.pos.y, 0.0), f32(FB_H - 16))
    if c.beep {
        c.beep = false
        g.beeps += 1
        pan := g.pos.x / f32(FB_W - 16) * 2.0 - 1.0
        mixer.play(beep, 0.5, pan, 1.0 + f32(g.beeps % 5) * 0.25, false)
    }
}

// Draws the state `alpha` (0..1) of the way from the previous step to the current one.
fn render(g: *Game, fb: []u8, alpha: f32) {
    for i in 0..FB_W * FB_H {
        fb[i * 4] = 24
        fb[i * 4 + 1] = 28
        fb[i * 4 + 2] = u8(40 + i / FB_W / 3)
    }
    p := g.prev + (g.pos - g.prev) * alpha
    x0 := i64(p.x)
    y0 := i64(p.y)
    for y in y0..y0 + 16 {
        for x in x0..x0 + 16 {
            i := (y * FB_W + x) * 4
            fb[i] = 255
            fb[i + 1] = u8(200 - g.beeps % 5 * 40)
            fb[i + 2] = 64
        }
    }
}

fn main() {
    w, ok := window_open(WindowDesc{title: "AL game loop", width: 960, height: 540, resizable: true})
    if !ok {
        print("cannot open a window (no display?)")
        return
    }
    mixer := mixer_new(48000, 2, 16)
    dev, _ := audio_open(48000, 2)       // nil without a sound device: audio_pump then does nothing
    beep := sound_tone(48000, 660.0, 0.08, 0.6)
    actions := bindings()
    gamepad_open(&w.input.pad, 0)        // optional; false if none is plugged in
    fb := alloc[u8](FB_W * FB_H * 4)
    controls: Controls
    game := Game{pos: vec2(152.0, 82.0), prev: vec2(152.0, 82.0)}
    max_frames := if len(args()) > 1 { parse_i64(args()[1]).0 } else { -1 }
    frames := 0
    last := clock_ns()
    acc := 0
    while !w.should_close() && frames != max_frames {
        // 1. input: pump the window, then turn raw state into game controls
        w.poll()
        inp := &w.input
        gamepad_poll(&inp.pad)
        controls.dir = actions.action_vec2(inp, ACT_LEFT, ACT_RIGHT, ACT_UP, ACT_DOWN)
        stick := inp.pad.pad_stick(PAD_AXIS_LX, PAD_AXIS_LY, 0.2)
        if stick != vec2(0.0) {
            controls.dir = vec2(stick.x, -stick.y)
        }
        controls.beep = controls.beep || actions.action_pressed(inp, ACT_BEEP)
        if actions.action_pressed(inp, ACT_QUIT) {
            w.closing = true
        }
        if inp.key_pressed(KEY_F11) {
            w.set_fullscreen(!w.fullscreen)
        }
        // 2. simulate: as many fixed steps as real time has passed (at most 0.25 s per frame)
        now := clock_ns()
        acc += min(now - last, 250_000_000)
        last = now
        while acc >= STEP_NS {
            step(&game, &controls, mixer, beep)
            acc -= STEP_NS
        }
        // 3. output: draw the interpolated state, keep the sound device fed
        render(&game, fb, f32(acc) / f32(STEP_NS))
        w.present(fb, FB_W, FB_H)
        audio_pump(dev, mixer)
        frames += 1
        sleep_ns(4_000_000)
    }
    print("frames:", frames, "beeps:", game.beeps)
    audio_close(dev)
    w.close()
}
```

Run it with `alc run game.al`; a number as argument (`alc run game.al -- 600`) stops it after
that many frames, which is handy for automated smoke tests.

## Testing

Window logic that does not need a display is covered by `tests/std/window_fit` (scaling and
conversion, both systems) and `tests/std/window_logic` (X11 key mapping and event translation).
`tests/sys/window_x11` exercises a real X11 window, but only on the display named by the
environment variable `AL_TEST_DISPLAY` (for example an `Xvfb` instance:
`Xvfb :99 & AL_TEST_DISPLAY=:99 tests/run.sh ./build/alc window`); without it the
test is skipped, so the test suite never opens a window on the desktop it runs on.

On Windows (`tests/run.sh --target windows`, under Wine with its null display driver: windows
exist and get messages, nothing is shown), `tests/sys/window_win32` opens a real Win32 window
and checks the key table, posted and `SendInput` keyboard messages, text, mouse buttons and
wheel, focus loss, `present` (pixels read back with `GetPixel`), the pointer, fullscreen, close
requests and leaving a modal move loop; `tests/sys/window_dx12` uses std.window together with
std.dx12. Both are skipped on Linux.
