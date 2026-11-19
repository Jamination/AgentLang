// The player of the --record video (front.al writes the frames, this file decides what
// happens): a couple of seconds of the title screen, then a game that starts from a prepared
// state (the player in the north-east corridor, all gems but two already taken, one wraith
// waiting on the way) and a player that moves like a person: it looks a little ahead
// along its way and turns towards that point with eased mouse motion, walks when it roughly
// faces it, raises the lantern at a wraith that comes for it, takes the two gems and walks into
// the open exit. It drives the game through Input events, as headless.al does; only the
// prepared state is set directly, and logic.al is not changed. Pure AL, like headless.al.
use std.input
use std.audio
use "logic.al"
use "sound.al"

const REC_FPS = 60
const REC_MIX = AUDIO_RATE / REC_FPS
const REC_TITLE_FRAMES = 150                 // the title screen before Enter
const REC_KEEP = [2](i64, i64){(15, 1), (13, 13)} // the gems left to take, in order (cells)

struct Recording {
    g: Game
    inp: Input
    snd: CryptSound
    frame: i64
    prepared: bool
    target: i64          // the gem it goes for (index into REC_KEEP), then the exit
    turn_rate: f32       // the turn of the last frame (eased)
    pcm: Vec[i16]        // the mixed sound so far, stereo
    buf: []i16
}

fn recording_new() -> Recording {
    r := Recording{g: game_new(5), snd: crypt_sound(), buf: alloc[i16](REC_MIX * 2)}
    r.inp.focused = true
    r
}

priv fn tap(inp: *Input, k: i64) {
    inp.feed(Event{kind: EventKeyDown, key: k})
    inp.feed(Event{kind: EventKeyUp, key: k})
}

priv fn hold(inp: *Input, k: i64, want: bool) {
    if want != inp.key_down(k) {
        inp.feed(Event{kind: if want { EventKeyDown } else { EventKeyUp }, key: k})
    }
}

// The prepared state: where the player stands, what is already taken, where the wraiths are.
priv fn prepare(g: *Game) {
    g.pos = cell_center(12, 3)
    g.prev_pos = g.pos
    g.yaw = HALF_PI                                     // looking west
    for i in 0..g.n_gems {
        keep := false
        for k in REC_KEEP {
            if g.gems[i].pos == cell_center(k.0, k.1) {
                keep = true
            }
        }
        g.gems[i].taken = !keep
    }
    g.got = g.n_gems - len(REC_KEEP)
    // one wraith on the way between the gems, the others far off in the west
    far := [_](i64, i64){(1, 13), (3, 5), (5, 9)}
    for i in 0..g.n_enemies {
        c := if i == 0 { (15, 7) } else { far[(i - 1) % 3] }
        p := cell_center(c.0, c.1)
        g.enemies[i] = Enemy{pos: p, prev: p, target: p}
    }
}

// Where the player heads now: the next gem to take, then the exit.
priv fn heading(r: *Recording) -> vec2 {
    g := &r.g
    while r.target < len(REC_KEEP) {
        k := REC_KEEP[r.target]
        p := cell_center(k.0, k.1)
        for i in 0..g.n_gems {
            if g.gems[i].pos == p && !g.gems[i].taken {
                return p
            }
        }
        r.target += 1
    }
    g.exit
}

// The input of one frame.
priv fn rec_script(r: *Recording) {
    g := &r.g
    inp := &r.inp
    if g.mode == Title {
        if r.frame == REC_TITLE_FRAMES {
            tap(inp, KEY_ENTER)
        }
        return
    }
    if g.mode != Playing {
        hold(inp, KEY_W, false)
        return
    }
    // look ahead: the next cell of the way and the one after it, so that corners are rounded
    goal := heading(r)
    a := path_next(g.pos, goal)
    b := path_next(a, goal)
    aim := lerp(a, b, 0.45)
    if distance(g.pos, goal) < 1.6 {
        aim = goal
    }
    d := aim - g.pos
    want := wrap_angle(atan2(-d.x, -d.y) - g.yaw)
    // eased turning: a fraction of what is left, limited, and smoothed from frame to frame
    turn := clamp(want * 0.12, -0.045, 0.045)
    r.turn_rate = lerp(r.turn_rate, turn, 0.25)
    counts := -r.turn_rate / mouse_scale(g.settings)
    inp.feed_motion(counts, 0.0)
    hold(inp, KEY_W, fabs(want) < 0.75)
    // the lantern, at a wraith that comes for the player
    for i in 0..g.n_enemies {
        e := g.enemies[i]
        if e.stun <= 0.0 && e.chasing && distance(e.pos, g.pos) < 4.0 && g.flash_wait <= 0.0 {
            tap(inp, KEY_F)
        }
    }
}

// One frame: input, two fixed steps, the sound of the frame mixed and kept.
fn recording_frame(r: *Recording) {
    g := &r.g
    r.inp.begin_frame()
    rec_script(r)
    handle_input(g, &r.inp)
    for k in 0..2 {
        update(g, &r.inp, 1.0 / f32(HZ))
    }
    if g.mode == Playing && !r.prepared {
        prepare(g)
        r.prepared = true
    }
    play_events(&r.snd, g)
    r.snd.mixer.mix_i16(r.buf, REC_MIX)
    r.pcm.extend(r.buf)
    r.frame += 1
}

// The sound mixed so far as a WAV file's bytes (16-bit stereo).
fn recording_wav(r: *Recording) -> str {
    samples := alloc[f32](r.pcm.len)
    for i in 0..r.pcm.len {
        samples[i] = f32(r.pcm[i]) / 32768.0
    }
    wav_encode(Sound{samples, AUDIO_RATE, 2}, WAV_PCM16)
}
