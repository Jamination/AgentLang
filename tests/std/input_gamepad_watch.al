// gamepad_changed: true on the first call (open the gamepads), then only when a joystick device
// appears or vanishes (Linux: inotify on /dev/input; Windows: at most once a second). Nobody
// plugs a gamepad in during the test.
use std.input

fn main() {
    w: GamepadWatch
    print("first:", gamepad_changed(&w), "started:", w.started)
    print("again:", gamepad_changed(&w), gamepad_changed(&w))
    pad: Gamepad
    if gamepad_changed(&w) && !pad.connected {
        print("would open")
    }
    gamepad_watch_close(&w)
    print("closed:", w.started, w.fd)
    print("restarted:", gamepad_changed(&w), gamepad_changed(&w))
    gamepad_watch_close(&w)
    gamepad_watch_close(&w)
    print("done")
}
