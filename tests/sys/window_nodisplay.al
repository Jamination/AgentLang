// std.window links against libX11 and fails cleanly when the display cannot be reached.
// The display name below has no ":number" part, so Xlib rejects it without connecting anywhere.
use std.window

fn main() {
    w, ok := window_open(WindowDesc{title: "never shown", width: 320, height: 200, display: "al-test-not-a-display"})
    print(ok, w == nil)
}
