// The renderer of examples/vk_renderer (instance, validation layer and debug messenger,
// extension commands, device with Vulkan 1.3 features, staging, PNG texture, depth, descriptor
// sets, push constants, compute, timestamps, frames in flight) rendered offscreen on the real
// driver; the last frame is read back and its pixels checked against what the scene must give.
// With VK_LAYER_KHRONOS_validation installed (with synchronization validation) any validation
// error or warning fails the test; without it the test runs unvalidated and says so on stderr.
// Exit code 77: no usable Vulkan 1.3 device.
use "../../examples/vk_renderer/renderer.al"

const SIZE: u32 = 256
const FRAMES = 8

struct Probe { name: str, x: i64, y: i64, want: [4]i64 }

fn main() -> i64 {
    result, problem := render_offscreen(SIZE, SIZE, FRAMES)
    if problem != "" {
        print("cannot use Vulkan:", problem)
        return 77
    }
    if !result.validation { eprint("note: VK_LAYER_KHRONOS_validation is not installed; rendered without validation") }

    // texture quadrants: red, green / blue, white; push-constant tint (1, 0.5, 1); the near quad
    // (instance 0) untinted, the far one (instance 1) cyan on odd frames: the last frame is 7
    probes := []Probe{
        Probe{"clear colour, corner", 2, 2, [4]i64{26, 26, 38, 255}},
        Probe{"near quad, red quadrant", 83, 70, [4]i64{255, 0, 0, 255}},
        Probe{"near quad, green quadrant", 147, 70, [4]i64{0, 128, 0, 255}},
        Probe{"near quad, blue quadrant", 83, 134, [4]i64{0, 0, 255, 255}},
        Probe{"near quad, white quadrant", 147, 134, [4]i64{255, 128, 255, 255}},
        Probe{"far quad hidden by the near one (depth test)", 153, 141, [4]i64{255, 128, 255, 255}},
        Probe{"far quad, green quadrant", 205, 141, [4]i64{0, 128, 0, 255}},
        Probe{"far quad, blue quadrant", 154, 192, [4]i64{0, 0, 255, 255}},
        Probe{"far quad, white quadrant, cyan (frame 7 from the compute shader)", 205, 192, [4]i64{0, 128, 255, 255}},
        Probe{"camera translation (uniform buffer): left of the near quad", 45, 100, [4]i64{26, 26, 38, 255}},
        Probe{"camera translation (uniform buffer): right edge of the near quad", 177, 60, [4]i64{0, 128, 0, 255}},
    }
    bad := 0
    for p in probes {
        at := (p.y * i64(SIZE) + p.x) * 4
        px := result.pixels[at..at + 4]
        ok := true
        for c in 0..4 {
            if abs(i64(px[c]) - p.want[c]) > 2 { ok = false }
        }
        if ok {
            print("ok  ", p.name)
        } else {
            bad += 1
            print("BAD ", p.name, "at", p.x, p.y, "got", px, "want", p.want)
        }
    }
    print("frames rendered:", result.frames, "with", FRAMES_IN_FLIGHT, "in flight")
    print("timestamps read:", result.gpu_ms.len)
    for ms in result.gpu_ms {
        if ms < 0.0 || ms > 1000.0 { print("implausible GPU time:", ms) }
    }
    print("debug messenger received the test message:", debug_stats.test_seen)
    print("validation errors:", debug_stats.errors, "warnings:", debug_stats.warnings)
    if bad > 0 { 1 } else { 0 }
}
