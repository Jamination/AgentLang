// std.audio: the software mixer on known waveforms (no device involved).
use std.audio

show :: (label: str, out: []f32) {
    put(label, ":")
    for x in out {
        put(" ")
        putf(f64(x), 3)
    }
    print()
}

// a mono ramp 0.1, 0.2, ... (n frames) at the given rate
ramp :: (rate: i64, n: i64) -> Sound {
    s := sound_new(rate, 1, n)
    for i in 0..n {
        s.samples[i] = f32(i + 1) / 10.0
    }
    s
}

checksum :: (a: []i16) -> u64 {
    h: u64 = 1469598103934665603
    for x in a {
        h = (h ^ u64(u16(x))) * 1099511628211
    }
    h
}

main :: () {
    r := ramp(8000, 5)
    out := alloc[f32](16)

    // mono voice, mono mixer, same rate: the source comes out unchanged, then silence
    m := mixer_new(8000, 1, 4)
    id := m.play(r, 1.0, 0.0, 1.0, false)
    print(valid(id), m.playing(id), m.active_voices())
    m.mix(out, 3)
    show("first 3", out[..3])
    print(m.playing(id))
    m.mix(out, 4)
    show("next 4", out[..4])
    print(m.playing(id), m.active_voices())
    m.mix(out, 2)
    show("idle", out[..2])

    // volume and pitch: 2x speed skips frames, 0.5x interpolates between them
    m.play(r, 0.5, 0.0, 2.0, false)
    m.mix(out, 4)
    show("pitch 2 vol .5", out[..4])
    m.play(r, 1.0, 0.0, 0.5, false)
    m.mix(out, 11)
    show("pitch .5", out[..11])
    // resampling follows the sound's own rate: a 4 kHz sound in the 8 kHz mixer
    m.play(ramp(4000, 3), 1.0, 0.0, 1.0, false)
    m.mix(out, 7)
    show("4k in 8k", out[..7])
    m.play(ramp(16000, 6), 1.0, 0.0, 1.0, false)
    m.mix(out, 4)
    show("16k in 8k", out[..4])

    // looping wraps around (interpolating towards the first frame)
    lp := m.play(ramp(8000, 3), 1.0, 0.0, 1.0, true)
    m.mix(out, 8)
    show("loop", out[..8])
    m.set_pitch(lp, 0.5)
    m.mix(out, 7)
    show("loop .5", out[..7])
    // pause keeps position, volume changes apply, stop frees the slot
    m.set_paused(lp, true)
    m.mix(out, 2)
    show("paused", out[..2])
    m.set_paused(lp, false)
    m.set_pitch(lp, 1.0)
    m.set_volume(lp, 2.0)
    m.mix(out, 3)
    show("vol 2", out[..3])
    m.set_master_volume(0.25)
    m.mix(out, 3)
    show("master .25", out[..3])
    m.set_master_volume(1.0)
    print(m.playing(lp), m.active_voices())
    m.stop(lp)
    print(m.playing(lp), m.active_voices())
    m.mix(out, 2)
    show("stopped", out[..2])

    // clipping: the sum of two loud voices is limited to -1..1
    loud := sound_new(8000, 1, 4)
    loud.samples[0] = 0.8
    loud.samples[1] = -0.8
    loud.samples[2] = 0.3
    loud.samples[3] = -0.3
    m.play(loud, 1.0, 0.0, 1.0, false)
    m.play(loud, 1.0, 0.0, 1.0, false)
    m.mix(out, 4)
    show("clip", out[..4])

    // the voice pool is fixed: the fifth voice is refused, stale handles do nothing
    ids: [5]VoiceId
    for i in 0..5 {
        ids[i] = m.play(r, 0.1, 0.0, 1.0, true)
    }
    print(valid(ids[3]), valid(ids[4]), m.playing(ids[4]), m.active_voices())
    m.stop(ids[1])
    again := m.play(r, 0.1, 0.0, 1.0, false)
    print(again.index, m.playing(ids[1]), m.playing(again), m.active_voices())
    m.stop(ids[1])
    m.set_volume(ids[1], 100.0)
    m.set_volume(VoiceId{}, 100.0)
    print(m.playing(again), valid(VoiceId{}))
    m.stop_all()
    print(m.active_voices())
    empty := sound_new(8000, 1, 0)
    print(valid(m.play(empty, 1.0, 0.0, 1.0, false)))

    // stereo mixer: pan of a mono sound, balance of a stereo sound
    st := mixer_new(8000, 2, 8)
    one := sound_new(8000, 1, 1)
    one.samples[0] = 0.8
    pans := []f32{-1.0, -0.5, 0.0, 0.5, 1.0, 7.0}
    for p in pans {
        st.play(one, 1.0, p, 1.0, false)
        st.mix(out, 1)
        show("pan", out[..2])
    }
    two := sound_new(8000, 2, 3)
    for i in 0..3 {
        two.samples[i * 2] = f32(i + 1) / 10.0
        two.samples[i * 2 + 1] = -f32(i + 1) / 20.0
    }
    st.play(two, 1.0, 0.0, 1.0, false)
    st.mix(out, 4)
    show("stereo", out[..8])
    v := st.play(two, 1.0, 0.0, 1.0, false)
    st.set_pan(v, 0.5)
    st.mix(out, 4)
    show("stereo pan .5", out[..8])
    // a stereo sound in a mono mixer is averaged; a mono sound keeps its level
    m.play(two, 1.0, 0.0, 1.0, false)
    m.mix(out, 3)
    show("stereo->mono", out[..3])

    // 16-bit output: rounding, and long buffers are mixed in chunks without seams
    m.play(loud, 1.0, 0.0, 1.0, false)
    m.play(loud, 0.5, 0.0, 1.0, false)
    o16 := alloc[i16](8)
    m.mix_i16(o16, 5)
    print(o16[..5])
    tone := sound_tone(44100, 440.0, 0.5, 0.6)
    noise := sound_noise(22050, 0.05, 0.3, 42)
    a := mixer_new(48000, 2, 8)
    b := mixer_new(48000, 2, 8)
    whole := alloc[i16](6000 * 2)
    parts := alloc[i16](6000 * 2)
    a.play(tone, 0.8, -0.3, 1.0, false)
    a.play(noise, 1.0, 0.6, 0.7, true)
    b.play(tone, 0.8, -0.3, 1.0, false)
    b.play(noise, 1.0, 0.6, 0.7, true)
    a.mix_i16(whole, 6000)
    done := 0
    step := 1
    while done < 6000 {
        n := min(step, 6000 - done)
        b.mix_i16(parts[done * 2..], n)
        done += n
        step = step * 3 % 701 + 1
    }
    peak: i16 = 0
    for x in whole {
        peak = max(peak, x)
    }
    print(whole == parts, checksum(whole), peak, whole[..6], whole[11990..])
    // the tone voice ends after 0.5 s (24000 output frames), the looped noise goes on
    rest := alloc[i16](20000 * 2)
    a.mix_i16(rest, 20000)
    print(a.active_voices(), checksum(rest))
}
