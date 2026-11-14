# Structuring a game in AL

This is the shape the standard library is built to support. The complete example is
[examples/starter](../examples/starter) (`logic.al`, the game, about 220 lines; `game.al`, a
minimal front end on the software framebuffer: a playable shooter that also runs headless and
prints a checksum, which is how it is tested). [examples/dx12_starter](../examples/dx12_starter)
is the same game drawn with the GPU.

## The frame

```
input ──> update (fixed step, repeated 0..n times) ──> render (reads state only) ──> present
```

```
clock := frame_clock()
steps := fixed_step(120.0)                     // simulation rate, independent of display rate
while !w.should_close() {
    w.poll()                                   // the only place the outside world enters
    for k in 0..steps.advance(clock.tick()) {
        update(&g, &w.input, f32(steps.step))  // every change to the game happens here
    }
    render(&r, &g, steps.alpha())              // your renderer; alpha: how far between two steps we are
}
```

- **Fixed timestep.** `update` always gets the same `dt`; physics and timers behave the same
  at 30 and 240 frames per second, and a run can be replayed from its inputs.
- **Rendering does not mutate.** `render` takes the game and draws it. Interpolate with
  `alpha` instead of simulating in the renderer.
- **One state struct.** Everything the game is lives in a `Game` value passed by pointer:
  no hidden globals, so saving, resetting and running two games side by side are trivial.
- **Seeded randomness.** The game owns an `Rng`; nothing uses a global generator.
- **Input through actions.** Game code asks `keys.action_down(inp, act.fire)`, never
  `key_down(KEY_SPACE)`; bindings are data.
- **Headless first.** `update` and `render` need no window. Drive them with scripted `Event`s
  fed to an `Input` and compare a checksum: that is a regression test for the whole game.
- **`f32` by default, `f64` where precision matters.** A float literal without a type from its
  context is an `f32`, the type of `vec2`..`mat4`, of GPU data and of the math functions game
  code calls (`speed := 4.5`, `sin(angle)`, `lerp(a, b, 0.25)`). Keep `f64` (declared:
  `t: f64 = 0.0`) for absolute time, long-running accumulators, money-like totals and large
  world coordinates; `frame_clock`, `FixedStep` and `Timer` keep their time in `f64` and accept
  an `f32` `dt` or period too. Convert at the boundary: `f32(steps.step)`, `f64(x)`.

## Entities: fat structs and tagged unions

AL has no entity-component framework, on purpose. Two plain representations cover games well
and keep every system a simple loop:

**Fat struct**: one struct with every field any kind of entity needs, plus a `kind`.

```
enum Kind { Player, Rock, Shot }
struct Entity { kind: Kind, pos: vec2, vel: vec2, radius: f32, life: f32, hp: i32, color: u32 }

for i in 0..g.ents.len {
    if !g.ents.is_live(i) { continue }
    e := &g.ents.items[i]
    e.pos = e.pos + e.vel * dt                 // shared behaviour: no dispatch at all
    match e.kind {                             // kind-specific behaviour
        Shot => { e.life -= dt }
        _ => {}
    }
}
```

**Tagged union**: an `enum` with data when the kinds share little. `match` must cover every
variant, so adding a kind makes the compiler point at every place that has to handle it.

```
enum Item { Weapon(i32, f32), Potion(i32), Key(str) }

fn describe(it: Item) -> str {
    match it {
        Weapon(damage, range) => fmt("weapon ", damage)
        Potion(heal) => fmt("potion +", heal)
        Key(door) => fmt("key to ", door)
    }
}
```

Mix them freely: a fat `Entity` whose `brain` field is a tagged union of AI states.

Store entities in a `Pool[Entity]` and keep `Handle`s, never pointers or indices, across
frames: a handle to a removed entity simply stops resolving (`get` returns nil), even when its
slot has been reused.

```
g.target = g.ents.insert(Entity{kind: Rock, pos: p})
...
t := g.ents.get(g.target)
if t != nil { aim_at(t.pos) }
```

Short-lived things that nothing refers to by handle (shots, particles, floating texts) can live
in a plain `Vec`. Remove the dead ones once per step with `retain`, not with `remove` inside a
loop over the indices (that skips the element after each removed one and moves the rest every
time):

```
g.shots.retain(fn(s: Shot) -> bool { s.life > 0.0 })     // one pass, the order is kept
g.sparks.retain(g.arena, fn(r: f32, p: Spark) -> bool { length(p.pos) < r })   // with a context
```

When the order does not matter, `v.swap_remove(i)` removes one element in constant time (the
last element takes its place: look at index `i` again).

## Memory

There is no `free` and no garbage collector, so there is nothing to leak or double-free:
memory is an arena that is released in bulk at the points where a game naturally forgets
things.

| Lifetime | How |
|----------|-----|
| the whole program (window, assets, pools) | allocate at start-up, never release |
| a level | `m := mark()` before loading, `release(m)` when leaving; or a `Region` entered while loading and `reset` when leaving |
| a frame (scratch strings, lists built for one frame) | `frame_begin()` ... `frame_end()` around the frame |
| objects that come and go (entities, particles, sounds) | a `Pool[T]`: slots are reused, the pool itself never grows past its capacity unless asked to |

Do not allocate per entity or per frame outside these patterns; `mem_used()` at the end of
each frame should be constant once a level is running.

**Jobs on threads.** For work that splits into independent pieces (path finding for many
agents, culling, procedural generation), start `cpu_count() - 1` workers with `thread_spawn`
(std.os) once, at start-up. They share a job queue: a `Mutex`, a `Cond` the workers `wait` on,
and an `atomic_add` counter of unfinished jobs the frame spins or waits on. Each job writes only
its own slot of a result array (no lock needed); a worker brackets each job with
`m := mark()` ... `release(m)` (or a region it resets), so its arena stays bounded, and results
that must outlive the job go into memory the main thread owns. Keep the simulation's order
deterministic: merge results in job order, not in finishing order. A panic in a job ends the
game like one in the main loop.

## Systems are functions

A system is a function over the state, called from `update` in a fixed order:

```
fn update(g: *Game, inp: *Input, dt: f32) {
    control_player(g, inp, dt)
    spawn(g, dt)
    move_all(g, dt)
    collide(g)
    reap(g)
}
```

Overloading keeps names short and uniform across types (`update(p: *Player)`,
`update(e: *Emitter)`, `length(v)`, `draw(s: Sprite)`), and `x.f()` is only another spelling of
`f(x)`, so there is no method/free-function split to design around.

## Data layout

- `vec2`/`vec3`/`vec4`/`quat`/`mat4` are values in SSE registers; arithmetic on them compiles
  to packed instructions. Write `p = p + v * dt`, not per-component code.
- Structs have C layout, vectors are plain `f32`s in memory: a `[]Vertex` is ready to upload
  (`as_bytes(vertices)`), and a struct matches the same struct in a shader or a C header.
- Hot loops over one or two fields of many entities are the case for splitting those fields
  into their own arrays (`pos: []vec3`, `vel: []vec3`); start with the fat struct and split only
  what a profile points at.

## Rendering

The standard library gives bindings, not a renderer: `std.vk` (Vulkan) and `std.dx12`
(Direct3D 12, Windows), on top of the platform layer (`std.window` with the native handles a
GPU surface needs, `std.input`, `std.audio`, `std.time`). Device set-up, swap chain,
pipelines, buffers and the sprite, tile or mesh drawing are the game's own code, shaped by
what the game needs.

- **Vulkan**: [std/vk.md](std/vk.md) has the workflow: shaders compiled to SPIR-V with `glslc`
  ahead of time and built into the executable with `embed("shader.vert.spv")` (or at run time
  with `std.shaderc`, for hot reload), a surface from the window's native handles, validation
  layers through the debug-utils messenger. Vsync is the present mode: FIFO by default, MAILBOX
  for low latency where offered.
- **Direct3D 12**: [std/dx12.md](std/dx12.md): HLSL compiled at run time with `D3DCompile`, a
  swap chain on `win32_hwnd(w)`.
- **The examples are reference code, not a library**: read them, copy what helps, change it.
  `examples/vk_triangle.al` and `examples/dx12_triangle.al` are complete minimal programs;
  `examples/vk_renderer/` uses most of what an engine needs from Vulkan (1.3 features, textures,
  depth, compute, frames in flight, swapchain recreation, validation);
  `examples/gamekit/dx12_gpu.al` (device with WARP fallback, fences, shader compilation, a
  sprite batcher) and `screen.al` (frames in flight, a virtual resolution letterboxed into the
  window, resizing) are what the two DX12 games draw with.
- `present` of std.window shows a CPU pixel buffer in the window (`blit_fit` scales one into
  it): the way to display pixels computed on the CPU, for tools, debugging views and simple
  programs such as `examples/starter/game.al`.

## Platform shell

- `std.window` + `std.input`: window, events, native handles for GPU surfaces
  (`x11_display(w)` / `x11_window(w)`, `win32_hwnd(w)`), gamepads; the same API on Linux (X11;
  on a Wayland session through XWayland) and Windows (Win32, XInput):
  `examples/starter/game.al` runs unchanged on both. `std.wayland` binds the Wayland client API
  for a program that wants to talk to the compositor itself.
- In the loop: skip rendering while `w.minimized`, rebuild the swapchain on `EventResize`;
  mouse-look with `set_cursor_locked(w, true)` and `mouse_delta`; gamepads plugged in later
  appear through `gamepad_changed` (see [std/window.md](std/window.md), [std/input.md](std/input.md)).
- `std.vk`, `std.dx12`: see [Rendering](#rendering).
- `std.audio`: mix in the game loop with `audio_pump(dev, &mixer)` once per frame (ALSA on
  Linux, WASAPI on Windows); the mixer is pure code and can be tested without a device.
- `std.image`, `std.asset`: loading; keep file access in a load phase, not in `update`. Saves
  and settings go in `data_dir(app)` / `config_dir(app)` (per user, per system).

A program that never opens a window or a device (a test run, a server, a tool) uses none of
the system libraries and is a static executable.

## Platform code and build flags

Code that differs per system goes in `when` branches, and a demo or debug build is a constant
set on the command line; neither costs anything in the other build:

```
const DEMO = false                      // alc build -D DEMO game.al: the demo build
const DEBUG_DRAW = false

when TARGET_OS == Windows {                // (std.os: run; saves go in std.asset's data_dir)
    fn open_url(url: str) { run([]str{"cmd", "/c", "start", "", url}) }
} else {
    fn open_url(url: str) { run([]str{"xdg-open", url}) }
}

fn update(g: *Game, inp: *Input, dt: f32) {
    if DEMO && g.level > 3 {            // decided at compile time: the full game has no trace of it
        g.screen = BuyScreen
        return
    }
    ...
}
```

Only the taken branch of a `when` is type-checked, so `alc check --all-targets game.al`
checks the game for Linux and Windows at once.

## Windows

**Building and shipping.** `alc build --target windows --gui game.al -o game.exe` makes one
executable that needs only DLLs every Windows 10/11 has (kernel32, user32, gdi32, ole32, d3d12,
dxgi, d3dcompiler_47; xinput1_4 is loaded only if a gamepad is opened). `--gui` gives it no
console window when started from Explorer; started from a terminal it still prints there, and a
panic also shows a message box ([DETAILS.md](DETAILS.md#windows)). Build assets into the
executable with `embed("file.png")` + `image_decode`: the working directory of a program started
from Explorer or a shortcut is not its own folder. Build from Linux; test under Wine
(`tests/run.sh --target windows`) and then on Windows.

**Which modules work where.** Pure AL, the same results everywhere: the core library, std.input
(events, `ActionMap`), the std.audio mixer, std.image, std.time's `FixedStep` / `Timer`.
Both systems with a per-OS layer: std.window, gamepads (XInput on Windows), std.audio devices
(WASAPI). Windows only: std.dx12. Linux only: std.vk, std.shaderc, std.x11, std.wayland, std.alsa.

**Structure of a Direct3D 12 game** (examples/dx12_starter, examples/dx12_breakout):

```
logic.al     state, rules, menus, the fixed step; events for sounds     (portable)
sound.al     sounds generated at start-up, events -> mixer voices          (portable)
headless.al  scripted input, N frames, checksums of state and mix          (portable)
game.al      window, GPU, sound device, drawing; `--headless` runs headless.al (Windows)
```

The frame: `w.poll()`; `if !inp.focused { pause }`; menu and command edges read once
(`handle_input`); `for k in 0..steps.advance(clock.tick()) { update(...) }`; play the events on
the mixer; `audio_pump(dev, mixer)`; draw and `Present` (vsync paces the loop).
[examples/gamekit](../examples/gamekit) has the parts both games share, as example code:
`dx12_gpu.al` (device, fences, shaders, a sprite batcher), `screen.al` (a swap chain on the
std.window window, two frames in flight, a fixed virtual resolution letterboxed into any window
size or fullscreen, resizing while the window is dragged), `font.al` (a 5 x 7 bitmap font baked
into the atlas), `synth.al` (tones, noise, sweeps and music rendered through a mixer),
`options.al`. A lost sound device (`dev.lost`) is shown and recovers by itself; a removed
GPU ends the game with a panic that names the reason. The headless run is the regression test:
`tests/std/dx12_*_sim` prints the same checksums on Linux as `tests/sys/dx12_*` on Windows.
