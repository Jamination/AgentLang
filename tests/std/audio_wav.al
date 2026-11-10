// std.audio: WAV encode / decode round trips in every sample format, generators, bad input.
use std.audio

fn put3(x f32) {
    putf(f64(x), 5)
    put(" ")
}

fn checksum(d str) u64 {
    var h u64 = 1469598103934665603
    for b in d {
        h = (h ^ u64(b)) * 1099511628211
    }
    h
}

// largest absolute difference between two sounds
fn max_diff(a Sound, b Sound) f32 {
    var d f32 = 0.0
    for i in 0..len(a.samples) {
        d = fmax(d, fabs(a.samples[i] - b.samples[i]))
    }
    d
}

fn main() {
    // generators
    t := sound_tone(8000, 1000.0, 0.004, 0.5)
    print(frames(t), t.rate, t.channels)
    for x in t.samples[..12] {
        put3(x)
    }
    print()
    putf(f64(duration(t)), 4)
    print()
    n1 := sound_noise(8000, 0.5, 0.25, 1)
    n2 := sound_noise(8000, 0.5, 0.25, 1)
    n3 := sound_noise(8000, 0.5, 0.25, 2)
    var lo f32 = 1.0
    var hi f32 = -1.0
    var mean f64 = 0.0
    for x in n1.samples {
        lo = fmin(lo, x)
        hi = fmax(hi, x)
        mean += f64(x)
    }
    print(frames(n1), n1.samples == n2.samples, n1.samples == n3.samples, lo >= -0.25, hi <= 0.25, lo < -0.24, hi > 0.24, fabs(mean / 4000.0) < 0.01)

    // a stereo test signal: left ramps up, right ramps down, with the extremes
    s := sound_new(44100, 2, 101)
    for i in 0..101 {
        s.samples[i * 2] = f32(i - 50) / 50.0
        s.samples[i * 2 + 1] = f32(50 - i) / 64.0
    }
    print(frames(s), len(s.samples))
    names := []str{"", "pcm8", "pcm16", "pcm24", "pcm32", "f32"}
    for f in WAV_PCM8..=WAV_F32 {
        file := wav_encode(s, f)
        d, ok := wav_decode(file)
        put(names[f], " ", len(file), " ", ok, " ", d.rate, " ", d.channels, " ", frames(d), " ", checksum(file), " ")
        put3(d.samples[0])
        put3(d.samples[1])
        put3(d.samples[200])
        put3(d.samples[201])
        print(max_diff(s, d) <= 1.0 / 128.0, max_diff(s, d) <= 1.0 / 32768.0, max_diff(s, d) == 0.0)
        // decoding what we encoded and encoding again is stable
        print(wav_encode(d, f) == file)
    }
    // header of the 16-bit file
    h := wav_encode(s, WAV_PCM16)
    print(h[..4], h[8..16], h[36..40], h[20], h[22], h[32], h[34], i64(h[24]) | i64(h[25]) << 8, i64(h[40]) | i64(h[41]) << 8)
    // values beyond -1..1 clip
    c := sound_new(8000, 1, 4)
    c.samples[0] = 2.0
    c.samples[1] = -2.0
    c.samples[2] = 0.5
    c.samples[3] = -0.25
    for f in WAV_PCM8..=WAV_PCM32 {
        d, _ := wav_decode(wav_encode(c, f))
        for x in d.samples {
            put3(x)
        }
        print()
    }

    // a hand-made file: extra chunk before fmt, odd-sized chunk (padded), WAVE_FORMAT_EXTENSIBLE,
    // 64-bit float handled separately below
    ext := alloc[u8](12 + 8 + 3 + 1 + 8 + 40 + 8 + 4)
    copy(ext, "RIFF")
    copy(ext[8..], "WAVELIST")
    ext[16] = 3
    copy(ext[24..], "fmt ")
    ext[28] = 40
    ext[32] = 0xFE
    ext[33] = 0xFF
    ext[34] = 1
    ext[36] = 0x40
    ext[37] = 0x1F
    ext[46] = 16
    ext[56] = 1
    copy(ext[72..], "data")
    ext[76] = 4
    ext[80] = 0x00
    ext[81] = 0x40
    ext[82] = 0x00
    ext[83] = 0xC0
    e, ok := wav_decode(ext)
    print(ok, e.rate, e.channels, e.samples)
    // 64-bit float data
    f64file := alloc[u8](44 + 16)
    copy(f64file, wav_encode(sound_new(8000, 1, 0), WAV_F32))
    f64file[34] = 64
    f64file[40] = 16
    vals := []f64{0.75, -0.125}
    memcopy(ptr(f64file[44..]), ptr(vals), 16)
    e, ok = wav_decode(f64file)
    print(ok, e.samples)

    // rejects: empty, not RIFF, no data chunk, unsupported codec, truncated data is cut to whole frames
    _, ok1 := wav_decode("")
    _, ok2 := wav_decode("RIFX....WAVEfmt ")
    _, ok3 := wav_decode(h[..36])
    bad := alloc[u8](len(h))
    copy(bad, h)
    bad[20] = 2
    _, ok4 := wav_decode(bad)
    cut, ok5 := wav_decode(h[..44 + 4 * 10 + 3])
    print(ok1, ok2, ok3, ok4, ok5, frames(cut))

    // files
    path := "/tmp/al_std_audio_wav_test.wav"
    print(wav_save(path, s, WAV_PCM24))
    back, ok6 := wav_load(path)
    print(ok6, frames(back), back.rate, back.channels, max_diff(s, back) < 0.000001)
    _, ok7 := wav_load("/nonexistent/dir/x.wav")
    print(ok7, wav_save("/nonexistent/dir/x.wav", s, WAV_PCM16))
    syscall(87, cstr(path))
}
