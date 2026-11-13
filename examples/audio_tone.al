// Plays a short melody through std.audio's mixer on the default sound device, driven the way
// a game drives it: one audio_pump per 16 ms frame, each note started when its time comes.
// The same program runs on Linux (ALSA) and Windows (WASAPI):
//   alc run examples/audio_tone.al
//   alc build --target windows examples/audio_tone.al     (then run audio_tone.exe)
// `alc run examples/audio_tone.al -- null` plays into the "null" device (silent).
use std.audio

const RATE = 48000

// a note: frequency in Hz and length in beats (frequency 0 is a rest)
struct Note {
    freq: f32
    beats: f32
}

// "Ode to Joy", first phrase
const MELODY = [_]Note{
    Note{329.63, 1.0}, Note{329.63, 1.0}, Note{349.23, 1.0}, Note{392.0, 1.0},
    Note{392.0, 1.0}, Note{349.23, 1.0}, Note{329.63, 1.0}, Note{293.66, 1.0},
    Note{261.63, 1.0}, Note{261.63, 1.0}, Note{293.66, 1.0}, Note{329.63, 1.0},
    Note{329.63, 1.5}, Note{293.66, 0.5}, Note{293.66, 2.0},
}

const BEAT = 0.3   // seconds

// A sine tone with a short attack and a fade-out, so that notes do not click (allocates).
fn pluck(freq: f32, seconds: f32) -> Sound {
    s := sound_tone(RATE, freq, seconds, 0.4)
    n := len(s.samples)
    attack := RATE / 200
    for i in 0..n {
        env: f32 = 1.0 - f32(i) / f32(n)
        if i < attack {
            env *= f32(i) / f32(attack)
        }
        s.samples[i] *= env
    }
    s
}

fn main() {
    a := args()
    name := if len(a) > 1 { a[1] } else { "default" }
    dev, ok := audio_open(name, RATE, 2, 50)
    if !ok {
        print("no sound device:", audio_error())
        return
    }
    print("playing on", name, "with", dev.buffer_frames, "frames of buffer")
    m := mixer_new(RATE, 2, 8)
    // one Sound per note, made before playing starts (no allocation in the loop)
    notes := alloc[Sound](len(MELODY))
    for i in 0..len(MELODY) {
        notes[i] = pluck(MELODY[i].freq, MELODY[i].beats * BEAT)
    }
    start := clock_ns()
    next := 0
    at: f64 = 0.0         // start time of the next note in seconds
    while next < len(MELODY) || m.active_voices() > 0 {
        now := f64(clock_ns() - start) / 1e9
        while next < len(MELODY) && now >= at {
            // left to right across the phrase
            pan := f32(next) / f32(len(MELODY) - 1) * 1.2 - 0.6
            m.play(notes[next], 1.0, pan, 1.0, false)
            at += f64(MELODY[next].beats * BEAT)
            next += 1
        }
        audio_pump(dev, m)
        sleep_ms(16)
    }
    // the last frames still in the device buffer
    for i in 0..4 {
        audio_pump(dev, m)
        sleep_ms(16)
    }
    print("done; underruns:", dev.underruns)
    audio_close(dev)
}
