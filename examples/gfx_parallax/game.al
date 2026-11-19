// A side-scrolling pixel-art landscape on std.gfx, entirely procedural: no asset files. A
// wanderer walks through hills at a virtual resolution of 480 x 270 while a day passes: a
// banded, dithered sky through dawn, noon, dusk and a starry night with moon and shooting
// stars; a sun with a pixel glow; drifting clouds; mountains, hills and a forest in parallax,
// each painted once from noise into masks that are tinted with the colours of the moment and
// fade into the haze of their distance; auto-tiled ground; lakes that mirror the scene; birds
// by day, fireflies by night, falling leaves, rain on demand, grass that sways in the wind and
// parts around the wanderer. Left alone for a few seconds it walks by itself.
//
//   alc run examples/gfx_parallax/game.al                      walk (a window)
//   alc run examples/gfx_parallax/game.al -- --frames 300      quit after 300 frames, print timing
//   alc run examples/gfx_parallax/game.al -- --shot out.png --time 0.75 --frames 120
//                                                              render offscreen at 1440 x 810, save
//   alc run examples/gfx_parallax/game.al -- --record tmp/clip --frames 1320 --time 0.64
//                                                              a scripted run (--script) offscreen:
//                                     raw RGBA frames, 60 per file tmp/clip.000, .001, ... (join them
//                                     with `copy /b` / `cat` for a video encoder); a day lasts 90 s
//
// Arrows / WASD / left stick or D-pad move, Space / W / Up / pad A jump, T time x14, R rain,
// F11 or Alt+Enter fullscreen, Escape / pad Back quits. Other options: --seed N, --time T (0..1,
// 0 midnight, 0.5 noon), --rain, --fast, --offscreen (no window, prints a check of the world),
// --script (offscreen: a scripted player instead of the attract mode), --warp (software
// rasterizer), --no-vsync.
//
// Files: palette.al (the colours of the day), paint.al (the painter of masks), scenery.al
// (mountains, hills, forest, clouds, props), sprites.al (tiles, the wanderer, moon, glows),
// world.al (terrain and simulation), render.al (the two drawing passes).
use std.window
use std.image
use std.gfx
use std.gfx_text
use "palette.al"
use "paint.al"
use "scenery.al"
use "sprites.al"
use "world.al"
use "render.al"

const SHOT_W = 1440              // 3 x 480: square pixels
const SHOT_H = 810

struct Options {
    frames: i64          // -1: until closed
    shot: str
    record: str          // base name of the raw frame files
    script: bool
    offscreen: bool
    tod: f64
    seed: u32
    rain: bool
    fast: bool
    warp: bool
    vsync: bool
    fullscreen: bool
}

fn parse(a: []str) -> (Options, str) {
    o := Options{frames: -1, tod: 0.3, seed: 7, vsync: true}
    k := 1
    while k < len(a) {
        s := a[k]
        has := k + 1 < len(a)
        if s == "--frames" && has {
            n, ok := parse_i64(a[k + 1])
            if !ok || n < 1 {
                return (o, fmt("--frames: not a positive number: ", a[k + 1]))
            }
            o.frames = n
            k += 1
        } else if s == "--shot" && has {
            o.shot = a[k + 1]
            o.offscreen = true
            k += 1
        } else if s == "--time" && has {
            t, ok := parse_f64(a[k + 1])
            if !ok || t < 0.0 || t > 1.0 {
                return (o, fmt("--time: a number from 0 to 1, not ", a[k + 1]))
            }
            o.tod = t
            k += 1
        } else if s == "--seed" && has {
            n, ok := parse_i64(a[k + 1])
            if !ok {
                return (o, fmt("--seed: not a number: ", a[k + 1]))
            }
            o.seed = u32(n)
            k += 1
        } else if s == "--record" && has {
            o.record = a[k + 1]
            o.offscreen = true
            o.script = true
            k += 1
        } else if s == "--script" {
            o.script = true
            o.offscreen = true
        } else if s == "--offscreen" {
            o.offscreen = true
        } else if s == "--rain" {
            o.rain = true
        } else if s == "--fast" {
            o.fast = true
        } else if s == "--warp" {
            o.warp = true
        } else if s == "--no-vsync" {
            o.vsync = false
        } else if s == "--fullscreen" {
            o.fullscreen = true
        } else {
            return (o, fmt("unknown option ", s, " (options: --frames N --shot FILE --record BASE --script --time T --seed N --rain --fast --offscreen --warp --no-vsync --fullscreen)"))
        }
        k += 1
    }
    (o, "")
}

// ---- the HUD

const FONT_PATHS = [_]str{
    "C:/Windows/Fonts/consolab.ttf",
    "C:/Windows/Fonts/consola.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Bold.ttf",
}
const TEST_FONT = embed("../../tests/std/data/font_test.ttf")
const TEXT_PX: f32 = 7.0         // em sizes of the HUD fonts in virtual pixels
const CLOCK_PX: f32 = 10.0

fn load_font() -> Font {
    for p in FONT_PATHS {
        f, err := font_load(p)
        if err == "" {
            return f
        }
    }
    eprint("no system font found: the HUD is drawn with the test font of std.font")
    f, _ := font_parse(TEST_FONT)
    f
}

// The HUD's fonts are rasterised at the size they have on the screen and drawn at their
// virtual size, so they are sharp at any window size; a new scale makes them anew.
struct Hud { font: Font, scale: f32, small: GfxFont, big: GfxFont, fps: f64 }

hud_mem: Region

fn fonts_for(g: *Gfx, h: *Hud, scale: f32) {
    if scale == h.scale || !(scale > 0.0) {
        return
    }
    if h.scale > 0.0 {
        gfx_font_free(g, h.small)
        gfx_font_free(g, h.big)
    }
    reset(&hud_mem)
    enter(&hud_mem)
    err := ""
    h.small, err = gfx_font(g, h.font, TEXT_PX * scale, char_range(32, 126))
    assert err == "", err
    h.big, err = gfx_font(g, h.font, CLOCK_PX * scale, char_range(32, 126))
    assert err == "", err
    leave()
    h.small.size = TEXT_PX
    h.big.size = CLOCK_PX
    h.scale = scale
}

// A panel with a one-pixel border and cut corners.
fn panel(g: *Gfx, r: vec4) {
    g.rect(vec4(r.x + 1.0, r.y, r.z - 2.0, r.w), 0xB8180E0C)
    g.rect(vec4(r.x, r.y + 1.0, r.z, r.w - 2.0), 0xB8180E0C)
    edge: u32 = 0x60F0E0D0
    g.rect(vec4(r.x + 1.0, r.y, r.z - 2.0, 1.0), edge)
    g.rect(vec4(r.x + 1.0, r.y + r.w - 1.0, r.z - 2.0, 1.0), edge)
    g.rect(vec4(r.x, r.y + 1.0, 1.0, r.w - 2.0), edge)
    g.rect(vec4(r.x + r.z - 1.0, r.y + 1.0, 1.0, r.w - 2.0), edge)
}

fn draw_hud(g: *Gfx, a: *Art, h: *Hud, w: *World, l: *Light) {
    if h.scale <= 0.0 {
        return
    }
    // the clock: sun or moon, the time, the part of the day, and a strip of the day's skies
    panel(g, vec4(5.0, 5.0, 84.0, 26.0))
    day := l.sun_elev > -0.05
    icon := if day { rgb(0xffd860) } else { rgb(0xdce4ff) }
    g.sprite(a.misc, vec4(96.0, 16.0, f32(DISC_SIZE), f32(DISC_SIZE)), vec4(9.0, 9.0, 9.0, 9.0), col(icon))
    if !day {
        g.sprite(a.misc, vec4(96.0, 16.0, f32(DISC_SIZE), f32(DISC_SIZE)), vec4(12.0, 8.0, 8.0, 8.0), 0xFF2A140E)
    }
    g.draw_text(h.big, 22.0, 6.0, clock_text(l.t), 0xFFF4F0E8)
    g.draw_text(h.small, 52.0, 8.0, period_name(l.t), 0xFFA8C8D8)
    for i in 0..24 {
        g.rect(vec4(9.0 + f32(i) * 3.0, 24.0, 3.0, 3.0), col(horizon_at((f32(i) + 0.5) / 24.0) * 0.85))
    }
    g.rect(vec4(9.0 + floor(l.t * 72.0), 22.0, 1.0, 7.0), 0xFFFFFFFF)
    if w.fast {
        g.draw_text(h.small, 52.0, 15.0, "x14", 0xFF60D0FF)
    }
    // frames per second
    vw := f32(VIEW_W)
    panel(g, vec4(vw - 47.0, 5.0, 42.0, 13.0))
    g.draw_text(h.small, vw - 9.0, 6.0, fmt(i64(h.fps + 0.5), " fps"), 0xFFC8E0E8, AlignRight)
    // hints, and the attract mode
    vh := f32(VIEW_H)
    hint := "Arrows/WASD move  Space jump  T time  R rain  F11 fullscreen  Esc quit"
    tw, _ := text_size(h.small, hint)
    panel(g, vec4(5.0, vh - 16.0, floor(tw) + 9.0, 12.0))
    g.draw_text(h.small, 9.0, vh - 15.5, hint, 0xFFB8C8D0)
    if w.attract {
        demo := "DEMO - any key to play"
        dw, _ := text_size(h.small, demo)
        panel(g, vec4(vw - floor(dw) - 14.0, vh - 16.0, floor(dw) + 9.0, 12.0))
        on := fract(w.time * 0.8) < 0.7
        g.draw_text(h.small, vw - 9.0, vh - 15.5, demo, if on { 0xFF80E0FF } else { 0xFF406070 }, AlignRight)
    }
}

// ---- running

fn new_world(o: Options) -> World {
    w := world_new(o.seed, o.tod)
    w.rain = o.rain
    w.rain_k = if o.rain { 1.0 } else { 0.0 }
    w.fast = o.fast
    w
}

// A frame: the scene into its texture, then the screen.
fn frame(g: *Gfx, a: *Art, h: *Hud, w: *World, alpha: f32) -> str {
    if !g.begin_frame(0xFF000000) {
        return ""
    }
    l := light_at(f32(w.tod))
    draw_scene(g, a, w, &l, alpha)
    g.set_view(f32(VIEW_W), f32(VIEW_H))
    draw_screen(g, a, w, &l, alpha)
    draw_hud(g, a, h, w, &l)
    g.end_frame()
}

// The player of --script and --record: runs right through the landscape as a person would,
// jumps onto every ledge a little early, hops now and then for joy, stops halfway over each
// bridge to take in the view, glances back once, and gets caught in a shower.
struct Script { t: f32, hold: f32, pause: f32, paused_at: i64 }

fn scripted(w: *World, s: *Script, dt: f32) -> Controls {
    s.t += dt
    w.rain = s.t > 9.5 && s.t < 12.5
    c := Controls{active: true}
    h := &w.hero
    if s.t < 1.0 {
        return c                                        // a look around first
    }
    tx := tile_x(h.pos.x)
    l := lake_of(tx, w.seed)
    if l.end > l.start && tx == (l.start + l.end) / 2 && s.paused_at != l.start && h.on_ground {
        s.paused_at = l.start
        s.pause = 1.8
    }
    if s.pause > 0.0 {
        s.pause -= dt
        return c
    }
    c.move = if s.t > 12.0 && s.t < 12.5 { -1.0 } else { 1.0 }
    ahead := ground_under(h.pos.x + 15.0 * c.move, HERO_HALF, w.seed)
    hop := fabs(s.t - 6.5) < 0.02 || fabs(s.t - 16.2) < 0.02
    if h.on_ground && (ahead < h.pos.y - 3.0 || hop) {
        c.jump = true
        s.hold = if hop { 0.15 } else { 0.35 }
    }
    s.hold -= dt
    c.hold = s.hold > 0.0
    c
}

const RECORD_CHUNK = 60          // frames per raw file

// No window: N frames of one step each, then (with --shot) the last frame as a PNG; with
// --record every frame, raw. Prints what the world came to, which depends only on the seed and
// the options.
fn run_offscreen(o: Options) -> i64 {
    g, err := gfx_offscreen(SHOT_W, SHOT_H, GfxDesc{software: o.warp, max_quads: 65536})
    if err != "" {
        print("no device for std.gfx:", err)
        return 77
    }
    art := make_art(g, o.seed)
    hud := Hud{font: load_font(), fps: 60.0}
    view, _, _, _, _ := fit_view(f32(VIEW_W), f32(VIEW_H), SHOT_W, SHOT_H)
    fonts_for(g, &hud, view.x.x)
    w := new_world(o)
    script := Script{}
    if o.script {
        w.day_secs = 90.0                               // dusk and night within the clip
    }
    frames := if o.frames > 0 { o.frames } else { 1 }
    dropped := 0
    mem_after_first: i64 = 0
    raw := vec[u8]()
    if o.record != "" {
        raw.reserve(RECORD_CHUNK * SHOT_W * SHOT_H * 4)   // grown once, before any frame
    }
    chunks := 0
    for f in 0..frames {
        c := if o.script { scripted(&w, &script, 1.0 / f32(HZ)) } else { Controls{} }
        update(&w, c, 1.0 / f32(HZ))
        frame_begin()
        ferr := frame(g, &art, &hud, &w, 1.0)
        if ferr != "" {
            panic(ferr)
        }
        if o.record != "" {
            raw.extend(read_pixels(g).pix)               // within the capacity: no growth
        }
        frame_end()
        if o.record != "" && (raw.len == raw.buf.len || f == frames - 1) {
            m := mark()
            name := fmt(o.record, ".", fmti(chunks, 3, '0'))
            if !write_file(name, raw.items()) {
                eprint(fmt("cannot write ", name))
                return 1
            }
            release(m)
            raw.clear()
            chunks += 1
        }
        dropped += g.stats.dropped
        if f == 0 {
            mem_after_first = mem_used()
        }
    }
    if mem_used() != mem_after_first {
        eprint(fmt("memory grew by ", mem_used() - mem_after_first, " bytes after the first frame"))
    }
    if o.shot != "" {
        if !png_save(o.shot, read_pixels(g)) {
            eprint(fmt("cannot write ", o.shot))
            return 1
        }
    }
    h := &w.hero
    print("frames", frames, "steps", w.steps, "time", clock_text(f32(w.tod)), "hero", fmtf(h.pos.x, 2), fmtf(h.pos.y, 2),
        "attract", w.attract, "dropped", dropped)
    print("world check", hex(world_check(&w)))
    gfx_close(g)
    0
}

fn run_window(o: Options) {
    win, ok := window_open(WindowDesc{title: "AL parallax (std.gfx)", width: SHOT_W, height: SHOT_H, resizable: true,
        fullscreen: o.fullscreen})
    if !ok {
        panic("cannot open a window")
    }
    g, err := gfx_open(win, GfxDesc{software: o.warp, max_quads: 65536})
    if err != "" {
        panic(err)
    }
    g.vsync = o.vsync
    art := make_art(g, o.seed)
    hud := Hud{font: load_font()}
    keys := action_map()
    left := keys.action("left")
    right := keys.action("right")
    jump := keys.action("jump")
    quit := keys.action("quit")
    for k in []i64{KEY_LEFT, KEY_A} { keys.bind_key(left, k) }
    for k in []i64{KEY_RIGHT, KEY_D} { keys.bind_key(right, k) }
    for k in []i64{KEY_SPACE, KEY_W, KEY_UP} { keys.bind_key(jump, k) }
    keys.bind_key(quit, KEY_ESCAPE)
    keys.bind_pad(jump, PAD_A)
    keys.bind_pad(quit, PAD_BACK)
    pad := &win.input.pad
    gamepad_open(pad, 0)
    w := new_world(o)
    clock := frame_clock()
    steps := fixed_step(f64(HZ))
    frames := 0
    start := time_ns()
    jump_latch := false
    while !win.should_close() && frames != o.frames {
        win.poll()
        inp := &win.input
        if pad.connected {
            gamepad_poll(pad)
        }
        if keys.action_pressed(inp, quit) {
            win.closing = true
        }
        if inp.key_pressed(KEY_F11) || (inp.key_pressed(KEY_ENTER) && inp.alt_down()) {
            win.set_fullscreen(!win.fullscreen)
        }
        if inp.key_pressed(KEY_T) {
            w.fast = !w.fast
        }
        if inp.key_pressed(KEY_R) {
            w.rain = !w.rain
        }
        // the controls of this frame; a jump press waits for the next step
        c := Controls{move: keys.action_axis(inp, left, right), hold: keys.action_down(inp, jump)}
        stick := pad_stick(pad, PAD_AXIS_LX, PAD_AXIS_LY, 0.25).x + pad_axis(pad, PAD_AXIS_DPAD_X)
        if pad.connected && fabs(stick) > 0.1 {
            c.move = clamp(stick, -1.0, 1.0)
        }
        jump_latch = jump_latch || keys.action_pressed(inp, jump)
        c.active = c.move != 0.0 || c.hold || jump_latch
        for k in 0..steps.advance(clock.tick()) {
            c.jump = jump_latch
            jump_latch = false
            update(&w, c, f32(steps.step))
        }
        hud.fps = clock.fps
        ww, wh := win.size()
        if ww > 0 && wh > 0 && !win.minimized {
            view, _, _, _, _ := fit_view(f32(VIEW_W), f32(VIEW_H), ww, wh)
            fonts_for(g, &hud, view.x.x)
        }
        frame_begin()
        ferr := frame(g, &art, &hud, &w, steps.alpha())
        if ferr != "" {
            panic(ferr)                      // the GPU was lost (the text is scratch: use it before frame_end)
        }
        if g.stats.dropped > 0 {
            eprint(fmt("dropped draws: ", g.stats.dropped))
        }
        frame_end()
        frames += 1
    }
    secs := f64(time_ns() - start) / 1e9
    print("frames", frames, "average frame", fmtf(secs * 1000.0 / f64(max(frames, 1)), 2), "ms", "device", g.device)
    gfx_close(g)
    win.close()
}

fn main() -> i64 {
    o, err := parse(args())
    if err != "" {
        eprint(err)
        return 2
    }
    if o.offscreen {
        return run_offscreen(o)
    }
    run_window(o)
    0
}
