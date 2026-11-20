# std.gfx

`use std.gfx`. A small 2D renderer on a [std.window](window.md) window: textures from
[std.image](image.md) images (also one-channel coverage, for font atlases), sprites with a
source rectangle, rotation, origin and tint, filled rectangles, lines, triangles with a colour
per corner, alpha and additive blending, a 2D transform (camera, virtual resolution), scissor,
render textures; TrueType text with `use std.gfx_text` ([Text](#text)). Draws are batched:
consecutive draws with the same texture and state become one draw call.

One API, a backend per target that the program never names: **Direct3D 12** on Windows
(`std/gfx_dx12.al`, derived from `examples/gamekit/dx12_gpu.al`), **Vulkan 1.3** on Linux
(`std/gfx_vk.al`, derived from `examples/vk_renderer`; an X11 window, or a window of std.window's
experimental Wayland backend: see [Wayland](#wayland)). The shaders are compiled
ahead of time and built into the module (`std/gfx_shaders.al`): running needs no shader
compiler, and the Direct3D build does not load `d3dcompiler_47.dll`. A program that wants
Vulkan on Windows writes `use std.gfx_vk` instead of `use std.gfx` (the tests do, to compare
the backends); everything else stays the same.

```
use std.window
use std.image
use std.gfx

fn main() {
    w, _ := window_open(WindowDesc{title: "gfx", width: 960, height: 540, resizable: true})
    g, err := gfx_open(w, GfxDesc{})
    if err != "" { panic(err) }
    img, _ := image_load("ship.png")
    ship := g.texture(img, FilterNearest)
    angle := 0.0
    while !w.should_close() {
        w.poll()
        angle += 0.02
        if g.begin_frame(0xFF201810) {                  // false while minimized: skip the frame
            g.set_view(320.0, 180.0)                     // draw in 320 x 180, letterboxed
            g.rect(vec4(0.0, 0.0, 320.0, 180.0), 0xFF402010)   // 0xAABBGGRR: dark blue
            g.sprite(ship, vec4(0.0, 0.0, f32(ship.w), f32(ship.h)), vec2(160.0, 90.0),
                vec2(32.0), angle, vec2(16.0), 0xFFFFFFFF)   // turned about its centre
            g.line(vec2(10.0, 170.0), vec2(310.0, 170.0), 2.0, 0xFF00FF00)
            err = g.end_frame()                          // draws, presents (vsync)
            if err != "" { panic(err) }                  // the device was lost: why
        }
    }
    gfx_close(g)
    w.close()
}
```

[examples/gfx_starter](../../examples/gfx_starter/game.al) is a complete game on it (a
procedural sprite atlas, additive particles, bloom and frosted panels from render textures).
More in `examples/`: `gfx_fireworks` (particles, a bloom chain, a mirrored reflection),
`gfx_lights` (shadow-casting lights; light times albedo from alpha and additive blending),
`gfx_parallax` (pixel art in a virtual resolution), `gfx_lowpoly` (a 3D landscape from
`triangle`), `gfx_flow` (render-texture feedback). Each takes `--shot file.png` to draw a
frame offscreen.

## Conventions

- **Coordinates** are pixels of the current target, origin top left, y down, before the
  transform. A rotation by a positive angle turns clockwise on screen.
- **Rectangles** are `vec4`: `(x, y, w, h)`.
- **Colours** are `u32` RGBA8 with red in the lowest byte, as `rgb8(r, g, b)`, `rgba8(r, g, b, a)`
  (bytes, usable in a `const`) and `color_u32(vec4(r, g, b, a))` of std.math give them: a literal
  reads `0xAABBGGRR` (`0xFFFFFFFF` white, `0xFF0000FF` red; `rgb8(255, 0, 0)` says it plainly).
  Blending uses straight (not premultiplied) alpha.
- **Errors**: what depends on the machine (no device, a lost device) is returned as text;
  misuse (drawing outside a frame, a freed texture) stops the program with a message.

## Opening and frames

```
struct GfxDesc {
    max_quads: i64        // sprites + rectangles + lines per frame; 0: 16384 (a triangle counts half)
    max_textures: i64     // textures alive at once; 0: 256
    software: bool        // the software rasterizer: WARP (Direct3D 12), a CPU device such as lavapipe (Vulkan, if installed)
    debug: bool           // the Direct3D 12 debug layer / Vulkan validation layer (with synchronization validation), if installed
}
```

| Function | |
|---|---|
| `gfx_open(w: *Window, d: GfxDesc) -> (*Gfx, str)` | the first hardware device (discrete before integrated), else (Direct3D 12) WARP; a swap chain on the window. `(nil, why)` if there is none |
| `gfx_offscreen(width, height, d) -> (*Gfx, str)` | no window: the screen is an image that `read_pixels` returns after `end_frame` (tests, screenshots, tools) |
| `begin_frame(g, clear: u32) -> bool` | starts a frame cleared to `clear`; follows the window's size and `g.vsync`; waits for the frame two frames back. `false`: nothing to draw into (minimized, after a 10 ms sleep so a loop does not spin; or the device is lost): draw nothing, do not call `end_frame` |
| `end_frame(g) -> str` | replays the frame on the GPU and presents it; `""` or why it failed |
| `gfx_close(g)` | waits for the GPU and releases everything (not the window) |

Fields of `Gfx` to read: `width`, `height` (the screen in pixels: the window's drawable area),
`device` (the GPU's name, `"... (WARP)"`), `lost` (`""`, or why the device stopped), `stats`
(of the last finished frame: `frames`, `draw_calls`, `vertices`, `passes`, `dropped`). To set:
`vsync` (default true; false presents at once: Direct3D 12 `Present(0, 0)`, Vulkan MAILBOX,
else IMMEDIATE).

**Window size and fullscreen.** Fullscreen is std.window's (`w.set_fullscreen(on)`, a
borderless window; DXGI's own Alt+Enter is switched off). `begin_frame` resizes the swap chain
whenever the window's size differs, also while the user drags an edge; nothing else is needed.

**Device loss** (driver update or crash, GPU reset, unplugged): the failing `end_frame` (or
`begin_frame`) sets `g.lost` to the reason (the Direct3D removal reason, the Vulkan result),
`end_frame` returns it, and from then on `begin_frame` returns false. Recreating the device
and the textures is left to the program (close, `gfx_open` again, upload again); the
examples end with the message.

**Memory.** After `gfx_open` the renderer allocates nothing per frame: vertices go straight
into a mapped GPU buffer per frame in flight, commands into a fixed array, swap-chain
rebuilds into fixed arrays. A frame can therefore sit inside `frame_begin()` / `frame_end()`
of std.mem ([GAMES.md](../GAMES.md#memory)). What does not fit into `max_quads` or the command
array is dropped and counted in `g.stats.dropped`. Two things are allocated in the arena in
use: the error texts (`g.lost`, the result of `end_frame`): read them before `frame_end`; and
`texture` of an image with two or three channels (converted to RGBA first).

## Textures

```
struct Texture { id: i64, w: i64, h: i64 }      // a value to keep and copy; Texture{} is none
enum Filter { FilterNearest, FilterLinear }
```

| Function | |
|---|---|
| `texture(g, img: Image, f: Filter) -> Texture` | uploads the image (waits for the GPU). **One channel is coverage**: drawn as the tint's colour with the channel as alpha (a font atlas: `Image{w, h, 1, coverage}`); two, three and four channels become RGBA |
| `render_texture(g, w, h, f) -> Texture` | an RGBA texture to draw into (`set_target`) and to draw with; transparent at first |
| `update_texture(g, t, x, y, img: Image)` | replaces a region (one channel for a coverage texture, else three or four); waits for the GPU. Called during a frame it changes what the whole frame shows, also draws made before it (they are replayed at `end_frame`) |
| `read_texture(g, t) -> Image` | the pixels (4 channels, 1 for coverage); not during a frame |
| `read_pixels(g) -> Image` | the screen of a `gfx_offscreen` renderer |
| `free_texture(g, t)` | waits for the GPU and releases it; not during a frame |

Filtering clamps at the edges. There are no mipmaps. With straight alpha the linear filter
mixes the colour of transparent texels into the edges of what is drawn: give them the colour
of their neighbours, not black (std.font's 4-channel atlases are white in every pixel; a
coverage texture has no colour to mix).

## Drawing

All between `begin_frame` and `end_frame`, in painter's order.

| Function | |
|---|---|
| `sprite(g, t, x, y: f32)` | the whole texture at its size, top left at (x, y) |
| `sprite(g, t, src: vec4, dst: vec4, tint: u32)` | texture rectangle `src` (texture pixels; a negative w or h mirrors) into rectangle `dst` |
| `sprite(g, t, src, pos: vec2, size: vec2, rotation: f32, origin: vec2, tint)` | `size` large, turned by `rotation` radians about `origin` (a point of the drawn rectangle from its top left corner), which lands on `pos` |
| `rect(g, r: vec4, color: u32)` | filled rectangle |
| `line(g, a, b: vec2, width: f32, color)` | `width` wide, square ends at a and b |
| `triangle(g, a, b, c: vec2, ca, cb, cc: u32)` | a colour per corner, interpolated |
| `clear(g, color)` | fills the whole current target (also outside the scissor) |

Text: [below](#text), `std.gfx_text`.

## Text

`use std.gfx_text` beside `use std.gfx` (or `use std.gfx_vk`): TrueType text from
[std.font](font.md), drawn through the batcher. A separate module, so that a game without text
carries none of the font code (a std.gfx program is as large with `use std.gfx_text` as
without until it calls it: 74,240 bytes for a small offscreen program on Windows, 156,160 with
a font and `draw_text`), and std.font stays usable without a GPU.

```
use std.gfx
use std.gfx_text

f, err := font_load("C:/Windows/Fonts/segoeui.ttf")         // std.font; font_parse(embed("x.ttf"))
font, _ := gfx_font(g, f, 16.0, char_range(32, 126))       // once, at load time
...
g.draw_text(font, 8.0, 8.0, fmt("Score ", score), 0xFFFFFFFF)        // every frame
g.draw_text(font, f32(g.width) - 8.0, 8.0, "HP 3", 0xFF40E0FF, AlignRight)
g.draw_text_box(font, vec4(40.0, 100.0, 300.0, 0.0), story, 0xFFC0C0C0, AlignLeft)
```

```
struct GfxFont { atlas: Atlas, tex: Texture, size: f32, filter: Filter, ... }   // a value to keep and copy
enum TextAlign { AlignLeft, AlignCenter, AlignRight }
```

| Function | |
|---|---|
| `gfx_font(g, f: Font, px: f32, chars: []i64) -> (GfxFont, str)` | rasterises the characters (those the font has) at an em size of `px` pixels into a one-channel atlas (std.font's `atlas_build`, as wide as needed) and uploads it as a coverage texture, linear filter. `""` or what is wrong (a size of 0 or above 2048) |
| `gfx_font(g, a: Atlas, filter) -> GfxFont` | from an atlas of your own (1 or 4 channels) |
| `gfx_font_add(g, &font, chars) -> str` | puts more characters in: a new atlas and texture (the old one is freed: not during a frame) |
| `gfx_font_free(g, font)` | frees the texture (not during a frame) |
| `draw_text(g, font, x, y, text, color: u32)` | UTF-8 text, `'\n'` breaks lines; (x, y) is the top left corner of the first line, whose baseline is the font's ascent below y; kerning from the font |
| `draw_text(g, font, x, y, text, color, align)` | x is the left end, the centre or the right end of every line |
| `draw_text_box(g, font, r: vec4, text, color, align) -> f32` | wrapped into the width of r (at `'\n'` and spaces; a word wider than the box between characters: std.font's `wrap_text`), lines aligned in it from its top; lines that would reach below r are not drawn (a height of 0: no limit). Returns the height of the lines drawn |
| `text_size(font, text) -> (f32, f32)` | the widest line and the number of lines times the line height, as `draw_text` draws it |
| `text_size(font, text, max_w) -> (f32, f32)` | the same wrapped to `max_w`, as `draw_text_box` draws it |
| `line_height(font) -> f32` | baseline to baseline |

**Characters.** A GfxFont has a fixed set of characters; one outside it (or one the font does
not have) is drawn as the font's missing glyph, glyph 0 (usually a box), with that glyph's
advance. Glyphs are not added on demand while drawing: that would rasterise (allocate) and
upload (wait for the GPU) in the middle of a frame, and an atlas that grows inside
`frame_begin()` / `frame_end()` would grow into the frame's scratch memory and be gone after it.
Text known only at run time (a player's name, a chat line) goes through `gfx_font_add` between
frames; a set for a language is given at load time (`char_range(32, 126)` and
`char_range(160, 255)` for Western European text).

**Pixels.** The pen position of every glyph is rounded to a whole pixel of the target, after
the transform, when the transform only scales and moves (also under `set_view`); each glyph
quad then starts on a pixel corner and, at the font's own size, every texel lands on one
pixel: the text is exactly std.font's `draw_text(&img, atlas, ...)` of the same string (see
Tests). Under a turned transform the pens are not rounded and the glyphs are filtered.

**Size and scaling.** A GfxFont is rasterised at one pixel size, `font.atlas.px`. It is drawn
at `font.size` units of the current transform (`px` at first). Drawn larger, by a scaled
`set_view` or `set_transform` or by a larger `size`, its glyphs are magnified by the texture
filter: soft with `FilterLinear`, blocky with `FilterNearest`. For sharp text in a virtual
resolution, rasterise at the size the text has on the screen and draw at the virtual size:

```
view := g.set_view(320.0, 180.0)                              // scale view.x.x, e.g. 3.0 in 960 x 540
hud, _ = gfx_font(g, f, 10.0 * view.x.x, char_range(32, 126)) // when the scale changes, between frames
hud.size = 10.0                                               // 10 virtual pixels, 30 rasterised
```

`examples/gfx_starter` does this (it makes its fonts anew in a Region when the window's size
changes). HiDPI works the same way: `g.width` / `g.height` are physical pixels, so text drawn
without a transform is drawn at `px` physical pixels; multiply `px` by the display's scale
for text of the same apparent size.

**Memory and batching.** `draw_text`, `draw_text_box` and `text_size` allocate nothing (UTF-8
is decoded in place, glyphs are looked up in the atlas, wrapping is computed line by line), so
they sit inside a frame's `frame_begin()` / `frame_end()` with the `fmt` that builds the text.
All text of one GfxFont is one texture: with nothing else in between, it is one draw call.
`gfx_font` and `gfx_font_add` allocate the atlas (keep it out of the frame's scratch memory).

## State

The state applies to the draws after it and is reset by `begin_frame` (identity transform,
alpha blending, no scissor, the screen as target).

| Function | |
|---|---|
| `set_blend(g, b: Blend)` | `BlendAlpha` (`src * a + dst * (1 - a)`) or `BlendAdd` (`src * a + dst`: light, fire) |
| `set_transform(g, m: Xform)` | the transform of everything drawn after it (also of `rect`, `line`, `triangle`) |
| `set_view(g, vw, vh: f32) -> Xform` | a virtual resolution: sets the transform and scissor so that a vw x vh area fills the target as far as it fits, centred, aspect kept, offset on whole pixels; returns the transform (`apply(inverse(m), mouse)` is the mouse in virtual pixels) |
| `set_scissor(g, x, y, w, h: i64)` / `reset_scissor(g)` | draw only inside the rectangle (target pixels, not transformed) |
| `set_target(g, t: Texture)` / `reset_target(g)` | draw into a render texture / the screen again; resets transform and scissor. A texture cannot be drawn into itself |

## Transforms

```
struct Xform { x: vec2, y: vec2, t: vec2 }       // p' = x * p.x + y * p.y + t
```

| Function | |
|---|---|
| `xform_identity()` | (the zero `Xform` is not the identity) |
| `xform_translate(v: vec2)`, `xform_scale(s: vec2)`, `xform_rotate(angle: f32)` | |
| `xform_mul(a, b) -> Xform` | b first, then a (the matrix product a * b) |
| `apply(m, p: vec2) -> vec2`, `inverse(m) -> Xform` | |
| `camera(center: vec2, zoom: f32, rotation: f32, view: vec2) -> Xform` | the world point `center` in the middle of a view of `view` pixels, `zoom` times larger, the camera turned by `rotation` |
| `fit_view(vw, vh: f32, tw, th: i64) -> (Xform, x, y, w, h)` | what `set_view` uses: the transform and the area in target pixels |

A scrolling world under a fixed-resolution HUD:

```
view := g.set_view(320.0, 180.0)
g.set_transform(xform_mul(view, camera(player.pos, 2.0, 0.0, vec2(320.0, 180.0))))
draw_world(g)
g.set_transform(view)                            // the HUD in virtual pixels
draw_hud(g)
```

## How it works

Drawing functions only write vertices (20 bytes: position, texture coordinate, RGBA8 colour;
six per quad, no index buffer) into this frame's region of a persistently mapped upload
buffer and append commands (draw, target, clear) to a fixed array; a draw joins the previous
draw command when the texture, blend mode and scissor are the same, and untextured shapes join
any (their texture coordinate says "no texture"). `end_frame` records one command list from
that: per draw command a texture binding and `DrawInstanced` / `vkCmdDraw`; per target change
the barriers (Direct3D: `PIXEL_SHADER_RESOURCE` <-> `RENDER_TARGET`; Vulkan: dynamic
rendering, `SHADER_READ_ONLY` <-> `COLOR_ATTACHMENT`). Two frames are in flight. Uploads and
read-backs go through a staging buffer and wait for the GPU.

| | Direct3D 12 | Vulkan |
|---|---|---|
| device | first hardware adapter, feature level 11.0; else WARP | Vulkan 1.3 with dynamic rendering and synchronization2; discrete before integrated |
| screen | flip-discard swap chain, 2 buffers, `R8G8B8A8_UNORM` | swapchain, `B8G8R8A8_UNORM` / `R8G8B8A8_UNORM`, FIFO or MAILBOX / IMMEDIATE |
| shaders | DXBC (shader model 5.0) from `tools/gfx/sprite.hlsl` | SPIR-V from `tools/gfx/sprite.vert`, `sprite.frag` |
| textures | `R8G8B8A8_UNORM`; coverage `R8_UNORM` with the view swizzle (1, 1, 1, r) | the same formats and swizzle |
| bindings | root constants (view), a texture table and a sampler table | push constants (view), a combined image sampler set per texture |

Regenerating the shaders (Windows, needs `glslc` of the Vulkan SDK; D3DCompile comes with
Windows): `build\alc.exe run tools/gen_gfx_shaders.al`, then rebuild `alc`. The output is
byte-identical when nothing changed.

## Wayland

**Experimental, run on a headless compositor only.** Everything in this section was written
and reasoned about on a Windows machine. `tests/sys/gfx_wayland` has since passed on Linux
(NVIDIA, driver Vulkan 1.4, headless weston 15 with its GL renderer, no validation message):
frames with and without vsync, fullscreen and back. No desktop compositor (GNOME, KDE, sway,
Hyprland) has been tried yet. The window side is
[std.window's Wayland backend](window.md#wayland), which is itself unverified and used only on
request (`WindowDesc.display` `"wayland"`, `ALC_WINDOW=wayland`, or no X display and
`$WAYLAND_DISPLAY` set).

What the Vulkan backend does for a window with `wayland_display(w) != nil`:

- **Surface.** It enables `VK_KHR_wayland_surface` instead of `VK_KHR_xlib_surface`
  (`__gfx_vk_surface_extension`) and creates the surface from `wayland_display(w)` and
  `wayland_surface(w)`. `vkCreateWaylandSurfaceKHR` is looked up with `vkGetInstanceProcAddr`,
  not imported from `libvulkan.so.1`: AL executables are bound at load time, and an import
  would stop every std.gfx program from starting under a loader built without Wayland. A
  program on X11 imports exactly what it imported before (the same libraries, `DT_NEEDED`
  `libX11.so.6`, `libasound.so.2`, `libc.so.6`, `libdl.so.2`, `libvulkan.so.1` for
  `examples/gfx_starter`, and the same symbols; nothing of libwayland, which std.window loads
  with `dlopen` only when a Wayland window is opened).
- **Size and scale.** A Wayland surface has no size of its own (`currentExtent` is
  0xFFFFFFFF): the swapchain is `size(w)`, the window's pixels, which std.window keeps at the
  surface size times the buffer scale it set on the surface in `window_open`
  (`__gfx_vk_extent`; within the surface's limits and a whole multiple of the scale, which the
  compositor requires of a buffer). std.window keeps that scale for a window that never calls
  `present`, so the scale the surface was told and the buffers the swapchain commits agree; on
  an output of another scale the compositor scales the picture. Do not call `present` on a
  window that std.gfx draws into (it would let the scale change under the swapchain).
  `g.width`, `g.height` are pixels, as on X11 and Windows.
- **Resize.** Wayland never reports the swapchain out of date when the window is resized; the
  window's configure events change `size(w)` in `poll` (std.window acknowledges them there),
  and `begin_frame` compares the size with the swapchain's every frame and recreates it, as it
  does on X11. Poll before `begin_frame`, as in the example above: the first commit after the
  acknowledgement is then a buffer of the new size.
- **Mapping.** `window_open` waits for the first configure (a bounded number of roundtrips) and
  maps the window with a black buffer; the first presented frame replaces it. Neither
  `window_open` nor `gfx_open` waits for a frame callback, so `window_open` then `gfx_open`
  cannot block on the compositor.
- **Hidden windows.** `w.minimized` follows the `suspended` state of xdg-shell 6 (minimized or
  otherwise not visible), and `begin_frame` then skips the frame as for a minimized window. On
  Wayland `vkAcquireNextImageKHR` waits at most 100 ms (an image comes back only when the
  compositor releases its buffer); after that the frame is skipped (`begin_frame` returns
  false) and the program goes on polling. A FIFO present (`vsync`) is paced by the compositor:
  drivers (Mesa) wait for the frame callback of the previous frame, and a compositor that stops
  sending frame callbacks for a hidden window without reporting it `suspended` can make
  `end_frame` (or the next `begin_frame`) wait until the window is shown again. The program
  then pauses (no events are polled) and continues when it is visible: not a deadlock, but
  unverified; `g.vsync = false` (MAILBOX, which does not tear on Wayland) avoids the wait.
- **Order.** `gfx_close(g)` before `w.close()`: the Vulkan surface must go before the
  `wl_surface` and the connection.
- **Connection lost** (the compositor ended): `w.closing` becomes true; what the driver
  returns for the surface then (`VK_ERROR_SURFACE_LOST_KHR`, which sets `g.lost`, or another
  error, which panics) has not been seen.

Checklist for a real session (GNOME, KDE Plasma and sway; each step names what to look at):

1. With weston installed (and lavapipe, `mesa-vulkan-drivers`, for the software fallback):
   `tests/run.sh ./build/alc gfx_wayland`. `sys/gfx_wayland` starts a headless weston (GL
   renderer, else pixman) and compares its output with `gfx_wayland.out`; its standard error
   says which device was used and why another failed. (Passed on NVIDIA with the GL renderer;
   with pixman, NVIDIA has no buffer path to present through and only lavapipe can pass.) Also `tests/run.sh ./build/alc window` (the
   window side, `sys/window_wayland`).
2. `ALC_WINDOW=wayland alc run examples/gfx_starter/game.al` on each compositor, and once with
   `WAYLAND_DEBUG=1 ... 2>&1 | grep -E 'set_buffer_scale|attach|ack_configure|error'`: the
   window appears (black, then the game), the game runs at the display's rate; `attach`
   follows each `ack_configure`, no protocol error. With a `GfxDesc{debug: true}` program
   (`tests/sys/gfx_window_vk.al` built for Linux under `ALC_WINDOW=wayland`): no validation
   message.
3. Resize by dragging the border (KDE, sway floating) and by tiling (sway), maximize,
   fullscreen and back: the picture is never stretched or cut, `g.width` / `g.height` equal
   `w.size()` after each change, no `xdg_surface` / `xdg_toplevel` protocol error (in
   particular for maximized and fullscreen, where the compositor may check the buffer size).
4. Minimize (GNOME, KDE), move the window to another workspace (sway), cover it fully: the
   program keeps running or pauses only while hidden (print a counter once a second to see
   which), never stays blocked after the window is shown again; with `vsync` on and off.
   Note which compositors send `suspended` (`WAYLAND_DEBUG=1`: `xdg_toplevel.configure` with
   state 9).
5. A 200 % output (GNOME / KDE scale 2): `g.width` is twice the surface width, the picture is
   sharp; move the window to a 100 % output: the compositor scales it, no protocol error, no
   swapchain rebuild loop; fractional 125 % / 150 % (the integer scale above, reduced by the
   compositor).
6. X11 unchanged: the same programs without `ALC_WINDOW` on an X11 session and under XWayland
   behave as before; `readelf -d` of `examples/gfx_starter` lists no libwayland, `nm -D` no
   `vkCreateWaylandSurfaceKHR`.
7. A Vulkan driver or loader without `VK_KHR_wayland_surface`, and a system without
   `libwayland-client.so.0`: `gfx_open` / `window_open` fail with a message, no crash.
8. Kill the compositor under a running program (weston): the program ends or reports
   `g.lost` / `w.closing`; record what the driver returned.

## Tests

- `tests/unit/gfx_batch.al`: the batcher and the transforms without a GPU (draw merging,
  state changes, vertices of rotated / mirrored / transformed sprites, lines, render-target and
  clear commands, dropping, texture ids, camera, `fit_view`).
- `tests/sys/gfx_offscreen.al`: the backend of the target renders the scene of
  `tests/sys/data/gfx_scene.al` offscreen, on the first device and on the software rasterizer,
  and checks 28 pixels (sprites, mirroring, alpha and additive blending, coverage with a tint,
  scissor, transform, line, triangle colours, a render texture, linear filtering, a texture
  updated during the frame). Run on Windows 11 with an AMD Radeon 780M and with WARP.
- `tests/sys/gfx_vulkan.al`: the same scene on the Vulkan backend with the validation layer
  (synchronization validation on); every message fails the test. On Windows its frame is
  byte-identical to the Direct3D 12 frame on the same GPU.
- `tests/unit/gfx_text.al`: std.gfx_text without a GPU (glyph quads with kerning, measuring
  and wrapping against std.font, alignment, box height, missing glyphs, size against raster
  size, rounding to target pixels, no allocation while drawing, `gfx_font_add`).
- `tests/sys/gfx_text.al` (the backend of the target, first device and WARP) and
  `gfx_text_vk.al` (Vulkan, validation layer on): text drawn offscreen and compared per pixel
  with std.font drawing the same string into an image: kerning, a wrapped paragraph, right
  and centred lines, non-ASCII characters (composites, a code point above U+FFFF), missing
  glyphs, `gfx_font_add`, a `set_view` scaled by 2 (a 24-pixel font at size 12), and white
  text from a 4-channel atlas on white under a linear filter (no dark fringe). On Windows 11
  with a Radeon 780M the largest difference is 1 of 255 (blending rounding; 0 with WARP),
  against std.font with the atlas and, where every pen is on a whole pixel, with the font's own
  subpixel rasteriser too; the Direct3D 12 and Vulkan frames are byte-identical; 0 validation
  messages.
- `tests/sys/gfx_window.al`, `gfx_window_vk.al`: a window, frames with and without vsync,
  fullscreen and back with the swap chain following (Windows; on Linux they would need an X
  display). `tests/sys/gfx_starter.al`: the example for 60 frames.
- `tests/unit/gfx_vk_surface.al`: the surface extension for Win32, X11 and Wayland windows and
  the swapchain extent (a surface with a size of its own, the window's pixels at scales 1 to
  3, limits that cut a size that is a multiple of the scale).
- `tests/sys/gfx_wayland.al`: a window of the Wayland backend on a headless weston, the frames
  of `gfx_window` (Linux, needs weston).

Not verified: the Vulkan backend on Linux (X11 and Wayland surfaces) has only been
type-checked and built (`alc check --target linux`), not run; device loss has not been
provoked.
