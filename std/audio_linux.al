// std.audio, Linux layer: the output device through ALSA (libasound.so.2, declared in
// std.alsa). Loaded by `use std.audio` for --target linux; the shared part is std/audio.al.
use std.alsa

// frees the strings that snd_device_name_get_hint returns
priv extern "libc.so.6" fn free(p: *u8)

// The ALSA part of an AudioDevice: the PCM handle and the 16-bit staging buffer (one device
// buffer long).
struct AudioOs {
    pcm: *u8
    buf: []i16
}

// why the last audio_open failed
priv audio_err: str

// Why the last audio_open failed: the ALSA error text with the call that failed; "" after a
// successful open.
fn audio_error() -> str {
    audio_err
}

// Opens the ALSA device `name` ("default", "null", "hw:0", ...) with `latency_ms` of buffering.
fn audio_open(name: str, rate: i64, channels: i64, latency_ms: i64) -> (*AudioDevice, bool) {
    pcm: *u8 = nil
    mk := mark()
    err := snd_pcm_open(&pcm, cstr(name), SND_PCM_STREAM_PLAYBACK, 0)
    release(mk)
    if err < 0 {
        audio_err = fmt("snd_pcm_open(", name, "): ", from_cstr(snd_strerror(err)))
        return (nil, false)
    }
    buffer: u64
    period: u64
    err = snd_pcm_set_params(pcm, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED, u32(channels), u32(rate), 1, u32(latency_ms * 1000))
    if err >= 0 {
        err = snd_pcm_get_params(pcm, &buffer, &period)
    }
    if err < 0 {
        audio_err = fmt("snd_pcm_set_params(", name, "): ", from_cstr(snd_strerror(err)))
        snd_pcm_close(pcm)
        return (nil, false)
    }
    audio_err = ""
    d := new[AudioDevice]()
    d.os.pcm = pcm
    d.rate = rate
    d.channels = channels
    d.buffer_frames = i64(buffer)
    d.period_frames = i64(period)
    d.os.buf = alloc[i16](d.buffer_frames * channels)
    (d, true)
}

// Mixes the next `count` frames and writes them to the device, waiting while the device
// buffer is full (so it paces a loop to real time). Returns the frames written (fewer only if
// the device failed). Does nothing for a nil device.
fn audio_write(d: *AudioDevice, m: *Mixer, count: i64) -> i64 {
    if d == nil || d.os.pcm == nil {
        return 0
    }
    assert m.rate == d.rate && m.channels == d.channels, "audio_write: mixer and device formats differ"
    total := 0
    while total < count {
        n := min(count - total, d.buffer_frames)
        mix_i16(m, d.os.buf, n)
        sent := 0
        while sent < n {
            r := snd_pcm_writei(d.os.pcm, cast[*u8](ptr(d.os.buf[sent * d.channels..])), u64(n - sent))
            if r < 0 {
                d.underruns += 1
                if snd_pcm_recover(d.os.pcm, i32(r), 1) < 0 {
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
    if d == nil || d.os.pcm == nil {
        return 0
    }
    avail := snd_pcm_avail_update(d.os.pcm)
    if avail < 0 {
        d.underruns += 1
        if snd_pcm_recover(d.os.pcm, i32(avail), 1) < 0 {
            return 0
        }
        avail = snd_pcm_avail_update(d.os.pcm)
    }
    if avail <= 0 {
        return 0
    }
    audio_write(d, m, min(avail, d.buffer_frames))
}

// Stops playback at once and closes the device.
fn audio_close(d: *AudioDevice) {
    if d == nil || d.os.pcm == nil {
        return
    }
    snd_pcm_drop(d.os.pcm)
    snd_pcm_close(d.os.pcm)
    d.os.pcm = nil
}

// The ALSA PCM names that can play (from the configuration and the sound cards: "default",
// "null", "sysdefault:CARD=...", "hw:CARD=...,DEV=0", ...). Allocates the list.
fn audio_devices() -> []str {
    names := vec[str]()
    hints: **u8 = nil
    if snd_device_name_hint(-1, ptr("pcm"), &hints) < 0 || hints == nil {
        return names.items()
    }
    i := 0
    while hints[i] != nil {
        name := snd_device_name_get_hint(hints[i], ptr("NAME"))
        io := snd_device_name_get_hint(hints[i], ptr("IOID"))
        // IOID is missing for devices that both play and record
        if name != nil && (io == nil || from_cstr(io) == "Output") {
            names.push(clone(from_cstr(name)))
        }
        if name != nil {
            free(name)
        }
        if io != nil {
            free(io)
        }
        i += 1
    }
    snd_device_name_free_hint(hints)
    names.items()
}
