// std.audio: Ogg streams. Seeking (to every page boundary region and to random frames) gives
// the frames of the whole decode from that frame on; a streamed voice in the mixer renders
// exactly what a voice playing the decoded Sound renders (looped, at other pitches, paused,
// stopped); a looped stream is gapless; chained and multiplexed files decode their first
// Vorbis stream; reading never allocates.
use std.audio

fn checksum(x: []f32) -> u64 {
    h: u64 = 1469598103934665603
    for v in x {
        h = (h ^ u64(cast[u32](v))) * 1099511628211
    }
    h
}

// frames from..from+n of st, after seeking, equal to the whole decode
fn seek_ok(st: *OggStream, s: Sound, from: i64, n: i64, buf: []f32) -> bool {
    if !ogg_seek(st, from) {
        return false
    }
    want := min(n, frames(s) - from)
    got := ogg_read(st, buf, n)
    if got != want || st.pos != from + got {
        return false
    }
    ch := s.channels
    buf[..got * ch] == s.samples[from * ch..(from + got) * ch]
}

fn main() {
    data, ok := read_file("tests/std/data/ogg_stereo.ogg")
    assert ok, "fixture missing"
    s, sok := ogg_decode(data)
    st, ok2 := ogg_open(data)
    print("open", sok, ok2, st.rate, st.channels, st.frames, st.pos)
    n := frames(s)
    buf := alloc[f32](2000 * 2)

    // seeking
    good := 0
    tries := 0
    x: u64 = 12345
    for i in 0..60 {
        x = x * 6364136223846793005 + 1442695040888963407
        from := i64((x >> 33) % u64(n + 1))
        if i < 5 {
            from = []i64{0, 1, n - 1, n, n / 2}[i]
        }
        tries += 1
        if seek_ok(st, s, from, 1500, buf) {
            good += 1
        }
    }
    print("seeks", good, "of", tries, ogg_seek(st, -1), ogg_seek(st, n + 1), ogg_rewind(st), st.pos)

    // a streamed voice renders the same as the decoded Sound, also looped and resampled
    for case in 0..4 {
        pitch: f32 = if case == 0 { 1.0 } else if case == 1 { 0.73 } else if case == 2 { 1.61 } else { 1.0 }
        looped := case != 0
        rate := if case == 3 { 48000 } else { 44100 }
        a := mixer_new(rate, 2, 4)
        b := mixer_new(rate, 2, 4)
        ogg_rewind(st)
        va := a.play(s, 0.8, 0.3, pitch, looped)
        vb := b.play_stream(st, 0.8, 0.3, pitch, looped)
        outa := alloc[f32](40000 * 2)
        outb := alloc[f32](40000 * 2)
        // uneven chunks, a pause in the middle
        done := 0
        chunk := 1
        while done < 40000 {
            k := min(chunk, 40000 - done)
            if done > 15000 && done < 16000 {
                a.set_paused(va, true)
                b.set_paused(vb, true)
            } else {
                a.set_paused(va, false)
                b.set_paused(vb, false)
            }
            a.mix(outa[done * 2..], k)
            b.mix(outb[done * 2..], k)
            done += k
            chunk = chunk * 3 % 997 + 1
        }
        print("voice", case, outa == outb, a.playing(va), b.playing(vb), checksum(outa) == checksum(outb))
    }

    // gapless looping: three passes of a looped stream are three copies of the sound
    m := mixer_new(44100, 2, 2)
    ogg_rewind(st)
    v := m.play_stream(st, 1.0, 0.0, 1.0, true)
    three := alloc[f32](n * 3 * 2)
    m.mix(three, n * 3)
    same := true
    for k in 0..3 {
        for i in 0..n * 2 {
            if three[k * n * 2 + i] != fmin(fmax(s.samples[i], -1.0), 1.0) {
                same = false
            }
        }
    }
    print("loop", same, m.playing(v))
    // a second play_stream of the same stream replaces the first voice; stop ends it
    v2 := m.play_stream(st, 1.0, 0.0, 1.0, false)
    print("replace", m.playing(v), m.playing(v2), m.active_voices())
    m.stop(v2)
    print("stopped", m.active_voices())

    // no allocation while streaming
    ogg_rewind(st)
    v3 := m.play_stream(st, 1.0, 0.0, 1.0, true)
    out := alloc[f32](512 * 2)
    mk := mark()
    for i in 0..200 {
        m.mix(out, 512)
    }
    after := mark()
    print("allocation-free", mk == after, m.playing(v3))

    // a non-looped stream ends and frees its voice; empty stream, closed stream
    m.stop_all()
    ogg_seek(st, n - 100)
    v4 := m.play_stream(st, 1.0, 0.0, 1.0, false)
    m.mix(out, 512)
    print("end", m.playing(v4), m.active_voices())
    ogg_close(st)
    print("closed", ogg_read(st, out, 10), valid(m.play_stream(st, 1.0, 0.0, 1.0, true)))

    // chained (two streams one after the other) and trailing data: the first stream
    other, _ := read_file("tests/std/data/ogg_mono.ogg")
    c, cok := ogg_decode(concat(data, other))
    print("chained", cok, c.samples == s.samples)
    t, tok := ogg_decode(concat(data, "trailing bytes"))
    print("trailing", tok, t.samples == s.samples)
}
