// The Vulkan backend of std.gfx (std/gfx_vk.al) on any system, also Windows (`use std.gfx_vk`
// instead of `use std.gfx`): the scene of data/gfx_scene.al offscreen with the validation
// layer on (GfxDesc.debug; without the layer installed it runs unvalidated and says so on
// standard error), then the same pixel checks as tests/sys/gfx_offscreen.al, which on Windows
// runs the Direct3D 12 backend. Any validation error or warning fails the test. Without a
// Vulkan 1.3 device it ends with status 77 (SKIP).
//
// `gfx_vulkan out.png` also writes the frame there.
use std.gfx_vk
use "data/gfx_scene.al"

fn main() -> i64 {
    save := if len(args()) > 1 { args()[1] } else { "" }
    print("first device, validation layer on")
    wrong, err := run_scene(GfxDesc{debug: true}, save)
    if err != "" {
        print("no device for std.gfx:", err)
        return 77
    }
    print("validation messages:", __gfx_vk_messages)
    if wrong == 0 && __gfx_vk_messages == 0 { 0 } else { 1 }
}
