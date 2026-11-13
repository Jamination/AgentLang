// Checks a recording of the signal of tone.al (tests/winaudio/run.sh). Arguments: the WAV
// file, the program's channel count (1 or 2). The recording may have more channels (a 5.1
// device): channels 0 and 1 are front left / right, the rest must be silent.
// Checks per tone: frequency (from the zero crossings), peak and RMS amplitude, the channel it
// is on, every period of the tone (no gap, no dropped or repeated frames: each interval
// between rising zero crossings is within half a sample of the expected period, and every
// 2 ms window carries signal), silence where there is no tone, and the length of the whole
// signal (the end of tone C lies 2.5 s after the start of tone A).
use std.audio

failures := 0
// first frame of tone A and the recording's rate
sig_start := 0
sig_rate := 0

// frame of second `t` of the signal
fn sec(t: f64) -> i64 {
    sig_start + i64(t * f64(sig_rate))
}

fn check(ok: bool, what: str) {
    print(if ok { "ok  " } else { "FAIL" }, what)
    if !ok {
        failures += 1
    }
}

// sample of channel `ch` at frame `i`
fn at(s: Sound, i: i64, ch: i64) -> f64 {
    f64(s.samples[i * s.channels + ch])
}

fn peak(s: Sound, ch: i64, from: i64, to: i64) -> f64 {
    p: f64 = 0.0
    for i in from..to {
        p = fmax(p, fabs(at(s, i, ch)))
    }
    p
}

fn rms(s: Sound, ch: i64, from: i64, to: i64) -> f64 {
    sum: f64 = 0.0
    for i in from..to {
        sum += at(s, i, ch) * at(s, i, ch)
    }
    sqrt(sum / f64(max(to - from, 1)))
}

// a tone on channel `ch` of frames from..to: frequency, amplitude and continuity
fn check_tone(s: Sound, ch: i64, from: i64, to: i64, freq: f64, amp: f64, name: str) {
    rate := f64(s.rate)
    // rising zero crossings, interpolated to fractions of a frame
    xs := vec[f64]()
    for i in from + 1..to {
        a := at(s, i - 1, ch)
        b := at(s, i, ch)
        if a < 0.0 && b >= 0.0 {
            xs.push(f64(i - 1) + a / (a - b))
        }
    }
    n := xs.len
    if n < 10 {
        check(false, fmt(name, ": tone present (", n, " rising zero crossings)"))
        return
    }
    f := f64(n - 1) * rate / (xs[n - 1] - xs[0])
    check(fabs(f - freq) < 0.2, fmt(name, ": frequency ", fmtf(f, 3), " Hz (expected ", freq, ")"))
    period := rate / freq
    worst: f64 = 0.0
    for k in 1..n {
        worst = fmax(worst, fabs(xs[k] - xs[k - 1] - period))
    }
    check(worst < 0.5, fmt(name, ": every period within ", fmtf(worst, 3), " frames of ", fmtf(period, 3), " (no gap, no lost or repeated frames)"))
    p := peak(s, ch, from, to)
    r := rms(s, ch, from, to)
    check(fabs(p - amp) < 0.02 * amp, fmt(name, ": peak ", fmtf(p, 4), " (expected ", amp, ")"))
    check(fabs(r - amp / sqrt(2.0)) < 0.02 * amp, fmt(name, ": RMS ", fmtf(r, 4), " (expected ", fmtf(amp / sqrt(2.0), 4), ")"))
    w := i64(rate) / 500
    low: f64 = 1.0
    i := from
    while i + w <= to {
        low = fmin(low, rms(s, ch, i, i + w))
        i += w
    }
    check(low > 0.6 * amp / sqrt(2.0), fmt(name, ": lowest RMS of a 2 ms window ", fmtf(low, 4), " (no dropout)"))
}

fn check_silent(s: Sound, ch: i64, from: i64, to: i64, what: str) {
    p := peak(s, ch, from, to)
    check(p < 0.001, fmt(what, ": silent (peak ", fmtf(p, 6), ")"))
}

fn main() {
    a := args()
    if len(a) != 3 {
        eprint("usage: check <recording.wav> <program channels>")
        exit(2)
    }
    s, ok := wav_load(a[1])
    if !ok {
        print("FAIL cannot read", a[1])
        exit(1)
    }
    mono := a[2] == "1"
    print("recording:", frames(s), "frames,", s.channels, "channels,", s.rate, "Hz")
    rate := s.rate
    // start of tone A: the first sample above 0.02 (the second sample of the sine at the latest)
    start := -1
    for i in 0..frames(s) {
        if fabs(at(s, i, 0)) > 0.02 {
            start = i
            break
        }
    }
    if start < 0 {
        print("FAIL no signal in the recording")
        exit(1)
    }
    // back to the zero crossing where the tone starts
    while start > 0 && fabs(at(s, start - 1, 0)) > 1e-6 {
        start -= 1
    }
    sig_start = start
    sig_rate = rate
    if sec(2.8) > frames(s) {
        print("FAIL recording ends", f64(frames(s) - start) / f64(rate), "s after the start of the signal")
        exit(1)
    }
    margin := rate / 200
    print("signal starts at frame", start)
    left := 0
    right := 1
    // tone A: 440 Hz on the left (mono: on both)
    check_tone(s, left, sec(0.0) + margin, sec(0.5) - margin, 440.0, 0.5, "A left")
    if mono {
        check_tone(s, right, sec(0.0) + margin, sec(0.5) - margin, 440.0, 0.5, "A right")
    } else {
        check_silent(s, right, sec(0.0), sec(0.5), "A right")
    }
    // tone B: 880 Hz on the right (mono: on both)
    check_tone(s, right, sec(0.75) + margin, sec(1.25) - margin, 880.0, 0.25, "B right")
    if mono {
        check_tone(s, left, sec(0.75) + margin, sec(1.25) - margin, 880.0, 0.25, "B left")
    } else {
        check_silent(s, left, sec(0.75), sec(1.25), "B left")
    }
    // tone C: 1000 Hz on both
    check_tone(s, left, sec(1.5) + margin, sec(2.5) - margin, 1000.0, 0.5, "C left")
    check_tone(s, right, sec(1.5) + margin, sec(2.5) - margin, 1000.0, 0.5, "C right")
    // the pauses, the channels beyond front left / right, and the end of the signal
    for ch in 0..2 {
        check_silent(s, ch, sec(0.5) + margin, sec(0.75) - margin, fmt("pause A-B channel ", ch))
        check_silent(s, ch, sec(1.25) + margin, sec(1.5) - margin, fmt("pause B-C channel ", ch))
        check_silent(s, ch, sec(2.5) + margin, sec(2.75) - margin, fmt("after C channel ", ch))
    }
    for ch in 2..s.channels {
        check_silent(s, ch, sec(0.0), sec(2.75), fmt("channel ", ch))
    }
    last := sec(2.5) + margin
    while last > sec(2.4) && fabs(at(s, last, 0)) < 0.02 {
        last -= 1
    }
    end := f64(last - start) / f64(rate)
    check(fabs(end - 2.5) < 0.002, fmt("tone C ends ", fmtf(end, 5), " s after tone A starts (expected 2.5: no frames lost or added)"))
    if failures > 0 {
        print(failures, "check(s) failed")
        exit(1)
    }
    print("all checks passed")
}
