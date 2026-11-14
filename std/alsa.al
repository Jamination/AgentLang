// std.alsa: raw ALSA PCM bindings (libasound.so.2). Names and arguments follow
// <alsa/asoundlib.h>: snd_pcm_t* and the params objects are `*u8`, frame counts are `i64`
// (snd_pcm_sframes_t) or `u64` (snd_pcm_uframes_t), enums and int are `i32`. Functions return
// a negative errno on failure. std.audio builds the mixer output device on top of this.

// snd_pcm_stream_t and open mode
const SND_PCM_STREAM_PLAYBACK: i32 = 0
const SND_PCM_STREAM_CAPTURE: i32 = 1
const SND_PCM_NONBLOCK: i32 = 1

// snd_pcm_format_t
const SND_PCM_FORMAT_U8: i32 = 1
const SND_PCM_FORMAT_S16_LE: i32 = 2
const SND_PCM_FORMAT_S24_LE: i32 = 6
const SND_PCM_FORMAT_S32_LE: i32 = 10
const SND_PCM_FORMAT_FLOAT_LE: i32 = 14

// snd_pcm_access_t
const SND_PCM_ACCESS_RW_INTERLEAVED: i32 = 3

// snd_pcm_state_t
const SND_PCM_STATE_OPEN: i32 = 0
const SND_PCM_STATE_SETUP: i32 = 1
const SND_PCM_STATE_PREPARED: i32 = 2
const SND_PCM_STATE_RUNNING: i32 = 3
const SND_PCM_STATE_XRUN: i32 = 4
const SND_PCM_STATE_DRAINING: i32 = 5
const SND_PCM_STATE_PAUSED: i32 = 6
const SND_PCM_STATE_SUSPENDED: i32 = 7
const SND_PCM_STATE_DISCONNECTED: i32 = 8

extern "libasound.so.2" fn snd_pcm_open(pcm: **u8, name: *u8, stream: i32, mode: i32) -> i32
extern "libasound.so.2" fn snd_pcm_close(pcm: *u8) -> i32
extern "libasound.so.2" fn snd_pcm_nonblock(pcm: *u8, nonblock: i32) -> i32
extern "libasound.so.2" fn snd_pcm_set_params(pcm: *u8, format: i32, access: i32, channels: u32, rate: u32, soft_resample: i32, latency_us: u32) -> i32
extern "libasound.so.2" fn snd_pcm_get_params(pcm: *u8, buffer_size: *u64, period_size: *u64) -> i32
extern "libasound.so.2" fn snd_pcm_prepare(pcm: *u8) -> i32
extern "libasound.so.2" fn snd_pcm_start(pcm: *u8) -> i32
extern "libasound.so.2" fn snd_pcm_drop(pcm: *u8) -> i32
extern "libasound.so.2" fn snd_pcm_drain(pcm: *u8) -> i32
extern "libasound.so.2" fn snd_pcm_pause(pcm: *u8, enable: i32) -> i32
extern "libasound.so.2" fn snd_pcm_resume(pcm: *u8) -> i32
extern "libasound.so.2" fn snd_pcm_state(pcm: *u8) -> i32
extern "libasound.so.2" fn snd_pcm_delay(pcm: *u8, delay: *i64) -> i32
extern "libasound.so.2" fn snd_pcm_avail(pcm: *u8) -> i64
extern "libasound.so.2" fn snd_pcm_avail_update(pcm: *u8) -> i64
extern "libasound.so.2" fn snd_pcm_writei(pcm: *u8, buffer: *u8, frames: u64) -> i64
extern "libasound.so.2" fn snd_pcm_readi(pcm: *u8, buffer: *u8, frames: u64) -> i64
extern "libasound.so.2" fn snd_pcm_wait(pcm: *u8, timeout_ms: i32) -> i32
extern "libasound.so.2" fn snd_pcm_recover(pcm: *u8, err: i32, silent: i32) -> i32
extern "libasound.so.2" fn snd_pcm_hw_params_malloc(params: **u8) -> i32
extern "libasound.so.2" fn snd_pcm_hw_params_free(params: *u8)
extern "libasound.so.2" fn snd_pcm_hw_params_any(pcm: *u8, params: *u8) -> i32
extern "libasound.so.2" fn snd_pcm_hw_params_set_access(pcm: *u8, params: *u8, access: i32) -> i32
extern "libasound.so.2" fn snd_pcm_hw_params_set_format(pcm: *u8, params: *u8, format: i32) -> i32
extern "libasound.so.2" fn snd_pcm_hw_params_set_channels(pcm: *u8, params: *u8, channels: u32) -> i32
// The functions below exist twice in libasound.so.2: the current API (symbol version
// ALSA_0.9.0rc4, pointer arguments, returns an error code) and the pre-1.0 API (ALSA_0.9: values
// in, values out). A reference without a version binds to the oldest one, so these call the
// current implementation through its unversioned alias `__snd_pcm_hw_params_*`.
priv extern "libasound.so.2" fn __snd_pcm_hw_params_set_rate_near(pcm: *u8, params: *u8, rate: *u32, dir: *i32) -> i32
priv extern "libasound.so.2" fn __snd_pcm_hw_params_set_period_size_near(pcm: *u8, params: *u8, frames: *u64, dir: *i32) -> i32
priv extern "libasound.so.2" fn __snd_pcm_hw_params_set_buffer_size_near(pcm: *u8, params: *u8, frames: *u64) -> i32
priv extern "libasound.so.2" fn __snd_pcm_hw_params_set_periods_near(pcm: *u8, params: *u8, periods: *u32, dir: *i32) -> i32
priv extern "libasound.so.2" fn __snd_pcm_hw_params_set_period_time_near(pcm: *u8, params: *u8, us: *u32, dir: *i32) -> i32
priv extern "libasound.so.2" fn __snd_pcm_hw_params_set_buffer_time_near(pcm: *u8, params: *u8, us: *u32, dir: *i32) -> i32
priv extern "libasound.so.2" fn __snd_pcm_hw_params_get_rate(params: *u8, rate: *u32, dir: *i32) -> i32
priv extern "libasound.so.2" fn __snd_pcm_hw_params_get_period_size(params: *u8, frames: *u64, dir: *i32) -> i32
priv extern "libasound.so.2" fn __snd_pcm_hw_params_get_buffer_size(params: *u8, frames: *u64) -> i32
priv extern "libasound.so.2" fn __snd_pcm_hw_params_get_periods(params: *u8, periods: *u32, dir: *i32) -> i32
fn snd_pcm_hw_params_set_rate_near(pcm: *u8, params: *u8, rate: *u32, dir: *i32) -> i32 { __snd_pcm_hw_params_set_rate_near(pcm, params, rate, dir) }
fn snd_pcm_hw_params_set_period_size_near(pcm: *u8, params: *u8, frames: *u64, dir: *i32) -> i32 { __snd_pcm_hw_params_set_period_size_near(pcm, params, frames, dir) }
fn snd_pcm_hw_params_set_buffer_size_near(pcm: *u8, params: *u8, frames: *u64) -> i32 { __snd_pcm_hw_params_set_buffer_size_near(pcm, params, frames) }
fn snd_pcm_hw_params_set_periods_near(pcm: *u8, params: *u8, periods: *u32, dir: *i32) -> i32 { __snd_pcm_hw_params_set_periods_near(pcm, params, periods, dir) }
fn snd_pcm_hw_params_set_period_time_near(pcm: *u8, params: *u8, us: *u32, dir: *i32) -> i32 { __snd_pcm_hw_params_set_period_time_near(pcm, params, us, dir) }
fn snd_pcm_hw_params_set_buffer_time_near(pcm: *u8, params: *u8, us: *u32, dir: *i32) -> i32 { __snd_pcm_hw_params_set_buffer_time_near(pcm, params, us, dir) }
fn snd_pcm_hw_params_get_rate(params: *u8, rate: *u32, dir: *i32) -> i32 { __snd_pcm_hw_params_get_rate(params, rate, dir) }
fn snd_pcm_hw_params_get_period_size(params: *u8, frames: *u64, dir: *i32) -> i32 { __snd_pcm_hw_params_get_period_size(params, frames, dir) }
fn snd_pcm_hw_params_get_buffer_size(params: *u8, frames: *u64) -> i32 { __snd_pcm_hw_params_get_buffer_size(params, frames) }
fn snd_pcm_hw_params_get_periods(params: *u8, periods: *u32, dir: *i32) -> i32 { __snd_pcm_hw_params_get_periods(params, periods, dir) }
extern "libasound.so.2" fn snd_pcm_hw_params_set_rate_resample(pcm: *u8, params: *u8, enable: u32) -> i32
extern "libasound.so.2" fn snd_pcm_hw_params_current(pcm: *u8, params: *u8) -> i32
extern "libasound.so.2" fn snd_pcm_hw_params(pcm: *u8, params: *u8) -> i32
extern "libasound.so.2" fn snd_pcm_sw_params_malloc(params: **u8) -> i32
extern "libasound.so.2" fn snd_pcm_sw_params_free(params: *u8)
extern "libasound.so.2" fn snd_pcm_sw_params_current(pcm: *u8, params: *u8) -> i32
extern "libasound.so.2" fn snd_pcm_sw_params_set_start_threshold(pcm: *u8, params: *u8, frames: u64) -> i32
extern "libasound.so.2" fn snd_pcm_sw_params_set_avail_min(pcm: *u8, params: *u8, frames: u64) -> i32
extern "libasound.so.2" fn snd_pcm_sw_params(pcm: *u8, params: *u8) -> i32
// struct pollfd array (8 bytes each: fd i32, events i16, revents i16) for waiting on the device
// in an event loop
extern "libasound.so.2" fn snd_pcm_poll_descriptors_count(pcm: *u8) -> i32
extern "libasound.so.2" fn snd_pcm_poll_descriptors(pcm: *u8, pfds: *u8, space: u32) -> i32
extern "libasound.so.2" fn snd_strerror(errnum: i32) -> *u8
// device name hints: snd_device_name_hint(-1, "pcm", &hints) lists every PCM as a nil-terminated
// array; snd_device_name_get_hint(hint, "NAME" | "DESC" | "IOID") returns a malloc'ed string
// (nil if absent; free it with libc free)
extern "libasound.so.2" fn snd_device_name_hint(card: i32, iface: *u8, hints: ***u8) -> i32
extern "libasound.so.2" fn snd_device_name_get_hint(hint: *u8, id: *u8) -> *u8
extern "libasound.so.2" fn snd_device_name_free_hint(hints: **u8) -> i32
