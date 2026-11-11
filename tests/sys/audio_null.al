// std.audio device layer against ALSA's "null" PCM (discards the samples, needs no sound card).
use std.audio

main :: () {
    _, missing := audio_open("al-test-no-such-pcm-device", 48000, 2, 50)
    print("unknown device opens:", missing)
    dev, ok := audio_open("null", 48000, 2, 50)
    print("null device opens:", ok)
    if !ok {
        return
    }
    print(dev.rate, dev.channels, dev.buffer_frames > 0, dev.period_frames > 0, len(dev.buf) == dev.buffer_frames * 2)
    m := mixer_new(48000, 2, 8)
    beep := m.play(sound_tone(48000, 440.0, 0.25, 0.5), 1.0, 0.0, 1.0, false)
    hum := m.play(sound_tone(48000, 110.0, 0.1, 0.2), 0.5, -1.0, 1.0, true)
    // blocking writes: exactly the requested frames, also across several device buffers
    print(audio_write(dev, m, 480), audio_write(dev, m, 10000), audio_write(dev, m, 0))
    print(m.playing(beep), m.playing(hum))
    // per-frame pumping: writes what the device accepts right now, never more than its buffer
    pumped := 0
    for frame in 0..20 {
        n := audio_pump(dev, m)
        assert n >= 0 && n <= dev.buffer_frames
        pumped += n
    }
    print(pumped > 0, audio_write(dev, m, 2000))
    print(m.playing(beep), m.playing(hum), dev.underruns)
    audio_close(dev)
    // a closed or missing device is a no-op, so a game runs unchanged without sound
    none: *AudioDevice = nil
    print(audio_write(dev, m, 100), audio_pump(dev, m), audio_write(none, m, 100), audio_pump(none, m))
    audio_close(dev)
    audio_close(none)
    print("done")
}
