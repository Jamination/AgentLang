// Recording a gameplay video of the software starter (game.al --record): no window and no sound
// device. A small autopilot plays (it reads the game like a player reads the screen and answers
// with key presses), every frame is drawn as the window draws it and its raw RGBA pixels are
// written out, and the game's events are mixed with the music of the Direct3D 12 version
// (examples/dx12_starter/sound.al) in step with the frames into a WAV file.
//   - the frames go to <base>.000, <base>.001, ... (60 frames, about 124 MB, each: AL writes
//     whole files); join them with `copy /b` (or `cat`) for an encoder that takes raw video
//   - the sound goes to <base>.wav: 16-bit stereo at 48 kHz
use std.audio
use "../dx12_starter/sound.al"

const REC_FPS = 60
const REC_CHUNK = 60                 // frames per output file
const REC_PREROLL = 150              // frames played before the recording starts (rocks arrive)

// The keys the autopilot holds.
struct Pilot { left: bool, right: bool, up: bool, down: bool, fire: bool, hurt_window: bool }

priv fn hold(inp: *Input, key: i64, now: bool, was: *bool) {
    if now != *was {
        inp.feed(Event{kind: if now { EventKeyDown } else { EventKeyUp }, key: key})
        *was = now
    }
}

// One frame of the autopilot: dodge what would hit the ship, otherwise line up under the rock
// that a shot reaches first and fire when it would hit. During frames `careless_from` ..
// `careless_to` it does not dodge (and so, sooner or later, takes a hit).
fn pilot(p: *Pilot, inp: *Input, g: *Game, frame: i64, careless_from: i64, careless_to: i64) {
    me := g.ents.get(g.player)
    if me == nil {
        hold(inp, KEY_LEFT, false, &p.left)
        hold(inp, KEY_RIGHT, false, &p.right)
        hold(inp, KEY_UP, false, &p.up)
        hold(inp, KEY_DOWN, false, &p.down)
        hold(inp, KEY_SPACE, false, &p.fire)
        return
    }
    careless := frame >= careless_from && frame < careless_to && player_hp(g) == 3
    at := me.pos
    goal_x := at.x
    goal_y := 140.0
    best := 1000.0
    danger := false
    aligned := false
    for i in 0..g.ents.len {
        if !g.ents.is_live(i) || g.ents.items[i].kind != Rock {
            continue
        }
        r := &g.ents.items[i]
        // danger: a rock that reaches the ship's height within 0.9 s close to its column
        if r.pos.y < at.y + 4.0 && r.vel.y > 0.0 {
            t := (at.y - r.pos.y) / r.vel.y
            x := r.pos.x + r.vel.x * t
            if t < 0.9 && fabs(x - at.x) < r.radius + 5.0 + 9.0 {
                if careless {
                    goal_x = x                         // misjudged: steers into it
                } else if !danger {
                    danger = true
                    side := if x > at.x { -1.0 } else { 1.0 }
                    if at.x < 30.0 { side = 1.0 }
                    if at.x > f32(WORLD_W) - 30.0 { side = -1.0 }
                    goal_x = x + side * (r.radius + 22.0)
                }
            }
        }
        // a target: where the rock will be when a shot fired now gets to it
        if !danger && !careless && r.pos.y > 4.0 && r.pos.y < at.y - 20.0 {
            t := (at.y - 6.0 - r.pos.y) / (220.0 + r.vel.y)
            x := r.pos.x + r.vel.x * t
            if t < best {
                best = t
                goal_x = x
            }
            if fabs(x - at.x) < r.radius * 0.8 {
                aligned = true
            }
        }
    }
    // a little sway now and then, as a person's hand is never quite still
    goal_x += sin(f32(frame) * 0.05) * 6.0
    hold(inp, KEY_LEFT, goal_x < at.x - 3.0, &p.left)
    hold(inp, KEY_RIGHT, goal_x > at.x + 3.0, &p.right)
    hold(inp, KEY_UP, goal_y < at.y - 6.0, &p.up)
    hold(inp, KEY_DOWN, goal_y > at.y + 6.0, &p.down)
    hold(inp, KEY_SPACE, aligned && !careless, &p.fire)
}

// Records `frames` frames of a game started from `seed` into base.000 ... and base.wav.
fn run_record(base: str, frames: i64, seed: u64) {
    g := game_new(seed)
    v := view_new(&g, false, load_font())
    snd := starter_sound()
    inp: Input
    p: Pilot
    per_frame := AUDIO_RATE / REC_FPS
    pixels := FB_W * FB_H * 4
    chunk := alloc[u8](REC_CHUNK * pixels)
    mix := alloc[i16](per_frame * 2)
    wav := sound_new(AUDIO_RATE, 2, frames * per_frame)
    kills := 0
    for f in -REC_PREROLL..frames {
        inp.begin_frame()
        pilot(&p, &inp, &g, f, 330, 520)
        before := g.score
        for k in 0..2 {
            update(&g, &inp, 1.0 / f32(HZ))
        }
        fx_update(&v.fx, &g, 2.0 / f32(HZ))
        if f < 0 {
            g.events.clear()                   // (the music starts with the recording)
            continue
        }
        kills += (g.score - before) / 10
        play_events(&snd, &g)
        snd.mixer.mix_i16(mix, per_frame)
        for i in 0..per_frame * 2 {
            wav.samples[f * per_frame * 2 + i] = f32(mix[i]) / 32768.0
        }
        frame_begin()
        render(&v, &g, 0.0)
        frame_end()
        n := f % REC_CHUNK
        copy(chunk[n * pixels..(n + 1) * pixels], as_bytes(v.canvas.px))
        if n == REC_CHUNK - 1 || f == frames - 1 {
            name := fmt(base, ".", fmti(f / REC_CHUNK, 3, '0'))
            if !write_file(name, chunk[..(n + 1) * pixels]) {
                eprint(fmt("cannot write ", name))
                exit(1)
            }
        }
    }
    if !wav_save(fmt(base, ".wav"), wav, WAV_PCM16) {
        eprint(fmt("cannot write ", base, ".wav"))
        exit(1)
    }
    print("recorded", frames, "frames in", (frames + REC_CHUNK - 1) / REC_CHUNK, "files; score", g.score, "kills", kills,
        "hp", player_hp(&g), "over", g.over)
}
