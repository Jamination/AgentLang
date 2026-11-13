// Game sounds without sound files: std.audio's tones and noise shaped by envelopes, and music
// rendered at start-up through a mixer of its own into one looping Sound. Pure AL: the same
// samples on every system, so the mix of a scripted run can be checksummed (audio_checksum).
use std.audio

const AUDIO_RATE = 48000

// Shapes a sound in place: a linear attack of `attack` seconds, then a decay to silence at
// the end, steep for a large `curve` (1 = linear). Returns s.
fn envelope(s: Sound, attack: f32, curve: f32) -> Sound {
    n := frames(s)
    a := max(i64(attack * f32(s.rate)), 1)
    for i in 0..n {
        t := f32(i) / f32(n)
        env := pow(1.0 - t, curve)
        if i < a {
            env *= f32(i) / f32(a)
        }
        for c in 0..s.channels {
            s.samples[i * s.channels + c] *= env
        }
    }
    s
}

// A plucked tone: a sine with a short attack and a decay.
fn pluck(freq: f32, seconds: f32, amp: f32) -> Sound {
    envelope(sound_tone(AUDIO_RATE, freq, seconds, amp), 0.004, 2.0)
}

// A chiptune-like tone: the sine plus its third and fifth harmonic (a softened square wave).
fn chip(freq: f32, seconds: f32, amp: f32) -> Sound {
    s := sound_tone(AUDIO_RATE, freq, seconds, amp)
    h3 := sound_tone(AUDIO_RATE, freq * 3.0, seconds, amp / 3.0)
    h5 := sound_tone(AUDIO_RATE, freq * 5.0, seconds, amp / 5.0)
    for i in 0..len(s.samples) {
        s.samples[i] += h3.samples[i] + h5.samples[i]
    }
    envelope(s, 0.003, 1.5)
}

// A noise burst (hits, explosions, drums): white noise with a decay.
fn burst_noise(seconds: f32, amp: f32, curve: f32, seed: u64) -> Sound {
    envelope(sound_noise(AUDIO_RATE, seconds, amp, seed), 0.001, curve)
}

// A tone whose pitch slides from f0 to f1 (sweeps, zaps, kicks): rendered through a mixer,
// whose voice pitch is changed every millisecond.
fn sweep(f0: f32, f1: f32, seconds: f32, amp: f32) -> Sound {
    base := sound_tone(AUDIO_RATE, 220.0, seconds * fmax(f0, f1) / 220.0 + 0.01, amp)
    out := sound_new(AUDIO_RATE, 1, i64(seconds * f32(AUDIO_RATE)))
    m := mixer_new(AUDIO_RATE, 1, 1)
    v := m.play(base, 1.0, 0.0, f0 / 220.0, false)
    chunk := AUDIO_RATE / 1000
    n := frames(out)
    pos := 0
    while pos < n {
        k := min(chunk, n - pos)
        m.set_pitch(v, lerp(f0, f1, f32(pos) / f32(n)) / 220.0)
        m.mix(out.samples[pos..], k)
        pos += k
    }
    envelope(out, 0.002, 1.5)
}

// The pitch for a MIDI note number (69 = A4 = 440 Hz).
fn note_freq(note: i64) -> f32 {
    440.0 * pow(2.0, f32(note - 69) / 12.0)
}

// One track of a loop: `steps` has one character per step, '.' a rest, '0'..'9' and 'a'..'z'
// the degree in `scale` (counting on into the next octaves); the instrument is played at the
// pitch that turns its `base` frequency into the note's.
struct Track {
    steps: str
    inst: Sound
    base: f32
    root: i64          // MIDI note of degree 0
    scale: []i64       // semitones above the root of the degrees of one octave
    volume: f32
    pan: f32
}

priv struct Hit { at: i64, track: i64, pitch: f32 }

// Renders the tracks as one loop of `beats` beats (each step a quarter beat) at `bpm`: a stereo
// Sound for a looping voice. What still sounds at the end is added to the beginning, so the
// loop has no seam.
fn render_loop(tracks: []Track, bpm: f32, beats: i64) -> Sound {
    step_frames := i64(f32(AUDIO_RATE) * 60.0 / bpm / 4.0)
    total := step_frames * beats * 4
    tail := AUDIO_RATE * 2
    hits := vec[Hit]()
    for t, tr in tracks {
        n := len(tr.steps)
        for k in 0..beats * 4 {
            c := tr.steps[k % n]
            degree := if c >= '0' && c <= '9' { i64(c - '0') } else if c >= 'a' && c <= 'z' { i64(c - 'a') + 10 } else { -1 }
            if degree < 0 {
                continue
            }
            octave := degree / len(tr.scale)
            note := tr.root + octave * 12 + tr.scale[degree % len(tr.scale)]
            hits.push(Hit{k * step_frames, t, note_freq(note) / tr.base})
        }
    }
    sort_by(hits.items(), fn(a: Hit, b: Hit) -> bool { a.at < b.at })
    out := sound_new(AUDIO_RATE, 2, total + tail)
    m := mixer_new(AUDIO_RATE, 2, 64)
    pos := 0
    for h in hits {
        m.mix(out.samples[pos * 2..], h.at - pos)
        pos = h.at
        tr := tracks[h.track]
        m.play(tr.inst, tr.volume, tr.pan, h.pitch, false)
    }
    m.mix(out.samples[pos * 2..], total + tail - pos)
    for i in 0..tail * 2 {
        out.samples[i] = clamp(out.samples[i] + out.samples[total * 2 + i], -1.0, 1.0)
    }
    Sound{out.samples[..total * 2], AUDIO_RATE, 2}
}

// Continues an FNV-1a hash over 16-bit samples: the checksum of a mix (mix_i16 output).
fn audio_checksum(h: u64, samples: []i16) -> u64 {
    for s in samples {
        h = (h ^ u64(u16(s))) * 1099511628211
    }
    h
}
