// std.window on Wayland against a real compositor. The program starts its own
// `weston --backend=headless` (it shows nothing) on a private socket named after its process
// id and opens its windows there by naming that socket in WindowDesc.display, never on
// $WAYLAND_DISPLAY. It uses only std.window, so it is not linked against libwayland-client:
// the backend loads it at run time. Headless weston has no input devices; the input paths are
// covered by tests/std/window_wayland_logic.
use std.window
use std.os

fn open_fds() -> i64 {
    m := mark()
    n := len(list_dir("/proc/self/fd"))
    release(m)
    n
}

// Ends the compositor (SIGTERM to `timeout`, which passes it on) and waits at most 10 s.
fn stop(weston: Process) -> i64 {
    kill(weston, 15)
    for attempt in 0..500 {
        status, ended := try_wait(weston)
        if ended {
            return status
        }
        sleep_ns(20_000_000)
    }
    kill(weston, 9)
    wait(weston)
    -1
}

// Polls (and presents, if `fb` is not empty) until `done(w)` or 3 s have passed; the events
// of the kinds seen, counted.
fn pump(w: *Window, fb: []u8, done: fn(*Window) -> bool) -> (bool, i64, i64) {
    resizes := 0
    others := 0
    for i in 0..300 {
        w.poll()
        loop {
            e, more := w.next_event()
            if !more {
                break
            }
            if e.kind == EventResize {
                resizes += 1
            } else {
                others += 1
            }
        }
        if fb.len > 0 {
            w.present(fb, 64, 48)
        }
        if done(w) {
            return (true, resizes, others)
        }
        sleep_ns(10_000_000)
    }
    (false, resizes, others)
}

fn main() {
    runtime, has := env_get("XDG_RUNTIME_DIR")
    if !has {
        print("XDG_RUNTIME_DIR is not set")
        exit(1)
    }
    // a socket that does not exist: no window, and no X11 either (the name chose Wayland)
    w0, ok0 := window_open(WindowDesc{title: "never", display: "wayland:al-wl-test-no-such-socket"})
    print("no compositor:", ok0, w0 == nil)

    socket := fmt("al-wl-test-", process_id())
    path := path_join(runtime, socket)
    wl_name := concat("wayland:", socket)
    weston, started := spawn([]str{"env", "-u", "WAYLAND_DISPLAY", "-u", "DISPLAY", "timeout", "-k", "5", "60",
        "weston", "--backend=headless", fmt("--socket=", socket), "--width=800", "--height=600", "--no-config",
        "--log=/dev/null"})
    if !started {
        print("cannot start weston:", error_text(io_error()))
        exit(1)
    }
    for attempt in 0..500 {
        if file_exists(path) {
            break
        }
        sleep_ns(20_000_000)
    }
    fds := open_fds()

    // a fixed-size window
    w, ok := window_open(WindowDesc{title: "AL Wayland window \xc3\xa9", width: 320, height: 200, display: wl_name})
    print("open:", ok)
    if !ok {
        stop(weston)
        exit(1)
    }
    print("handles:", wayland_display(w) != nil, wayland_surface(w) != nil, x11_display(w) == nil, x11_window(w))
    print("size:", w.size(), w.fullscreen, w.minimized, w.should_close())
    fb := alloc[u8](64 * 48 * 4)
    for i in 0..64 * 48 {
        fb[i * 4] = u8(i % 64 * 4)
        fb[i * 4 + 1] = u8(i / 64 * 5)
        fb[i * 4 + 2] = 128
    }
    presented := 0
    for frame in 0..20 {
        w.poll()
        if w.present(fb, 64, 48) {
            presented += 1
        }
        if frame == 5 {
            w.set_title("renamed")
            w.set_cursor_visible(false)
            w.set_text_input(true)
        }
        if frame == 10 {
            w.set_cursor_visible(true)
            w.set_cursor_locked(true)
        }
        if frame == 15 {
            w.set_cursor_locked(false)
        }
        sleep_ns(10_000_000)
    }
    print("presented:", presented, "size:", w.size(), "cursor:", w.cursor_hidden, w.cursor_locked, "text input:", w.text_input)

    // fullscreen: the output's size, then back to the window's own
    w.set_fullscreen(true)
    full, r1, _ := pump(w, fb, fn(w: *Window) -> bool { w.width == 800 && w.height == 600 })
    print("fullscreen:", full, w.fullscreen, w.size(), "resize events:", r1 > 0)
    w.set_fullscreen(false)
    back, r2, _ := pump(w, fb, fn(w: *Window) -> bool { w.width == 320 && w.height == 200 })
    print("windowed:", back, w.fullscreen, w.size(), "resize events:", r2 > 0)

    w.close()
    print("closed:", w.should_close(), w.present(fb, 64, 48), wayland_display(w) == nil)
    w.poll()
    w.set_title("after close")
    w.set_fullscreen(true)
    w.close()

    // a resizable window that presents nothing (as one with a GPU swapchain would)
    v, vok := window_open(WindowDesc{title: "resizable", width: 300, height: 100, resizable: true, display: wl_name})
    v.poll()
    print("resizable:", vok, v.size())
    v.close()

    // open / close cycles leave no descriptor open
    cycles := 0
    for i in 0..10 {
        c, cok := window_open(WindowDesc{title: "cycle", width: 64, height: 64, display: wl_name})
        if !cok {
            break
        }
        c.poll()
        c.present(fb, 64, 48)
        c.close()
        cycles += 1
    }
    print("cycles:", cycles, "descriptors left open:", open_fds() - fds)

    // the compositor goes away under an open window: the window wants to close
    g, gok := window_open(WindowDesc{title: "orphan", width: 64, height: 64, display: wl_name})
    status := stop(weston)
    gone, _, _ := pump(g, []u8{}, fn(w: *Window) -> bool { w.should_close() })
    print("compositor gone:", gok, status >= 0, gone, g.present(fb, 64, 48))
    g.close()
}
