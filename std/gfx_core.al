// std.gfx_core: the part of std.gfx that does not touch a GPU: the types, the 2D transform,
// and the batcher that turns sprite / rectangle / line / triangle calls into vertices and a
// list of draw commands. A program writes `use std.gfx`, which adds the backend of the target
// (std/gfx_dx12.al on Windows, std/gfx_vk.al on Linux); the backend opens the device, owns
// the textures and replays the commands at end_frame. docs/std/gfx.md describes the API.
//
// Nothing here allocates after gfx_open: the vertices of a frame go straight into the mapped
// GPU buffer of that frame, the commands into a fixed array; what does not fit is dropped and
// counted (g.stats.dropped).
use std.image

// How a draw combines with what is in the target: straight (not premultiplied) alpha
// `src * a + dst * (1 - a)`, or additive `src * a + dst`.
enum Blend { BlendAlpha, BlendAdd }

// How a texture is sampled when it is drawn larger or smaller than its pixels.
enum Filter { FilterNearest, FilterLinear }

// A texture of a Gfx: `w` x `h` pixels. A value to copy and keep; `id` 0 is no texture.
struct Texture { id: i64, w: i64, h: i64 }

// A 2D affine transform: p' = x * p.x + y * p.y + t (x and y are the images of the axes, t of
// the origin). The zero value is not the identity: xform_identity().
struct Xform { x: vec2, y: vec2, t: vec2 }

// How to open a Gfx. Zero fields mean: 16384 quads per frame, 256 textures, the first
// hardware device, no debug layer.
struct GfxDesc {
    max_quads: i64        // sprites + rectangles + lines per frame (a triangle counts half)
    max_textures: i64     // textures and render textures alive at once
    software: bool        // the software rasterizer: WARP (Direct3D 12), a CPU device (Vulkan, if installed)
    debug: bool           // the Direct3D 12 debug layer / Vulkan validation layer, if installed
}

// What the last finished frame did.
struct GfxStats {
    frames: i64           // frames finished so far
    draw_calls: i64       // of the last frame
    vertices: i64
    passes: i64           // render-target changes, the first screen pass included
    dropped: i64          // primitives that did not fit (raise max_quads)
}

// One corner of a primitive as the shaders read it: position in target pixels, texture
// coordinate (x below -1: no texture), colour RGBA8 (red in the lowest byte: color_u32).
struct GfxVertex { pos: vec2, uv: vec2, color: u32 }

// A recorded command (internal).
struct GfxCmd {
    kind: i32             // __GFX_DRAW, __GFX_TARGET, __GFX_CLEAR
    tex: i32              // draw: the texture; target: the texture drawn into (0: the screen)
    blend: i32            // draw: Blend as a number
    first: i32            // draw: first vertex, number of vertices
    count: i32
    clip: [4]i32          // draw: scissor x, y, w, h in target pixels; w < 0: the whole target
    color: u32            // clear: the colour
}

const __GFX_DRAW: i32 = 0
const __GFX_TARGET: i32 = 1
const __GFX_CLEAR: i32 = 2

// What the front end knows of a texture (internal; index = Texture.id).
struct GfxTex {
    w: i64
    h: i64
    live: bool
    target: bool          // a render texture
    coverage: bool        // one channel, sampled as (1, 1, 1, coverage)
    filter: Filter
}

// An open renderer. Read `width` / `height` (the screen target, the window's drawable area),
// `lost`, `stats`; set `vsync`. The other fields are internal.
struct Gfx {
    width: i64
    height: i64
    vsync: bool                // wait for the display (the default); false: present at once
    lost: str                  // "" while the device works; else why it stopped (end_frame says so too)
    offscreen: bool            // gfx_offscreen: the screen is a texture, read_pixels reads it
    device: str                // the GPU's name ("... (WARP)" for the software rasterizer)
    stats: GfxStats
    // the frame being recorded
    in_frame: bool
    clear_color: u32
    verts: []GfxVertex         // this frame's vertex memory (mapped GPU memory)
    nverts: i64
    cmds: []GfxCmd
    ncmds: i64
    open: i64                  // the draw command new vertices join, -1: none
    xform: Xform
    blend: Blend
    clip: [4]i32
    target: i64                // 0: the screen, else the render texture drawn into
    tw: i64                    // size of the current target
    th: i64
    dropped: i64
    passes: i64
    texs: []GfxTex             // [0] unused
    os: *u8                    // the backend's state
}

// ---- 2D transforms ---------------------------------------------------------------------------

fn xform_identity() -> Xform { Xform{vec2(1.0, 0.0), vec2(0.0, 1.0), vec2(0.0)} }

fn xform_translate(v: vec2) -> Xform { Xform{vec2(1.0, 0.0), vec2(0.0, 1.0), v} }

fn xform_scale(s: vec2) -> Xform { Xform{vec2(s.x, 0.0), vec2(0.0, s.y), vec2(0.0)} }

// Rotation by `angle` radians; with y pointing down (pixels) a positive angle turns clockwise.
fn xform_rotate(angle: f32) -> Xform {
    c := cos(angle)
    s := sin(angle)
    Xform{vec2(c, s), vec2(-s, c), vec2(0.0)}
}

// The transform that applies b first, then a (the matrix product a * b).
fn xform_mul(a: Xform, b: Xform) -> Xform {
    Xform{a.x * b.x.x + a.y * b.x.y, a.x * b.y.x + a.y * b.y.y, a.x * b.t.x + a.y * b.t.y + a.t}
}

// The image of point p.
fn apply(m: Xform, p: vec2) -> vec2 { m.x * p.x + m.y * p.y + m.t }

// The transform that undoes m (m must not squash the plane to a line: a zero scale gives inf).
fn inverse(m: Xform) -> Xform {
    det := m.x.x * m.y.y - m.y.x * m.x.y
    ix := vec2(m.y.y, -m.x.y) / det
    iy := vec2(-m.y.x, m.x.x) / det
    Xform{ix, iy, -(ix * m.t.x + iy * m.t.y)}
}

// A 2D camera for a view of `view` pixels: the world point `center` appears in the middle of
// the view, `zoom` times larger, the world turned by -`rotation` (the camera turns by it).
fn camera(center: vec2, zoom: f32, rotation: f32, view: vec2) -> Xform {
    m := xform_translate(view * 0.5)
    m = xform_mul(m, xform_rotate(-rotation))
    m = xform_mul(m, xform_scale(vec2(zoom)))
    xform_mul(m, xform_translate(-center))
}

// The transform that shows a vw x vh area (origin top left) as large as it fits in a tw x th
// target, centred, aspect kept, the offset on whole pixels; and that area in target pixels
// (x, y, w, h).
fn fit_view(vw: f32, vh: f32, tw: i64, th: i64) -> (Xform, i64, i64, i64, i64) {
    if vw <= 0.0 || vh <= 0.0 || tw <= 0 || th <= 0 {
        return (xform_identity(), 0, 0, 0, 0)
    }
    s := fmin(f32(tw) / vw, f32(th) / vh)
    w := i64(round(vw * s))
    h := i64(round(vh * s))
    x := (tw - w) / 2
    y := (th - h) / 2
    (Xform{vec2(s, 0.0), vec2(0.0, s), vec2(f32(x), f32(y))}, x, y, w, h)
}

// ---- frame state -----------------------------------------------------------------------------

// Draws in a virtual resolution: sets the transform and the scissor so that a vw x vh area
// (origin top left) fills the current target as far as it fits, centred, aspect kept (the
// bars beside it keep the clear colour). Returns the transform: apply(inverse(m), mouse) is
// the mouse in virtual pixels.
fn set_view(g: *Gfx, vw: f32, vh: f32) -> Xform {
    m, x, y, w, h := fit_view(vw, vh, g.tw, g.th)
    g.set_transform(m)
    g.set_scissor(x, y, w, h)
    m
}

// The transform of everything drawn from now on (until the frame ends; begin_frame and
// set_target reset it to the identity).
fn set_transform(g: *Gfx, m: Xform) { g.xform = m }

fn set_blend(g: *Gfx, b: Blend) {
    if b != g.blend {
        g.blend = b
        g.open = -1
    }
}

// Draws only inside x, y, w, h (pixels of the current target, not transformed) until
// reset_scissor or the end of the frame.
fn set_scissor(g: *Gfx, x: i64, y: i64, w: i64, h: i64) {
    x0 := clamp(x, 0, g.tw)
    y0 := clamp(y, 0, g.th)
    x1 := clamp(x + max(w, 0), 0, g.tw)
    y1 := clamp(y + max(h, 0), 0, g.th)
    c := [4]i32{i32(x0), i32(y0), i32(x1 - x0), i32(y1 - y0)}
    if c != g.clip {
        g.clip = c
        g.open = -1
    }
}

fn reset_scissor(g: *Gfx) {
    if g.clip[2] >= 0 {
        g.clip = [4]i32{0, 0, -1, -1}
        g.open = -1
    }
}

// Draws into the render texture t (made by render_texture) from now on, keeping what it holds
// (clear(g, colour) to start afresh). Resets the transform and the scissor. Within one frame
// a texture is either drawn into or drawn with at a time: drawing t into itself is an error.
fn set_target(g: *Gfx, t: Texture) {
    assert t.id > 0 && t.id < len(g.texs) && g.texs[t.id].live && g.texs[t.id].target, "set_target: not a render texture"
    g.__gfx_target(t.id, t.w, t.h)
}

// Draws into the screen again (the window, or the offscreen image).
fn reset_target(g: *Gfx) {
    if g.target != 0 {
        g.__gfx_target(0, g.width, g.height)
    }
}

fn __gfx_target(g: *Gfx, id: i64, w: i64, h: i64) {
    assert g.in_frame, "gfx: set_target outside begin_frame / end_frame"
    g.open = -1
    g.target = id
    g.tw = w
    g.th = h
    g.xform = xform_identity()
    g.clip = [4]i32{0, 0, -1, -1}
    if g.ncmds < len(g.cmds) {
        g.cmds[g.ncmds] = GfxCmd{kind: __GFX_TARGET, tex: i32(id)}
        g.ncmds += 1
        g.passes += 1
    } else {
        g.dropped += 1
    }
}

// Fills the whole current target with `color` (also outside the scissor).
fn clear(g: *Gfx, color: u32) {
    assert g.in_frame, "gfx: clear outside begin_frame / end_frame"
    g.open = -1
    if g.ncmds < len(g.cmds) {
        g.cmds[g.ncmds] = GfxCmd{kind: __GFX_CLEAR, color: color}
        g.ncmds += 1
    } else {
        g.dropped += 1
    }
}

// ---- drawing ---------------------------------------------------------------------------------

// The whole texture with its top left corner at (x, y), at its size, untinted.
fn sprite(g: *Gfx, t: Texture, x: f32, y: f32) {
    g.sprite(t, vec4(0.0, 0.0, f32(t.w), f32(t.h)), vec4(x, y, f32(t.w), f32(t.h)), 0xFFFFFFFF)
}

// The texture's rectangle `src` (x, y, w, h in texture pixels; a negative w or h mirrors)
// drawn into the rectangle `dst`, tinted by `tint` (RGBA8, red in the lowest byte: 0xFFFFFFFF
// as it is; a coverage texture takes the tint's colour).
fn sprite(g: *Gfx, t: Texture, src: vec4, dst: vec4, tint: u32) {
    m := g.xform
    p := apply(m, dst.xy)
    dx := m.x * dst.z
    dy := m.y * dst.w
    g.__gfx_quad(t, src, p, p + dx, p + dy, p + dx + dy, tint)
}

// The full form: `src` as above, drawn `size` large, turned by `rotation` radians (clockwise)
// about `origin` (a point of the drawn rectangle, from its top left corner), which lands on
// `pos`. origin vec2(0.0) and rotation 0.0: the rectangle (pos, size).
fn sprite(g: *Gfx, t: Texture, src: vec4, pos: vec2, size: vec2, rotation: f32, origin: vec2, tint: u32) {
    m := xform_mul(g.xform, xform_mul(xform_translate(pos), xform_rotate(rotation)))
    p := apply(m, -origin)
    dx := m.x * size.x
    dy := m.y * size.y
    g.__gfx_quad(t, src, p, p + dx, p + dy, p + dx + dy, tint)
}

// A filled rectangle (x, y, w, h).
fn rect(g: *Gfx, r: vec4, color: u32) {
    m := g.xform
    p := apply(m, r.xy)
    dx := m.x * r.z
    dy := m.y * r.w
    first := g.__gfx_reserve(-1, 6)
    if first >= 0 {
        g.__gfx_put_quad(first, p, p + dx, p + dy, p + dx + dy, vec2(-2.0), vec2(-2.0), vec2(-2.0), vec2(-2.0), color)
    }
}

// A line from a to b, `width` pixels wide (before the transform), with square ends at a and b.
fn line(g: *Gfx, a: vec2, b: vec2, width: f32, color: u32) {
    d := b - a
    n := length(d)
    if n <= 0.0 {
        return
    }
    side := vec2(-d.y, d.x) * (width * 0.5 / n)
    m := g.xform
    p0 := apply(m, a + side)
    p1 := apply(m, b + side)
    p2 := apply(m, a - side)
    p3 := apply(m, b - side)
    first := g.__gfx_reserve(-1, 6)
    if first >= 0 {
        g.__gfx_put_quad(first, p0, p1, p2, p3, vec2(-2.0), vec2(-2.0), vec2(-2.0), vec2(-2.0), color)
    }
}

// A triangle with a colour per corner, blended across it.
fn triangle(g: *Gfx, a: vec2, b: vec2, c: vec2, ca: u32, cb: u32, cc: u32) {
    first := g.__gfx_reserve(-1, 3)
    if first < 0 {
        return
    }
    m := g.xform
    g.verts[first] = GfxVertex{apply(m, a), vec2(-2.0), ca}
    g.verts[first + 1] = GfxVertex{apply(m, b), vec2(-2.0), cb}
    g.verts[first + 2] = GfxVertex{apply(m, c), vec2(-2.0), cc}
}

// ---- the batcher (internal) ------------------------------------------------------------------

priv fn __gfx_quad(g: *Gfx, t: Texture, src: vec4, p0: vec2, p1: vec2, p2: vec2, p3: vec2, tint: u32) {
    assert t.id > 0 && t.id < len(g.texs) && g.texs[t.id].live, "gfx: not a texture of this Gfx (freed, or Texture{})"
    assert t.id != g.target, "gfx: drawing a render texture into itself"
    first := g.__gfx_reserve(t.id, 6)
    if first < 0 {
        return
    }
    inv := vec2(1.0 / f32(t.w), 1.0 / f32(t.h))
    u0 := src.xy * inv
    u1 := (src.xy + src.zw) * inv
    g.__gfx_put_quad(first, p0, p1, p2, p3, u0, vec2(u1.x, u0.y), vec2(u0.x, u1.y), u1, tint)
}

priv fn __gfx_put_quad(g: *Gfx, i: i64, p0: vec2, p1: vec2, p2: vec2, p3: vec2, t0: vec2, t1: vec2, t2: vec2, t3: vec2, c: u32) {
    v := g.verts
    a := GfxVertex{p0, t0, c}
    b := GfxVertex{p1, t1, c}
    d := GfxVertex{p2, t2, c}
    v[i] = a
    v[i + 1] = b
    v[i + 2] = d
    v[i + 3] = d
    v[i + 4] = b
    v[i + 5] = GfxVertex{p3, t3, c}
}

// Room for n vertices in a draw command of texture `tex` (-1: no texture, joins any) with the
// current state: the index of the first, or -1 if they do not fit (counted as dropped).
fn __gfx_reserve(g: *Gfx, tex: i64, n: i64) -> i64 {
    assert g.in_frame, "gfx: drawing outside begin_frame / end_frame"
    if g.nverts + n > len(g.verts) {
        g.dropped += 1
        return -1
    }
    if g.open < 0 || (tex >= 0 && i64(g.cmds[g.open].tex) != tex) {
        if g.ncmds == len(g.cmds) {
            g.dropped += 1
            return -1
        }
        g.cmds[g.ncmds] = GfxCmd{kind: __GFX_DRAW, tex: i32(max(tex, 1)), blend: i32(i64(g.blend)), first: i32(g.nverts), clip: g.clip}
        g.open = g.ncmds
        g.ncmds += 1
    }
    first := g.nverts
    g.nverts += n
    g.cmds[g.open].count += i32(n)
    first
}

// A Gfx front end without a backend: max_quads and max_textures as in GfxDesc (0: the
// defaults). Texture 1 is the built-in white pixel. The backends start with it; the tests of
// the batcher use it directly with vertex memory of their own (__gfx_begin).
fn __gfx_new(width: i64, height: i64, d: GfxDesc) -> *Gfx {
    g := new[Gfx]()
    g.width = width
    g.height = height
    g.vsync = true
    quads := if d.max_quads > 0 { d.max_quads } else { 16384 }
    g.cmds = alloc[GfxCmd](quads / 4 + 64)
    g.texs = alloc[GfxTex](if d.max_textures > 0 { d.max_textures + 2 } else { 258 })
    g.texs[1] = GfxTex{w: 1, h: 1, live: true}
    g
}

// The most vertices of a frame.
fn __gfx_max_vertices(d: GfxDesc) -> i64 { (if d.max_quads > 0 { d.max_quads } else { 16384 }) * 6 }

// Starts recording a frame into `verts`.
fn __gfx_begin(g: *Gfx, verts: []GfxVertex, clear: u32) {
    assert !g.in_frame, "begin_frame: the last frame was not ended (end_frame)"
    g.in_frame = true
    g.clear_color = clear
    g.verts = verts
    g.nverts = 0
    g.ncmds = 0
    g.open = -1
    g.xform = xform_identity()
    g.blend = BlendAlpha
    g.clip = [4]i32{0, 0, -1, -1}
    g.target = 0
    g.tw = g.width
    g.th = g.height
    g.dropped = 0
    g.passes = 1
}

// Ends recording; the backend then replays g.cmds[..g.ncmds].
fn __gfx_end(g: *Gfx) {
    assert g.in_frame, "end_frame without begin_frame"
    g.in_frame = false
    draws := 0
    for c in g.cmds[..g.ncmds] {
        if c.kind == __GFX_DRAW && c.count > 0 { draws += 1 }
    }
    g.stats = GfxStats{frames: g.stats.frames + 1, draw_calls: draws, vertices: g.nverts, passes: g.passes, dropped: g.dropped}
}

// A free texture id for a w x h texture, or 0 if all max_textures are in use.
fn __gfx_tex_new(g: *Gfx, w: i64, h: i64, filter: Filter, coverage: bool, target: bool) -> i64 {
    assert w > 0 && h > 0 && w <= 16384 && h <= 16384, "gfx: a texture is 1 to 16384 pixels wide and high"
    for i in 2..len(g.texs) {
        if !g.texs[i].live {
            g.texs[i] = GfxTex{w, h, true, target, coverage, filter}
            return i
        }
    }
    0
}

// The pixels of an image as a texture holds them: (1, pixels) for one channel (coverage),
// else (4, RGBA pixels), converting two and three channels (allocates then).
fn __gfx_pixels(img: Image) -> (i64, []u8) {
    assert img.w > 0 && img.h > 0 && len(img.pix) >= img.w * img.h * img.channels, "gfx: bad image"
    if img.channels == 1 || img.channels == 4 {
        return (img.channels, img.pix)
    }
    (4, convert(img, 4).pix)
}
