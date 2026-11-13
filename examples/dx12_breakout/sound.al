// Breakout's sound: effects, two jingles and a music loop, all generated at start-up
// (gamekit/synth.al); the game's events become voices on the mixer at the volumes of the
// settings. Pure AL: the headless run mixes exactly what the game plays on a device.
use std.audio
use "logic.al"
use "../gamekit/synth.al"

struct BreakoutSound {
    mixer: *Mixer
    wall: Sound
    paddle: Sound
    brick: Sound
    smash: Sound
    launch: Sound
    lost: Sound
    move: Sound
    select: Sound
    level: Sound
    over: Sound
    music: Sound
    music_voice: VoiceId
}

priv const MAJOR_PENTATONIC = [_]i64{0, 2, 4, 7, 9}

// Generates every sound (a fraction of a second) and starts the music.
fn breakout_sound() -> BreakoutSound {
    scale := MAJOR_PENTATONIC[..]
    drum := []i64{0}
    bell := pluck(880.0, 0.5, 0.3)
    bass := chip(110.0, 0.25, 0.35)
    kick := sweep(140.0, 40.0, 0.16, 0.9)
    hat := burst_noise(0.03, 0.2, 4.0, 21)
    music := []Track{
        Track{steps: "0.0.4.0.0.0.3.2.0.0.4.0.0.0.5.4.", inst: bass, base: 110.0, root: 36, scale: scale, volume: 0.7, pan: 0.0},
        Track{steps: "5.7.9.7.8...7...5.7.9.a.c...a...", inst: bell, base: 880.0, root: 60, scale: scale, volume: 0.35, pan: 0.3},
        Track{steps: "0...0...0...0.0.", inst: kick, base: 440.0, root: 69, scale: drum, volume: 0.7, pan: 0.0},
        Track{steps: "..0...0...0...00", inst: hat, base: 440.0, root: 69, scale: drum, volume: 0.45, pan: -0.3},
    }
    level := []Track{Track{steps: "0246a", inst: bell, base: 880.0, root: 72, scale: scale, volume: 0.6, pan: 0.0}}
    over := []Track{Track{steps: "7.5.3.1.0", inst: bass, base: 110.0, root: 48, scale: scale, volume: 0.8, pan: 0.0}}
    s := BreakoutSound{
        mixer: mixer_new(AUDIO_RATE, 2, 32),
        wall: pluck(330.0, 0.05, 0.4),
        paddle: chip(220.0, 0.09, 0.4),
        brick: pluck(660.0, 0.08, 0.4),
        smash: burst_noise(0.18, 0.4, 2.5, 22),
        launch: sweep(260.0, 780.0, 0.12, 0.35),
        lost: sweep(520.0, 90.0, 0.55, 0.5),
        move: pluck(1320.0, 0.03, 0.25),
        select: chip(660.0, 0.12, 0.3),
        level: render_music(level, 480.0, 2, false),
        over: render_music(over, 300.0, 3, false),
        music: render_music(music, 140.0, 8, true),
    }
    s.mixer.set_master_volume(0.8)                      // head room: effects on top of the music
    s.music_voice = s.mixer.play(s.music, 0.0, 0.0, 1.0, true)
    s
}

// Sets the music's volume for the settings and the mode, then plays a sound for each event of
// the game at the volume of the settings, and forgets the events.
fn play_events(s: *BreakoutSound, g: *Game) {
    music := 0.6 * f32(g.settings.music) / f32(VOLUME_STEPS)
    music *= match g.mode { Paused => 0.4; GameOver => 0.3; _ => 1.0 }
    s.mixer.set_volume(s.music_voice, music)
    v := f32(g.settings.sound) / f32(VOLUME_STEPS)
    for e in g.events {
        pan := clamp((e.x - f32(VIEW_W) / 2.0) / f32(VIEW_W) * 1.4, -1.0, 1.0)
        match e.sfx {
            SfxWall => s.mixer.play(s.wall, 0.6 * v, pan, 1.0, false)
            SfxPaddle => s.mixer.play(s.paddle, 0.8 * v, pan, 1.0, false)
            SfxBrick => s.mixer.play(s.brick, 0.7 * v, pan, 1.0 + 0.1 * f32(ROWS - 1 - e.n), false)
            SfxBreak => {
                s.mixer.play(s.smash, 0.6 * v, pan, 1.0, false)
                s.mixer.play(s.brick, 0.6 * v, pan, 1.5 + 0.1 * f32(ROWS - 1 - e.n), false)
            }
            SfxLaunch => s.mixer.play(s.launch, 0.7 * v, pan, 1.0, false)
            SfxLost => s.mixer.play(s.lost, 0.9 * v, pan, 1.0, false)
            SfxLevel => s.mixer.play(s.level, 0.9 * v, 0.0, 1.0, false)
            SfxOver => s.mixer.play(s.over, 0.9 * v, 0.0, 1.0, false)
            SfxMove => s.mixer.play(s.move, 0.7 * v, 0.0, 1.0, false)
            SfxSelect => s.mixer.play(s.select, 0.7 * v, 0.0, 1.0, false)
        }
    }
    g.events.clear()
}
