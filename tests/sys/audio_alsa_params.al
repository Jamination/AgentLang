// std.alsa explicit configuration on ALSA's "null" PCM (needs no sound card): an engine picks
// the period and buffer sizes itself with snd_pcm_hw_params_* / snd_pcm_sw_params_* and reads
// back what the device granted; the PCM of a std.audio device (d.os.pcm) answers queries such
// as snd_pcm_delay.
use std.audio

fn check(what: str, err: i32) {
    if err < 0 {
        print(what, "failed:", from_cstr(snd_strerror(err)))
        exit(1)
    }
}

fn main() {
    pcm: *u8 = nil
    check("open", snd_pcm_open(&pcm, ptr("null"), SND_PCM_STREAM_PLAYBACK, 0))
    hw: *u8 = nil
    check("hw malloc", snd_pcm_hw_params_malloc(&hw))
    check("any", snd_pcm_hw_params_any(pcm, hw))
    check("access", snd_pcm_hw_params_set_access(pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED))
    check("format", snd_pcm_hw_params_set_format(pcm, hw, SND_PCM_FORMAT_FLOAT_LE))
    check("channels", snd_pcm_hw_params_set_channels(pcm, hw, 2))
    check("resample", snd_pcm_hw_params_set_rate_resample(pcm, hw, 1))
    rate: u32 = 48000
    dir: i32 = 0
    check("rate", snd_pcm_hw_params_set_rate_near(pcm, hw, &rate, &dir))
    period: u64 = 256                                    // 5.3 ms at 48 kHz
    check("period", snd_pcm_hw_params_set_period_size_near(pcm, hw, &period, &dir))
    periods: u32 = 3
    check("periods", snd_pcm_hw_params_set_periods_near(pcm, hw, &periods, &dir))
    check("hw", snd_pcm_hw_params(pcm, hw))
    // what the device granted
    got_rate: u32
    got_period: u64
    got_periods: u32
    got_buffer: u64
    check("current", snd_pcm_hw_params_current(pcm, hw))
    snd_pcm_hw_params_get_rate(hw, &got_rate, &dir)
    snd_pcm_hw_params_get_period_size(hw, &got_period, &dir)
    snd_pcm_hw_params_get_periods(hw, &got_periods, &dir)
    snd_pcm_hw_params_get_buffer_size(hw, &got_buffer)
    print("rate", got_rate, "period", got_period, "periods", got_periods, "buffer", got_buffer)
    snd_pcm_hw_params_free(hw)
    // wake up per period, start once one period is queued
    sw: *u8 = nil
    check("sw malloc", snd_pcm_sw_params_malloc(&sw))
    check("sw current", snd_pcm_sw_params_current(pcm, sw))
    check("avail min", snd_pcm_sw_params_set_avail_min(pcm, sw, got_period))
    check("start threshold", snd_pcm_sw_params_set_start_threshold(pcm, sw, got_period))
    check("sw", snd_pcm_sw_params(pcm, sw))
    snd_pcm_sw_params_free(sw)
    n := snd_pcm_poll_descriptors_count(pcm)
    print("poll descriptors:", n >= 0)
    silence := alloc[f32](i64(got_period) * 2)
    print("written:", snd_pcm_writei(pcm, cast[*u8](ptr(silence)), got_period), "state running:", snd_pcm_state(pcm) == SND_PCM_STATE_RUNNING)
    snd_pcm_drop(pcm)
    snd_pcm_close(pcm)

    // the latency of a std.audio device: buffer and period as granted, the queue through d.os.pcm
    dev, ok := audio_open("null", 48000, 2, 20)
    print("audio_open:", ok, "buffer ms:", dev.buffer_frames * 1000 / dev.rate, "period <= buffer:", dev.period_frames <= dev.buffer_frames)
    delay: i64
    print("snd_pcm_delay:", snd_pcm_delay(dev.os.pcm, &delay) == 0, delay >= 0)
    audio_close(dev)
}
