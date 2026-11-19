// Flow: generative art with std.gfx. Tens of thousands of particles drift through an animated
// curl-noise flow field and leave luminous, silky trails: each frame the previous picture is
// drawn faded into a second render texture (slightly zoomed or turned for some pieces) and the
// particles' new segments are drawn on top; a blurred small copy adds the glow. Five pieces
// (Aurora, Ink in water, Solar wind, Nebula, Silk), each with its own palette, field, particle
// count, line width, trail length and ground, cross-fade into each other every 20 seconds.
// Deterministic: the same seed (and mouse) gives the same pictures, frame for frame. Runs on
// Windows (Direct3D 12) and Linux (Vulkan); flow.al is the simulation, render.al the GPU
// passes, presets.al the pieces.
//
//   alc run examples/gfx_flow/game.al                    in a window
//   alc run examples/gfx_flow/game.al -- --shot out.png --preset 3 --frames 600
//                                                        a 1280 x 720 picture, no window
//
// Keys: 1-5 pick a piece, N or Right the next one, Space reseeds, S saves the picture as a PNG
// in the current directory, H hides the text, C stops / resumes the cycling, F11 or Alt+Enter
// fullscreen, Escape quits. Hold the left mouse button to attract the flow, the right one to
// push it away.
//
// Options: --frames N (quit after N frames; the window prints the frame count and the mean
// frame time), --preset K, --seed S, --no-cycle, --fullscreen, --warp, --no-vsync; for
// --shot FILE also --size WxH, --hud, --mouse X,Y,PULL (X, Y fractions of the picture,
// PULL 1 attracts, -1 repels). --check N runs N frames offscreen and prints a checksum of the
// particles (the test). --record FILE writes the 22-second showcase video as raw RGBA frames
// (record.al).
use std.window
use std.image
use std.gfx
use std.gfx_text
use "presets.al"
use "flow.al"
use "render.al"
use "record.al"

const MAX_PARTICLES = 60000
const HOLD_STEPS = 20 * HZ       // a piece is shown this long before the next one comes
const FADE_STEPS = 4 * HZ        // and the cross-fade takes this long
const DEFAULT_SEED: u64 = 20261119

// ---- the show: which piece, the cross-fade, the palette

struct Show {
    all: [PRESET_COUNT]Preset
    luts: []u32                  // PRESET_COUNT ramps of LUT_SIZE colours
    from: Params                 // where the cross-fade started (a snapshot: switching again
    from_lut: []u32              // mid-way starts from what is on screen)
    to: i64                      // the piece shown, or faded to
    t: i64                       // steps into the cross-fade; `fade`: done
    fade: i64                    // steps a cross-fade takes
    hold: i64                    // steps since the cross-fade ended
    cycle: bool
    p: Params                    // now
    lut: []u32                   // now
    paper: u32                   // the paper of the ink layer
}

fn show_new(first: i64, cycle: bool) -> Show {
    s := Show{all: presets(), to: first, t: FADE_STEPS, fade: FADE_STEPS, cycle: cycle}
    s.luts = alloc[u32](PRESET_COUNT * LUT_SIZE)
    for k in 0..PRESET_COUNT {
        ramp_lut(s.all[k], s.luts[k * LUT_SIZE..(k + 1) * LUT_SIZE])
    }
    s.from_lut = alloc[u32](LUT_SIZE)
    s.lut = alloc[u32](LUT_SIZE)
    s.p = params_of(s.all[first])
    copy(s.lut, preset_lut(&s, first))
    s.paper = paper_of(s.all[first])
    for k in 0..PRESET_COUNT {
        if s.all[first].mode != Ink && s.all[k].mode == Ink {
            s.paper = paper_of(s.all[k])
        }
    }
    s
}

// The colour of an ink piece's paper: its ink layer, white where clean, is drawn tinted by it.
fn paper_of(p: Preset) -> u32 { color_u32(lerp(color_vec4(p.top), color_vec4(p.bottom), 0.5)) }

fn preset_lut(s: *Show, k: i64) -> []u32 { s.luts[k * LUT_SIZE..(k + 1) * LUT_SIZE] }

// Starts the cross-fade to piece k.
fn show_pick(s: *Show, sim: *Sim, k: i64) {
    if k == s.to && s.t >= s.fade {
        return
    }
    s.from = s.p
    copy(s.from_lut, s.lut)
    s.to = k
    s.t = 0
    s.hold = 0
    sim.spawn = s.all[k].spawn
    sim.spread = s.all[k].spread
    if s.all[k].mode == Ink {
        s.paper = paper_of(s.all[k])
    }
    if (s.p.ink >= 0.5) != (s.all[k].mode == Ink) {
        sim_respawn(sim)                                  // light trails do not become ink, nor ink light
    }
}

// One step of the show: the cross-fade, the cycling; the simulation follows `s.p`.
fn show_step(s: *Show, sim: *Sim) {
    if s.t < s.fade {
        s.t += 1
        x := f32(s.t) / f32(s.fade)
        e := x * x * x * (x * (x * 6.0 - 15.0) + 10.0)     // smootherstep
        target := params_of(s.all[s.to])
        s.p = mix_params(s.from, target, e)
        if (s.from.ink >= 0.5) != (target.ink >= 0.5) {
            copy(s.lut, preset_lut(s, s.to))                // another layer: its own colours,
            g := smoothstep(0.35, 0.65, e)                  // and a quick change of ground (paper and
            s.p.top = lerp(s.from.top, target.top, g)       // night sky do not mix well)
            s.p.bottom = lerp(s.from.bottom, target.bottom, g)
        } else {
            mix_lut(s.from_lut, preset_lut(s, s.to), e, s.lut)
        }
    } else {
        s.hold += 1
        if s.cycle && s.hold >= HOLD_STEPS {
            show_pick(s, sim, (s.to + 1) % PRESET_COUNT)
        }
    }
    sim.p = s.p
}

// ---- options

struct Options {
    frames: i64                  // -1: until closed
    shot: str
    record: str                  // --record: the showcase video (record.al)
    check: i64                   // > 0: the test run
    preset: i64                  // 0-based
    seed: u64
    cycle: bool
    fullscreen: bool
    warp: bool
    vsync: bool
    hud: bool                    // text in the shot
    size: (i64, i64)
    mouse: Mouse                 // held during a shot, in fractions of the picture
}

fn parse_options(a: []str) -> (Options, str) {
    o := Options{frames: -1, seed: DEFAULT_SEED, cycle: true, vsync: true, size: (1280, 720)}
    k := 1
    while k < len(a) {
        s := a[k]
        arg := if k + 1 < len(a) { a[k + 1] } else { "" }
        n, num := parse_i64(arg)
        if (s == "--frames" || s == "--preset" || s == "--seed" || s == "--check") && !num {
            return (o, fmt(s, ": not a number: ", arg))
        }
        if s == "--frames" {
            o.frames = n
            k += 1
        } else if s == "--preset" {
            if n < 1 || n > PRESET_COUNT {
                return (o, fmt("--preset: 1 to ", PRESET_COUNT))
            }
            o.preset = n - 1
            k += 1
        } else if s == "--seed" {
            o.seed = u64(n)
            k += 1
        } else if s == "--check" {
            o.check = n
            k += 1
        } else if s == "--shot" && arg != "" {
            o.shot = arg
            k += 1
        } else if s == "--record" && arg != "" {
            o.record = arg
            k += 1
        } else if s == "--size" && arg != "" {
            parts := split(arg, 'x')
            w, okw := parse_i64(parts[0])
            h, okh := if len(parts) == 2 { parse_i64(parts[1]) } else { (0, false) }
            if !okw || !okh || w < 16 || h < 16 {
                return (o, fmt("--size: WxH, not ", arg))
            }
            o.size = (w, h)
            k += 1
        } else if s == "--mouse" && arg != "" {
            parts := split(arg, ',')
            if len(parts) != 3 {
                return (o, "--mouse X,Y,PULL")
            }
            x, okx := parse_f64(parts[0])
            y, oky := parse_f64(parts[1])
            pull, okp := parse_f64(parts[2])
            if !okx || !oky || !okp {
                return (o, "--mouse X,Y,PULL")
            }
            o.mouse = Mouse{vec2(f32(x), f32(y)), f32(pull)}
            k += 1
        } else if s == "--no-cycle" {
            o.cycle = false
        } else if s == "--fullscreen" {
            o.fullscreen = true
        } else if s == "--warp" {
            o.warp = true
        } else if s == "--no-vsync" {
            o.vsync = false
        } else if s == "--hud" {
            o.hud = true
        } else {
            return (o, fmt("unknown option ", s, " (options: --frames N --preset K --seed S --no-cycle --fullscreen ",
                "--warp --no-vsync --shot FILE --size WxH --hud --mouse X,Y,PULL --check N --record FILE))"))
        }
        k += 1
    }
    (o, "")
}

// ---- text

const FONT_PATHS = [_]str{
    "C:/Windows/Fonts/segoeuil.ttf",          // Segoe UI Light
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-ExtraLight.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
}
const TEST_FONT = embed("../../tests/std/data/font_test.ttf")

fn load_font() -> Font {
    for p in FONT_PATHS {
        f, err := font_load(p)
        if err == "" {
            return f
        }
    }
    eprint("no system font found: the text is drawn with the test font of std.font")
    f, _ := font_parse(TEST_FONT)
    f
}

struct Hud { title: GfxFont, small: GfxFont }

fn hud_new(g: *Gfx) -> Hud {
    f := load_font()
    title, err := gfx_font(g, f, 30.0, char_range(32, 126))
    assert err == "", err
    small, err2 := gfx_font(g, f, 14.0, char_range(32, 126))
    assert err2 == "", err2
    Hud{title, small}
}

// 36000 as "36,000".
fn grouped(n: i64) -> str {
    if n < 1000 {
        return fmt(n)
    }
    fmt(grouped(n / 1000), ",", fmti(n % 1000, 3, '0'))
}

fn draw_hud(g: *Gfx, h: *Hud, show: *Show, sim: *Sim, fps: f64) {
    c := show.p.hud
    col := fn(c: vec4, a: f32) -> u32 { color_u32(vec4(c.x, c.y, c.z, a)) }
    x := 34.0
    g.set_blend(BlendAlpha)
    g.draw_text(h.title, x, 26.0, show.all[show.to].name, col(c, 0.92))
    info := fmt(grouped(sim.active), " particles      ", i64(fps + 0.5), " fps")
    if !show.cycle {
        info = fmt(info, "      hold")
    }
    g.draw_text(h.small, x, 68.0, info, col(c, 0.62))
    keys := "1-5  piece      N  next      Space  reseed      S  save      H  hide      C  cycle      mouse  pull / push"
    g.draw_text(h.small, x, f32(g.height) - 34.0 - line_height(h.small), keys, col(c, 0.42))
}

// ---- running

// Everything that depends on the picture's size: made again when the window is resized.
struct Scene {
    look: Look
    sim: Sim
}

scene_mem: Region                // the scene's slices; reset when it is made again

fn scene_new(g: *Gfx, w: i64, h: i64, show: *Show, seed: u64) -> Scene {
    reset(&scene_mem)
    enter(&scene_mem)
    sc := Scene{}
    sc.look = look_new(g, w, h, seed)
    target := show.all[show.to]
    sc.sim = sim_new(f32(w) / f32(h), MAX_PARTICLES, seed, show.p, target.spawn, target.spread)
    leave()
    sc
}

// One frame of the picture; `steps` simulation steps were taken since the last one.
fn frame(g: *Gfx, sc: *Scene, show: *Show, steps: i64) {
    if steps > 0 {
        p := show.p
        p.trail = p.trail / f32(steps)               // as much fading as the steps took
        render_picture(g, &sc.look, &sc.sim, &p, show.lut, show.paper, show.all[show.to].mode == Ink)
    }
    g.reset_target()
    g.set_blend(BlendAlpha)
    l := &sc.look
    g.sprite(l.final, 0.0, 0.0)
}

fn save_picture(g: *Gfx, sc: *Scene, path: str) {
    img := g.read_texture(sc.look.final)
    if png_save(path, img) {
        print("saved", path)
    } else {
        eprint(fmt("cannot write ", path))
    }
}

fn next_seed(seed: u64) -> u64 {
    r := rng(seed)
    r.next_u64() >> 16
}

fn run_window(o: Options) {
    w, ok := window_open(WindowDesc{title: "Flow", width: 1280, height: 720, resizable: true, fullscreen: o.fullscreen})
    if !ok {
        panic("cannot open a window")
    }
    g, err := gfx_open(w, GfxDesc{max_quads: MAX_PARTICLES + 4096, software: o.warp})
    if err != "" {
        panic(err)
    }
    g.vsync = o.vsync
    hud := hud_new(g)
    show := show_new(o.preset, o.cycle)
    seed := o.seed
    ww, wh := w.size()
    sc := scene_new(g, max(ww, 16), max(wh, 16), &show, seed)
    clock := frame_clock()
    steps := fixed_step(HZ)
    pull: f32 = 0.0
    show_hud := true
    frames := 0
    dropped := 0
    start := clock_ns()
    busy := 0                                              // ns of CPU work: simulation and drawing
    while !w.should_close() && frames != o.frames {
        w.poll()
        inp := &w.input
        if inp.key_pressed(KEY_ESCAPE) {
            w.closing = true
        }
        if inp.key_pressed(KEY_F11) || (inp.key_pressed(KEY_ENTER) && inp.alt_down()) {
            w.set_fullscreen(!w.fullscreen)
        }
        for k in 0..PRESET_COUNT {
            if inp.key_pressed(KEY_1 + k) {
                show_pick(&show, &sc.sim, k)
            }
        }
        if inp.key_pressed(KEY_N) || inp.key_pressed(KEY_RIGHT) {
            show_pick(&show, &sc.sim, (show.to + 1) % PRESET_COUNT)
        }
        if inp.key_pressed(KEY_SPACE) {
            seed = next_seed(seed)
            sim_reseed(&sc.sim, seed)
        }
        if inp.key_pressed(KEY_H) {
            show_hud = !show_hud
        }
        if inp.key_pressed(KEY_C) {
            show.cycle = !show.cycle
            show.hold = 0
        }
        save := inp.key_pressed(KEY_S)
        ww, wh = w.size()
        if ww > 0 && wh > 0 && !w.minimized && (ww != sc.look.w || wh != sc.look.h) {
            look_free(g, &sc.look)                         // a new size: the picture starts again
            sc = scene_new(g, ww, wh, &show, seed)
        }
        want: f32 = if inp.mouse_down(MOUSE_LEFT) { 1.0 } else if inp.mouse_down(MOUSE_RIGHT) { -1.0 } else { 0.0 }
        n := steps.advance(clock.tick())
        t0 := clock_ns()
        for k in 0..n {
            pull += clamp(want - pull, -0.1, 0.1)          // eased in and out over 1/6 s
            show_step(&show, &sc.sim)
            m := inp.mouse_pos() * (UNITS / f32(sc.look.h))
            sim_step(&sc.sim, Mouse{m, pull})
        }
        busy += clock_ns() - t0
        frame_begin()
        if g.begin_frame(0xFF000000) {
            t1 := clock_ns()
            frame(g, &sc, &show, n)
            if show_hud {
                draw_hud(g, &hud, &show, &sc.sim, clock.fps)
            }
            busy += clock_ns() - t1
            rerr := g.end_frame()
            if rerr != "" {
                panic(rerr)
            }
            dropped += g.stats.dropped
            if save {
                frame_end()
                m := mark()                                // the image read back is gone after saving
                save_picture(g, &sc, fmt("flow_", replace(to_lower(show.all[show.to].name), " ", "_"), "_", frames, ".png"))
                release(m)
                frame_begin()
            }
        }
        frame_end()
        frames += 1
    }
    ms := f64(clock_ns() - start) / 1e6 / f64(max(frames, 1))
    cpu := f64(busy) / 1e6 / f64(max(frames, 1))
    print("frames", frames, "mean frame", fmtf(ms, 2), "ms", "cpu", fmtf(cpu, 2), "ms", "dropped", dropped, "device", g.device)
    gfx_close(g)
    w.close()
}

// Offscreen: the shot (one simulation step per frame) or the test.
fn run_offscreen(o: Options) -> i64 {
    w := o.size.0
    h := o.size.1
    if o.check > 0 {
        w = 640
        h = 360
    }
    g, err := gfx_offscreen(w, h, GfxDesc{max_quads: MAX_PARTICLES + 4096, software: o.warp})
    if err != "" {
        print("no device for std.gfx:", err)
        return 77
    }
    hud := hud_new(g)
    show := show_new(o.preset, o.cycle)
    sc := scene_new(g, w, h, &show, o.seed)
    frames := if o.check > 0 { o.check } else if o.frames > 0 { o.frames } else { 600 }
    m := Mouse{vec2(o.mouse.pos.x * sc.sim.w, o.mouse.pos.y * sc.sim.h), o.mouse.pull}
    dropped := 0
    for f in 0..frames {
        if o.check > 0 {                                   // the test: a cross-fade, a reseed, the mouse
            if f == frames / 4 {
                show_pick(&show, &sc.sim, (show.to + 2) % PRESET_COUNT)
            }
            if f == frames / 2 {
                sim_reseed(&sc.sim, next_seed(o.seed))
            }
            m = Mouse{vec2(sc.sim.w * 0.5, sc.sim.h * 0.5), if f > frames * 3 / 4 { 1.0 } else { 0.0 }}
        }
        show_step(&show, &sc.sim)
        sim_step(&sc.sim, m)
        frame_begin()
        if !g.begin_frame(0xFF000000) {
            print("the device was lost:", g.lost)
            return 1
        }
        frame(g, &sc, &show, 1)
        if o.hud {
            draw_hud(g, &hud, &show, &sc.sim, 60.0)
        }
        rerr := g.end_frame()
        if rerr != "" {
            print("the device was lost:", rerr)
            return 1
        }
        dropped += g.stats.dropped
        frame_end()
    }
    if o.check > 0 {
        print("frames", frames, "particles", sc.sim.active, "piece", show.all[show.to].name,
            "dropped", dropped, "checksum", hex(sim_checksum(&sc.sim)))
        return 0
    }
    if !png_save(o.shot, read_pixels(g)) {
        eprint(fmt("cannot write ", o.shot))
        return 1
    }
    print("wrote", o.shot, w, "x", h, "frames", frames, "piece", show.all[show.to].name, "dropped", dropped)
    gfx_close(g)
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
    if o.shot != "" || o.check > 0 {
        return run_offscreen(o)
    }
    run_window(o)
    0
}
