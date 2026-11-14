// std.input, Linux layer: gamepads are kernel joystick devices (/dev/input/js*), read with
// plain system calls; hot-plugging is seen through inotify on /dev/input. Loaded by
// `use std.input` for --target linux.

// Opens gamepad number `index` (/dev/input/js<index>) without blocking; false if there is none.
fn gamepad_open(g: *Gamepad, index: i64) -> bool {
    gamepad_close(g)
    m := mark()
    fd := syscall(2, cstr(fmt("/dev/input/js", index)), 0x80800, 0)    // O_RDONLY | O_NONBLOCK | O_CLOEXEC
    release(m)
    if fd < 0 {
        return false
    }
    g.fd = fd
    g.connected = true
    true
}

// Reads all pending events of an open gamepad; false once it is disconnected. Call it after
// begin_frame (after the window's poll) every frame.
fn gamepad_poll(g: *Gamepad) -> bool {
    if !g.connected {
        return false
    }
    ev: [8]u8
    loop {
        r := syscall(0, g.fd, ptr(ev), 8)
        if r == -4 {
            continue
        }
        if r != 8 {
            if r != -11 {
                gamepad_close(g)
            }
            break
        }
        gamepad_event(g, ev[6], ev[7], i16(u16(ev[4]) | u16(ev[5]) << 8))
    }
    g.connected
}

// Closes the device and clears the state.
fn gamepad_close(g: *Gamepad) {
    if g.connected {
        syscall(3, g.fd)
    }
    *g = Gamepad{}
}

// True on the first call and whenever a joystick device (/dev/input/js*) appeared, vanished or
// changed its permissions since the last call: then (re)open the gamepads. Never blocks; the
// first call starts an inotify watch on /dev/input (one file descriptor, released by
// gamepad_watch_close). Without inotify it is true once a second instead.
fn gamepad_changed(w: *GamepadWatch) -> bool {
    if !w.started {
        w.started = true
        w.fd = -1
        fd := syscall(294, 0x80800)                                    // inotify_init1(IN_NONBLOCK | IN_CLOEXEC)
        if fd >= 0 {
            // IN_ATTRIB (udev sets the permissions after creating the node) | IN_MOVED_TO |
            // IN_CREATE | IN_DELETE
            if syscall(254, fd, ptr("/dev/input"), 0x384) >= 0 {
                w.fd = fd
            } else {
                syscall(3, fd)
            }
        }
        w.next_ns = clock_ns() + 1_000_000_000
        return true
    }
    if w.fd < 0 {
        now := clock_ns()
        if now < w.next_ns {
            return false
        }
        w.next_ns = now + 1_000_000_000
        return true
    }
    changed := false
    buf: [4096]u8
    loop {
        r := syscall(0, w.fd, ptr(buf), 4096)
        if r == -4 {
            continue
        }
        if r <= 0 {
            break
        }
        // struct inotify_event { i32 wd; u32 mask; u32 cookie; u32 len; char name[len] }
        pos := 0
        while pos + 16 <= r {
            mask := u32(buf[pos + 4]) | u32(buf[pos + 5]) << 8 | u32(buf[pos + 6]) << 16 | u32(buf[pos + 7]) << 24
            n := i64(u32(buf[pos + 12]) | u32(buf[pos + 13]) << 8 | u32(buf[pos + 14]) << 16 | u32(buf[pos + 15]) << 24)
            // IN_Q_OVERFLOW: events were lost; a name starting with "js": a joystick device
            if mask & 0x4000 != 0 || n >= 2 && buf[pos + 16] == 'j' && buf[pos + 17] == 's' {
                changed = true
            }
            pos += 16 + n
        }
    }
    changed
}

// Stops the watch of gamepad_changed (closes its file descriptor); the next gamepad_changed
// starts it again.
fn gamepad_watch_close(w: *GamepadWatch) {
    if w.started && w.fd >= 0 {
        syscall(3, w.fd)
    }
    *w = GamepadWatch{}
}
