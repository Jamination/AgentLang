// The showcase video of examples/gfx_flow: `--record FILE` runs the simulation offscreen at
// 1280 x 720, one 60 Hz step per frame, on a faster schedule than the window's (four pieces
// in 22 seconds, 2-second cross-fades, the mouse pulling and then pushing the corona of Solar
// wind along a scripted path) and writes every frame as raw RGBA, top row first. std's
// write_file cannot append, so the frames go to chunk files FILE.000, FILE.001, ... of
// REC_CHUNK frames each; join them (`copy /b FILE.000+FILE.001+... FILE`, or cat) and encode,
// e.g. with tmp/video/mfenc.exe.

const REC_PRE = 360              // steps run before the first recorded frame (Aurora develops)
const REC_FRAMES = 22 * HZ
const REC_CHUNK = 60
const REC_FADE = 2 * HZ

struct Cue { frame: i64, piece: i64 }

// When each piece starts (frames of the recording; Aurora from the start).
const CUES = [_]Cue{Cue{0, 0}, Cue{300, 2}, Cue{750, 1}, Cue{1050, 3}}

// Where the hand is: (frame, x, y, pull), x and y fractions of the picture. Between two
// points the hand eases in and out, as a hand does; the pull is the first point's.
struct Waypoint { frame: i64, x: f32, y: f32, pull: f32 }

const PATH = [_]Waypoint{
    Waypoint{555, 0.86, 0.22, 0.0}, Waypoint{585, 0.76, 0.28, 1.0}, Waypoint{625, 0.71, 0.52, 1.0},
    Waypoint{665, 0.57, 0.76, 1.0}, Waypoint{690, 0.42, 0.80, 0.0}, Waypoint{712, 0.30, 0.64, -1.0},
    Waypoint{735, 0.27, 0.42, -1.0}, Waypoint{758, 0.33, 0.22, 0.0}, Waypoint{800, 0.45, 0.05, 0.0},
}

// The hand at frame f: position (fractions) and the pull it wants.
fn hand_at(f: i64) -> (vec2, f32) {
    if f < PATH[0].frame || f >= PATH[len(PATH) - 1].frame {
        return (vec2(-1.0), 0.0)
    }
    k := 0
    while PATH[k + 1].frame <= f {
        k += 1
    }
    a := PATH[k]
    b := PATH[k + 1]
    t := smoothstep(0.0, 1.0, f32(f - a.frame) / f32(b.frame - a.frame))
    wobble := vec2(sin(f32(f) * 0.07), cos(f32(f) * 0.113)) * 0.004   // not a robot's line
    (lerp(vec2(a.x, a.y), vec2(b.x, b.y), t) + wobble, a.pull)
}

// The piece's name, fading in after its cue, held, fading out.
priv fn title(g: *Gfx, h: *Hud, show: *Show, f: i64) {
    since := f
    for c in CUES {
        if c.frame <= f {
            since = f - c.frame
        }
    }
    a := smoothstep(0.0, 30.0, f32(since)) * (1.0 - smoothstep(130.0, 170.0, f32(since)))
    if a > 0.0 {
        c := show.p.hud
        g.set_blend(BlendAlpha)
        g.draw_text(h.title, 34.0, 26.0, show.all[show.to].name, color_u32(vec4(c.x, c.y, c.z, 0.85 * a)))
    }
}

fn run_record(o: Options) -> i64 {
    w := 1280
    h := 720
    g, err := gfx_offscreen(w, h, GfxDesc{max_quads: MAX_PARTICLES + 4096, software: o.warp})
    if err != "" {
        print("no device for std.gfx:", err)
        return 77
    }
    hud := hud_new(g)
    show := show_new(0, false)
    show.fade = REC_FADE
    sc := scene_new(g, w, h, &show, o.seed)
    sc.look.grain_a = 0.012                                // grain costs the encoder dearly
    size := w * h * 4
    buf := alloc[u8](REC_CHUNK * size)
    chunks := 0
    pull: f32 = 0.0
    dropped := 0
    for f in -REC_PRE..REC_FRAMES {
        for c in CUES[1..] {
            if c.frame == f {
                show_pick(&show, &sc.sim, c.piece)
            }
        }
        pos, want := hand_at(f)
        pull += clamp(want - pull, -0.1, 0.1)
        show_step(&show, &sc.sim)
        sim_step(&sc.sim, Mouse{vec2(pos.x * sc.sim.w, pos.y * sc.sim.h), pull})
        frame_begin()
        if !g.begin_frame(0xFF000000) {
            print("the device was lost:", g.lost)
            return 1
        }
        frame(g, &sc, &show, 1)
        if f >= 0 {
            title(g, &hud, &show, f)
        }
        rerr := g.end_frame()
        if rerr != "" {
            print("the device was lost:", rerr)
            return 1
        }
        dropped += g.stats.dropped
        frame_end()
        if f < 0 {
            continue
        }
        m := mark()
        img := read_pixels(g)
        k := f % REC_CHUNK
        copy(buf[k * size..(k + 1) * size], img.pix)
        release(m)
        if k == REC_CHUNK - 1 || f == REC_FRAMES - 1 {
            path := fmt(o.record, ".", fmti(chunks, 3, '0'))
            if !write_file(path, buf[..(k + 1) * size]) {
                eprint(fmt("cannot write ", path))
                return 1
            }
            chunks += 1
        }
    }
    print("recorded", REC_FRAMES, "frames", w, "x", h, "in", chunks, "chunks", o.record, ".000 ...", "dropped", dropped)
    gfx_close(g)
    0
}
