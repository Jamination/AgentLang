// std.gfx in a window with the Vulkan backend (`use std.gfx_vk`; on Windows a Win32 surface)
// and the validation layer on: see data/gfx_window.al. Any validation message fails the test.
use std.gfx_vk
use "data/gfx_window.al"

fn main() -> i64 {
    status := run_window(GfxDesc{debug: true})
    print("validation messages:", __gfx_vk_messages)
    if status == 0 && __gfx_vk_messages != 0 { 1 } else { status }
}
