// Renders the scene of renderer.al without a window: 8 frames with two in flight, then reads
// the last one back and saves it as vk_renderer.png. Prints the device, the GPU time per frame
// (timestamp queries) and what the validation layer reported.
//
//     alc run examples/vk_renderer/offscreen.al
use "renderer.al"

fn main() -> i64 {
    result, problem := render_offscreen(512, 512, 8)
    if problem != "" {
        print("cannot use Vulkan:", problem)
        return 77
    }
    print("device:", result.device)
    print("validation layer:", if result.validation { "enabled" } else { "not installed" })
    for i, ms in result.gpu_ms { print("frame", i, "GPU time", fmtf(ms, 3), "ms") }
    img := image_new(512, 512, 4)
    copy(img.pix, result.pixels)
    if !png_save("vk_renderer.png", img) {
        print("cannot write vk_renderer.png")
        return 1
    }
    print("wrote vk_renderer.png; validation warnings", debug_stats.warnings, "errors", debug_stats.errors)
    if debug_stats.warnings + debug_stats.errors > 0 { 1 } else { 0 }
}
