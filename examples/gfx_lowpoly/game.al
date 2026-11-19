// A 3D low-poly landscape flyover drawn with nothing but std.gfx's 2D `triangle` (a colour per
// corner): a 3D scene needs no 3D API. The 3D is done on the CPU with std.math (a look_at view
// matrix, a perspective projection, near-plane clipping, back-face culling) and ordered with
// the painter's algorithm (render.al). The land is an endless fractal-noise heightfield
// streamed around the camera in three rings of detail out to 300 units (world.al): sand,
// grass, forest, alpine meadow, rock and snow by height and slope, flat-shaded facets lit by
// the sun and the sky with ray-marched shadows, translucent moving water that reflects the sky
// and glitters, aerial haze that fades into the sky, a sun with an additive glow, low-poly
// clouds, trees and rocks, and a small aircraft with navigation lights that the camera chases
// along an automatic course (flight.al). Golden hour, noon and night (moon and stars). About
// 20,000 to 35,000 triangles a frame, a few milliseconds of CPU.
//
//   alc run examples/gfx_lowpoly/game.al                      fly (Windows: Direct3D 12, Linux: Vulkan)
//   alc run examples/gfx_lowpoly/game.al -- --shot out.png    render one 1280 x 720 frame offscreen
//
// Options: --frames N (quit after N frames, printing the average frame time; with --shot: fly
// N steps first), --shot FILE (offscreen frames saved as PNG; --shots K saves K consecutive
// frames, FILE gets _0, _1, ...), --record FILE (offscreen: after --frames steps, --length N
// frames (default 1320, 22 s) of a scripted showcase, a look around, a wireframe peek and a
// fade into the night, written raw as RGBA to FILE.0, FILE.1, ... for a video encoder),
// --check N (offscreen after N steps: prints what the three times of day send to std.gfx; the
// test), --aa 1|2|3 (supersampling for smooth edges, default 3; lowered for large screens),
// --time golden|noon|night, --wire, --no-hud, --seed N (another land; default 7), --warp,
// --no-vsync, --fullscreen. Everything follows from the seed and the number of fixed steps:
// the same options give the same picture.
//
// Drag with the left mouse button to look around, W / S faster / slower, T time of day,
// F wireframe (the triangles' edges), H hides the text, F11 fullscreen, Escape quits.
use std.window
use std.image
use std.gfx
use std.gfx_text
use "world.al"
use "render.al"
use "flight.al"

const HZ = 60                    // simulation steps per second
const MAX_QUADS = 160000         // the vertex budget of a frame (a triangle is half a quad, a line one)
const SHOT_W = 1280
const SHOT_H = 720

struct Options {
    frames: i64          // -1: until closed
    shot: str
    shots: i64
    check: i64           // -1: not the check run
    aa: i64              // supersampling factor asked for, 1..3
    record: str          // the showcase run: frames written raw to record.0, record.1, ...
    length: i64          // its number of frames
    tod: i64
    wire: bool
    hud: bool
    seed: u32
    warp: bool
    vsync: bool
    fullscreen: bool
}

fn parse_options(a: []str) -> (Options, str) {
    o := Options{frames: -1, shots: 1, check: -1, aa: 3, length: 1320, tod: TOD_GOLDEN, hud: true, seed: 7, vsync: true}
    k := 1
    while k < len(a) {
        s := a[k]
        more := k + 1 < len(a)
        if (s == "--frames" || s == "--shots" || s == "--check" || s == "--seed" || s == "--aa" || s == "--length") && more {
            n, ok := parse_i64(a[k + 1])
            if !ok || n < 0 {
                return (o, fmt(s, ": not a number: ", a[k + 1]))
            }
            if s == "--frames" { o.frames = n }
            if s == "--shots" { o.shots = n }
            if s == "--check" { o.check = n }
            if s == "--seed" { o.seed = u32(n) }
            if s == "--aa" { o.aa = clamp(n, 1, 3) }
            if s == "--length" { o.length = n }
            k += 1
        } else if s == "--shot" && more {
            o.shot = a[k + 1]
            k += 1
        } else if s == "--record" && more {
            o.record = a[k + 1]
            k += 1
        } else if s == "--time" && more {
            t := a[k + 1]
            o.tod = if t == "noon" { TOD_NOON } else if t == "night" { TOD_NIGHT } else if t == "golden" { TOD_GOLDEN } else { -1 }
            if o.tod < 0 {
                return (o, fmt("--time: golden, noon or night, not ", t))
            }
            k += 1
        } else if s == "--wire" {
            o.wire = true
        } else if s == "--no-hud" {
            o.hud = false
        } else if s == "--warp" {
            o.warp = true
        } else if s == "--no-vsync" {
            o.vsync = false
        } else if s == "--fullscreen" {
            o.fullscreen = true
        } else {
            return (o, fmt("unknown option ", s, " (options: --frames N --shot FILE --shots K --record FILE --length N --check N --aa 1|2|3 --time golden|noon|night --wire --no-hud --seed N --warp --no-vsync --fullscreen)"))
        }
        k += 1
    }
    (o, "")
}

// ---------- text ----------

const FONT_PATHS = [_]str{
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
}
const BOLD_PATHS = [_]str{
    "C:/Windows/Fonts/segoeuib.ttf",
    "C:/Windows/Fonts/arialbd.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
}
const TEST_FONT = embed("../../tests/std/data/font_test.ttf")

fn load_font(paths: []str) -> (Font, bool) {
    for p in paths {
        f, err := font_load(p)
        if err == "" {
            return (f, true)
        }
    }
    f, _ := font_parse(TEST_FONT)
    (f, false)
}

// The HUD's fonts, rasterised at the size they have on the screen (anew when the window's
// height changes).
struct Hud {
    regular: Font
    bold: Font
    height: i64
    small: GfxFont
    title: GfxFont
}

hud_mem: Region                  // the atlases of the fonts in use

fn hud_fonts(g: *Gfx, h: *Hud, height: i64) {
    if height == h.height || height <= 0 {
        return
    }
    if h.height > 0 {
        gfx_font_free(g, h.small)
        gfx_font_free(g, h.title)
    }
    reset(&hud_mem)
    enter(&hud_mem)
    sc := f32(height) / 720.0
    err := ""
    h.small, err = gfx_font(g, h.regular, fmax(10.0, 14.0 * sc), char_range(32, 126))
    assert err == "", err
    h.title, err = gfx_font(g, h.bold, fmax(14.0, 24.0 * sc), char_range(32, 126))
    assert err == "", err
    leave()
    h.height = height
}

// Text with a soft shadow under it, readable over sky and land.
fn label(g: *Gfx, f: GfxFont, x: f32, y: f32, text: str, color: u32, align: TextAlign) {
    g.draw_text(f, x + 1.0, y + 1.0, text, 0x99000000, align)
    g.draw_text(f, x + 1.0, y, text, 0x44000000, align)
    g.draw_text(f, x, y, text, color, align)
}

// 12345 as "12,345".
fn thousands(n: i64) -> str {
    if n < 1000 {
        return fmt(n)
    }
    fmt(thousands(n / 1000), ",", fmti(n % 1000, 3, '0'))
}

fn draw_hud(g: *Gfx, h: *Hud, s: *Scene, fps: f64, speed: f32) {
    sc := f32(g.height) / 720.0
    m := 22.0 * sc
    white: u32 = 0xF2FFFFFF
    muted: u32 = 0xC8E8E0D8
    label(g, h.title, m, m, "LOW-POLY FLYOVER", white, AlignLeft)
    label(g, h.small, m, m + line_height(h.title) + 2.0 * sc, "a 3D landscape from 2D triangles  -  std.gfx", muted, AlignLeft)
    rx := f32(g.width) - m
    lh := line_height(h.small)
    label(g, h.small, rx, m, s.lt.name, white, AlignRight)
    label(g, h.small, rx, m + lh, fmt(thousands(s.tris), " triangles"), muted, AlignRight)
    rate := if fps > 0.0 { fmt(i64(fps + 0.5), " fps") } else { "offscreen" }
    label(g, h.small, rx, m + 2.0 * lh, fmt(rate, "   3D on the CPU ", fmtf(f64(s.cpu_ns) / 1e6, 1), " ms"), muted, AlignRight)
    label(g, h.small, rx, m + 3.0 * lh, fmt("speed ", fmtf(speed, 1), "x"), muted, AlignRight)
    keys := "drag  look      W / S  speed      T  time of day      F  wireframe      H  hide text      Esc  quit"
    label(g, h.small, m, f32(g.height) - m - lh, keys, muted, AlignLeft)
}

// ---------- frames ----------

// ---------- anti-aliasing ----------

// std.gfx has no multisampling, so the 3D is drawn into a render texture `k` times the screen's
// size in each direction and drawn down to the screen with the linear filter (the HUD after
// it, at the screen's own resolution, stays sharp). For k = 2 the centre of each screen pixel
// falls exactly between four texels: one linear tap is the box average of its 2 x 2 samples.
// For k = 3 four taps half a texel off the centre, averaged, weigh the 3 x 3 samples by a
// (1, 2, 1) tent in each direction. Above AA_MAX_SAMPLES supersamples a frame the factor is
// lowered, a margin for fill rate: on a Radeon 780M 1280 x 720 at 3x and 1920 x 1200 at 2x hold
// 60 fps; 1920 x 1200 at 3x (20.7 million) held 60 on a quiet machine but fell to 51 under load.
const AA_MAX_SAMPLES = 10_000_000

struct Super {
    asked: i64           // the factor asked for (--aa)
    k: i64               // the factor in use for this screen size (1: none)
    tex: Texture         // the k times larger target
    mix: Texture         // a screen-sized target for cross-fades (made when first needed)
    w: i64               // the screen size they were made for
    h: i64
}

// Makes the targets fit a w x h screen. Between frames: textures are made and freed there.
fn super_fit(g: *Gfx, sp: *Super, w: i64, h: i64) {
    k := sp.asked
    while k > 1 && w * h * k * k > AA_MAX_SAMPLES {
        k -= 1
    }
    if k == sp.k && w == sp.w && h == sp.h {
        return
    }
    if sp.tex.id != 0 {
        g.free_texture(sp.tex)
    }
    if sp.mix.id != 0 {
        g.free_texture(sp.mix)
    }
    sp.tex = if k > 1 { g.render_texture(w * k, h * k, FilterLinear) } else { Texture{} }
    sp.mix = Texture{}
    sp.k = k
    sp.w = w
    sp.h = h
}

// Draws the supersampled target down onto the current target, w x h.
fn resolve(g: *Gfx, sp: *Super, w: f32, h: f32) {
    t := sp.tex
    dst := vec4(0.0, 0.0, w, h)
    if sp.k == 2 {
        g.sprite(t, vec4(0.0, 0.0, f32(t.w), f32(t.h)), dst, 0xFFFFFFFF)
        return
    }
    // the running average of four taps: alpha 1, 1/2, 1/3, 1/4
    for i in 0..4 {
        o := vec2(if i % 2 == 0 { -0.5 } else { 0.5 }, if i < 2 { -0.5 } else { 0.5 })
        g.sprite(t, vec4(o.x, o.y, f32(t.w), f32(t.h)), dst, rgba8(255, 255, 255, u8(255 / (i + 1))))
    }
}

struct Demo {
    world: World
    scene: Scene
    prev: Flight         // the flight one step ago and now: the frame is drawn between them
    cur: Flight
    tod: i64
    fade_to: i64         // with fade > 0: the time of day cross-faded in
    fade: f32
    ss: Super
    hud: Hud
    show_hud: bool
}

fn demo_new(o: Options) -> Demo {
    d := Demo{world: world_new(o.seed), scene: scene_new(), tod: o.tod, show_hud: o.hud, ss: Super{asked: o.aa}}
    d.cur = flight_new(&d.world)
    d.prev = d.cur
    d.scene.wire = o.wire
    d.hud.regular, _ = load_font(FONT_PATHS[..])
    d.hud.bold, _ = load_font(BOLD_PATHS[..])
    d
}

fn step(d: *Demo, dragging: bool) {
    d.prev = d.cur
    flight_step(&d.cur, &d.world, 1.0 / f32(HZ), dragging)
}

// Draws one frame, `alpha` of the way from the previous step to the current one: the scene,
// supersampled if the targets fit the screen, then the HUD.
fn render(g: *Gfx, d: *Demo, alpha: f32, fps: f64) -> str {
    if !g.begin_frame(color_u32(vec4(light_of(d.tod).horizon, 1.0))) {
        return ""                                       // minimized
    }
    sp := &d.ss
    sw := f32(g.width)
    sh := f32(g.height)
    ok := sp.k > 1 && sp.w == g.width && sp.h == g.height
    draw_view(g, d, alpha, d.tod, if ok { sp.tex } else { Texture{} }, sp.k)
    if ok {
        g.reset_target()
        resolve(g, sp, sw, sh)
    }
    if d.fade > 0.0 && ok && sp.mix.id != 0 {
        // a cross-fade: the other time of day drawn down into a screen-sized target, laid over
        draw_view(g, d, alpha, d.fade_to, sp.tex, sp.k)
        g.set_target(sp.mix)
        resolve(g, sp, sw, sh)
        g.reset_target()
        g.sprite(sp.mix, vec4(0.0, 0.0, sw, sh), vec4(0.0, 0.0, sw, sh), rgba8(255, 255, 255, u8(d.fade * 255.0 + 0.5)))
    }
    s := &d.scene
    if d.show_hud {
        draw_hud(g, &d.hud, s, fps, d.cur.speed)
    }
    g.end_frame()
}

// The 3D scene at time of day `tod`, into `target` (k times the screen) or, without one,
// straight onto the screen.
fn draw_view(g: *Gfx, d: *Demo, alpha: f32, tod: i64, target: Texture, k: i64) {
    s := &d.scene
    s.lt = light_of(tod)
    world_set_sun(&d.world, s.lt.sun)
    w := f32(g.width)
    h := f32(g.height)
    s.px = 1.0
    if target.id != 0 {
        g.set_target(target)
        g.clear(color_u32(vec4(s.lt.horizon, 1.0)))
        w = f32(target.w)
        h = f32(target.h)
        s.px = f32(k)
    }
    p := pose_of(&d.prev, &d.cur, alpha)
    s.cam = cam_make(p.eye, p.target, p.up, w, h)
    s.plane = p.plane
    s.time = f32(d.prev.t + (d.cur.t - d.prev.t) * f64(alpha))
    draw_scene(g, s, &d.world)
}

fn run_window(o: Options) {
    w, ok := window_open(WindowDesc{title: "Low-poly flyover (std.gfx)", width: 1280, height: 720,
        resizable: true, fullscreen: o.fullscreen})
    if !ok {
        panic("cannot open a window")
    }
    g, err := gfx_open(w, GfxDesc{max_quads: MAX_QUADS, software: o.warp})
    if err != "" {
        panic(err)
    }
    g.vsync = o.vsync
    d := demo_new(o)
    clock := frame_clock()
    steps := fixed_step(f64(HZ))
    frames := 0
    cpu_ns := 0
    start := time_ns()
    steady_at := start                                   // after the first 30 frames (caches filled)
    slow := 0                                            // of those, frames over 20 ms: a missed vsync
    last := start
    while !w.should_close() && frames != o.frames {
        w.poll()
        inp := &w.input
        if inp.key_pressed(KEY_ESCAPE) {
            w.closing = true
        }
        if inp.key_pressed(KEY_F11) || (inp.key_pressed(KEY_ENTER) && inp.alt_down()) {
            w.set_fullscreen(!w.fullscreen)
        }
        if inp.key_pressed(KEY_T) {
            d.tod = (d.tod + 1) % 3
        }
        if inp.key_pressed(KEY_F) || inp.key_pressed(KEY_TAB) {
            d.scene.wire = !d.scene.wire
        }
        if inp.key_pressed(KEY_H) {
            d.show_hud = !d.show_hud
        }
        dt := clock.tick()
        if inp.key_down(KEY_W) {
            d.cur.speed = fmin(4.0, d.cur.speed * f32(1.0 + dt))
        }
        if inp.key_down(KEY_S) {
            d.cur.speed = fmax(0.25, d.cur.speed / f32(1.0 + dt))
        }
        dragging := inp.mouse_down(MOUSE_LEFT)
        if dragging {
            md := inp.mouse_delta()
            d.cur.look_yaw = wrap_angle(d.cur.look_yaw - md.x * 0.004)
            d.cur.look_pitch = clamp(d.cur.look_pitch - md.y * 0.004, -1.0, 1.0)
        }
        for k in 0..steps.advance(dt) {
            step(&d, dragging)
        }
        ww, wh := w.size()
        if ww > 0 && wh > 0 && !w.minimized {
            hud_fonts(g, &d.hud, wh)                     // (not in the frame's scratch memory)
            super_fit(g, &d.ss, ww, wh)
        }
        frame_begin()
        rerr := render(g, &d, steps.alpha(), clock.fps)
        if rerr != "" {
            panic(rerr)                                  // the GPU was lost
        }
        if g.stats.dropped > 0 {
            eprint(fmt("frame ", frames, ": ", g.stats.dropped, " draws dropped"))
        }
        frame_end()
        frames += 1
        now := time_ns()
        if frames == 30 {
            steady_at = now
        } else if frames > 30 {
            cpu_ns += d.scene.cpu_ns
            if now - last > 20_000_000 {
                slow += 1
            }
        }
        last = now
    }
    n := f64(max(frames - 30, 1))
    ms := f64(time_ns() - steady_at) / 1e6 / n
    print("frames", frames, "- after the first 30: average frame", fmtf(ms, 2), "ms", fmt("(", fmtf(1000.0 / ms, 1), " fps),"),
        slow, "over 20 ms, 3D on the CPU", fmtf(f64(cpu_ns) / 1e6 / n, 2), "ms;", fmt(d.ss.w, " x ", d.ss.h), "supersampled",
        fmt(d.ss.k, "x"), "on", g.device)
    gfx_close(g)
    w.close()
}

// Offscreen: fly `frames` steps, then save `shots` consecutive frames as PNG.
fn run_shots(o: Options) -> i64 {
    g, err := gfx_offscreen(SHOT_W, SHOT_H, GfxDesc{max_quads: MAX_QUADS, software: o.warp})
    if err != "" {
        eprint(fmt("no device for std.gfx: ", err))
        return 1
    }
    d := demo_new(o)
    hud_fonts(g, &d.hud, SHOT_H)
    super_fit(g, &d.ss, SHOT_W, SHOT_H)
    for i in 0..max(o.frames, 0) {
        step(&d, false)
    }
    for k in 0..2 {                                     // fill the caches: the HUD shows a usual frame
        frame_begin()
        rerr := render(g, &d, 0.0, 0.0)
        assert rerr == "", rerr
        frame_end()
    }
    for k in 0..o.shots {
        t0 := time_ns()
        frame_begin()
        rerr := render(g, &d, 0.0, 0.0)
        assert rerr == "", rerr
        frame_end()
        cpu := f64(time_ns() - t0) / 1e6
        path := o.shot
        if o.shots > 1 {
            dot := rfind(path, ".")
            path = if dot > 0 { fmt(path[..dot], "_", k, path[dot..]) } else { fmt(path, "_", k) }
        }
        if !png_save(path, g.read_pixels()) {
            eprint(fmt("cannot write ", path))
            return 1
        }
        print(path, "triangles", d.scene.tris, "vertices", g.stats.vertices, "dropped", g.stats.dropped, "frame", fmtf(cpu, 1), "ms")
        step(&d, false)
    }
    gfx_close(g)
    0
}

// Offscreen, for the test: after `n` steps one frame at each time of day; what is printed
// comes from the CPU side (the triangles sent, the vertices std.gfx took, none dropped).
fn run_check(o: Options) -> i64 {
    g, err := gfx_offscreen(SHOT_W, SHOT_H, GfxDesc{max_quads: MAX_QUADS, software: o.warp})
    if err != "" {
        print("no device for std.gfx:", err)
        return 77
    }
    d := demo_new(o)
    d.show_hud = false
    super_fit(g, &d.ss, SHOT_W, SHOT_H)
    for i in 0..o.check {
        step(&d, false)
    }
    for tod in 0..3 {
        d.tod = tod
        frame_begin()
        rerr := render(g, &d, 0.0, 0.0)
        assert rerr == "", rerr
        frame_end()
        print(d.scene.lt.name, "triangles", d.scene.tris, "vertices", g.stats.vertices, "dropped", g.stats.dropped)
    }
    p := d.cur.pos
    print("aircraft at", fmtf(p.x, 2), fmtf(p.y, 2), fmtf(p.z, 2), "after", o.check, "steps")
    gfx_close(g)
    0
}

// ---------- the showcase recording ----------

// sin² from 0 at a up to 1 halfway to b and back to 0 at b: a smooth there-and-back.
fn bump(t: f32, a: f32, b: f32) -> f32 {
    if t <= a || t >= b {
        return 0.0
    }
    s := sin(PI * (t - a) / (b - a))
    s * s
}

// What a person might do during the recording, at t seconds into it: look around with the
// mouse (left and a little down, later right), peek at the wireframe, and towards the end
// let the evening fade into the night.
fn showcase(d: *Demo, t: f32) {
    d.cur.look_yaw = 0.9 * bump(t, 3.5, 9.0) - 0.6 * bump(t, 12.5, 16.5)
    d.cur.look_pitch = -0.14 * bump(t, 3.5, 9.0) + 0.08 * bump(t, 12.5, 16.5)
    d.scene.wire = t >= 9.8 && t < 11.8
    fade := smoothstep(17.0, 18.6, t)
    d.fade_to = TOD_NIGHT
    d.fade = if fade < 1.0 { fade } else { 0.0 }
    d.tod = if fade < 1.0 { TOD_GOLDEN } else { TOD_NIGHT }
}

// Offscreen: fly `frames` steps, then `length` frames of the showcase, one 60 Hz step each,
// supersampled, written raw (RGBA, top row first) to FILE.0, FILE.1, ... (AL has no appending
// write; join them in order for an encoder).
fn run_record(o: Options) -> i64 {
    g, err := gfx_offscreen(SHOT_W, SHOT_H, GfxDesc{max_quads: MAX_QUADS, software: o.warp})
    if err != "" {
        eprint(fmt("no device for std.gfx: ", err))
        return 1
    }
    d := demo_new(o)
    d.show_hud = false
    super_fit(g, &d.ss, SHOT_W, SHOT_H)
    if d.ss.k > 1 {
        d.ss.mix = g.render_texture(SHOT_W, SHOT_H, FilterNearest)
    }
    for i in 0..max(o.frames, 0) {
        step(&d, false)
    }
    for f in 0..o.length {
        showcase(&d, f32(f) / f32(HZ))
        frame_begin()
        rerr := render(g, &d, 0.0, 0.0)
        assert rerr == "", rerr
        img := g.read_pixels()
        if !write_file(fmt(o.record, ".", f), img.pix) {
            eprint(fmt("cannot write ", o.record, ".", f))
            return 1
        }
        frame_end()
        step(&d, true)                                   // (true: the scripted look stays)
    }
    print("recorded", o.length, "frames of", SHOT_W, "x", SHOT_H, "to", fmt(o.record, ".0 .. ", o.record, ".", o.length - 1))
    gfx_close(g)
    0
}
fn main() -> i64 {
    o, err := parse_options(args())
    if err != "" {
        eprint(err)
        return 2
    }
    if o.check >= 0 {
        return run_check(o)
    }
    if o.record != "" {
        return run_record(o)
    }
    if o.shot != "" {
        return run_shots(o)
    }
    run_window(o)
    0
}
