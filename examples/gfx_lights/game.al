// Dynamic 2D lights with soft shadows in a dungeon chamber, on std.gfx (Direct3D 12 on
// Windows, Vulkan on Linux). Five torches flicker and throw embers, a magic orb circles the
// rune carving in the middle, a lantern follows the mouse (and wanders by itself while the
// mouse rests); every light casts shadows from the walls, pillars and crates. All the art is
// made in code at start-up (art.al): flagstones, bricks, crates, the rune circle, ambient
// occlusion. The simulation runs at a fixed 60 steps per second from a seed (world.al).
//
// How light falls in its own colour on the textured surfaces although std.gfx blends only by
// alpha and by adding (no multiply, no shaders of the program's own): lighting.al, at the top.
// In short: a light map of visibility polygons (triangle fans) in a render texture; per colour
// channel, the light map masked to that channel, darkened by a coverage texture of 1 - albedo
// with alpha blending (dst * albedo); the three channel textures added on the screen.
//
//   alc run examples/gfx_lights/game.al                         in a window
//   alc run examples/gfx_lights/game.al -- --frames 300         quit after 300 frames: prints
//                                                               the frame count, frame time
//                                                               and CPU time per frame
//   alc run examples/gfx_lights/game.al -- --shot out.png --frames 600
//                                                               no window: 600 steps of the
//                                                               scripted run, the last frame
//                                                               saved as a 1280 x 720 PNG
//   alc run examples/gfx_lights/game.al -- --record tmp/lights.rgba
//                                                               no window: the 24 s scripted
//                                                               showcase (showcase.al), raw
//                                                               RGBA frames for a video
//                                                               encoder, in one-second parts
//   alc run examples/gfx_lights/game.al -- --offscreen --frames 120
//                                                               the same without a picture:
//                                                               a checksum of the simulation
//
// Click to add a light (a wisp, in the next colour) or to remove the light under the pointer;
// S switches shadows off and on, L shows the light map, then the bare albedo, then the lit
// room again; H hides the text, F11 / Alt+Enter is fullscreen, Escape quits. Other options:
// --seed N (another floor), --view lit|lightmap|albedo and --no-shadows (what to show at
// first, also for --shot), --warp (the software rasterizer), --no-vsync, --fullscreen.
use std.window
use std.image
use std.gfx
use std.gfx_text
use std.asset
use "world.al"
use "art.al"
use "lighting.al"
use "showcase.al"

const MAX_QUADS = 1 << 17                // the fans of all sub-lights are many triangles

struct Options {
    frames: i64          // -1: until the window is closed
    shot: str            // a PNG to write (no window)
    offscreen: bool      // no window (also with shot)
    seed: u64
    warp: bool
    vsync: bool
    fullscreen: bool
    view: View           // what to show at first
    no_shadows: bool
    record: str          // raw RGBA frames of the showcase to write (no window)
}

fn parse_options(a: []str) -> (Options, str) {
    o := Options{frames: -1, seed: 7, vsync: true}
    k := 1
    while k < len(a) {
        s := a[k]
        if (s == "--frames" || s == "--seed" || s == "--shot" || s == "--record") && k + 1 < len(a) {
            v := a[k + 1]
            k += 1
            if s == "--record" {
                o.record = v
            } else if s == "--shot" {
                o.shot = v
                o.offscreen = true
            } else {
                n, ok := parse_i64(v)
                if !ok || n < 0 {
                    return (o, fmt(s, ": not a number: ", v))
                }
                if s == "--frames" { o.frames = n } else { o.seed = u64(n) }
            }
        } else if s == "--offscreen" {
            o.offscreen = true
        } else if s == "--warp" {
            o.warp = true
        } else if s == "--no-vsync" {
            o.vsync = false
        } else if s == "--no-shadows" {
            o.no_shadows = true
        } else if s == "--fullscreen" {
            o.fullscreen = true
        } else if s == "--view" && k + 1 < len(a) {
            k += 1
            v := a[k]
            if v == "lightmap" {
                o.view = LightMap
            } else if v == "albedo" {
                o.view = Albedo
            } else if v != "lit" {
                return (o, fmt("--view: lit, lightmap or albedo, not ", v))
            }
        } else {
            return (o, fmt("unknown option ", s, " (options: --frames N --shot FILE.png --record FILE.rgba --offscreen --seed N --view lit|lightmap|albedo --no-shadows --warp --no-vsync --fullscreen)"))
        }
        k += 1
    }
    (o, "")
}

// ---- text ---------------------------------------------------------------------------------

const SANS_PATHS = [_]str{
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
}
const SERIF_PATHS = [_]str{
    "C:/Windows/Fonts/georgia.ttf",
    "C:/Windows/Fonts/constan.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf",
    "/usr/share/fonts/TTF/DejaVuSerif.ttf",
    "/usr/share/fonts/dejavu/DejaVuSerif.ttf",
    "/usr/share/fonts/noto/NotoSerif-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSerif-Regular.ttf",
}
const TEST_FONT = embed("../../tests/std/data/font_test.ttf")

fn load_font(paths: []str) -> Font {
    for p in paths {
        f, err := font_load(p)
        if err == "" {
            return f
        }
    }
    f, _ := font_parse(TEST_FONT)
    f
}

const TITLE_PX: f32 = 30.0
const TEXT_PX: f32 = 15.0

// The fonts of the HUD, rasterised at their size on the screen (virtual size times the scale of
// the view) and drawn at their virtual size: sharp in any window size. Made anew when it changes.
struct Hud { sans: Font, serif: Font, scale: f32, title: GfxFont, text: GfxFont, show: bool }

hud_mem: Region

fn fonts_for(g: *Gfx, h: *Hud, scale: f32) {
    if scale == h.scale || !(scale > 0.0) {
        return
    }
    if h.scale > 0.0 {
        gfx_font_free(g, h.title)
        gfx_font_free(g, h.text)
    }
    reset(&hud_mem)
    enter(&hud_mem)
    err := ""
    h.title, err = gfx_font(g, h.serif, TITLE_PX * scale, char_range(32, 126))
    assert err == "", err
    h.text, err = gfx_font(g, h.sans, TEXT_PX * scale, char_range(32, 126))
    assert err == "", err
    leave()
    h.title.size = TITLE_PX
    h.text.size = TEXT_PX
    h.scale = scale
}

const INK = 0xFFC8DDEB                   // parchment
const DIM = 0xFF8B9196
const KEY = 0xFF6AC4F2                   // warm gold

// Text with a soft dark shadow under it, readable over light and dark stone.
fn shadowed(g: *Gfx, f: GfxFont, x: f32, y: f32, s: str, color: u32, align: TextAlign) {
    g.draw_text(f, x + 1.0, y + 2.0, s, 0xB0000000, align)
    g.draw_text(f, x, y, s, color, align)
}

const HINTS = [_](str, str){("click", "add / remove a light"), ("S", "shadows"), ("L", "light map"), ("H", "hide text"), ("Esc", "quit")}

fn draw_hud(g: *Gfx, h: *Hud, w: *World, lt: *Lighting, view_name: str, cpu_ms: f64, fps: f64) {
    if !h.show {
        return
    }
    g.set_blend(BlendAlpha)
    shadowed(g, h.title, 64.0, 10.0, "Dungeon Lights", INK, AlignLeft)
    shadowed(g, h.text, 66.0, 46.0, "shadow-casting 2D light on std.gfx", DIM, AlignLeft)
    x := f32(VW) - 64.0
    shadows := if lt.shadows { "soft shadows" } else { "shadows off" }
    shadowed(g, h.text, x, 18.0, fmt(w.lights.len, " lights  |  ", shadows, "  |  ", view_name), INK, AlignRight)
    perf := if fps > 0.0 { fmt(fmtf(fps, 0), " fps  |  frame built in ", fmtf(cpu_ms, 2), " ms") } else { "fixed step 60 Hz" }
    shadowed(g, h.text, x, 40.0, perf, DIM, AlignRight)
    // the keys along the bottom wall, centred
    gap: f32 = 26.0
    total: f32 = 0.0
    for hint in HINTS {
        kw, _ := text_size(h.text, hint.0)
        dw, _ := text_size(h.text, hint.1)
        total += kw + 7.0 + dw + gap
    }
    hx := (f32(VW) - (total - gap)) * 0.5
    y := f32(VH) - 31.0
    for hint in HINTS {
        kw, _ := text_size(h.text, hint.0)
        dw, _ := text_size(h.text, hint.1)
        shadowed(g, h.text, hx, y, hint.0, KEY, AlignLeft)
        shadowed(g, h.text, hx + kw + 7.0, y, hint.1, DIM, AlignLeft)
        hx += kw + 7.0 + dw + gap
    }
}

// ---- what glows by itself -----------------------------------------------------------------

struct Sprites { glow: Texture, disc: Texture, flame: Texture, runes: [RUNE_SECTORS]Texture, vignette: Texture }

fn rgba(c: vec3, a: f32) -> u32 { color_u32(vec4(c, a)) }

fn glow_at(g: *Gfx, sp: *Sprites, p: vec2, size: f32, color: vec3, a: f32) {
    s := f32(GLOW_SIZE)
    g.sprite(sp.glow, vec4(0.0, 0.0, s, s), vec4(p.x - size * 0.5, p.y - size * 0.5, size, size), rgba(color, a))
}

// A glow stretched into a streak, turned by `angle`: the rays of the orb's star.
fn streak(g: *Gfx, sp: *Sprites, p: vec2, len: f32, wid: f32, angle: f32, color: vec3, a: f32) {
    s := f32(GLOW_SIZE)
    g.sprite(sp.glow, vec4(0.0, 0.0, s, s), p, vec2(len, wid), angle, vec2(len, wid) * 0.5, rgba(color, a))
}

fn flame(g: *Gfx, sp: *Sprites, base: vec2, w: f32, h: f32, sway: f32, color: vec3, a: f32) {
    src := vec4(0.0, 0.0, f32(FLAME_W), f32(FLAME_H))
    g.sprite(sp.flame, src, base, vec2(w, h), sway, vec2(w * 0.5, h * 0.78), rgba(color, a))
}

fn disc(g: *Gfx, sp: *Sprites, p: vec2, r: f32, color: u32) {
    s := f32(DISC_SIZE)
    g.sprite(sp.disc, vec4(0.0, 0.0, s, s), vec4(p.x - r, p.y - r, 2.0 * r, 2.0 * r), color)
}

// The lantern seen from above: a brass rim, light through the glass around its domed cap.
fn lantern(g: *Gfx, sp: *Sprites, p: vec2, c: vec3) {
    glow_at(g, sp, p, 150.0, c, 0.2)
    glow_at(g, sp, p, 50.0, c, 0.45)
    g.set_blend(BlendAlpha)
    disc(g, sp, p, 11.5, 0xFF102236)                    // dark brass rim
    g.set_blend(BlendAdd)
    disc(g, sp, p, 9.5, rgba(vec3(1.0, 0.74, 0.36), 1.0))
    glow_at(g, sp, p, 24.0, vec3(1.0, 0.9, 0.7), 0.8)
    g.set_blend(BlendAlpha)
    for k in 0..4 {
        a := f32(k) * HALF_PI + 0.785
        g.line(p, p + vec2(cos(a), sin(a)) * 10.5, 1.3, 0xB00E1A26)   // struts
    }
    disc(g, sp, p, 5.5, 0xFF1C3A57)                     // the cap
    disc(g, sp, p + vec2(-1.3, -1.5), 2.6, 0xFF5A9AD0)  // its highlight
    g.set_blend(BlendAdd)
}

fn draw_emissive(g: *Gfx, sp: *Sprites, w: *World, lt: *Lighting, alpha: f32) {
    t := f32(w.t)
    g.set_blend(BlendAdd)
    // the rune circle smoulders; the carving wakes where the orb passes, a wave of light that
    // follows it around (each angular sector of the carving has its own brightness)
    orb_angle: f32 = 0.0
    has_orb := false
    for l in w.lights {
        if l.kind == Orb {
            d := light_at(l, alpha) - ROOM_CENTER
            orb_angle = atan2(d.y, d.x)
            has_orb = true
        }
    }
    rs := f32(RUNE_SIZE)
    src := vec4(0.0, 0.0, rs, rs)
    dst := vec4(ROOM_CENTER.x - rs * 0.5, ROOM_CENTER.y - rs * 0.5, rs, rs)
    awake: f32 = 0.0
    for k in 0..RUNE_SECTORS {
        mid := (f32(k) + 0.5) / f32(RUNE_SECTORS) * TAU - PI
        d := wrap_angle(orb_angle - mid)
        wave := if has_orb { exp(-d * d / 0.25) } else { 0.0 }
        a := 0.085 + 0.03 * sin(t * 1.3 + f32(k)) + 0.6 * wave
        awake += wave
        g.sprite(sp.runes[k], src, dst, rgba(vec3(0.62, 0.42, 1.0), a))
    }
    glow_at(g, sp, ROOM_CENTER, 440.0, vec3(0.35, 0.2, 0.9), 0.04 + 0.02 * awake)
    // embers and sparks
    for p in w.parts {
        f := saturate(p.life / p.span)
        color := match p.kind {
            Ember => lerp(vec3(0.9, 0.16, 0.03), p.color, f)
            Spark => p.color
        }
        a := saturate(f * 2.5)
        glow_at(g, sp, p.pos, p.size * 8.0, color, a * 0.3)
        glow_at(g, sp, p.pos, p.size * 2.6, lerp(color, vec3(1.0), 0.35), a)
    }
    // the lights themselves
    for l in w.lights {
        p := light_at(l, alpha)
        c := l.color
        match l.kind {
            Torch => {
                glow_at(g, sp, p, 190.0 * l.level, c, 0.18)
                glow_at(g, sp, p + vec2(0.0, -8.0), 70.0, vec3(1.0, 0.55, 0.2), 0.45 * l.level)
                sway := noise2(t * 3.1, l.seed + 1.0) * 0.22
                k := 0.8 + 0.3 * l.level
                tall := 1.0 + 0.18 * noise2(t * 9.0, l.seed + 2.0)
                flame(g, sp, p, 24.0 * k, 50.0 * k * tall, sway, vec3(1.0, 0.28, 0.05), 0.9)
                flame(g, sp, p, 16.0 * k, 36.0 * k * tall, sway * 1.4, vec3(1.0, 0.58, 0.16), 0.95)
                flame(g, sp, p + vec2(0.0, 1.0), 9.0 * k, 19.0 * k, sway * 1.8, vec3(1.0, 0.92, 0.66), 1.0)
            }
            Orb => {
                glow_at(g, sp, p, 280.0, c, 0.2)
                glow_at(g, sp, p, 80.0, c, 0.7)
                for k in 0..3 {
                    a := t * 0.6 + f32(k) * PI / 3.0
                    streak(g, sp, p, 70.0 + 12.0 * sin(t * 2.0 + f32(k)), 5.0, a, lerp(c, vec3(1.0), 0.4), 0.55)
                }
                glow_at(g, sp, p, 28.0, vec3(0.85, 0.85, 1.0), 1.0)
                glow_at(g, sp, p, 12.0, vec3(1.0), 1.0)
            }
            Lantern => lantern(g, sp, p, c)
            Wisp => {
                glow_at(g, sp, p, 160.0, c, 0.25)
                glow_at(g, sp, p, 44.0, c, 0.8)
                glow_at(g, sp, p, 14.0, lerp(c, vec3(1.0), 0.6), 1.0)
            }
        }
    }
}

// Dust in the air: only where light reaches it, in the colour of that light.
fn draw_motes(g: *Gfx, sp: *Sprites, w: *World, lt: *Lighting, alpha: f32) {
    t := f32(w.t)
    g.set_blend(BlendAdd)
    for m in w.motes {
        light := light_on(lt, w, m.pos, alpha)
        lum := fmax(light.x, fmax(light.y, light.z))
        if lum < 0.03 {
            continue
        }
        twinkle := 0.55 + 0.45 * sin(t * 1.7 + m.phase)
        a := saturate(lum * 0.8) * twinkle
        color := light / lum
        glow_at(g, sp, m.pos, m.size * 7.0, color, a * 0.45)
        glow_at(g, sp, m.pos, m.size * 2.2, lerp(color, vec3(1.0), 0.5), a)
    }
}

// ---- a frame ------------------------------------------------------------------------------

enum View { Lit, LightMap, Albedo }

struct Scene {
    lt: Lighting
    sp: Sprites
    hud: Hud
    view: View
    cpu_ms: f64          // CPU time spent building the last frame (update not included)
    cursor: vec2         // a mouse pointer drawn into the picture (the recording), if show_cursor
    show_cursor: bool
    click_age: f32       // seconds since the pointer last clicked: a ring spreads from it
}

fn scene_new(g: *Gfx, seed: u64) -> Scene {
    art := bake_art(seed)
    sp := Sprites{glow: g.texture(art.glow, FilterLinear), disc: g.texture(art.disc, FilterLinear), flame: g.texture(art.flame, FilterLinear),
        vignette: g.texture(art.vignette, FilterLinear)}
    for k in 0..RUNE_SECTORS {
        sp.runes[k] = g.texture(art.runes[k], FilterLinear)
    }
    Scene{lt: lighting_new(g, &art), sp: sp, hud: Hud{sans: load_font(SANS_PATHS[..]), serif: load_font(SERIF_PATHS[..]), show: true}}
}

fn view_name(v: View) -> str {
    match v {
        Lit => "lit"
        LightMap => "light map"
        Albedo => "albedo"
    }
}

// Draws one frame of the world; "" or why the device failed.
fn render(g: *Gfx, s: *Scene, w: *World, alpha: f32, fps: f64) -> str {
    if !g.begin_frame(0xFF000000) {
        return ""
    }
    t0 := time_ns()
    draw_lightmap(g, &s.lt, w, alpha)
    if s.view == Lit {
        draw_channels(g, &s.lt)
    }
    g.set_view(f32(VW), f32(VH))
    full := vec4(0.0, 0.0, f32(VW), f32(VH))
    match s.view {
        Lit => {
            draw_lit(g, &s.lt)
            draw_haze(g, &s.lt)
        }
        LightMap => draw_lightmap_view(g, &s.lt)
        Albedo => {
            g.set_blend(BlendAlpha)
            g.sprite(s.lt.albedo, full, full, 0xFFFFFFFF)
        }
    }
    if s.view != Albedo {
        draw_motes(g, &s.sp, w, &s.lt, alpha)
        draw_emissive(g, &s.sp, w, &s.lt, alpha)
    }
    g.set_blend(BlendAlpha)
    g.sprite(s.sp.vignette, vec4(0.0, 0.0, f32(s.sp.vignette.w), f32(s.sp.vignette.h)), full, 0xFFFFFFFF)
    if s.show_cursor {
        draw_cursor(g, &s.sp, s.cursor, s.click_age)
    }
    draw_hud(g, &s.hud, w, &s.lt, view_name(s.view), s.cpu_ms, fps)
    s.cpu_ms = f64(time_ns() - t0) / 1e6
    g.end_frame()
}

// ---- running ------------------------------------------------------------------------------

// The scripted input of a run without a window: two lights added, one removed, one added
// again; the lantern wanders.
fn scripted(step: i64) -> Control {
    c := Control{mouse: vec2(0.0)}
    pts := [_](i64, vec2){(20, vec2(200.0, 450.0)), (50, vec2(1150.0, 290.0)), (80, vec2(200.0, 450.0)), (100, vec2(560.0, 140.0))}
    for e in pts {
        if step == e.0 {
            c.mouse = e.1
            c.click = true
        }
    }
    c
}

fn run_offscreen(o: Options) -> i64 {
    g, err := gfx_offscreen(VW, VH, GfxDesc{max_quads: MAX_QUADS, software: o.warp})
    if err != "" {
        print("no device for std.gfx:", err)
        return 77
    }
    scene := scene_new(g, o.seed)
    scene.view = o.view
    scene.lt.shadows = !o.no_shadows
    fonts_for(g, &scene.hud, 1.0)
    world := world_new(o.seed)
    frames := if o.frames < 0 { 1 } else { o.frames }
    dropped := 0
    for f in 0..frames {
        world_update(&world, scripted(world.steps), f32(1.0 / HZ))
        if o.shot != "" && f + 1 < frames {
            continue                                       // a shot needs only the last frame
        }
        frame_begin()
        rerr := render(g, &scene, &world, 1.0, 0.0)
        if rerr != "" {
            panic(rerr)
        }
        frame_end()
        dropped += g.stats.dropped
    }
    if o.shot != "" {
        if !png_save(o.shot, g.read_pixels()) {
            eprint(fmt("cannot write ", o.shot))
            return 1
        }
    }
    print("steps", world.steps, "lights", world.lights.len, "added", world.added, "removed", world.removed, "particles", world.parts.len,
        "checksum", hex(world_checksum(&world)), "dropped", dropped)
    gfx_close(g)
    0
}

fn run_window(o: Options) -> i64 {
    win, ok := window_open(WindowDesc{title: "Dungeon Lights (std.gfx)", width: VW, height: VH, resizable: true, fullscreen: o.fullscreen})
    if !ok {
        eprint("cannot open a window")
        return 1
    }
    g, err := gfx_open(win, GfxDesc{max_quads: MAX_QUADS, software: o.warp})
    if err != "" {
        eprint(err)
        return 1
    }
    g.vsync = o.vsync
    eprint(concat("device: ", g.device))
    scene := scene_new(g, o.seed)
    scene.view = o.view
    scene.lt.shadows = !o.no_shadows
    world := world_new(o.seed)
    clock := frame_clock()
    steps := fixed_step(HZ)
    frames := 0
    dropped := 0
    click := false
    moved := false
    build_ms: f64 = 0.0                                    // CPU time building the frames
    started := time_ns()
    mem0: i64 = 0                                          // arena in use after the first frame: must stay so
    while !win.should_close() && frames != o.frames {
        win.poll()
        inp := &win.input
        if inp.key_pressed(KEY_ESCAPE) {
            win.closing = true
        }
        if inp.key_pressed(KEY_F11) || (inp.key_pressed(KEY_ENTER) && inp.alt_down()) {
            win.set_fullscreen(!win.fullscreen)
        }
        if inp.key_pressed(KEY_S) {
            scene.lt.shadows = !scene.lt.shadows
        }
        if inp.key_pressed(KEY_L) {
            scene.view = View((i64(scene.view) + 1) % variant_count[View]())
        }
        if inp.key_pressed(KEY_H) {
            scene.hud.show = !scene.hud.show
        }
        ww, wh := win.size()
        view, _, _, _, _ := fit_view(f32(VW), f32(VH), ww, wh)
        // a click or a move between two steps is kept for the next step
        if inp.mouse_pressed(MOUSE_LEFT) {
            click = true
        }
        md := inp.mouse_delta()
        if md.x != 0.0 || md.y != 0.0 {
            moved = true
        }
        for k in 0..steps.advance(clock.tick()) {
            world_update(&world, Control{mouse: apply(inverse(view), inp.mouse_pos()), mouse_moved: moved, click: click}, f32(steps.step))
            click = false
            moved = false
        }
        if ww > 0 && wh > 0 && !win.minimized {
            fonts_for(g, &scene.hud, view.x.x)
        }
        frame_begin()
        rerr := render(g, &scene, &world, steps.alpha(), clock.fps)
        build_ms += scene.cpu_ms
        if rerr != "" {
            panic(rerr)
        }
        frame_end()
        dropped += g.stats.dropped
        frames += 1
        if frames == 1 {
            mem0 = mem_used()
        }
    }
    growth := mem_used() - mem0                            // (before the texts below allocate)
    secs := f64(time_ns() - started) / 1e9
    n := f64(max(frames, 1))
    print("frames", frames, "in", fmtf(secs, 2), "s: average frame", fmtf(secs * 1000.0 / n, 2), "ms, built in", fmtf(build_ms / n, 2),
        "ms of CPU; dropped", dropped, "; memory growth", growth, "bytes")
    gfx_close(g)
    win.close()
    0
}

fn main() -> i64 {
    o, err := parse_options(args())
    if err != "" {
        eprint(err)
        return 2
    }
    if o.record != "" {
        return run_record(o)
    }
    if o.offscreen {
        return run_offscreen(o)
    }
    run_window(o)
}
