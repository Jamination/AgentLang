// std.input, Linux layer: gamepads are kernel joystick devices (/dev/input/js*), read with
// plain system calls. Loaded by `use std.input` for --target linux.

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
