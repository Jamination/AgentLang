// std.gfx in a window with the backend of the target (Direct3D 12 on Windows): see
// data/gfx_window.al. Windows only as a test (on Linux it needs an X display).
use std.gfx
use "data/gfx_window.al"

fn main() -> i64 { run_window(GfxDesc{}) }
