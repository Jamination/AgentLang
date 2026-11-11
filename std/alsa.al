// std.alsa: raw ALSA PCM bindings (libasound.so.2). Names and arguments follow
// <alsa/asoundlib.h>: snd_pcm_t* and the params objects are `*u8`, frame counts are `i64`
// (snd_pcm_sframes_t) or `u64` (snd_pcm_uframes_t), enums and int are `i32`. Functions return
// a negative errno on failure. std.audio builds the mixer output device on top of this.

// snd_pcm_stream_t and open mode
SND_PCM_STREAM_PLAYBACK : i32 : 0
SND_PCM_STREAM_CAPTURE : i32 : 1
SND_PCM_NONBLOCK : i32 : 1

// snd_pcm_format_t
SND_PCM_FORMAT_U8 : i32 : 1
SND_PCM_FORMAT_S16_LE : i32 : 2
SND_PCM_FORMAT_S24_LE : i32 : 6
SND_PCM_FORMAT_S32_LE : i32 : 10
SND_PCM_FORMAT_FLOAT_LE : i32 : 14

// snd_pcm_access_t
SND_PCM_ACCESS_RW_INTERLEAVED : i32 : 3

// snd_pcm_state_t
SND_PCM_STATE_OPEN : i32 : 0
SND_PCM_STATE_SETUP : i32 : 1
SND_PCM_STATE_PREPARED : i32 : 2
SND_PCM_STATE_RUNNING : i32 : 3
SND_PCM_STATE_XRUN : i32 : 4
SND_PCM_STATE_DRAINING : i32 : 5
SND_PCM_STATE_PAUSED : i32 : 6
SND_PCM_STATE_SUSPENDED : i32 : 7
SND_PCM_STATE_DISCONNECTED : i32 : 8

extern "libasound.so.2" snd_pcm_open :: (pcm: **u8, name: *u8, stream: i32, mode: i32) -> i32
extern "libasound.so.2" snd_pcm_close :: (pcm: *u8) -> i32
extern "libasound.so.2" snd_pcm_nonblock :: (pcm: *u8, nonblock: i32) -> i32
extern "libasound.so.2" snd_pcm_set_params :: (pcm: *u8, format: i32, access: i32, channels: u32, rate: u32, soft_resample: i32, latency_us: u32) -> i32
extern "libasound.so.2" snd_pcm_get_params :: (pcm: *u8, buffer_size: *u64, period_size: *u64) -> i32
extern "libasound.so.2" snd_pcm_prepare :: (pcm: *u8) -> i32
extern "libasound.so.2" snd_pcm_start :: (pcm: *u8) -> i32
extern "libasound.so.2" snd_pcm_drop :: (pcm: *u8) -> i32
extern "libasound.so.2" snd_pcm_drain :: (pcm: *u8) -> i32
extern "libasound.so.2" snd_pcm_pause :: (pcm: *u8, enable: i32) -> i32
extern "libasound.so.2" snd_pcm_resume :: (pcm: *u8) -> i32
extern "libasound.so.2" snd_pcm_state :: (pcm: *u8) -> i32
extern "libasound.so.2" snd_pcm_delay :: (pcm: *u8, delay: *i64) -> i32
extern "libasound.so.2" snd_pcm_avail :: (pcm: *u8) -> i64
extern "libasound.so.2" snd_pcm_avail_update :: (pcm: *u8) -> i64
extern "libasound.so.2" snd_pcm_writei :: (pcm: *u8, buffer: *u8, frames: u64) -> i64
extern "libasound.so.2" snd_pcm_readi :: (pcm: *u8, buffer: *u8, frames: u64) -> i64
extern "libasound.so.2" snd_pcm_wait :: (pcm: *u8, timeout_ms: i32) -> i32
extern "libasound.so.2" snd_pcm_recover :: (pcm: *u8, err: i32, silent: i32) -> i32
extern "libasound.so.2" snd_pcm_hw_params_malloc :: (params: **u8) -> i32
extern "libasound.so.2" snd_pcm_hw_params_free :: (params: *u8)
extern "libasound.so.2" snd_pcm_hw_params_any :: (pcm: *u8, params: *u8) -> i32
extern "libasound.so.2" snd_pcm_hw_params_set_access :: (pcm: *u8, params: *u8, access: i32) -> i32
extern "libasound.so.2" snd_pcm_hw_params_set_format :: (pcm: *u8, params: *u8, format: i32) -> i32
extern "libasound.so.2" snd_pcm_hw_params_set_channels :: (pcm: *u8, params: *u8, channels: u32) -> i32
extern "libasound.so.2" snd_pcm_hw_params_set_rate_near :: (pcm: *u8, params: *u8, rate: *u32, dir: *i32) -> i32
extern "libasound.so.2" snd_pcm_hw_params_set_period_size_near :: (pcm: *u8, params: *u8, frames: *u64, dir: *i32) -> i32
extern "libasound.so.2" snd_pcm_hw_params_set_buffer_size_near :: (pcm: *u8, params: *u8, frames: *u64) -> i32
extern "libasound.so.2" snd_pcm_hw_params_get_rate :: (params: *u8, rate: *u32, dir: *i32) -> i32
extern "libasound.so.2" snd_pcm_hw_params_get_period_size :: (params: *u8, frames: *u64, dir: *i32) -> i32
extern "libasound.so.2" snd_pcm_hw_params_get_buffer_size :: (params: *u8, frames: *u64) -> i32
extern "libasound.so.2" snd_pcm_hw_params :: (pcm: *u8, params: *u8) -> i32
extern "libasound.so.2" snd_pcm_sw_params_malloc :: (params: **u8) -> i32
extern "libasound.so.2" snd_pcm_sw_params_free :: (params: *u8)
extern "libasound.so.2" snd_pcm_sw_params_current :: (pcm: *u8, params: *u8) -> i32
extern "libasound.so.2" snd_pcm_sw_params_set_start_threshold :: (pcm: *u8, params: *u8, frames: u64) -> i32
extern "libasound.so.2" snd_pcm_sw_params_set_avail_min :: (pcm: *u8, params: *u8, frames: u64) -> i32
extern "libasound.so.2" snd_pcm_sw_params :: (pcm: *u8, params: *u8) -> i32
extern "libasound.so.2" snd_strerror :: (errnum: i32) -> *u8
