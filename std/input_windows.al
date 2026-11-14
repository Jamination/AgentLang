// std.input, Windows layer: gamepads through XInput (xinput1_4.dll, else xinput9_1_0.dll),
// loaded at run time with LoadLibraryW, so a program that never opens a gamepad does not need
// the DLL. Loaded by `use std.input` for --target windows. The XInput state is translated into
// the Linux joystick numbering of an Xbox pad (PAD_*, PAD_AXIS_*), so games see the same
// buttons and axes on both systems.

priv extern "kernel32.dll" fn LoadLibraryW(name: *u16) -> *u8
priv extern "kernel32.dll" fn GetProcAddress(module: *u8, name: *u8) -> *u8

// XINPUT_STATE: packet number + XINPUT_GAMEPAD (16 bytes)
priv struct XInputState {
    packet: u32
    buttons: u16
    left_trigger: u8
    right_trigger: u8
    lx: i16
    ly: i16
    rx: i16
    ry: i16
}

// XInputGetStateEx (ordinal 100: also reports the guide button) or XInputGetState
priv xinput_proc: *u8
priv xinput_tried: bool

// XINPUT_GAMEPAD button bits in PAD_* order (0x0400: guide, XInputGetStateEx only)
priv const XINPUT_PAD_BITS = [11]u16{0x1000, 0x2000, 0x4000, 0x8000, 0x0100, 0x0200, 0x0020, 0x0010, 0x0400, 0x0040, 0x0080}

priv fn xinput_load() -> bool {
    if xinput_tried {
        return xinput_proc != nil
    }
    xinput_tried = true
    names := [2]str{"xinput1_4.dll", "xinput9_1_0.dll"}
    for name in names {
        wname: [32]u16
        for i in 0..len(name) {
            wname[i] = u16(name[i])
        }
        h := LoadLibraryW(ptr(wname))
        if h == nil {
            continue
        }
        p := GetProcAddress(h, cast[*u8](u64(100)))
        if p == nil {
            p = GetProcAddress(h, ptr("XInputGetState"))
        }
        if p != nil {
            xinput_proc = p
            return true
        }
    }
    false
}

// XInputGetState of controller `index`: 0 if it is connected
priv fn xinput_get(index: i64, s: *XInputState) -> u32 {
    cast[fn(u32, *XInputState) -> u32](xinput_proc)(u32(index), s)
}

priv fn xinput_axis(v: i64) -> i16 {
    i16(min(max(v, -32767), 32767))
}

// Applies one XInput state: button changes as joystick button events (kind 1, or 0x81 for
// the initial state), every axis as an axis event (kind 2 / 0x82).
priv fn xinput_apply(g: *Gamepad, s: *XInputState, initial: bool) {
    init: u8 = if initial { 0x80 } else { 0 }
    for n in 0..len(XINPUT_PAD_BITS) {
        down := s.buttons & XINPUT_PAD_BITS[n] != 0
        if initial || down != (g.buttons[n] & INPUT_DOWN != 0) {
            gamepad_event(g, 1 | init, u8(n), if down { 1 } else { 0 })
        }
    }
    b := s.buttons
    dx := (if b & 0x8 != 0 { 32767 } else { 0 }) - (if b & 0x4 != 0 { 32767 } else { 0 })
    dy := (if b & 0x2 != 0 { 32767 } else { 0 }) - (if b & 0x1 != 0 { 32767 } else { 0 })
    // as on Linux: sticks right / down positive, triggers -1 (released) .. 1
    axes := [PAD_AXIS_COUNT]i64{
        i64(s.lx), -i64(s.ly), i64(s.left_trigger) * 65534 / 255 - 32767,
        i64(s.rx), -i64(s.ry), i64(s.right_trigger) * 65534 / 255 - 32767, dx, dy
    }
    for n in 0..PAD_AXIS_COUNT {
        gamepad_event(g, 2 | init, u8(n), xinput_axis(axes[n]))
    }
}

// Applies one XInput controller state (the fields of XINPUT_GAMEPAD) as gamepad_poll does:
// pressed / released edges for changed buttons, all axes (useful for tests and replays).
fn gamepad_xinput(g: *Gamepad, buttons: u16, left_trigger: u8, right_trigger: u8, lx: i16, ly: i16, rx: i16, ry: i16) {
    s := XInputState{0, buttons, left_trigger, right_trigger, lx, ly, rx, ry}
    xinput_apply(g, &s, false)
}

// Opens XInput controller number `index` (0..3); false if it is not connected or XInput is
// not available. The current state counts as the initial state (no pressed edges).
fn gamepad_open(g: *Gamepad, index: i64) -> bool {
    gamepad_close(g)
    if index < 0 || index > 3 || !xinput_load() {
        return false
    }
    s: XInputState
    if xinput_get(index, &s) != 0 {
        return false
    }
    g.fd = index
    g.connected = true
    xinput_apply(g, &s, true)
    true
}

// Reads the controller's current state; false once it is disconnected. Call it after
// begin_frame (after the window's poll) every frame.
fn gamepad_poll(g: *Gamepad) -> bool {
    if !g.connected {
        return false
    }
    s: XInputState
    if xinput_get(g.fd, &s) != 0 {
        gamepad_close(g)
        return false
    }
    xinput_apply(g, &s, false)
    true
}

// Forgets the controller and clears the state.
fn gamepad_close(g: *Gamepad) {
    *g = Gamepad{}
}

// True on the first call and then at most once a second (XInput reports no plugging, and
// asking for absent controllers is slow): then try gamepad_open for the controllers that are
// not connected. Never blocks.
fn gamepad_changed(w: *GamepadWatch) -> bool {
    now := clock_ns()
    if w.started && now < w.next_ns {
        return false
    }
    w.started = true
    w.next_ns = now + 1_000_000_000
    true
}

// Resets the watch of gamepad_changed (nothing to release on Windows).
fn gamepad_watch_close(w: *GamepadWatch) {
    *w = GamepadWatch{}
}
