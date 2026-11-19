// --record: a gameplay video's raw material. An autopilot plays (pilot below: it reads the game
// and presses keys like a player would), every frame is drawn offscreen as --shot draws one and
// appended to a file of raw RGBA frames (top row first), and the game's sounds and music are
// mixed without a device in step with the frames, as headless.al does, into a WAV file. An
// encoder makes the video (tmp/video/mfenc in the AL repository: H.264 + AAC).
//
// The pilot weaves and shoots: each frame it scores nine ways to steer (eight directions and
// none) over the next 0.7 s against where every rock will be, and takes the cheapest: far from
// the rocks, under the rock it can shoot soonest. To end like a game, from FIRST_SLIP on, and
// SLIP_GAP frames after each hit, it grows careless: it lets go of fire and darts at a rock
// nearby until it is hit. After the third hit the game is over: the recording goes on for the
// end panel, then stops (with game_new(3): hits at 8.4 and 13.3 s, the end at 18.2 s, 22.7 s in all).
use std.input
use std.audio
use std.image
use "../starter/logic.al"
use "../gamekit/options.al"
use "sound.al"
use "art.al"
use "fx.al"
use "render.al"
use "scene.al"

const RECORD_FPS = 60
const RECORD_FRAMES = 1500        // 25 s at most
const RECORD_TAIL = 270           // frames after the end of the game: the GAME OVER panel
priv const FIRST_SLIP = 480       // when the pilot first grows careless (8 s)
priv const SLIP_GAP = 280         // and again this long after each hit

priv extern "kernel32.dll" fn CreateFileA(name: *u8, access: u32, share: u32, security: *u8, disposition: u32, flags: u32, template: *u8) -> *u8
priv extern "kernel32.dll" fn WriteFile(file: *u8, data: *u8, size: u32, written: *u32, overlapped: *u8) -> i32
priv const GENERIC_WRITE: u32 = 0x40000000
priv const CREATE_ALWAYS: u32 = 2

// The keys the pilot holds.
struct Pilot { left: bool, right: bool, up: bool, down: bool, fire: bool, careless: bool, next_slip: i64, hp: i64, hits: Vec[i64] }

priv fn press(inp: *Input, k: i64, held: *bool, want: bool) {
    if *held != want {
        inp.feed(Event{kind: if want { EventKeyDown } else { EventKeyUp }, key: k})
        *held = want
    }
}

// How bad steering `dir` (a unit vector or zero, y down) for the next 0.7 s looks: closeness to
// rocks (not when careless), distance from the shooting position.
priv fn steer_cost(g: *Game, p: *Entity, dir: vec2, aim: vec2, careless: bool) -> f32 {
    cost: f32 = 0.0
    lo := vec2(p.radius)
    hi := vec2(f32(WORLD_W), f32(WORLD_H)) - p.radius
    for i in 0..g.ents.used {
        if !g.ents.is_live(i) || g.ents.items[i].kind != Rock {
            continue
        }
        r := &g.ents.items[i]
        for s in 1..15 {
            t := f32(s) * 0.05
            ship := clamp(p.pos + dir * (110.0 * t), lo, hi)
            gap := distance(ship, r.pos + r.vel * t) - r.radius - p.radius
            if gap < 7.0 && !careless {
                cost += (7.0 - gap) * (7.0 - gap) * (1.6 - t) * 3.0
            }
        }
    }
    end := clamp(p.pos + dir * (110.0 * 0.3), lo, hi)
    // a player keeps room to dodge: away from the sides
    wall := fmax(fmax(50.0 - end.x, end.x - f32(WORLD_W - 50)), 0.0)
    cost + fabs(end.x - aim.x) * 1.2 + fabs(end.y - aim.y) * 0.4 + wall * wall * 0.08
}

// Where the pilot wants to be: under the rock its shots reach soonest, else weaving.
priv fn aim_point(g: *Game, p: *Entity, f: i64) -> vec2 {
    t := f32(f) / f32(RECORD_FPS)
    best: f32 = 1e9
    aim := vec2(160.0 + 90.0 * sin(t * 0.45), 0.0)
    for i in 0..g.ents.used {
        if !g.ents.is_live(i) || g.ents.items[i].kind != Rock {
            continue
        }
        r := &g.ents.items[i]
        if r.pos.y < 4.0 || r.pos.y > p.pos.y - 18.0 {
            continue
        }
        reach := (p.pos.y - r.pos.y) / (220.0 + r.vel.y)       // when a shot fired now meets it
        x := r.pos.x + r.vel.x * reach
        score := fabs(x - p.pos.x) + (p.pos.y - r.pos.y) * 0.35 + (if r.hp < 2 { -12.0 } else { 0.0 })
        if score < best {
            best = score
            aim.x = x
        }
    }
    aim.y = 146.0 + 14.0 * sin(t * 0.8)
    aim
}

// The pilot's keys for frame f.
fn pilot(inp: *Input, g: *Game, pl: *Pilot, f: i64) {
    p := g.ents.get(g.player)
    if f == 0 {
        pl.hp = player_hp(g)
        pl.next_slip = FIRST_SLIP
    }
    if p == nil || g.over {
        press(inp, KEY_LEFT, &pl.left, false)
        press(inp, KEY_RIGHT, &pl.right, false)
        press(inp, KEY_UP, &pl.up, false)
        press(inp, KEY_DOWN, &pl.down, false)
        press(inp, KEY_SPACE, &pl.fire, false)
        return
    }
    if player_hp(g) < pl.hp {
        pl.hp = player_hp(g)
        pl.hits.push(f)
        pl.careless = false
        pl.next_slip = f + SLIP_GAP
    }
    if f >= pl.next_slip {
        pl.careless = true
    }
    aim := aim_point(g, p, f)
    best_cost: f32 = 1e30
    best := vec2(0.0)
    for k in 0..9 {
        d := vec2(f32(k % 3 - 1), f32(k / 3 - 1))
        if d != vec2(0.0) {
            d = normalize(d)
        }
        c := steer_cost(g, p, d, aim, pl.careless)
        if c < best_cost {
            best_cost = c
            best = d
        }
    }
    if pl.careless {
        // it lets go of fire and darts at a rock close by, and misjudges
        near: f32 = 110.0
        for i in 0..g.ents.used {
            if g.ents.is_live(i) && g.ents.items[i].kind == Rock {
                r := &g.ents.items[i]
                d := distance(r.pos, p.pos)
                if d < near {
                    near = d
                    best = normalize(r.pos + r.vel * (d / 110.0) - p.pos)
                }
            }
        }
    }
    press(inp, KEY_LEFT, &pl.left, best.x < -0.1)
    press(inp, KEY_RIGHT, &pl.right, best.x > 0.1)
    press(inp, KEY_UP, &pl.up, best.y < -0.1)
    press(inp, KEY_DOWN, &pl.down, best.y > 0.1)
    press(inp, KEY_SPACE, &pl.fire, f >= 20 && !pl.careless)
}

priv fn put_le(b: []u8, at: i64, v: i64, n: i64) {
    for k in 0..n {
        b[at + k] = u8(v >> (8 * k))
    }
}

// The recording: frames to `path` (raw RGBA, the size of --shot-size), the sound to the same
// name with ".wav" in place of its extension. At most o.frames frames (RECORD_FRAMES if not
// given), less if the game ends before.
fn run_record(o: GameOptions, path: str, width: i64, height: i64, debug: bool) {
    limit := if o.frames < 0 { RECORD_FRAMES } else { o.frames }
    art := make_art()
    r, err := renderer_offscreen(width, height, WORLD_W, WORLD_H, &art, o.warp, debug)
    if err != "" {
        panic(err)
    }
    file := CreateFileA(cstr(path), GENERIC_WRITE, 0, nil, CREATE_ALWAYS, 0x80, nil)
    if cast[i64](file) == -1 || file == nil {
        panic(fmt("--record: cannot create ", path))
    }
    g := game_new(3)
    fx := fx_new(&g)
    snd := starter_sound()
    inp: Input
    pl: Pilot
    per_frame := AUDIO_RATE / RECORD_FPS
    pcm := alloc[i16](limit * per_frame * 2)
    over_at := -1
    frames := 0
    while frames < limit && (over_at < 0 || frames < over_at + RECORD_TAIL) {
        f := frames
        inp.begin_frame()
        pilot(&inp, &g, &pl, f)
        for k in 0..2 {
            update(&g, &inp, 1.0 / f32(HZ))
        }
        play_events(&snd, &g)
        snd.mixer.mix_i16(pcm[f * per_frame * 2..(f + 1) * per_frame * 2], per_frame)
        fx_update(&fx, &g, 1.0 / f32(RECORD_FPS))
        if g.over && over_at < 0 {
            over_at = f
        }
        m := mark()
        b := render_begin(r)
        post := draw_frame(b, &art, &g, &fx, 0.0, false, "")
        img, rerr := render_end(r, post, true)
        if rerr != "" {
            panic(rerr)
        }
        written: u32
        if WriteFile(file, ptr(img.pix), u32(len(img.pix)), &written, nil) == 0 || written != u32(len(img.pix)) {
            panic(fmt("--record: cannot write ", path))
        }
        release(m)
        frames += 1
    }
    CloseHandle(file)
    // the sound: a 16-bit stereo WAV of exactly the recorded frames
    n := frames * per_frame * 2
    wav := alloc[u8](44 + n * 2)
    copy(wav, "RIFF")
    put_le(wav, 4, 36 + n * 2, 4)
    copy(wav[8..], "WAVEfmt ")
    put_le(wav, 16, 16, 4)
    put_le(wav, 20, 1, 2)
    put_le(wav, 22, 2, 2)
    put_le(wav, 24, AUDIO_RATE, 4)
    put_le(wav, 28, AUDIO_RATE * 4, 4)
    put_le(wav, 32, 4, 2)
    put_le(wav, 34, 16, 2)
    copy(wav[36..], "data")
    put_le(wav, 40, n * 2, 4)
    for i in 0..n {
        put_le(wav, 44 + i * 2, i64(pcm[i]), 2)
    }
    dot := rfind(path, ".")
    wav_path := fmt(if dot > 0 { path[..dot] } else { path }, ".wav")
    print("recorded", frames, "frames", width, "x", height, "score", g.score, "hp", player_hp(&g), "hits at frames", pl.hits[..], "game over at frame", over_at,
        "sound", wav_path, write_file(wav_path, wav))
    renderer_close(r)
}
