# std.audio: sounds, WAV files, mixer and audio output

`use std.audio` provides

- `Sound`: decoded PCM audio in memory, plus tone / noise generators,
- WAV decoding and encoding,
- `Mixer`: a software mixer with a fixed pool of voices (volume, pan, pitch, looping),
- `AudioDevice`: playback fed from the game loop, through ALSA on Linux and WASAPI on Windows
  (`--target windows`), with the same functions and behaviour.

Sounds, WAV and the mixer are pure AL: a program that uses only them stays a static
executable and its output is bit-for-bit reproducible, so game audio can be tested by
checksumming the mix. Only the `audio_*` device functions use the system: on Linux ALSA
(`libasound.so.2`, declared in `std.alsa`; using one of them makes the program dynamically
linked), on Windows `ole32.dll` (COM) and the audio engine behind it. The device code is in the
module's OS layers, `std/audio_linux.al` and `std/audio_windows.al`, which `std/audio.al`
includes for the target with `when TARGET_OS == ...`.

## Sound

```
struct Sound { samples: []f32, rate: i64, channels: i64 }
```

Interleaved `f32` samples in -1..1, `channels` samples per frame, `rate` frames per second. A
`Sound` is a small value that refers to its samples; copying it does not copy audio data.

| Function | |
|----------|---|
| `sound_new(rate, channels, frames) -> Sound` | silent sound to fill in (allocates) |
| `frames(s: Sound) -> i64` | number of frames |
| `duration(s: Sound) -> f32` | length in seconds |
| `sound_tone(rate, freq: f32, seconds: f32, amp: f32) -> Sound` | mono sine tone (allocates) |
| `sound_noise(rate, seconds: f32, amp: f32, seed: u64) -> Sound` | mono white noise; the same seed gives the same samples (allocates) |

## WAV

| Function | |
|----------|---|
| `wav_decode(data: str) -> (Sound, bool)` | decode a WAV file image (allocates the samples) |
| `wav_load(path: str) -> (Sound, bool)` | read and decode a file |
| `wav_encode(s: Sound, format: i64) -> str` | encode as a WAV file image (allocates) |
| `wav_save(path: str, s: Sound, format: i64) -> bool` | encode and write a file |

Formats for encoding: `WAV_PCM8`, `WAV_PCM16`, `WAV_PCM24`, `WAV_PCM32`, `WAV_F32`.
Decoding accepts integer PCM with 8, 16, 24 or 32 bits and IEEE float with 32 or 64 bits, any
number of channels, plain or `WAVE_FORMAT_EXTENSIBLE` headers; unknown chunks are skipped and
truncated data is cut to whole samples. Anything else (compressed codecs, not a RIFF file)
returns false. Integer encoding rounds to nearest and clips to -1..1; 16-bit and 24-bit files
decode and re-encode to identical bytes. `embed("jump.wav")` plus `wav_decode` builds sounds
into the executable.

## Mixer

```
m := mixer_new(48000, 2, 32)                       // output rate, channels (1 or 2), voices
id := m.play(sound, 1.0, 0.0, 1.0, false)          // volume, pan, pitch, looped
m.mix(out, n)                                      // render the next n frames
```

| Function | |
|----------|---|
| `mixer_new(rate, channels, max_voices) -> *Mixer` | create a mixer (allocates once) |
| `play(m, s: Sound, volume: f32, pan: f32, pitch: f32, looped: bool) -> VoiceId` | start a voice |
| `valid(id: VoiceId) -> bool` | the handle came from a successful `play` |
| `playing(m, id) -> bool` | the voice is still in the pool (also while paused) |
| `stop(m, id)`, `stop_all(m)` | end a voice / all voices |
| `set_volume(m, id, volume)`, `set_pan(m, id, pan)`, `set_pitch(m, id, pitch)` | change a playing voice |
| `set_paused(m, id, paused: bool)` | pause / resume, keeping the position |
| `set_master_volume(m, volume)` | gain of the whole mix (applied before clipping) |
| `active_voices(m) -> i64` | voices in use |
| `mix(m, out: []f32, frames)` | render `frames` frames of interleaved `f32` into `out` |
| `mix_i16(m, out: []i16, frames)` | the same as signed 16-bit samples (rounded) |

Behaviour:

- **Voice pool.** `max_voices` slots exist from the start; `play`, `mix` and the setters never
  allocate. When all slots are busy `play` returns an invalid `VoiceId`; the sound is simply
  not played. A voice frees its slot when it reaches the end of a non-looped sound (at the
  latest by the end of the `mix` call that plays its last frame) or on `stop`.
- **Handles.** A `VoiceId` carries a serial number, so a handle to a voice that has finished
  never affects the voice that later reuses the slot. Calls with stale or invalid handles do
  nothing; `VoiceId{}` is invalid.
- **Volume and pan.** `volume` is a linear gain. `pan` runs from -1 (left) to 1 (right); at 0
  both channels play at full volume, towards one side the opposite channel fades linearly. A
  stereo sound keeps its channels and `pan` acts as balance. In a mono mixer `pan` is ignored
  and stereo sounds are averaged. Sounds with more than two channels play their first two.
- **Pitch and resampling.** A voice advances by `pitch * sound.rate / mixer.rate` source frames
  per output frame with linear interpolation, so sounds of any sample rate play at the right
  speed and `pitch` 2.0 is an octave up. Positions are 32.32 fixed point: results do not depend
  on how the output is split into `mix` calls.
- **Clipping.** The sum of all voices times the master volume is limited to -1..1.
- The mixer references the samples of a `Sound`; keep them alive (do not `release` them) while
  it plays.

## Audio output

| Function | |
|----------|---|
| `audio_open(rate, channels) -> (*AudioDevice, bool)` | open the default playback device with about 50 ms of buffer |
| `audio_open(name: str, rate, channels, latency_ms) -> (*AudioDevice, bool)` | open a named device (see [Devices](#devices)) with a chosen buffer length |
| `audio_pump(d, m: *Mixer) -> i64` | mix and write as many frames as the device accepts right now; never waits |
| `audio_write(d, m: *Mixer, frames) -> i64` | mix and write exactly `frames` frames, waiting while the buffer is full |
| `audio_close(d)` | stop at once and close |
| `audio_error() -> str` | why the last `audio_open` failed; `""` after a successful one |
| `audio_devices() -> []str` | the names of the playback devices `audio_open` accepts (allocates) |

`AudioDevice` fields: `rate`, `channels` (the format the program opened, which the mixer must
have), `buffer_frames` (device buffer = output latency) and `period_frames` (the device's
transfer unit), both in frames of `rate`, `underruns` (stalls: the buffer ran dry), `lost`
(Windows: the device is gone, see [Device loss](#device-loss)), and `os`, the OS layer's own
state. `audio_open` returns `(nil, false)` when there is no usable device (ALSA may also print
a diagnostic to standard error) and `audio_error()` says why; all other device functions
accept a nil or closed device and do nothing, so a game runs unchanged on a machine without
sound.

### Devices

| | Linux (ALSA) | Windows (WASAPI) |
|---|---|---|
| `"default"` | the ALSA `default` PCM | the default playback endpoint (role "console"); follows it when the user picks another default (checked once a second, the stream moves) |
| `"null"` | ALSA's null PCM: discards everything, never waits | the same, built in: discards everything, never waits |
| other names | any ALSA PCM name (`"hw:0"`, `"plughw:CARD=PCH"`, `"pipewire"`) | the friendly name of an active endpoint (`"Speakers (Realtek(R) Audio)"`) or its endpoint ID string |
| `audio_devices()` | the PCM names of the ALSA configuration and the cards that can play | the friendly names of the active playback endpoints |

**Formats.** On Linux the device is opened as 16-bit at the program's rate and channel count;
ALSA's plug layer converts. On Windows the stream is opened in shared mode in the audio
engine's mix format exactly as it reports it (`GetMixFormat`: usually 32-bit float at 44.1 or
48 kHz with 2 or more channels), and std.audio converts itself: a different rate by linear
interpolation (as the mixer's pitch), channels by the same rules as ALSA's plug layer (a mono
program plays on the first two channels, a stereo program on front left and right with further
channels silent, a mono device gets the average), and the samples to the mix format's type
(32-bit float, or 16, 24 or 32-bit integers). `buffer_frames` is the engine's buffer for the
requested latency (it may round up), `period_frames` the engine period (usually 10 ms).

**`audio_error()` texts on Windows** name the call and the HRESULT: `WASAPI: no playback device
(GetDefaultAudioEndpoint: HRESULT 0x80070490, E_NOTFOUND)` when the system has no active
playback device (also under Wine without a sound server), `WASAPI: no playback device named
"..." (audio_devices() lists them)`, `WASAPI: <call> failed: HRESULT 0x...` otherwise (for
example `CoCreateInstance(MMDeviceEnumerator)` when the audio service is not running), and
`audio_open: bad format (...)` for a rate or channel count below 1. On Linux they are the ALSA
error text: `snd_pcm_open(name): No such file or directory`.

**COM.** On Windows `audio_open` and `audio_devices` initialise COM on the calling thread as a
single-threaded apartment (`CoInitializeEx`, balanced at `audio_close`); a thread that already
uses the multithreaded apartment keeps it. Call the device functions from one thread.

### Device loss

On Windows a device can go away while it plays: unplugged headphones or USB speakers, a
disabled endpoint, a changed format in the sound settings, the audio service restarting
(`AUDCLNT_E_DEVICE_INVALIDATED`, or any other failing call). Then the stream is released and
`lost` becomes true; `audio_pump` returns 0 and does not advance the mixer (the sounds pause,
as when ALSA fails on Linux), `audio_write` returns early with the frames written so far after
waiting for up to the length of the missing frames (at most 100 ms, so a loop around it does
not spin). Both open the device again by the same name, at once and then at most every 500 ms;
for `"default"` that is the new default device. When that works `lost` is false again and the
sounds continue where they paused. A device that stays away costs no memory per attempt. On
Linux, `lost` stays false: a device that fails ends playback (`audio_pump` returns 0).

### Pumping from the game loop

There is no audio thread: AL code must not run (and allocate) on a thread created by a C
library, and a single-threaded loop keeps the game deterministic. Instead the game tops up
the device buffer once per frame:

```
while !w.should_close() {
    w.poll()
    ...update, render, present...
    audio_pump(dev, mixer)       // fills whatever the device has played since the last frame
}
```

- **Latency** is the buffer length: a sound started in a frame is heard up to `latency_ms`
  later (50 ms by default) plus the device's own delay.
- **Frame time budget**: the buffer must outlast the longest frame. If a frame takes longer
  than the buffer (loading a level, a debugger stop) the device runs dry: playback pauses, the
  stall is counted in `underruns`, and the next `audio_pump` recovers and continues. Choose
  `latency_ms` 2 to 3 times the worst expected frame time: 50 ms suits 60 Hz games, use
  100 ms or more if frames can take 40 ms. Lower values (20 to 30 ms) work when the frame rate
  is stable.
- `audio_pump` advances the mixer only by what the device consumed, so audio stays in real
  time independently of the frame rate; do not call `mix` yourself on a mixer that feeds a
  device.
- `audio_write` is the blocking alternative for programs without a frame loop (players,
  tools): it paces the caller to real time, as in the example below.
- For long loading phases, call `audio_pump` between loading steps to keep music running.

## Example

```
// Renders two seconds of mixed sound to a WAV file, then plays the same mix on a device.
use std.audio

fn main() {
    note := sound_tone(48000, 440.0, 0.3, 0.5)
    hiss := sound_noise(48000, 0.2, 0.1, 7)
    mixer := mixer_new(48000, 2, 16)

    // offline: mix into a Sound and save it (deterministic, needs no sound card)
    song := sound_new(48000, 2, 96000)
    mixer.play(hiss, 1.0, 0.0, 1.0, true)                 // looped background, centre
    for beat in 0..4 {
        pan := f32(beat) / 1.5 - 1.0                      // left to right
        mixer.play(note, 0.8, pan, 1.0 + f32(beat) * 0.25, false)
        mixer.mix(song.samples[beat * 48000..], 24000)    // half a second per note
    }
    print("voices still playing:", mixer.active_voices())
    print("saved:", wav_save("/tmp/al_audio_example.wav", song, WAV_PCM16))
    back, ok := wav_load("/tmp/al_audio_example.wav")
    print("loaded:", ok, frames(back), "frames,", back.channels, "channels,", back.rate, "Hz")

    // on a device ("null" discards the samples; use audio_open(48000, 2) for the default device)
    dev, opened := audio_open("null", 48000, 2, 50)
    if !opened {
        print("no audio device")
        return
    }
    mixer.stop_all()
    mixer.play(back, 1.0, 0.0, 1.0, false)
    written := 0
    while mixer.active_voices() > 0 {
        written += audio_write(dev, mixer, 480)           // blocks while the device buffer is full
    }
    print("played", written, "frames")
    audio_close(dev)
}
```

Output:

```
voices still playing: 1
saved: true
loaded: true 96000 frames, 2 channels, 48000 Hz
played 96000 frames
```

[examples/audio_tone.al](../../examples/audio_tone.al) plays a melody on the default device the
way a game does (notes started from the frame loop, one `audio_pump` per frame), on both
systems.

## Testing the Windows device

`tests/run.sh --target windows` runs the device tests under Wine without any sound device
(`sys/audio_nodevice`: the documented error; `sys/audio_null`). `tests/winaudio/run.sh`
tests WASAPI end to end under Wine against a private PipeWire server whose only outputs are
null sinks (stereo 48 kHz and 5.1 at 44.1 kHz; it checks that before playing anything): it
records the sinks' monitors while `tests/winaudio/tone.al` plays a known signal through
`audio_pump` and `audio_write` at several rates and channel counts, and checks frequency,
amplitude, channel order, continuity and length (`check.al`), counts underruns of a stalling
loop, and restarts the server under a playing program to check device loss. It needs
`pipewire`, `pipewire-pulse` and Wine.

## std.alsa

`use std.alsa` (Linux only; included by `std.audio` for Linux) declares the ALSA PCM functions used above and the
usual rest of the playback API with their C names and signatures: `snd_pcm_open`,
`snd_pcm_set_params`, `snd_pcm_get_params`, `snd_pcm_writei`, `snd_pcm_readi`,
`snd_pcm_avail`, `snd_pcm_avail_update`, `snd_pcm_delay`, `snd_pcm_recover`, `snd_pcm_wait`,
`snd_pcm_prepare`, `snd_pcm_start`, `snd_pcm_drop`, `snd_pcm_drain`, `snd_pcm_pause`,
`snd_pcm_resume`, `snd_pcm_state`, `snd_pcm_nonblock`, `snd_pcm_close`, the
`snd_pcm_hw_params_*` / `snd_pcm_sw_params_*` functions for explicit configuration,
`snd_strerror`, and the device name hints (`snd_device_name_hint`,
`snd_device_name_get_hint`, `snd_device_name_free_hint`); constants `SND_PCM_STREAM_*`, `SND_PCM_NONBLOCK`, `SND_PCM_FORMAT_*`,
`SND_PCM_ACCESS_RW_INTERLEAVED`, `SND_PCM_STATE_*`. Handles are `*u8`, frame counts `i64` /
`u64`, results are negative `errno` values on failure.
