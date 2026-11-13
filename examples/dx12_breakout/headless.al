// Breakout without window, GPU or sound device: a scripted player (keyboard, then gamepad)
// plays for a number of 60 Hz frames through the same calls as the front end, including the
// pause menu (volumes, fullscreen request) and a focus loss; the sounds are mixed into a buffer
// and checksums of the game state and of the mix are printed. Pure AL: the same numbers on
// Linux and Windows (tests/std/dx12_breakout_sim and tests/sys/dx12_breakout).
use std.input
use std.audio
use "logic.al"
use "sound.al"

const HEADLESS_FPS = 60
const MIX_FRAMES = AUDIO_RATE / HEADLESS_FPS

priv fn key(inp: *Input, k: i64, down: bool) {
    inp.feed(Event{kind: if down { EventKeyDown } else { EventKeyUp }, key: k})
}

// a key pressed and released within the frame
priv fn tap(inp: *Input, k: i64) {
    key(inp, k, true)
    key(inp, k, false)
}

// holds `k` if `want`, else releases it
priv fn hold(inp: *Input, k: i64, want: bool) {
    if want != inp.key_down(k) {
        key(inp, k, want)
    }
}

// The scripted player of frame f. It follows the ball (with the keys until frame 2700, then
// with the gamepad's stick and A button), dozes for a while so that a ball gets lost, goes
// through the pause menu (music up, sound down, fullscreen) and loses the focus once.
fn breakout_script(g: *Game, inp: *Input, f: i64) {
    dozing := f >= 1900 && f < 2200
    dx := if g.stuck || dozing { 0.0 } else { g.ball.x + g.vel.x * 0.05 - g.paddle }
    pad := f >= 2700
    hold(inp, KEY_LEFT, !pad && dx < -4.0)
    hold(inp, KEY_RIGHT, !pad && dx > 4.0)
    if pad {
        x: i16 = if dx < -4.0 { -30000 } else if dx > 4.0 { 30000 } else { 0 }
        gamepad_event(&inp.pad, 2, u8(PAD_AXIS_LX), x)
    }
    if f == 30 {
        tap(inp, KEY_ENTER)                             // start
    }
    if g.stuck && f % 60 == 0 {
        if pad {
            gamepad_event(&inp.pad, 1, u8(PAD_A), 1)    // launch with the pad's A
        } else {
            tap(inp, KEY_SPACE)                         // launch
        }
    }
    if pad && f % 60 == 1 {
        gamepad_event(&inp.pad, 1, u8(PAD_A), 0)
    }
    // the pause menu
    menu := [_](i64, i64){(1500, KEY_ESCAPE), (1510, KEY_DOWN), (1520, KEY_RIGHT), (1530, KEY_RIGHT), (1540, KEY_DOWN),
        (1550, KEY_LEFT), (1560, KEY_LEFT), (1570, KEY_DOWN), (1580, KEY_ENTER), (1590, KEY_UP), (1600, KEY_UP),
        (1610, KEY_UP), (1620, KEY_ENTER)}
    for m in menu {
        if f == m.0 {
            tap(inp, m.1)
        }
    }
    // the focus goes away (the game pauses), comes back, and the menu resumes the game
    if f == 2400 {
        inp.feed(Event{kind: EventUnfocus})
    }
    if f == 2460 {
        inp.feed(Event{kind: EventFocus})
    }
    if f == 2470 {
        tap(inp, KEY_ENTER)
    }
}

// Runs `frames` frames of two simulation steps each and prints the results.
fn breakout_headless(frames: i64) {
    g := game_new(11)
    snd := breakout_sound()
    inp: Input
    inp.focused = true                                  // as a window that has the focus
    buf := alloc[i16](MIX_FRAMES * 2)
    audio: u64 = 1469598103934665603
    fullscreen_requests := 0
    for f in 0..frames {
        inp.begin_frame()
        breakout_script(&g, &inp, f)
        if !inp.focused {
            lose_focus(&g)
        }
        handle_input(&g, &inp)
        if g.want_fullscreen {
            g.want_fullscreen = false
            fullscreen_requests += 1
        }
        for k in 0..2 {
            update(&g, &inp, 1.0 / f32(HZ))
        }
        play_events(&snd, &g)
        snd.mixer.mix_i16(buf, MIX_FRAMES)
        audio = audio_checksum(audio, buf)
    }
    mode := match g.mode { Title => "title"; Playing => "playing"; Paused => "paused"; GameOver => "over" }
    print("frames", frames, "steps", g.step_no, "mode", mode, "level", g.level, "score", g.score, "lives", g.lives,
        "bricks", g.left, "music", g.settings.music, "sound", g.settings.sound, "fullscreen requests", fullscreen_requests)
    print("state", hex(state_checksum(&g), 16), "audio", hex(audio, 16))
}
