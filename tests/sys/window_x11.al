// std.window against a real X server: opens a window on the display named by the environment
// variable AL_TEST_DISPLAY (a private test display such as Xvfb, never the user's desktop),
// presents frames, polls events and closes again.
use std.window

fn main() {
    display := from_cstr(getenv(ptr("AL_TEST_DISPLAY")))
    if len(display) == 0 {
        print("AL_TEST_DISPLAY is not set")
        exit(1)
    }
    w, ok := window_open(WindowDesc{title: "AL window test \xc3\xa9", width: 320, height: 240, resizable: true, display: display})
    print("open:", ok)
    if !ok {
        exit(1)
    }
    width, height := w.size()
    print(width, height, w.should_close(), w.x11_display() != nil, w.x11_window() != 0)
    fb := alloc[u8](64 * 48 * 4)
    for i in 0..64 * 48 {
        fb[i * 4] = u8(i % 64 * 4)
        fb[i * 4 + 1] = u8(i / 64 * 5)
        fb[i * 4 + 2] = 128
        fb[i * 4 + 3] = 255
    }
    presented := 0
    for frame in 0..30 {
        w.poll()
        loop {
            _, more := w.next_event()
            if !more {
                break
            }
        }
        if frame == 5 {
            w.set_title("renamed")
            w.set_cursor_visible(false)
        }
        if frame == 10 {
            w.set_cursor_visible(true)
            w.set_fullscreen(true)
        }
        if frame == 20 {
            w.set_fullscreen(false)
        }
        if w.present(fb, 64, 48) {
            presented += 1
        }
        var ts = [2]i64{0, 10_000_000}
        syscall(35, ptr(ts), 0)
    }
    width, height = w.size()
    print("presented:", presented, "size ok:", width > 0 && height > 0, "closing:", w.should_close(), "dropped:", w.events.dropped)
    w.close()
    print(w.should_close(), w.x11_display() == nil, w.present(fb, 64, 48))
    w.poll()
    w.close()
    print("done")
}
