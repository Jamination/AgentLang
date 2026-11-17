// std.window links against libX11 and fails cleanly when the display cannot be reached.
// ":not-a-number" names an X display (it has a `:`) whose display number Xlib cannot parse, so
// it is rejected without connecting anywhere; with that, no Wayland compositor is tried.
// "al-test-not-a-display" (no `:`) names a Wayland socket that does not exist: the Wayland
// backend fails (also without libwayland-client) and does not fall back to X11.
use std.window

fn main() {
    w, ok := window_open(WindowDesc{title: "never shown", width: 320, height: 200, display: ":not-a-number"})
    print(ok, w == nil)
    w, ok = window_open(WindowDesc{title: "never shown", width: 320, height: 200, display: "al-test-not-a-display"})
    print(ok, w == nil)
}
