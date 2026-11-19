// A night fireworks display over a city by the water, drawn with std.gfx (Direct3D 12 on
// Windows, Vulkan on Linux). Everything is made in code at start-up: the sprite atlas (soft
// sparks, tapered streaks, twinkles, glows, smoke and cloud noise, a crescent moon), the
// skyline in three hazy layers with thousands of lit windows, the stars. Each frame:
//
//   - thousands of additive sparks: shells climb on comet tails and burst as peonies,
//     chrysanthemums, rings, willows, crackle, pistils, palms, glitter and rainbows, under
//     gravity and drag, with fading streaks, trail embers and white-hot starts (show.al)
//   - a real bloom: the bright pass in a half-size render texture, blurred down a chain of
//     ever smaller linear-filtered render textures and added back up (render.al)
//   - the bursts light the sky, the drifting smoke, the clouds and the buildings' corners
//   - the scene is rendered into a texture and drawn again under the horizon, mirrored in
//     2-pixel strips displaced by travelling ripples, with glints of the bursts (frame.al)
//
// The show runs on its own (a choreography in acts: overture, willows, colours, crackle,
// finale); a click launches a shell that bursts at the pointer, Space a volley from every
// pad, A stops or resumes the show, F11 fullscreen, Escape quits. The simulation runs on a
// fixed step from a seed, so a run is the same every time:
//
//   alc run examples/gfx_fireworks/game.al                               watch
//   alc run examples/gfx_fireworks/game.al -- --frames 300               quit after 300 frames, print timing
//   alc run examples/gfx_fireworks/game.al -- --shot out.png --frames 900
//                     simulate 900 steps (15 s), render one 1280 x 720 frame offscreen, save it
//   alc run examples/gfx_fireworks/game.al -- --record tmp/show.rgba --from 960 --frames 1320
//                     simulate 960 steps, then render 1320 frames offscreen, one step each, with
//                     a few scripted clicks and volleys (RECORD_SCRIPT), as raw 1280 x 720 RGBA
//                     frames for a video encoder. AL cannot append to a file, so they go into
//                     tmp/show.rgba.000, .001, ... of 60 frames each: join them in order
//                     (Windows: copy /b a.000+a.001+... all.rgba; Linux: cat)
//   alc run examples/gfx_fireworks/game.al -- --offscreen --frames 240
//                     240 frames offscreen, one step each: counts and a checksum (the test)
//
// Other options: --from N (steps simulated before --record starts), --seed N, --warp (software rasterizer), --no-vsync, --fullscreen.
use std.window
use std.image
use std.gfx
use std.gfx_text
use "show.al"
use "render.al"
use "frame.al"

const MAX_QUADS = 60000          // sprites per frame: two per spark, one more in the bright pass

struct Options {
    frames: i64          // -1: until closed
    shot: str
    record: str
    from: i64
    offscreen: bool
    seed: u64
    warp: bool
    vsync: bool
    fullscreen: bool
}

fn parse_options(a: []str) -> (Options, str) {
    o := Options{frames: -1, seed: 1, vsync: true}
    k := 1
    while k < len(a) {
        s := a[k]
        has := k + 1 < len(a)
        if s == "--frames" && has {
            n, ok := parse_i64(a[k + 1])
            if !ok || n < 0 {
                return (o, fmt("--frames: not a count: ", a[k + 1]))
            }
            o.frames = n
            k += 1
        } else if s == "--seed" && has {
            n, ok := parse_u64(a[k + 1])
            if !ok {
                return (o, fmt("--seed: not a number: ", a[k + 1]))
            }
            o.seed = n
            k += 1
        } else if s == "--from" && has {
            n, ok := parse_i64(a[k + 1])
            if !ok || n < 0 {
                return (o, fmt("--from: not a count: ", a[k + 1]))
            }
            o.from = n
            k += 1
        } else if s == "--record" && has {
            o.record = a[k + 1]
            k += 1
        } else if s == "--shot" && has {
            o.shot = a[k + 1]
            k += 1
        } else if s == "--offscreen" {
            o.offscreen = true
        } else if s == "--warp" {
            o.warp = true
        } else if s == "--no-vsync" {
            o.vsync = false
        } else if s == "--fullscreen" {
            o.fullscreen = true
        } else {
            return (o, fmt("unknown option ", s, " (options: --frames N --shot FILE.png --record FILE.rgba --from N --offscreen --seed N --warp --no-vsync --fullscreen)"))
        }
        k += 1
    }
    (o, "")
}

// --shot: the show simulated for `frames` steps, then one frame rendered offscreen and saved.
fn run_shot(o: Options) -> i64 {
    g, err := gfx_offscreen(i64(VW), i64(VH), GfxDesc{max_quads: MAX_QUADS, software: o.warp})
    if err != "" {
        eprint(fmt("no device for std.gfx: ", err))
        return 1
    }
    art := art_new(g, 2024)
    hud := hud_new()
    hud_fonts(g, &hud, 1.0)
    s := show_new(o.seed)
    for k in 0..max(o.frames, 1) {
        show_step(&s)
    }
    _, rerr, _ := render_frame(g, &art, &hud, &s, 0.0, "1280 x 720 offscreen")
    if rerr != "" {
        eprint(rerr)
        return 1
    }
    if !png_save(o.shot, g.read_pixels()) {
        eprint(fmt("cannot write ", o.shot))
        return 1
    }
    print("wrote", o.shot, "after", s.steps, "steps:", s.nparts, "particles,", g.stats.draw_calls, "draw calls,",
        g.stats.passes, "passes, dropped", g.stats.dropped)
    gfx_close(g)
    0
}

// What --record does by hand, in seconds from the start of the recording: 0 a click at
// (x, y), 1 a volley.
const RECORD_SCRIPT = [_](f32, i64, f32, f32){
    (1.5, 0, 330.0, 210.0),
    (4.0, 0, 900.0, 170.0),
    (6.5, 0, 560.0, 250.0),
    (10.5, 1, 0.0, 0.0),
    (13.0, 0, 1010.0, 230.0),
    (15.2, 1, 0.0, 0.0),
}
const RECORD_CHUNK = 60          // frames per file

// --record: frames rendered offscreen one step apart, written raw for a video encoder.
fn run_record(o: Options) -> i64 {
    g, err := gfx_offscreen(i64(VW), i64(VH), GfxDesc{max_quads: MAX_QUADS, software: o.warp})
    if err != "" {
        eprint(fmt("no device for std.gfx: ", err))
        return 1
    }
    art := art_new(g, 2024)
    hud := hud_new()
    hud_fonts(g, &hud, 1.0)
    s := show_new(o.seed)
    for k in 0..o.from {
        show_step(&s)
    }
    frames := if o.frames < 0 { 1320 } else { o.frames }
    size := i64(VW) * i64(VH) * 4
    chunk := alloc[u8](size * RECORD_CHUNK)
    n := 0                        // frames in chunk
    files := 0
    dropped := 0
    for f in 0..frames {
        for e in RECORD_SCRIPT {
            if i64(e.0 * f32(HZ)) == f {
                if e.1 == 0 { launch_at(&s, vec2(e.2, e.3)) } else { volley(&s) }
            }
        }
        show_step(&s)
        m := mark()
        _, rerr, _ := render_frame(g, &art, &hud, &s, 0.0, "60 fps")
        if rerr != "" {
            panic(rerr)
        }
        dropped += g.stats.dropped
        copy(chunk[n * size..(n + 1) * size], g.read_pixels().pix)
        release(m)
        n += 1
        if n == RECORD_CHUNK || f == frames - 1 {
            path := fmt(o.record, ".", fmti(files, 3, '0'))
            if !write_file(path, chunk[..n * size]) {
                eprint(fmt("cannot write ", path))
                return 1
            }
            files += 1
            n = 0
        }
    }
    print("recorded", frames, "frames from step", o.from, "into", files, "files", fmt(o.record, ".000 .."), "dropped", dropped)
    gfx_close(g)
    0
}

// --offscreen: every frame drawn offscreen after one step. What it prints depends only on the
// simulation (and on nothing being dropped), not on the GPU or the time it takes.
fn run_offscreen(o: Options) -> i64 {
    g, err := gfx_offscreen(i64(VW), i64(VH), GfxDesc{max_quads: MAX_QUADS, software: o.warp})
    if err != "" {
        print("no device for std.gfx:", err)
        return 77
    }
    art := art_new(g, 2024)
    hud := hud_new()
    hud_fonts(g, &hud, 1.0)
    s := show_new(o.seed)
    frames := if o.frames < 0 { 240 } else { o.frames }
    dropped := 0
    peak := 0
    used := 0
    for f in 0..frames {
        show_step(&s)
        if f == frames / 2 {
            used = mem_used()
        }
        frame_begin()
        _, rerr, _ := render_frame(g, &art, &hud, &s, 0.0, "offscreen")
        if rerr != "" {
            panic(rerr)
        }
        frame_end()
        dropped += g.stats.dropped
        peak = max(peak, s.nparts)
    }
    print("frames", frames, "launched", s.launched, "bursts", s.bursts, "particles", s.nparts, "peak", peak)
    print("dropped", dropped, "memory grew", mem_used() != used, "checksum", hex(show_checksum(&s)))
    gfx_close(g)
    0
}

fn run_window(o: Options) -> i64 {
    w, ok := window_open(WindowDesc{title: "Fireworks (std.gfx)", width: i64(VW), height: i64(VH), resizable: true,
        fullscreen: o.fullscreen})
    if !ok {
        eprint("cannot open a window")
        return 1
    }
    g, err := gfx_open(w, GfxDesc{max_quads: MAX_QUADS, software: o.warp})
    if err != "" {
        eprint(err)
        return 1
    }
    g.vsync = o.vsync
    art := art_new(g, 2024)
    hud := hud_new()
    s := show_new(o.seed)
    clock := frame_clock()
    steps := fixed_step(f64(HZ))
    view := xform_identity()
    frames := 0
    dropped := 0
    slow := 0                     // frames that took longer than 20 ms (a missed vsync at 60 Hz)
    shown_ms: f64 = 0.0           // the frame time shown, smoothed
    start := time_ns()
    while !w.should_close() && frames != o.frames {
        w.poll()
        inp := &w.input
        if inp.key_pressed(KEY_ESCAPE) {
            w.closing = true
        }
        if inp.key_pressed(KEY_F11) || (inp.key_pressed(KEY_ENTER) && inp.alt_down()) {
            w.set_fullscreen(!w.fullscreen)
        }
        if inp.key_pressed(KEY_SPACE) {
            volley(&s)
        }
        if inp.key_pressed(KEY_A) {
            s.auto = !s.auto
            s.next_cue = s.time + 0.3
        }
        if inp.mouse_pressed(MOUSE_LEFT) {
            p := apply(inverse(view), inp.mouse_pos())
            if p.y < HORIZON - 40.0 && p.x > 0.0 && p.x < VW {
                launch_at(&s, p)
            }
        }
        dt := clock.tick()
        if frames > 0 && dt > 0.020 {
            slow += 1
        }
        shown_ms = if frames == 0 { dt * 1000.0 } else { shown_ms * 0.95 + dt * 50.0 }
        for k in 0..steps.advance(dt) {
            show_step(&s)
        }
        ww, wh := w.size()
        if ww > 0 && wh > 0 && !w.minimized {
            v, _, _, _, _ := fit_view(VW, VH, ww, wh)
            hud_fonts(g, &hud, v.x.x)               // (not in the frame's scratch memory)
        }
        frame_begin()                               // the HUD's texts are scratch memory
        fps := fmt(i64(1000.0 / fmax(shown_ms, 0.1) + 0.5), " fps")
        v, rerr, drawn := render_frame(g, &art, &hud, &s, steps.alpha(), fps)
        if rerr != "" {
            panic(rerr)                             // the GPU was lost (the text is scratch: use it before frame_end)
        }
        frame_end()
        if drawn {
            view = v
            dropped += g.stats.dropped
        }
        frames += 1
    }
    secs := f64(time_ns() - start) / 1e9
    print("frames", frames, "average", fmtf(secs * 1000.0 / f64(max(frames, 1)), 2), "ms", "(", fmtf(f64(frames) / secs, 1),
        "fps ), over 20 ms:", slow, "particles", s.nparts, "dropped", dropped, "on", g.device)
    gfx_close(g)
    w.close()
    0
}

fn main() -> i64 {
    o, err := parse_options(args())
    if err != "" {
        eprint(err)
        return 2
    }
    if o.shot != "" {
        return run_shot(o)
    }
    if o.record != "" {
        return run_record(o)
    }
    if o.offscreen {
        return run_offscreen(o)
    }
    run_window(o)
}
