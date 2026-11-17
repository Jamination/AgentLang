// std.gfx with the backend of the target (Direct3D 12 on Windows, Vulkan on Linux), without a
// window: the scene of data/gfx_scene.al (sprites, mirroring, shapes, alpha and additive
// blending, a coverage texture, scissor, transform, line, triangle colours, a render texture,
// linear filtering, a texture updated during the frame) is drawn offscreen, read back and
// checked pixel by pixel; once on the first device and once on the software rasterizer (WARP;
// on Linux a CPU Vulkan device such as lavapipe if one is installed, else the first device
// again). Without a device it says why and ends with status 77 (SKIP).
//
// `gfx_offscreen --save out.png` also writes the first frame there (the test runner passes
// the arguments a1 b2 to every test, which must not name a file to write).
use std.gfx
use "data/gfx_scene.al"

fn main() -> i64 {
    save := if len(args()) > 2 && args()[1] == "--save" { args()[2] } else { "" }
    wrong := 0
    for software in []bool{false, true} {
        print(if software { "software device" } else { "first device" })
        n, err := run_scene(GfxDesc{software: software}, if software { "" } else { save })
        if err != "" {
            print("no device for std.gfx:", err)
            return if software { 1 } else { 77 }
        }
        wrong += n
    }
    if wrong == 0 { 0 } else { 1 }
}
