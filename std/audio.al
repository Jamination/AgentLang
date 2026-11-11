// std.audio: sounds (decoded PCM), WAV reading / writing, a software mixer with a fixed voice
// pool, and an ALSA output device driven from the game loop. Everything except the device
// functions is pure computation (no libraries, testable without sound hardware); only
// audio_open / audio_write / audio_pump / audio_close link libasound.so.2.
use std.alsa

// ---- sounds ----

// Decoded audio: interleaved f32 samples in -1..1, `channels` per frame, `rate` frames per second.
struct Sound {
    samples: []f32
    rate: i64
    channels: i64
}

// A silent sound of `frames` frames to fill in (allocates the samples).
fn sound_new(rate: i64, channels: i64, frames: i64) -> Sound {
    assert rate > 0 && channels > 0 && frames >= 0, "sound_new: bad format"
    Sound{alloc[f32](frames * channels), rate, channels}
}

// Number of frames (samples per channel).
fn frames(s: Sound) -> i64 {
    if s.channels <= 0 {
        return 0
    }
    len(s.samples) / s.channels
}

// Length in seconds.
fn duration(s: Sound) -> f32 {
    if s.rate <= 0 {
        return 0.0
    }
    f32(frames(s)) / f32(s.rate)
}

// sin(2 pi t) for t in turns; accurate to about 1e-11.
fn audio_sin_turns(t: f64) -> f64 {
    r := (t - floor(t + 0.5)) * 6.283185307179586
    if r > 1.5707963267948966 {
        r = 3.141592653589793 - r
    } else if r < -1.5707963267948966 {
        r = -3.141592653589793 - r
    }
    r2 := r * r
    r * (1.0 + r2 * (-1.0 / 6.0 + r2 * (1.0 / 120.0 + r2 * (-1.0 / 5040.0 + r2 * (1.0 / 362880.0 +
        r2 * (-1.0 / 39916800.0 + r2 * (1.0 / 6227020800.0 + r2 * (-1.0 / 1307674368000.0))))))))
}

// A mono sine tone of `freq` Hz with peak amplitude `amp` (allocates).
fn sound_tone(rate: i64, freq: f32, seconds: f32, amp: f32) -> Sound {
    s := sound_new(rate, 1, i64(seconds * f32(rate)))
    cycles := f64(freq) / f64(rate)
    for i in 0..len(s.samples) {
        s.samples[i] = amp * f32(audio_sin_turns(cycles * f64(i)))
    }
    s
}

// Mono white noise in -amp..amp from a seed; the same seed gives the same sound (allocates).
fn sound_noise(rate: i64, seconds: f32, amp: f32, seed: u64) -> Sound {
    s := sound_new(rate, 1, i64(seconds * f32(rate)))
    x := seed * 0x9E3779B97F4A7C15 + 0xD1B54A32D192ED03
    for i in 0..len(s.samples) {
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        r := (x * 0x2545F4914F6CDD1D) >> 40
        s.samples[i] = amp * (f32(i64(r)) / 8388608.0 - 1.0)
    }
    s
}

// ---- WAV files ----

// sample formats for wav_encode / wav_save
const WAV_PCM8 = 1
const WAV_PCM16 = 2
const WAV_PCM24 = 3
const WAV_PCM32 = 4
const WAV_F32 = 5

fn audio_u16(d: str, at: i64) -> i64 {
    i64(d[at]) | i64(d[at + 1]) << 8
}

fn audio_u32(d: str, at: i64) -> i64 {
    audio_u16(d, at) | audio_u16(d, at + 2) << 16
}

fn audio_put16(d: []u8, at: i64, v: i64) {
    d[at] = u8(v)
    d[at + 1] = u8(v >> 8)
}

fn audio_put32(d: []u8, at: i64, v: i64) {
    audio_put16(d, at, v)
    audio_put16(d, at + 2, v >> 16)
}

// x * scale rounded to the nearest integer and limited to lo..hi
fn audio_quantize(x: f32, scale: f64, lo: i64, hi: i64) -> i64 {
    v := i64(floor(f64(x) * scale + 0.5))
    min(max(v, lo), hi)
}

// Decodes a RIFF/WAVE file image: PCM with 8, 16, 24 or 32 bits, or 32/64-bit float, any
// channel count (also WAVE_FORMAT_EXTENSIBLE). False if the data is not such a file.
// Allocates the samples.
fn wav_decode(data: str) -> (Sound, bool) {
    none: Sound
    if len(data) < 12 || data[..4] != "RIFF" || data[8..12] != "WAVE" {
        return (none, false)
    }
    format := 0
    channels := 0
    rate := 0
    bits := 0
    at := 12
    while at + 8 <= len(data) {
        id := data[at..at + 4]
        size := audio_u32(data, at + 4)
        body := at + 8
        if id == "fmt " && size >= 16 && body + size <= len(data) {
            format = audio_u16(data, body)
            channels = audio_u16(data, body + 2)
            rate = audio_u32(data, body + 4)
            bits = audio_u16(data, body + 14)
            if format == 0xFFFE && size >= 26 {
                format = audio_u16(data, body + 24)
            }
        } else if id == "data" {
            bytes := bits / 8
            float := format == 3 && (bits == 32 || bits == 64)
            pcm := format == 1 && (bits == 8 || bits == 16 || bits == 24 || bits == 32)
            if channels <= 0 || rate <= 0 || !(float || pcm) {
                return (none, false)
            }
            size = min(size, len(data) - body)
            n := size / (bytes * channels) * channels
            s := Sound{alloc[f32](n), rate, channels}
            for i in 0..n {
                p := body + i * bytes
                v: f32
                if bits == 8 {
                    v = f32(i64(data[p]) - 128) / 128.0
                } else if bits == 16 {
                    v = f32(i16(audio_u16(data, p))) / 32768.0
                } else if bits == 24 {
                    v = f32(i32((audio_u16(data, p) | i64(data[p + 2]) << 16) << 8) >> 8) / 8388608.0
                } else if format == 1 {
                    v = f32(f64(i32(audio_u32(data, p))) / 2147483648.0)
                } else if bits == 32 {
                    v = cast[f32](u32(audio_u32(data, p)))
                } else {
                    v = f32(cast[f64](audio_u32(data, p) | audio_u32(data, p + 4) << 32))
                }
                s.samples[i] = v
            }
            return (s, true)
        }
        at = body + size + (size & 1)
    }
    (none, false)
}

// Encodes a sound as a WAV file image in the given sample format (WAV_PCM8 .. WAV_F32);
// integer formats round to nearest and clip to -1..1. Allocates the result.
fn wav_encode(s: Sound, format: i64) -> str {
    assert format >= WAV_PCM8 && format <= WAV_F32, "wav_encode: unknown format"
    bytes := if format == WAV_F32 { 4 } else { format }
    n := len(s.samples)
    out := alloc[u8](44 + n * bytes)
    copy(out, "RIFF")
    audio_put32(out, 4, 36 + n * bytes)
    copy(out[8..], "WAVEfmt ")
    audio_put32(out, 16, 16)
    audio_put16(out, 20, if format == WAV_F32 { 3 } else { 1 })
    audio_put16(out, 22, s.channels)
    audio_put32(out, 24, s.rate)
    audio_put32(out, 28, s.rate * s.channels * bytes)
    audio_put16(out, 32, s.channels * bytes)
    audio_put16(out, 34, bytes * 8)
    copy(out[36..], "data")
    audio_put32(out, 40, n * bytes)
    for i in 0..n {
        p := 44 + i * bytes
        x := s.samples[i]
        match format {
            WAV_PCM8 => out[p] = u8(audio_quantize(x, 128.0, -128, 127) + 128)
            WAV_PCM16 => audio_put16(out, p, audio_quantize(x, 32768.0, -32768, 32767))
            WAV_PCM24 => {
                v := audio_quantize(x, 8388608.0, -8388608, 8388607)
                audio_put16(out, p, v)
                out[p + 2] = u8(v >> 16)
            }
            WAV_PCM32 => audio_put32(out, p, audio_quantize(x, 2147483648.0, -2147483648, 2147483647))
            _ => audio_put32(out, p, i64(cast[u32](x)))
        }
    }
    out
}

// Reads and decodes a WAV file; false if it is missing or not a supported WAV. Allocates.
fn wav_load(path: str) -> (Sound, bool) {
    data, ok := read_file(path)
    if !ok {
        none: Sound
        return (none, false)
    }
    wav_decode(data)
}

// Writes a sound as a WAV file in the given sample format; false if the file cannot be written.
fn wav_save(path: str, s: Sound, format: i64) -> bool {
    m := mark()
    ok := write_file(path, wav_encode(s, format))
    release(m)
    ok
}

// ---- mixer ----

// frames mixed per pass through the mixer's scratch buffer when producing i16 output
const AUDIO_CHUNK_FRAMES = 1024

// Handle of a playing voice. The zero value and handles of finished voices are invalid;
// using them is harmless (the calls do nothing).
struct VoiceId {
    index: i32
    serial: u32
}

// One slot of the voice pool. `pos` and `step` are source frames in 32.32 fixed point.
struct Voice {
    sound: Sound
    pos: i64
    step: i64
    volume: f32
    pan: f32
    serial: u32
    active: bool
    looped: bool
    paused: bool
}

// Software mixer: sums the playing voices into an output stream of `rate` Hz with `channels`
// (1 or 2) channels.
struct Mixer {
    rate: i64
    channels: i64
    master: f32
    voices: []Voice
    serial: u32
    scratch: []f32
}

// A mixer for the given output format with room for `max_voices` simultaneous sounds.
// Allocates once; play / mix never allocate.
fn mixer_new(rate: i64, channels: i64, max_voices: i64) -> *Mixer {
    assert rate > 0 && (channels == 1 || channels == 2) && max_voices > 0, "mixer_new: bad format"
    m := new[Mixer]()
    m.rate = rate
    m.channels = channels
    m.master = 1.0
    m.voices = alloc[Voice](max_voices)
    m.scratch = alloc[f32](AUDIO_CHUNK_FRAMES * channels)
    m
}

fn audio_step(m: *Mixer, s: Sound, pitch: f32) -> i64 {
    i64(f64(fmax(pitch, 0.0)) * f64(s.rate) / f64(m.rate) * 4294967296.0)
}

// Starts playing a sound: `volume` is a linear gain, `pan` -1 (left) .. 1 (right), `pitch` a
// speed factor (1 = original; resampled with linear interpolation), `looped` repeats forever.
// The Sound's samples are referenced, not copied. Returns an invalid VoiceId (see `valid`)
// when all voices are busy or the sound is empty.
fn play(m: *Mixer, s: Sound, volume: f32, pan: f32, pitch: f32, looped: bool) -> VoiceId {
    if frames(s) == 0 || s.rate <= 0 {
        return VoiceId{}
    }
    for i in 0..len(m.voices) {
        v := &m.voices[i]
        if !v.active {
            m.serial += 1
            *v = Voice{sound: s, step: audio_step(m, s, pitch), volume: volume, pan: pan, serial: m.serial, active: true, looped: looped}
            return VoiceId{i32(i), m.serial}
        }
    }
    VoiceId{}
}

fn audio_voice(m: *Mixer, id: VoiceId) -> *Voice {
    i := i64(id.index)
    if id.serial == 0 || i < 0 || i >= len(m.voices) {
        return nil
    }
    v := &m.voices[i]
    if !v.active || v.serial != id.serial {
        return nil
    }
    v
}

// True if the handle came from a successful `play` (the voice may have finished since).
fn valid(id: VoiceId) -> bool {
    id.serial != 0
}

// True while the voice is still in the pool (playing or paused).
fn playing(m: *Mixer, id: VoiceId) -> bool {
    audio_voice(m, id) != nil
}

// Stops a voice and frees its slot.
fn stop(m: *Mixer, id: VoiceId) {
    v := audio_voice(m, id)
    if v != nil {
        v.active = false
    }
}

// Stops every voice.
fn stop_all(m: *Mixer) {
    for i in 0..len(m.voices) {
        m.voices[i].active = false
    }
}

// Sets the linear gain of a voice.
fn set_volume(m: *Mixer, id: VoiceId, volume: f32) {
    v := audio_voice(m, id)
    if v != nil {
        v.volume = volume
    }
}

// Sets the stereo position of a voice: -1 (left) .. 1 (right).
fn set_pan(m: *Mixer, id: VoiceId, pan: f32) {
    v := audio_voice(m, id)
    if v != nil {
        v.pan = pan
    }
}

// Sets the playback speed factor of a voice.
fn set_pitch(m: *Mixer, id: VoiceId, pitch: f32) {
    v := audio_voice(m, id)
    if v != nil {
        v.step = audio_step(m, v.sound, pitch)
    }
}

// Pauses or resumes a voice (a paused voice keeps its slot and position).
fn set_paused(m: *Mixer, id: VoiceId, paused: bool) {
    v := audio_voice(m, id)
    if v != nil {
        v.paused = paused
    }
}

// Sets the gain applied to the whole mix (before clipping).
fn set_master_volume(m: *Mixer, volume: f32) {
    m.master = volume
}

// Number of voices in use.
fn active_voices(m: *Mixer) -> i64 {
    n := 0
    for i in 0..len(m.voices) {
        if m.voices[i].active {
            n += 1
        }
    }
    n
}

// adds `count` output frames of one voice to `out` and advances it
fn audio_mix_voice(m: *Mixer, v: *Voice, out: []f32, count: i64) {
    src := v.sound.samples
    ch := v.sound.channels
    right := min(ch, 2) - 1
    n := frames(v.sound)
    span := n << 32
    pan := fmin(fmax(v.pan, -1.0), 1.0)
    gain_l := v.volume * m.master
    gain_r := gain_l
    if m.channels == 2 {
        gain_l *= fmin(1.0 - pan, 1.0)
        gain_r *= fmin(1.0 + pan, 1.0)
    } else {
        gain_l *= 0.5
        gain_r *= 0.5
    }
    pos := v.pos
    for f in 0..count {
        if pos >= span {
            if !v.looped {
                v.active = false
                break
            }
            pos %= span
        }
        i0 := pos >> 32
        i1 := i0 + 1
        if i1 == n {
            i1 = if v.looped { 0 } else { i0 }
        }
        t := f32(pos & 0xFFFFFFFF) * (1.0 / 4294967296.0)
        a := src[i0 * ch]
        b := src[i0 * ch + right]
        l := (a + (src[i1 * ch] - a) * t) * gain_l
        r := (b + (src[i1 * ch + right] - b) * t) * gain_r
        if m.channels == 2 {
            out[f * 2] += l
            out[f * 2 + 1] += r
        } else {
            out[f] += l + r
        }
        pos += v.step
    }
    v.pos = pos
    if pos >= span && !v.looped {
        v.active = false
    }
}

// Renders the next `count` frames into `out` (interleaved, count * channels samples, replaced
// not added) and advances all voices; the sum is clipped to -1..1. Voices that reach their end
// free their slot.
fn mix(m: *Mixer, out: []f32, count: i64) {
    total := count * m.channels
    assert len(out) >= total, "mix: output buffer too small"
    out = out[..total]
    fill(out, 0.0)
    for i in 0..len(m.voices) {
        v := &m.voices[i]
        if v.active && !v.paused {
            audio_mix_voice(m, v, out, count)
        }
    }
    for i in 0..total {
        out[i] = fmin(fmax(out[i], -1.0), 1.0)
    }
}

// Like `mix`, producing signed 16-bit samples (rounded to nearest).
fn mix_i16(m: *Mixer, out: []i16, count: i64) {
    assert len(out) >= count * m.channels, "mix_i16: output buffer too small"
    done := 0
    while done < count {
        n := min(count - done, AUDIO_CHUNK_FRAMES)
        mix(m, m.scratch, n)
        base := done * m.channels
        for i in 0..n * m.channels {
            out[base + i] = i16(i64(floor(f64(m.scratch[i]) * 32767.0 + 0.5)))
        }
        done += n
    }
}

// ---- output device (ALSA) ----

// An open playback device. `buffer_frames` is the device buffer (the output latency),
// `underruns` counts recovered stalls.
struct AudioDevice {
    pcm: *u8
    rate: i64
    channels: i64
    buffer_frames: i64
    period_frames: i64
    underruns: i64
    buf: []i16
}

// Opens the default playback device for 16-bit output with about 50 ms of buffering; false if
// there is no usable device. Allocates the device once.
fn audio_open(rate: i64, channels: i64) -> (*AudioDevice, bool) {
    audio_open("default", rate, channels, 50)
}

// Opens the ALSA device `name` ("default", "null", "hw:0", ...) with `latency_ms` of buffering.
fn audio_open(name: str, rate: i64, channels: i64, latency_ms: i64) -> (*AudioDevice, bool) {
    pcm: *u8 = nil
    mk := mark()
    err := snd_pcm_open(&pcm, cstr(name), SND_PCM_STREAM_PLAYBACK, 0)
    release(mk)
    if err < 0 {
        return (nil, false)
    }
    buffer: u64
    period: u64
    if snd_pcm_set_params(pcm, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED, u32(channels), u32(rate), 1, u32(latency_ms * 1000)) < 0 ||
        snd_pcm_get_params(pcm, &buffer, &period) < 0 {
        snd_pcm_close(pcm)
        return (nil, false)
    }
    d := new[AudioDevice]()
    d.pcm = pcm
    d.rate = rate
    d.channels = channels
    d.buffer_frames = i64(buffer)
    d.period_frames = i64(period)
    d.buf = alloc[i16](d.buffer_frames * channels)
    (d, true)
}

// Mixes the next `count` frames and writes them to the device, waiting while the device
// buffer is full (so it paces a loop to real time). Returns the frames written (fewer only if
// the device failed). Does nothing for a nil device.
fn audio_write(d: *AudioDevice, m: *Mixer, count: i64) -> i64 {
    if d == nil || d.pcm == nil {
        return 0
    }
    assert m.rate == d.rate && m.channels == d.channels, "audio_write: mixer and device formats differ"
    total := 0
    while total < count {
        n := min(count - total, d.buffer_frames)
        mix_i16(m, d.buf, n)
        sent := 0
        while sent < n {
            r := snd_pcm_writei(d.pcm, cast[*u8](ptr(d.buf[sent * d.channels..])), u64(n - sent))
            if r < 0 {
                d.underruns += 1
                if snd_pcm_recover(d.pcm, i32(r), 1) < 0 {
                    return total + sent
                }
                continue
            }
            sent += r
        }
        total += n
    }
    total
}

// Tops the device buffer up with as many frames as it accepts right now, without waiting.
// Call it once per frame; returns the frames written. Does nothing for a nil device.
fn audio_pump(d: *AudioDevice, m: *Mixer) -> i64 {
    if d == nil || d.pcm == nil {
        return 0
    }
    avail := snd_pcm_avail_update(d.pcm)
    if avail < 0 {
        d.underruns += 1
        if snd_pcm_recover(d.pcm, i32(avail), 1) < 0 {
            return 0
        }
        avail = snd_pcm_avail_update(d.pcm)
    }
    if avail <= 0 {
        return 0
    }
    audio_write(d, m, min(avail, d.buffer_frames))
}

// Stops playback at once and closes the device.
fn audio_close(d: *AudioDevice) {
    if d == nil || d.pcm == nil {
        return
    }
    snd_pcm_drop(d.pcm)
    snd_pcm_close(d.pcm)
    d.pcm = nil
}
