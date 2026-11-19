// The breakout's video run (--record): a short scripted game drawn offscreen frame by frame,
// with its sound mixed in step, for a video encoder. Pure AL apart from what game.al draws with.
//
// It shows the title screen for a moment, then a game played by a bot that plays like a person:
// it reacts late (it looks again every 8 to 14 frames), moves the paddle with the arrow keys,
// misjudges by a few pixels, and aims its returns at the bricks that are left by where on the
// paddle it takes the ball. A look into the pause menu on the way. So that the wall falls within
// a short video, the game starts from a wall that is nearly cleared (a recording-only set-up of
// the state the moment the game starts; the rules are the game's own).
use std.input
use std.audio
use "logic.al"
use "sound.al"
use "fx.al"

const VIDEO_FPS = 60
const VIDEO_MIX = AUDIO_RATE / VIDEO_FPS          // sound frames per video frame
const VIDEO_START = 120                           // the frame the game is started at

// The bricks left at the start of the recorded game: '.' gone, else the layout's hit points.
priv const VIDEO_WALL = [ROWS]str{
    "............",
    ".....3......",
    "...2..1.....",
    "..1.11.1....",
    "....1..11...",
    "............",
}

struct VideoBot {
    target: f32          // where the paddle's centre should go
    replan: i64          // the frame it looks again
    launch_at: i64       // the frame it launches a waiting ball (-1: not decided yet)
    rng: Rng
}

struct Video {
    g: Game
    inp: Input
    bot: VideoBot
    frame: i64
    cleared: i64         // the frame the wall fell (-1: not yet)
}

fn video_new() -> Video {
    v: Video
    v.g = game_new(2026)
    v.inp.focused = true
    v.bot = VideoBot{target: (FIELD_L + FIELD_R) / 2.0, launch_at: -1, rng: rng(77)}
    v.cleared = -1
    v
}

priv fn press(inp: *Input, k: i64) {
    inp.feed(Event{kind: EventKeyDown, key: k})
    inp.feed(Event{kind: EventKeyUp, key: k})
}

priv fn hold_key(inp: *Input, k: i64, want: bool) {
    if want != inp.key_down(k) {
        inp.feed(Event{kind: if want { EventKeyDown } else { EventKeyUp }, key: k})
    }
}

// Where the ball will cross the paddle's line, the side walls folded in.
priv fn landing(g: *Game) -> f32 {
    if g.vel.y <= 1.0 {
        return g.ball.x
    }
    t := (PADDLE_Y - BALL_R - g.ball.y) / g.vel.y
    lo := FIELD_L + BALL_R
    w := FIELD_R - BALL_R - lo
    x := fmod(g.ball.x + g.vel.x * t - lo, 2.0 * w)
    if x < 0.0 {
        x += 2.0 * w
    }
    lo + if x > w { 2.0 * w - x } else { x }
}

// Where the paddle should be to send the ball landing at x towards a brick that is left.
priv fn aim(g: *Game, bot: *VideoBot, x: f32) -> f32 {
    best := -1
    best_score: f32 = 1.0e9
    for i in 0..ROWS * COLS {
        if g.bricks[i] == 0 {
            continue
        }
        r := brick_rect(i)
        // the lower and nearer bricks first, with some whim
        score := fabs(r.x + r.z / 2.0 - x) - r.y * 0.6 + bot.rng.range(0.0, 60.0)
        if score < best_score {
            best_score = score
            best = i
        }
    }
    if best < 0 {
        return x
    }
    r := brick_rect(best)
    dx := r.x + r.z / 2.0 - x
    dy := PADDLE_Y - (r.y + r.w)
    angle := clamp(atan2(dx, dy), -0.9, 0.9)               // straight up is 0, as in hit_paddle
    off := angle / 1.0472
    x - off * (PADDLE_W / 2.0 + BALL_R)
}

priv fn bot_play(v: *Video) {
    g := &v.g
    inp := &v.inp
    bot := &v.bot
    f := v.frame
    if f >= bot.replan {
        bot.replan = f + 8 + i64(bot.rng.below(7))
        if g.stuck {
            bot.target = g.paddle
        } else if g.vel.y > 0.0 {
            bot.target = aim(g, bot, landing(g)) + bot.rng.range(-2.5, 2.5)
        } else {
            bot.target = lerp(g.paddle, g.ball.x, 0.35)       // drifts after the ball going up
        }
    }
    half := PADDLE_W / 2.0
    target := clamp(bot.target, FIELD_L + half, FIELD_R - half)
    hold_key(inp, KEY_LEFT, target < g.paddle - 2.0)
    hold_key(inp, KEY_RIGHT, target > g.paddle + 2.0)
    // a waiting ball goes when the banner allows and a moment has passed
    if g.stuck && g.banner <= 1.0 {
        if bot.launch_at < 0 {
            bot.launch_at = f + 18 + i64(bot.rng.below(20))
        } else if f >= bot.launch_at {
            press(inp, KEY_SPACE)
            bot.launch_at = -1
        }
    }
}

// The wall of the recording, in place of level 1's full one.
priv fn prepare(g: *Game) {
    g.left = 0
    for i in 0..ROWS * COLS {
        c := VIDEO_WALL[i / COLS][i % COLS]
        g.bricks[i] = if c == '.' { 0 } else { i32(c - '0') }
        if g.bricks[i] > 0 {
            g.left += 1
        }
    }
    g.score = 1240
}

// One frame: input (the title, then the bot and a visit to the pause menu), the fixed steps,
// the effects. The caller plays and clears the frame's events.
fn video_frame(v: *Video, fx: *Fx) {
    g := &v.g
    inp := &v.inp
    f := v.frame
    inp.begin_frame()
    if f == VIDEO_START {
        press(inp, KEY_ENTER)
    } else if g.mode == Playing || g.mode == Paused {
        if f == 560 || f == 630 {
            press(inp, KEY_ESCAPE)                      // into the menu and out again
        } else if f == 586 {
            press(inp, KEY_DOWN)
        } else if g.mode == Playing {
            bot_play(v)
        }
    }
    handle_input(g, inp)
    if f == VIDEO_START {
        prepare(g)
    }
    for k in 0..2 {
        update(g, inp, 1.0 / f32(HZ))
    }
    for e in g.events {
        if e.sfx == SfxLevel && v.cleared < 0 {
            v.cleared = f
        }
    }
    fx_frame(fx, g, 1.0 / f32(VIDEO_FPS), g.ball)
    v.frame += 1
}

// A 16-bit PCM WAV of interleaved stereo samples.
fn wav_bytes(samples: []i16, rate: i64) -> str {
    n := len(samples) * 2
    out := alloc[u8](44 + n)
    fn put(d: []u8, at: i64, v: i64, bytes: i64) {
        for k in 0..bytes {
            d[at + k] = u8(v >> (8 * k))
        }
    }
    copy(out, "RIFF")
    put(out, 4, 36 + n, 4)
    copy(out[8..], "WAVEfmt ")
    put(out, 16, 16, 4)
    put(out, 20, 1, 2)
    put(out, 22, 2, 2)
    put(out, 24, rate, 4)
    put(out, 28, rate * 4, 4)
    put(out, 32, 4, 2)
    put(out, 34, 16, 2)
    copy(out[36..], "data")
    put(out, 40, n, 4)
    copy(out[44..], as_bytes(samples))
    out
}
