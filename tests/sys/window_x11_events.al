// std.window against a real X server (the display named by AL_TEST_DISPLAY: a private test
// display without a window manager such as Xvfb or a rootful Xwayland, never the user's
// desktop): a second client connection plays the user and the window manager. It resizes the
// window, minimizes it (_NET_WM_STATE_HIDDEN, unmapping), changes the fullscreen state, moves
// the mouse while the pointer is locked (set_cursor_locked: XInput 2 raw motion, made with
// XTEST, then the fallback without that extension, pointer motion) and takes the focus away.
use std.window

d2: *u8
win: u64

extern "libXtst.so.6" fn XTestFakeRelativeMotionEvent(dpy: *u8, dx: i32, dy: i32, delay: u64) -> i32

// the user moves the mouse by (dx, dy) counts
fn mouse(dx: i32, dy: i32) {
    XTestFakeRelativeMotionEvent(d2, dx, dy, 0)
    XSync(d2, 0)
}

// polls (5 ms apart, at most 2 s) until an event of `kind` arrives; false if none came
fn wait_for(w: *Window, kind: EventKind) -> (Event, bool) {
    for i in 0..400 {
        w.poll()
        loop {
            e, more := w.next_event()
            if !more {
                break
            }
            if e.kind == kind {
                return (e, true)
            }
        }
        sleep_ms(5)
    }
    (Event{}, false)
}

// polls `n` frames and returns the sum of their mouse deltas
fn deltas(w: *Window, n: i64) -> vec2 {
    d := vec2(0.0)
    for i in 0..n {
        w.poll()
        d = d + w.input.mouse_delta()
        sleep_ms(5)
    }
    d
}

// another client asks for the pointer grab: X_ALREADY_GRABBED while the window holds it
fn grabbed_by_window() -> bool {
    r := XGrabPointer(d2, XRootWindow(d2, 0), 0, 0x40, X_GRAB_MODE_ASYNC, X_GRAB_MODE_ASYNC, 0, 0, X_CURRENT_TIME)
    if r == X_GRAB_SUCCESS {
        XUngrabPointer(d2, X_CURRENT_TIME)
    }
    XSync(d2, 0)
    r == X_ALREADY_GRABBED
}

fn set_state(atoms: []u64) {
    state := XInternAtom(d2, ptr("_NET_WM_STATE"), 0)
    XChangeProperty(d2, win, state, X_ATOM_ATOM, 32, X_PROP_MODE_REPLACE, cast[*u8](ptr(atoms)), i32(len(atoms)))
    XSync(d2, 0)
}

fn focus(w: *Window) -> bool {
    XSetInputFocus(d2, win, X_REVERT_TO_PARENT, X_CURRENT_TIME)
    XSync(d2, 0)
    _, ok := wait_for(w, EventFocus)
    ok
}

fn pointer_in_window() -> (i64, i64) {
    root: u64
    child: u64
    rx: i32
    ry: i32
    wx: i32
    wy: i32
    mask: u32
    XQueryPointer(d2, win, &root, &child, &rx, &ry, &wx, &wy, &mask)
    (i64(wx), i64(wy))
}

fn main() {
    display := from_cstr(getenv(ptr("AL_TEST_DISPLAY")))
    if len(display) == 0 {
        print("AL_TEST_DISPLAY is not set")
        exit(1)
    }
    w, ok := window_open(WindowDesc{title: "AL window events", width: 320, height: 240, resizable: true, display: display})
    print("open:", ok, "minimized:", w.minimized, "locked:", w.cursor_locked)
    if !ok {
        exit(1)
    }
    d2 = XOpenDisplay(cstr(display))
    win = w.x11_window()
    print("focus:", focus(w), w.input.focused)

    print("resize")
    XResizeWindow(d2, win, 400, 300)
    XSync(d2, 0)
    e, got := wait_for(w, EventResize)
    print(" event:", got, e.x, e.y, "size:", w.size())

    print("minimize (_NET_WM_STATE_HIDDEN)")
    hidden := XInternAtom(d2, ptr("_NET_WM_STATE_HIDDEN"), 0)
    fs := XInternAtom(d2, ptr("_NET_WM_STATE_FULLSCREEN"), 0)
    set_state([]u64{hidden})
    _, got = wait_for(w, EventMinimize)
    print(" minimized:", got, w.minimized, "size:", w.size())
    set_state([]u64{})
    _, got = wait_for(w, EventRestore)
    print(" restored:", got, w.minimized)

    print("minimize (unmapped)")
    XUnmapWindow(d2, win)
    XSync(d2, 0)
    _, got = wait_for(w, EventMinimize)
    print(" minimized:", got, w.minimized)
    XMapWindow(d2, win)
    XSync(d2, 0)
    _, got = wait_for(w, EventRestore)
    print(" restored:", got, w.minimized)
    print(" focus again:", focus(w))

    print("fullscreen set by the window manager")
    set_state([]u64{hidden, fs})
    _, got = wait_for(w, EventMinimize)
    print(" fullscreen:", w.fullscreen, "minimized:", got, w.minimized)
    set_state([]u64{})
    _, got = wait_for(w, EventRestore)
    print(" fullscreen:", w.fullscreen, "minimized:", w.minimized)

    print("locked pointer (raw motion)")
    XWarpPointer(d2, 0, win, 0, 0, 0, 0, 100, 80)
    XSync(d2, 0)
    deltas(w, 5)
    w.set_cursor_locked(true)
    print(" locked:", w.cursor_locked, "raw:", w.os.raw_on, "pos:", w.input.mouse_pos(), "delta:", deltas(w, 5), "grabbed:", grabbed_by_window(), "centred:", pointer_in_window())
    mouse(30, 10)
    print(" move:", deltas(w, 10), "pos:", w.input.mouse_pos(), "centred:", pointer_in_window())
    mouse(-50, -20)
    print(" move:", deltas(w, 10), "pos:", w.input.mouse_pos(), "centred:", pointer_in_window())
    for i in 0..100 {                                       // further than the screen is wide: no bound
        mouse(-70, -50)
    }
    print(" move:", deltas(w, 10), "pos:", w.input.mouse_pos())
    // a mouse that reports thousands of times between two polls: nothing is lost, one event
    for i in 0..3000 {
        XTestFakeRelativeMotionEvent(d2, 1, 0, 0)
        XTestFakeRelativeMotionEvent(d2, 0, -1, 0)
    }
    XSync(d2, 0)
    sleep_ms(50)
    w.poll()
    print(" fast:", w.input.mouse_delta() + deltas(w, 5), "events:", w.events.len <= 1, "dropped:", w.events.dropped)
    // pointer motion that is not the mouse's (another client warps the pointer) does not count
    XWarpPointer(d2, 0, win, 0, 0, 0, 0, 230, 160)
    XSync(d2, 0)
    print(" warped:", deltas(w, 10), "centred:", pointer_in_window())
    XSetInputFocus(d2, XRootWindow(d2, 0), X_REVERT_TO_PARENT, X_CURRENT_TIME)
    XSync(d2, 0)
    _, got = wait_for(w, EventUnfocus)
    mouse(9, 9)
    print(" unfocused:", got, "raw:", w.os.raw_on, "delta:", deltas(w, 5))
    print(" focus:", focus(w))
    deltas(w, 3)
    mouse(2, 3)
    print(" raw:", w.os.raw_on, "delta:", deltas(w, 5), "centred:", pointer_in_window())
    w.set_cursor_locked(false)
    print(" unlocked:", w.input.mouse_pos(), "delta:", deltas(w, 5), "pointer:", pointer_in_window())

    print("locked pointer (no XInput 2: pointer motion)")
    w.os.xi = -1
    w.set_cursor_locked(true)
    print(" locked:", w.cursor_locked, "raw:", w.os.raw_on, "pos:", w.input.mouse_pos(), "delta:", deltas(w, 5), "grabbed:", grabbed_by_window(), "centred:", pointer_in_window())
    XWarpPointer(d2, 0, win, 0, 0, 0, 0, 230, 160)          // centre + (30, 10)
    XSync(d2, 0)
    print(" move:", deltas(w, 10), "pos:", w.input.mouse_pos(), "centred:", pointer_in_window())
    XWarpPointer(d2, 0, win, 0, 0, 0, 0, 150, 130)          // centre - (50, 20)
    XSync(d2, 0)
    print(" move:", deltas(w, 10), "pos:", w.input.mouse_pos(), "centred:", pointer_in_window())
    XWarpPointer(d2, 0, win, 0, 0, 0, 0, 0, 0)              // as far as the window goes
    XSync(d2, 0)
    print(" move:", deltas(w, 10), "pos:", w.input.mouse_pos())
    XWarpPointer(d2, 0, win, 0, 0, 0, 0, 0, 0)              // and again: no bound
    XSync(d2, 0)
    print(" move:", deltas(w, 10), "pos:", w.input.mouse_pos())

    print("focus lost while locked")
    XSetInputFocus(d2, XRootWindow(d2, 0), X_REVERT_TO_PARENT, X_CURRENT_TIME)
    XSync(d2, 0)
    _, got = wait_for(w, EventUnfocus)
    print(" unfocused:", got, "grabbed:", grabbed_by_window(), "locked:", w.cursor_locked)
    print(" focus:", focus(w))
    deltas(w, 3)
    print(" grabbed again:", grabbed_by_window())

    print("unlocked")
    w.set_cursor_locked(false)
    print(" pos:", w.input.mouse_pos(), "delta:", deltas(w, 5), "grabbed:", grabbed_by_window(), "pointer:", pointer_in_window())

    w.close()
    w.set_cursor_locked(true)
    print("closed:", w.should_close(), w.cursor_locked)
    XCloseDisplay(d2)
}
