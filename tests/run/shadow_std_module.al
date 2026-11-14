// A program may reuse the names of a bundled module, as it may those of the core library: its
// code sees its own declarations, and std.audio keeps using its own `Sound`, `Voice`,
// `frames` and `WAV_*` constants internally.
use std.audio

enum Voice { Kick, Snare }                  // std.audio: struct Voice (the mixer's voice slots)
struct Sound { name: str, voice: Voice }    // std.audio: struct Sound
const WAV_PCM16 = "sixteen"                 // std.audio: const WAV_PCM16 = 2 (wav_encode matches on it)
const WAV_F32 = 99
AUDIO_CHUNK_FRAMES := 3                     // std.audio: a constant

// an overload next to std.audio's `frames(s: Sound) -> i64` (its Sound, not this one)
fn frames(s: Sound) -> str {
    return fmt(s.name, ":", match s.voice { Kick => "kick"; Snare => "snare" })
}

// the same parameter types as std.audio's: the program's definition is used by the program
fn active_voices(m: *Mixer) -> i64 {
    return -1
}

fn main() {
    drum := Sound{name: "drum", voice: Snare}
    print(frames(drum), WAV_PCM16, WAV_F32 + 1, AUDIO_CHUNK_FRAMES)
    v: Voice = Kick
    print(match v { Kick => 1; Snare => 2 })

    // std.audio's Sound, built and used by the module
    tone := sound_tone(8000, 1000.0, 0.01, 0.5)
    print(frames(tone), tone.rate, tone.channels)
    m := mixer_new(8000, 1, 4)
    id := m.play(tone, 1.0, 0.0, 1.0, false)
    print(valid(id), m.playing(id), m.active_voices())
    out: [8]f32
    m.mix(out[..], 8)
    print(out[0], out[2], out[4])
    // format 2 is std.audio's WAV_PCM16, whatever the program calls WAV_PCM16
    wav := wav_encode(tone, 2)
    back, ok := wav_decode(wav)
    print(len(wav), ok, frames(back), abs(back.samples[2] - tone.samples[2]) < 0.0001)
    wavf := wav_encode(tone, 5)
    backf, okf := wav_decode(wavf)
    print(len(wavf), okf, backf.samples[2] == tone.samples[2])
}
