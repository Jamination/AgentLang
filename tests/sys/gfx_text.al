// std.gfx_text on the backend of the target (Direct3D 12 on Windows, Vulkan on Linux): the
// scenes of data/gfx_text_scene.al drawn offscreen on the first device and on the software
// rasterizer (WARP; on Linux a CPU Vulkan device if installed, else the first device again)
// and compared with std.font's software drawing of the same text. The largest differences
// are written to standard error. Without a device it says why and ends with status 77 (SKIP).
//
// `gfx_text --save DIR` also writes the frames of the first device and their references there.
use std.gfx
use "data/gfx_text_scene.al"

fn main() -> i64 {
    save := if len(args()) > 2 && args()[1] == "--save" { args()[2] } else { "" }
    wrong := 0
    for software in []bool{false, true} {
        print(if software { "software device" } else { "first device" })
        n, err := run_text(GfxDesc{software: software}, if software { "" } else { save })
        if err != "" {
            print("no device for std.gfx:", err)
            return if software { 1 } else { 77 }
        }
        wrong += n
    }
    eprint(fmt("largest difference to std.font: ", worst))
    if wrong == 0 { 0 } else { 1 }
}
