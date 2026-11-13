// The starter's sound: effects and a music loop generated at start-up (gamekit/synth.al), and
// the rule that turns the game's events into voices on the mixer. Pure AL: the headless run
// mixes exactly what the game plays on a device.
use std.audio
use "../starter/logic.al"
use "../gamekit/synth.al"

struct StarterSound {
    mixer: *Mixer
    shot: Sound
    hit: Sound
    boom: Sound
    hurt: Sound
    over: Sound
    music: Sound
    music_voice: VoiceId
    music_on: bool
}

priv const MINOR_PENTATONIC = [_]i64{0, 3, 5, 7, 10}

// Generates every sound (about 0.2 s of work) and starts the music.
fn starter_sound() -> StarterSound {
    scale := MINOR_PENTATONIC[..]
    kick := sweep(150.0, 45.0, 0.18, 0.9)
    hat := burst_noise(0.04, 0.25, 4.0, 3)
    snare := burst_noise(0.16, 0.35, 2.5, 4)
    bass := chip(110.0, 0.30, 0.35)
    lead := pluck(440.0, 0.45, 0.30)
    tracks := []Track{
        Track{steps: "0..0..0.0..0.3..2..2..2.2..2.1..0..0..0.0..0.3..4..4..3.2..1.0..", inst: bass, base: 110.0, root: 45, scale: scale, volume: 0.8, pan: 0.0},
        Track{steps: "7...5.4.2...4...5...4.2.1...2...7...5.4.2...5.7.9...7.5.4.2.1.0.", inst: lead, base: 440.0, root: 57, scale: scale, volume: 0.45, pan: 0.25},
        // drums: degree 0 of root 69 is 440 Hz, the `base`: played at their own pitch
        Track{steps: "0.......0.......", inst: kick, base: 440.0, root: 69, scale: []i64{0}, volume: 0.8, pan: 0.0},
        Track{steps: "....0.......0...", inst: snare, base: 440.0, root: 69, scale: []i64{0}, volume: 0.5, pan: -0.1},
        Track{steps: "..0...0...0...0.", inst: hat, base: 440.0, root: 69, scale: []i64{0}, volume: 0.5, pan: -0.3},
    }
    s := StarterSound{
        mixer: mixer_new(AUDIO_RATE, 2, 24),
        shot: sweep(1400.0, 600.0, 0.07, 0.22),
        hit: burst_noise(0.06, 0.35, 3.0, 11),
        boom: burst_noise(0.40, 0.55, 2.0, 12),
        hurt: sweep(320.0, 70.0, 0.30, 0.5),
        over: sweep(440.0, 40.0, 1.20, 0.5),
        music: render_music(tracks, 132.0, 16, true),
        music_on: true,
    }
    s.mixer.set_master_volume(0.8)                  // head room: effects on top of the music
    s.music_voice = s.mixer.play(s.music, 0.55, 0.0, 1.0, true)
    s
}

// Plays a sound for each event of the game and forgets the events.
fn play_events(s: *StarterSound, g: *Game) {
    for e in g.events {
        pan := clamp(e.x / f32(WORLD_W) * 2.0 - 1.0, -1.0, 1.0) * 0.7
        match e.sfx {
            SfxShot => s.mixer.play(s.shot, 0.5, pan, 1.0, false)
            SfxHit => s.mixer.play(s.hit, 0.7, pan, 1.6, false)
            SfxBreak => s.mixer.play(s.boom, 0.8, pan, 0.8, false)
            SfxHurt => s.mixer.play(s.hurt, 0.9, pan, 1.0, false)
            SfxOver => {
                s.mixer.play(s.over, 1.0, 0.0, 1.0, false)
                s.mixer.set_volume(s.music_voice, 0.2)
            }
        }
    }
    g.events.clear()
}

// Music on or off (M): the loop keeps its place.
fn toggle_music(s: *StarterSound) {
    s.music_on = !s.music_on
    s.mixer.set_paused(s.music_voice, !s.music_on)
}
