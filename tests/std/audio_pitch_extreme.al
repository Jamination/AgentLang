// std.audio: a huge pitch used to wrap the voice's 32.32 step around to a negative number and
// index the samples at a negative position (panic in mix); NaN and negative pitches hold the voice
use std.audio

fn main() {
    m := mixer_new(48000, 2, 4)
    s := sound_tone(48000, 440.0, 0.1, 0.5)
    out := alloc[f32](256)
    id := m.play(s, 1.0, 0.0, 1e10, false)
    m.mix(out, 128)
    print(m.playing(id), out[0], out[2])
    id2 := m.play(s, 1.0, 0.0, 0.0 / 0.0, true)
    id3 := m.play(s, 1.0, 0.0, -2.0, false)
    m.mix(out, 128)
    print(m.playing(id2), m.playing(id3), out[0] == out[254])
    m.set_pitch(id2, 3e9)
    m.mix(out, 128)
    print(m.playing(id2))
}
