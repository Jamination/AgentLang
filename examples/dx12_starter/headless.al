// The DX12 starter without window, GPU or sound device: scripted input (keys and a gamepad)
// drives the game for a number of 60 Hz frames, the sounds it triggers are mixed into a buffer,
// and checksums of the game state and of the mix are printed. Pure AL, so the same numbers come
// out on Linux and Windows (tests/std/dx12_starter_sim and tests/sys/dx12_starter).
use std.input
use std.audio
use "../starter/logic.al"
use "sound.al"

const HEADLESS_FPS = 60
const MIX_FRAMES = AUDIO_RATE / HEADLESS_FPS

priv fn key(inp: *Input, k: i64, down: bool) {
    inp.feed(Event{kind: if down { EventKeyDown } else { EventKeyUp }, key: k})
}

// The input of frame f: fire held throughout, weaving left and right on the keyboard, a while
// on the gamepad's stick, and the music off and on again (M).
fn starter_script(inp: *Input, f: i64) {
    if f == 0 {
        key(inp, KEY_SPACE, true)
    }
    if f < 600 && f % 120 == 0 {
        key(inp, KEY_RIGHT, false)
        key(inp, KEY_LEFT, true)
    }
    if f < 600 && f % 120 == 60 {
        key(inp, KEY_LEFT, false)
        key(inp, KEY_RIGHT, true)
    }
    if f == 600 {
        key(inp, KEY_RIGHT, false)
        key(inp, KEY_SPACE, false)
        gamepad_event(&inp.pad, 1, u8(PAD_A), 1)          // fire with the pad's A button
    }
    if f >= 600 && f < 1200 && f % 90 == 0 {
        x: i16 = if f / 90 % 2 == 0 { 24000 } else { -24000 }
        gamepad_event(&inp.pad, 2, u8(PAD_AXIS_LX), x)    // the left stick
    }
    if f == 1200 {
        gamepad_event(&inp.pad, 2, u8(PAD_AXIS_LX), 0)
        gamepad_event(&inp.pad, 1, u8(PAD_A), 0)
        key(inp, KEY_M, true)
    }
    if f == 1201 {
        key(inp, KEY_M, false)
    }
    if f == 1500 {
        key(inp, KEY_M, true)
        key(inp, KEY_SPACE, true)
    }
    if f == 1501 {
        key(inp, KEY_M, false)
    }
}

// Runs `frames` frames of two simulation steps each and prints the results.
fn starter_headless(frames: i64) {
    g := game_new(7)
    snd := starter_sound()
    inp: Input
    buf := alloc[i16](MIX_FRAMES * 2)
    audio: u64 = 1469598103934665603
    for f in 0..frames {
        inp.begin_frame()
        starter_script(&inp, f)
        if inp.key_pressed(KEY_M) {
            toggle_music(&snd)
        }
        for k in 0..2 {
            update(&g, &inp, 1.0 / f32(HZ))
        }
        play_events(&snd, &g)
        snd.mixer.mix_i16(buf, MIX_FRAMES)
        audio = audio_checksum(audio, buf)
    }
    print("frames", frames, "steps", g.step_no, "score", g.score, "hp", player_hp(&g), "over", g.over,
        "entities", g.ents.used, "voices", snd.mixer.active_voices())
    print("state", hex(state_checksum(&g), 16), "audio", hex(audio, 16))
}
