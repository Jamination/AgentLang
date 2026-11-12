// play(..., pitch = 1e10) or set_pitch(id, 3e9): audio_step converts pitch * 2^32 to i64,
// which overflows to i64 MIN; the position becomes negative and mix indexes the samples at a
// negative index. expected: no panic   actual (before the fix): panic: index out of bounds at <std/audio.al>:412
use std.audio
fn main() {
    m := mixer_new(48000, 2, 4)
    s := sound_tone(48000, 440.0, 0.1, 0.5)
    out := alloc[f32](256)
    m.play(s, 1.0, 0.0, 1e10, false)
    m.mix(out, 128)
    print("ok")
}
