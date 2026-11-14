// Mixer.mixed: the frames rendered by mix and mix_i16 since mixer_new, whatever the chunk
// sizes and whether voices play (the audio clock for syncing game time to the sound)
use std.audio

fn main() {
    m := mixer_new(48000, 2, 4)
    print("new:", m.mixed)
    out := alloc[f32](4096 * 2)
    m.mix(out, 0)
    print("empty mix:", m.mixed)
    m.mix(out, 480)
    m.mix(out, 1)
    print("silence:", m.mixed)
    m.play(sound_tone(48000, 440.0, 0.01, 0.5), 1.0, 0.0, 1.0, false)
    m.mix(out, 4096)                       // the voice ends inside this call
    print("after a voice:", m.mixed, m.active_voices())
    pcm := alloc[i16](3000 * 2)
    m.mix_i16(pcm, 3000)                   // more than AUDIO_CHUNK_FRAMES: several passes, counted once
    print("i16:", m.mixed, "=", 480 + 1 + 4096 + 3000)
    m.set_paused(m.play(sound_tone(48000, 440.0, 1.0, 0.5), 1.0, 0.0, 1.0, true), true)
    total := m.mixed
    for k in 1..=100 {
        m.mix(out, k)
        total += k
    }
    print("chunks:", m.mixed == total, "seconds:", f64(m.mixed) / f64(m.rate))
    mono := mixer_new(22050, 1, 1)
    mono.mix_i16(pcm, 2205)
    print("mono:", mono.mixed, f64(mono.mixed) / f64(mono.rate))
}
