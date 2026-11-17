// std.audio: Ogg Vorbis decoding against libvorbis. Each fixture tests/std/data/ogg_NAME.ogg
// was encoded by libvorbis and decoded by libvorbisfile into ogg_NAME.ref.wav (32-bit float;
// tests/std/data/ogg.txt says how). The decoder must give the same number of frames and the
// same samples up to float rounding. The fixtures cover mono, stereo (coupled, residue 2),
// 6 channels (two submaps, four coupling steps, residues 1 and 2), 8 kHz with one block size,
// lowest and highest quality, and a stream of a single page.
use std.audio

fn main() {
    names := []str{"stereo", "mono", "6ch", "lowq", "hiq", "8k", "tiny"}
    for name in names {
        m := mark()
        path := fmt("tests/std/data/ogg_", name, ".ogg")
        ref, rok := wav_load(fmt("tests/std/data/ogg_", name, ".ref.wav"))
        assert rok, "reference missing"
        s, ok := ogg_load(path)
        if !ok {
            print(name, "failed:", ogg_error())
            continue
        }
        d: f32 = 0.0
        peak: f32 = 0.0
        same := len(s.samples) == len(ref.samples)
        if same {
            for i in 0..len(s.samples) {
                d = fmax(d, fabs(s.samples[i] - ref.samples[i]))
                peak = fmax(peak, fabs(ref.samples[i]))
            }
        }
        print(name, s.rate, s.channels, frames(s), same, d < 2e-6, peak > 0.1, ogg_error() == "")
        // the same through a stream, read in pieces of awkward sizes
        st, sok := ogg_open_file(path)
        buf := alloc[f32](4096 * st.channels)
        total := 0
        equal := sok
        sizes := []i64{1, 7, 333, 4096, 64}
        k := 0
        loop {
            n := sizes[k % len(sizes)]
            got := ogg_read(st, buf, n)
            for i in 0..got * st.channels {
                if buf[i] != s.samples[total * st.channels + i] {
                    equal = false
                }
            }
            total += got
            k += 1
            if got < n {
                break
            }
        }
        print("  stream", st.frames, total, st.pos, equal, st.error == "", ogg_read(st, buf, 10))
        release(m)
    }
    // not Ogg Vorbis
    for data in []str{"", "OggS", "RIFF....WAVE", repeat("x", 100)} {
        _, ok := ogg_decode(data)
        print("bad input:", ok, ogg_error())
    }
    _, ok := ogg_load("tests/std/data/no_such_file.ogg")
    print("missing file:", ok, ogg_error() != "")
}
