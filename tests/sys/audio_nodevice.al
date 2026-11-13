// std.audio on Windows without any sound device (tests/run.sh --target windows gives Wine no
// sound server and no ALSA device): enumeration finds nothing and audio_open fails with the
// documented error instead of crashing or hanging; the device functions accept the nil device.
use std.audio

fn main() {
    print("devices:", audio_devices())
    dev, ok := audio_open(48000, 2)
    print("default opens:", ok, dev == nil)
    print("error:", audio_error())
    _, named := audio_open("Speakers (none)", 48000, 2, 50)
    print("named opens:", named)
    print("error:", audio_error())
    _, bad := audio_open("default", 0, 2, 50)
    print("bad format opens:", bad)
    print("error:", audio_error())
    m := mixer_new(48000, 2, 4)
    print(audio_write(dev, m, 100), audio_pump(dev, m))
    audio_close(dev)
    // the "null" device needs no sound system
    null, nok := audio_open("null", 48000, 2, 50)
    print("null opens:", nok, audio_error() == "", null.buffer_frames, null.period_frames)
    audio_close(null)
}
