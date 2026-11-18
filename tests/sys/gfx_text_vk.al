// std.gfx_text on the Vulkan backend of std.gfx on any system, also Windows (`use std.gfx_vk`):
// the scenes of data/gfx_text_scene.al with the validation layer on (synchronization
// validation too), compared with std.font's software drawing as in tests/sys/gfx_text.al. Any
// validation message fails the test. Without a Vulkan 1.3 device it ends with status 77 (SKIP).
//
// `gfx_text_vk --save DIR` also writes the frames and their references there.
use std.gfx_vk
use "data/gfx_text_scene.al"

fn main() -> i64 {
    save := if len(args()) > 2 && args()[1] == "--save" { args()[2] } else { "" }
    print("first device, validation layer on")
    wrong, err := run_text(GfxDesc{debug: true}, save)
    if err != "" {
        print("no device for std.gfx:", err)
        return 77
    }
    print("validation messages:", __gfx_vk_messages)
    eprint(fmt("largest difference to std.font: ", worst))
    if wrong == 0 && __gfx_vk_messages == 0 { 0 } else { 1 }
}
