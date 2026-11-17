// Crypt's sound: effects, two jingles and a slow music loop, all generated at start-up with
// the synthesizer of ../gamekit/synth.al. Events of the game become voices panned and faded by
// where they happened relative to the player. Pure AL: the scripted runs mix exactly what the
// game plays on a device.
use std.audio
use "logic.al"
use "../gamekit/synth.al"

struct CryptSound {
    mixer: *Mixer
    step: Sound
    gem: Sound
    hurt: Sound
    open: Sound
    alert: Sound
    flash: Sound
    move: Sound
    select: Sound
    win: Sound
    lose: Sound
    music: Sound
    drone: Sound
    music_voice: VoiceId
    drone_voice: VoiceId
}

priv const MINOR = [_]i64{0, 2, 3, 5, 7, 8, 10}

fn crypt_sound() -> CryptSound {
    scale := MINOR[..]
    drum := []i64{0}
    bell := pluck(880.0, 0.9, 0.3)
    bass := chip(110.0, 0.5, 0.3)
    kick := sweep(120.0, 35.0, 0.25, 0.8)
    tick := burst_noise(0.02, 0.15, 5.0, 31)
    music := []Track{
        Track{steps: "0...0...5...4...0...0...3...4...", inst: bass, base: 110.0, root: 33, scale: scale, volume: 0.6, pan: 0.0},
        Track{steps: "7.....9.....b...7.....5...4.....", inst: bell, base: 880.0, root: 57, scale: scale, volume: 0.25, pan: 0.4},
        Track{steps: "0.......0.......0.......0...0...", inst: kick, base: 440.0, root: 69, scale: drum, volume: 0.6, pan: 0.0},
        Track{steps: "....0.......0.......0.......0.0.", inst: tick, base: 440.0, root: 69, scale: drum, volume: 0.4, pan: -0.4},
    }
    win := []Track{Track{steps: "0.2.4.7...", inst: bell, base: 880.0, root: 69, scale: []i64{0, 2, 4, 5, 7, 9, 11}, volume: 0.7, pan: 0.0}}
    lose := []Track{Track{steps: "4.3.1.0...", inst: bass, base: 110.0, root: 45, scale: scale, volume: 0.8, pan: 0.0}}
    s := CryptSound{
        mixer: mixer_new(AUDIO_RATE, 2, 32),
        step: burst_noise(0.06, 0.25, 6.0, 7),
        gem: render_music([]Track{Track{steps: "047", inst: bell, base: 880.0, root: 76, scale: []i64{0, 2, 4, 5, 7, 9, 11}, volume: 0.6, pan: 0.0}}, 900.0, 1, false),
        hurt: sweep(400.0, 70.0, 0.4, 0.6),
        open: render_music([]Track{Track{steps: "0246", inst: bell, base: 880.0, root: 64, scale: scale, volume: 0.6, pan: 0.0}}, 600.0, 1, false),
        alert: sweep(180.0, 520.0, 0.3, 0.35),
        move: pluck(1320.0, 0.03, 0.25),
        flash: sweep(900.0, 1800.0, 0.25, 0.3),
        select: chip(660.0, 0.12, 0.3),
        win: render_music(win, 300.0, 3, false),
        lose: render_music(lose, 200.0, 3, false),
        music: render_music(music, 90.0, 8, true),
        drone: burst_noise(2.0, 0.05, 0.3, 99),
    }
    s.mixer.set_master_volume(0.8)
    s.music_voice = s.mixer.play(s.music, 0.0, 0.0, 1.0, true)
    s.drone_voice = s.mixer.play(s.drone, 0.0, 0.0, 0.5, true)
    s
}

// Sets the music for the settings and the mode, then plays a sound for each event of the game
// (panned by where it happened, quieter far away), and forgets the events.
fn play_events(s: *CryptSound, g: *Game) {
    music := 0.6 * f32(g.settings.music) / f32(VOLUME_STEPS)
    music *= match g.mode { Paused => 0.4; Won, Lost => 0.2; _ => 1.0 }
    s.mixer.set_volume(s.music_voice, music)
    v := f32(g.settings.sound) / f32(VOLUME_STEPS)
    s.mixer.set_volume(s.drone_voice, if g.mode == Playing { v } else { 0.0 })
    right := right_of(g.yaw)
    for e in g.events {
        rel := e.at - g.pos
        dist := length(rel)
        pan := if dist > 0.01 { clamp(dot(rel / dist, right), -1.0, 1.0) * 0.8 } else { 0.0 }
        near := 1.0 / (1.0 + dist * 0.15)
        m := s.mixer
        match e.sfx {
            SfxStep => m.play(s.step, 0.5 * v, 0.0, 0.9 + 0.2 * g.rng_free(), false)
            SfxGem => m.play(s.gem, 0.8 * v, pan, 1.0, false)
            SfxHurt => m.play(s.hurt, 0.9 * v, pan, 1.0, false)
            SfxOpen => m.play(s.open, 0.8 * v, 0.0, 1.0, false)
            SfxAlert => m.play(s.alert, 0.8 * v * near, pan, 1.0, false)
            SfxWin => m.play(s.win, 0.9 * v, 0.0, 1.0, false)
            SfxLose => m.play(s.lose, 0.9 * v, 0.0, 1.0, false)
            SfxMove => m.play(s.move, 0.7 * v, 0.0, 1.0, false)
            SfxSelect => m.play(s.select, 0.7 * v, 0.0, 1.0, false)
            SfxFlash => m.play(s.flash, 0.7 * v, 0.0, 1.0, false)
        }
    }
    g.events.clear()
}

// A pitch variation for footsteps that does not touch the game's generator: from the step number.
priv fn rng_free(g: *Game) -> f32 {
    f32(u64(g.step_no) * 2654435761 % 1000) / 1000.0
}
