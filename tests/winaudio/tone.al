// Plays a known test signal through std.audio (tests/winaudio/run.sh records it and check.al
// verifies it). Arguments: device name, rate, channels (1 or 2), pump | write | stall.
//
// The signal, after `LEAD` seconds of silence (times in seconds from the start of tone A):
//   A  0.00-0.50  440 Hz, peak 0.5, left channel only (mono: the one channel)
//      0.50-0.75  silence
//   B  0.75-1.25  880 Hz, peak 0.25, right channel only (mono: the one channel)
//      1.25-1.50  silence
//   C  1.50-2.50  1000 Hz, peak 0.5, both channels
//      2.50-2.75  silence
// `pump` drives the device with audio_pump once per 16 ms "game frame", `write` with
// audio_write in blocks of 10 ms; `stall` pumps only every 80 ms, longer than the 50 ms
// buffer, so the device runs dry (underruns are counted; the recording is not checked).
use std.audio

const LEAD = 0.25

// adds a sine of `freq` Hz to channel `ch` of `s` from second `from` for `seconds`
fn put_tone(s: Sound, ch: i64, from: f32, seconds: f32, freq: f32, amp: f32) {
    t := sound_tone(s.rate, freq, seconds, amp)
    at := i64((LEAD + from) * f32(s.rate))
    for i in 0..len(t.samples) {
        s.samples[(at + i) * s.channels + ch] = t.samples[i]
    }
}

fn main() {
    a := args()
    if len(a) != 5 {
        eprint("usage: tone <device> <rate> <channels> pump|write|stall")
        exit(2)
    }
    name := a[1]
    rate, _ := parse_i64(a[2])
    channels, _ := parse_i64(a[3])
    pump := a[4] != "write"
    frame_ms := if a[4] == "stall" { 80 } else { 16 }
    dev, ok := audio_open(name, rate, channels, 50)
    if !ok {
        print("audio_open failed:", audio_error())
        exit(1)
    }
    print("device:", name, "program", dev.rate, "Hz", dev.channels, "ch; buffer", dev.buffer_frames, "period", dev.period_frames)
    print("device format:", dev.os.dev_rate, "Hz", dev.os.dev_channels, "ch, kind", dev.os.kind, "buffer", dev.os.dev_buffer, "frames")

    s := sound_new(rate, channels, i64((LEAD + 2.75) * f32(rate)))
    right := channels - 1
    put_tone(s, 0, 0.0, 0.5, 440.0, 0.5)
    put_tone(s, right, 0.75, 0.5, 880.0, 0.25)
    for ch in 0..channels {
        put_tone(s, ch, 1.5, 1.0, 1000.0, 0.5)
    }
    m := mixer_new(rate, channels, 4)
    m.play(s, 1.0, 0.0, 1.0, false)
    total := 0
    calls := 0
    if pump {
        while m.active_voices() > 0 {
            total += audio_pump(dev, m)
            calls += 1
            sleep_ms(frame_ms)
        }
        // let the buffer play out (silence follows)
        for i in 0..20 {
            total += audio_pump(dev, m)
            sleep_ms(16)
        }
    } else {
        while m.active_voices() > 0 {
            total += audio_write(dev, m, rate / 100)
            calls += 1
        }
        total += audio_write(dev, m, rate * 3 / 10)
    }
    print("frames:", total, "calls:", calls, "underruns:", dev.underruns, "lost:", dev.lost, "reopened:", dev.os.reopened)
    audio_close(dev)
}
