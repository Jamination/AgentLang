// Device loss (tests/winaudio/run.sh): plays a looped tone on the default device with
// audio_pump; run.sh stops the sound server after "playing" and starts it again. The device
// must be reported lost (`lost`), audio_pump must return 0 meanwhile, and playback must
// resume on the new server by itself.
use std.audio

fn main() {
    dev, ok := audio_open("default", 48000, 2, 50)
    if !ok {
        print("audio_open failed:", audio_error())
        exit(1)
    }
    m := mixer_new(48000, 2, 4)
    m.play(sound_tone(48000, 500.0, 1.0, 0.3), 1.0, 0.0, 1.0, true)
    t0 := clock_ns()
    announced := false
    seen_lost := false
    pumped_while_lost := 0
    recovered_at: i64 = 0
    after := 0
    while clock_ns() - t0 < 30000000000 {
        n := audio_pump(dev, m)
        if dev.lost {
            if !seen_lost {
                print("lost")
                flush()
            }
            seen_lost = true
            pumped_while_lost += n
        } else if seen_lost {
            if recovered_at == 0 {
                recovered_at = clock_ns()
                print("recovered")
                flush()
            }
            after += n
            if clock_ns() - recovered_at > 1000000000 {
                break
            }
        } else if n > 0 && !announced {
            announced = true
            print("playing")
            flush()
        }
        sleep_ms(16)
    }
    print("lost seen:", seen_lost, "frames while lost:", pumped_while_lost, "reopened:", dev.os.reopened, "frames in the second after:", after > 40000)
    audio_close(dev)
}
