// std.input: platform-independent input state. A window (std.window) or a test feeds `Event`s
// into an `Input`; the game reads per-frame key / mouse / text state from it and maps keys to
// game actions with an `ActionMap`. Nothing here allocates per frame.

// ---- key codes (dense, independent of the platform's key symbols) ----
const KEY_UNKNOWN = 0
const KEY_A = 1
const KEY_B = 2
const KEY_C = 3
const KEY_D = 4
const KEY_E = 5
const KEY_F = 6
const KEY_G = 7
const KEY_H = 8
const KEY_I = 9
const KEY_J = 10
const KEY_K = 11
const KEY_L = 12
const KEY_M = 13
const KEY_N = 14
const KEY_O = 15
const KEY_P = 16
const KEY_Q = 17
const KEY_R = 18
const KEY_S = 19
const KEY_T = 20
const KEY_U = 21
const KEY_V = 22
const KEY_W = 23
const KEY_X = 24
const KEY_Y = 25
const KEY_Z = 26
const KEY_0 = 27
const KEY_1 = 28
const KEY_2 = 29
const KEY_3 = 30
const KEY_4 = 31
const KEY_5 = 32
const KEY_6 = 33
const KEY_7 = 34
const KEY_8 = 35
const KEY_9 = 36
const KEY_SPACE = 37
const KEY_ESCAPE = 38
const KEY_ENTER = 39
const KEY_TAB = 40
const KEY_BACKSPACE = 41
const KEY_INSERT = 42
const KEY_DELETE = 43
const KEY_HOME = 44
const KEY_END = 45
const KEY_PAGE_UP = 46
const KEY_PAGE_DOWN = 47
const KEY_LEFT = 48
const KEY_RIGHT = 49
const KEY_UP = 50
const KEY_DOWN = 51
const KEY_LSHIFT = 52
const KEY_RSHIFT = 53
const KEY_LCTRL = 54
const KEY_RCTRL = 55
const KEY_LALT = 56
const KEY_RALT = 57
const KEY_LSUPER = 58
const KEY_RSUPER = 59
const KEY_CAPS_LOCK = 60
const KEY_F1 = 61
const KEY_F2 = 62
const KEY_F3 = 63
const KEY_F4 = 64
const KEY_F5 = 65
const KEY_F6 = 66
const KEY_F7 = 67
const KEY_F8 = 68
const KEY_F9 = 69
const KEY_F10 = 70
const KEY_F11 = 71
const KEY_F12 = 72
const KEY_MINUS = 73
const KEY_EQUAL = 74
const KEY_LBRACKET = 75
const KEY_RBRACKET = 76
const KEY_BACKSLASH = 77
const KEY_SEMICOLON = 78
const KEY_APOSTROPHE = 79
const KEY_GRAVE = 80
const KEY_COMMA = 81
const KEY_PERIOD = 82
const KEY_SLASH = 83
const KEY_KP_0 = 84
const KEY_KP_1 = 85
const KEY_KP_2 = 86
const KEY_KP_3 = 87
const KEY_KP_4 = 88
const KEY_KP_5 = 89
const KEY_KP_6 = 90
const KEY_KP_7 = 91
const KEY_KP_8 = 92
const KEY_KP_9 = 93
const KEY_KP_ADD = 94
const KEY_KP_SUBTRACT = 95
const KEY_KP_MULTIPLY = 96
const KEY_KP_DIVIDE = 97
const KEY_KP_ENTER = 98
const KEY_KP_DECIMAL = 99
const KEY_PRINT_SCREEN = 100
const KEY_SCROLL_LOCK = 101
const KEY_PAUSE = 102
const KEY_NUM_LOCK = 103
const KEY_MENU = 104
const KEY_COUNT = 105

// ---- mouse buttons ----
const MOUSE_LEFT = 0
const MOUSE_RIGHT = 1
const MOUSE_MIDDLE = 2
const MOUSE_X1 = 3
const MOUSE_X2 = 4
const MOUSE_BUTTON_COUNT = 5

// ---- modifier bits in Event.mods ----
const MOD_SHIFT u8 = 1
const MOD_CTRL u8 = 2
const MOD_ALT u8 = 4
const MOD_SUPER u8 = 8

// ---- gamepad buttons and axes (Linux joystick numbering of an Xbox-style pad) ----
const PAD_A = 0
const PAD_B = 1
const PAD_X = 2
const PAD_Y = 3
const PAD_LB = 4
const PAD_RB = 5
const PAD_BACK = 6
const PAD_START = 7
const PAD_GUIDE = 8
const PAD_LSTICK = 9
const PAD_RSTICK = 10
const PAD_BUTTON_COUNT = 16
const PAD_AXIS_LX = 0
const PAD_AXIS_LY = 1
const PAD_AXIS_LT = 2
const PAD_AXIS_RX = 3
const PAD_AXIS_RY = 4
const PAD_AXIS_RT = 5
const PAD_AXIS_DPAD_X = 6
const PAD_AXIS_DPAD_Y = 7
const PAD_AXIS_COUNT = 8

// state bits of one key or button
const INPUT_DOWN u8 = 1
const INPUT_PRESSED u8 = 2
const INPUT_RELEASED u8 = 4
const INPUT_REPEATED u8 = 8

// most code points of text input kept per frame
const INPUT_TEXT_MAX = 32
// capacity of an EventQueue
const EVENT_QUEUE_CAP = 256

// ---- events ----

// What happened. `Event` fields used: EventResize x, y = new size; EventKeyDown / EventKeyUp
// key, repeat, mods; EventText codepoint; EventMouseMove x, y; EventMouseDown / EventMouseUp
// key = MOUSE_* button, x, y, mods; EventWheel x, y = scroll steps (y > 0: away from the user).
enum EventKind {
    EventNone, EventClose, EventResize, EventFocus, EventUnfocus, EventKeyDown, EventKeyUp,
    EventText, EventMouseMove, EventMouseDown, EventMouseUp, EventWheel
}

// One window or input event (plain data).
struct Event {
    kind EventKind
    key i64
    x i64
    y i64
    codepoint u32
    mods u8
    repeat bool
}

// Fixed-capacity FIFO of events; when full, new events are counted in `dropped` and discarded.
struct EventQueue {
    items [EVENT_QUEUE_CAP]Event
    head i64
    len i64
    dropped i64
}

// Appends an event; false (and `dropped` grows) when the queue is full.
fn push_event(q *EventQueue, e Event) bool {
    if q.len == EVENT_QUEUE_CAP {
        q.dropped += 1
        return false
    }
    q.items[(q.head + q.len) % EVENT_QUEUE_CAP] = e
    q.len += 1
    true
}

// Removes and returns the oldest event; false when the queue is empty.
fn next_event(q *EventQueue) (Event, bool) {
    if q.len == 0 {
        return (Event{}, false)
    }
    e := q.items[q.head]
    q.head = (q.head + 1) % EVENT_QUEUE_CAP
    q.len -= 1
    (e, true)
}

// Empties the queue (the `dropped` counter is kept).
fn clear_events(q *EventQueue) {
    q.head = 0
    q.len = 0
}

// ---- gamepad state ----

// One gamepad: button state bits and axes in -1..1. Zero value = not connected.
struct Gamepad {
    fd i64
    connected bool
    buttons [PAD_BUTTON_COUNT]u8
    axes [PAD_AXIS_COUNT]f32
}

// ---- input state ----

// Keyboard, mouse, text and (optionally) one gamepad for the current frame. Zero value is valid.
struct Input {
    keys [KEY_COUNT]u8
    buttons [MOUSE_BUTTON_COUNT]u8
    mouse_x f32
    mouse_y f32
    mouse_dx f32
    mouse_dy f32
    wheel_x f32
    wheel_y f32
    mouse_seen bool
    focused bool
    text [INPUT_TEXT_MAX]u32
    text_len i64
    pad Gamepad
}

// Starts a new frame: forgets pressed/released edges, mouse delta, wheel and text of the last one.
fn begin_frame(i *Input) {
    for k in 0..KEY_COUNT {
        i.keys[k] &= INPUT_DOWN
    }
    for b in 0..MOUSE_BUTTON_COUNT {
        i.buttons[b] &= INPUT_DOWN
    }
    for b in 0..PAD_BUTTON_COUNT {
        i.pad.buttons[b] &= INPUT_DOWN
    }
    i.mouse_dx = 0.0
    i.mouse_dy = 0.0
    i.wheel_x = 0.0
    i.wheel_y = 0.0
    i.text_len = 0
}

fn input_press(state u8, repeat bool) u8 {
    if state & INPUT_DOWN != 0 || repeat {
        return state | INPUT_DOWN | INPUT_REPEATED
    }
    state | INPUT_DOWN | INPUT_PRESSED
}

fn input_release(state u8) u8 {
    if state & INPUT_DOWN == 0 {
        return state
    }
    state & INPUT_PRESSED | INPUT_RELEASED
}

fn input_mouse_to(i *Input, x i64, y i64) {
    fx := f32(x)
    fy := f32(y)
    if i.mouse_seen {
        i.mouse_dx += fx - i.mouse_x
        i.mouse_dy += fy - i.mouse_y
    }
    i.mouse_seen = true
    i.mouse_x = fx
    i.mouse_y = fy
}

// Applies one event to the state (the window does this for every event it receives).
fn feed(i *Input, e Event) {
    match e.kind {
        EventKeyDown => {
            if e.key > 0 && e.key < KEY_COUNT {
                i.keys[e.key] = input_press(i.keys[e.key], e.repeat)
            }
        }
        EventKeyUp => {
            if e.key > 0 && e.key < KEY_COUNT {
                i.keys[e.key] = input_release(i.keys[e.key])
            }
        }
        EventText => {
            if i.text_len < INPUT_TEXT_MAX {
                i.text[i.text_len] = e.codepoint
                i.text_len += 1
            }
        }
        EventMouseMove => input_mouse_to(i, e.x, e.y)
        EventMouseDown => {
            input_mouse_to(i, e.x, e.y)
            if e.key >= 0 && e.key < MOUSE_BUTTON_COUNT {
                i.buttons[e.key] = input_press(i.buttons[e.key], false)
            }
        }
        EventMouseUp => {
            input_mouse_to(i, e.x, e.y)
            if e.key >= 0 && e.key < MOUSE_BUTTON_COUNT {
                i.buttons[e.key] = input_release(i.buttons[e.key])
            }
        }
        EventWheel => {
            i.wheel_x += f32(e.x)
            i.wheel_y += f32(e.y)
        }
        EventFocus => i.focused = true
        EventUnfocus => {
            i.focused = false
            release_all(i)
        }
        _ => {}
    }
}

// Releases every held key and mouse button (done automatically when the window loses focus).
fn release_all(i *Input) {
    for k in 0..KEY_COUNT {
        i.keys[k] = input_release(i.keys[k])
    }
    for b in 0..MOUSE_BUTTON_COUNT {
        i.buttons[b] = input_release(i.buttons[b])
    }
}

fn input_key_state(i *Input, key i64) u8 {
    if key <= 0 || key >= KEY_COUNT {
        return 0
    }
    i.keys[key]
}

fn input_button_state(i *Input, button i64) u8 {
    if button < 0 || button >= MOUSE_BUTTON_COUNT {
        return 0
    }
    i.buttons[button]
}

// True while the key is held.
fn key_down(i *Input, key i64) bool { input_key_state(i, key) & INPUT_DOWN != 0 }

// True in the frame the key went down (also when it was released again in the same frame).
fn key_pressed(i *Input, key i64) bool { input_key_state(i, key) & INPUT_PRESSED != 0 }

// True in the frame the key went up.
fn key_released(i *Input, key i64) bool { input_key_state(i, key) & INPUT_RELEASED != 0 }

// True in frames where the held key auto-repeated (for text-like navigation).
fn key_repeated(i *Input, key i64) bool { input_key_state(i, key) & INPUT_REPEATED != 0 }

// True while either shift key is held.
fn shift_down(i *Input) bool { key_down(i, KEY_LSHIFT) || key_down(i, KEY_RSHIFT) }

// True while either control key is held.
fn ctrl_down(i *Input) bool { key_down(i, KEY_LCTRL) || key_down(i, KEY_RCTRL) }

// True while either alt key is held.
fn alt_down(i *Input) bool { key_down(i, KEY_LALT) || key_down(i, KEY_RALT) }

// True while the mouse button (MOUSE_*) is held.
fn mouse_down(i *Input, button i64) bool { input_button_state(i, button) & INPUT_DOWN != 0 }

// True in the frame the mouse button went down.
fn mouse_pressed(i *Input, button i64) bool { input_button_state(i, button) & INPUT_PRESSED != 0 }

// True in the frame the mouse button went up.
fn mouse_released(i *Input, button i64) bool { input_button_state(i, button) & INPUT_RELEASED != 0 }

// Pointer position in window pixels (origin top-left).
fn mouse_pos(i *Input) vec2 { vec2(i.mouse_x, i.mouse_y) }

// Pointer movement during this frame.
fn mouse_delta(i *Input) vec2 { vec2(i.mouse_dx, i.mouse_dy) }

// Wheel steps during this frame (x: horizontal, y > 0: away from the user).
fn wheel(i *Input) vec2 { vec2(i.wheel_x, i.wheel_y) }

// Unicode code points typed during this frame (a view into the Input, valid until begin_frame).
fn text(i *Input) []u32 { i.text[..i.text_len] }

// The frame's typed text encoded as UTF-8 into `buf`; returns the used part of `buf`.
fn text_utf8(i *Input, buf []u8) str {
    n := 0
    for k in 0..i.text_len {
        c := i.text[k]
        need := if c < 0x80 { 1 } else if c < 0x800 { 2 } else if c < 0x10000 { 3 } else { 4 }
        if n + need > len(buf) {
            break
        }
        if need == 1 {
            buf[n] = u8(c)
        } else if need == 2 {
            buf[n] = u8(0xC0 | c >> 6)
            buf[n + 1] = u8(0x80 | c & 0x3F)
        } else if need == 3 {
            buf[n] = u8(0xE0 | c >> 12)
            buf[n + 1] = u8(0x80 | c >> 6 & 0x3F)
            buf[n + 2] = u8(0x80 | c & 0x3F)
        } else {
            buf[n] = u8(0xF0 | c >> 18)
            buf[n + 1] = u8(0x80 | c >> 12 & 0x3F)
            buf[n + 2] = u8(0x80 | c >> 6 & 0x3F)
            buf[n + 3] = u8(0x80 | c & 0x3F)
        }
        n += need
    }
    buf[..n]
}

// ---- key names (for configuration files and binding menus) ----

var input_key_names = [KEY_COUNT]str{
    "Unknown", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q",
    "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    "Space", "Escape", "Enter", "Tab", "Backspace", "Insert", "Delete", "Home", "End", "PageUp",
    "PageDown", "Left", "Right", "Up", "Down", "LShift", "RShift", "LCtrl", "RCtrl", "LAlt",
    "RAlt", "LSuper", "RSuper", "CapsLock", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9",
    "F10", "F11", "F12", "Minus", "Equal", "LBracket", "RBracket", "Backslash", "Semicolon",
    "Apostrophe", "Grave", "Comma", "Period", "Slash", "Kp0", "Kp1", "Kp2", "Kp3", "Kp4", "Kp5",
    "Kp6", "Kp7", "Kp8", "Kp9", "KpAdd", "KpSubtract", "KpMultiply", "KpDivide", "KpEnter",
    "KpDecimal", "PrintScreen", "ScrollLock", "Pause", "NumLock", "Menu"
}

// Name of a key code ("A", "Space", "LShift", ...); "Unknown" for anything else.
fn key_name(key i64) str {
    if key < 0 || key >= KEY_COUNT {
        return input_key_names[0]
    }
    input_key_names[key]
}

// Key code for a name as returned by key_name (letter case ignored); KEY_UNKNOWN if none.
fn key_from_name(name str) i64 {
    for k in 1..KEY_COUNT {
        kn := input_key_names[k]
        if len(kn) != len(name) {
            continue
        }
        same := true
        for j in 0..len(kn) {
            if kn[j] | 0x20 != name[j] | 0x20 {
                same = false
                break
            }
        }
        if same {
            return k
        }
    }
    KEY_UNKNOWN
}

// ---- gamepad (Linux joystick devices /dev/input/js*) ----

// Opens gamepad number `index` (/dev/input/js<index>) without blocking; false if there is none.
fn gamepad_open(g *Gamepad, index i64) bool {
    gamepad_close(g)
    m := mark()
    fd := syscall(2, cstr(fmt("/dev/input/js", index)), 0x800, 0)
    release(m)
    if fd < 0 {
        return false
    }
    g.fd = fd
    g.connected = true
    true
}

// Applies one raw joystick event (kind 1 = button, 2 = axis; bit 0x80 marks initial state).
fn gamepad_event(g *Gamepad, kind u8, number u8, value i16) {
    n := i64(number)
    if kind & 0x7F == 1 && n < PAD_BUTTON_COUNT {
        if value != 0 {
            g.buttons[n] = if kind & 0x80 != 0 { INPUT_DOWN } else { input_press(g.buttons[n], false) }
        } else {
            g.buttons[n] = input_release(g.buttons[n])
        }
    } else if kind & 0x7F == 2 && n < PAD_AXIS_COUNT {
        g.axes[n] = fmax(f32(value) / 32767.0, -1.0)
    }
}

// Reads all pending events of an open gamepad; false once it is disconnected. Call it after
// begin_frame (after the window's poll) every frame.
fn gamepad_poll(g *Gamepad) bool {
    if !g.connected {
        return false
    }
    var ev [8]u8
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
fn gamepad_close(g *Gamepad) {
    if g.connected {
        syscall(3, g.fd)
    }
    *g = Gamepad{}
}

fn input_pad_state(g *Gamepad, button i64) u8 {
    if button < 0 || button >= PAD_BUTTON_COUNT {
        return 0
    }
    g.buttons[button]
}

// True while the gamepad button is held.
fn pad_down(g *Gamepad, button i64) bool { input_pad_state(g, button) & INPUT_DOWN != 0 }

// True in the frame the gamepad button went down.
fn pad_pressed(g *Gamepad, button i64) bool { input_pad_state(g, button) & INPUT_PRESSED != 0 }

// True in the frame the gamepad button went up.
fn pad_released(g *Gamepad, button i64) bool { input_pad_state(g, button) & INPUT_RELEASED != 0 }

// Axis value in -1..1 (0 for an unknown axis); sticks: right / down are positive.
fn pad_axis(g *Gamepad, axis i64) f32 {
    if axis < 0 || axis >= PAD_AXIS_COUNT {
        return 0.0
    }
    g.axes[axis]
}

// Two axes as a stick vector with a radial dead zone: 0 inside `deadzone`, rescaled to reach
// length 1 at full deflection.
fn pad_stick(g *Gamepad, axis_x i64, axis_y i64, deadzone f32) vec2 {
    v := vec2(pad_axis(g, axis_x), pad_axis(g, axis_y))
    l := sqrt(v.x * v.x + v.y * v.y)
    if l <= deadzone || l == 0.0 {
        return vec2(0.0)
    }
    v * (fmin((l - deadzone) / (1.0 - deadzone), 1.0) / l)
}

// ---- action mapping ----

// where a binding reads its state from
const BIND_KEY = 0
const BIND_MOUSE = 1
const BIND_PAD = 2

// One input source bound to an action.
struct Binding {
    action i64
    source i64
    code i64
}

// Maps game actions (small integers, optionally named) to any number of keys, mouse buttons
// and gamepad buttons, so game code asks for "jump" instead of KEY_SPACE.
struct ActionMap {
    binds Vec[Binding]
    names Vec[str]
}

// An empty action map. Binding and naming allocate; queries do not.
fn action_map() ActionMap {
    ActionMap{binds: vec[Binding](), names: vec[str]()}
}

// The action id for a name, registering the name on first use (ids count up from 0).
fn action(m *ActionMap, name str) i64 {
    for k in 0..m.names.len {
        if m.names.buf[k] == name {
            return k
        }
    }
    m.names.push(name)
    m.names.len - 1
}

// The name registered for an action id ("" if it has none).
fn action_name(m *ActionMap, action i64) str {
    if action < 0 || action >= m.names.len {
        return ""
    }
    m.names.buf[action]
}

// Adds a binding from an input source (BIND_KEY / BIND_MOUSE / BIND_PAD) and its code.
fn bind(m *ActionMap, action i64, source i64, code i64) {
    m.binds.push(Binding{action, source, code})
}

// Binds a keyboard key (KEY_*) to the action.
fn bind_key(m *ActionMap, action i64, key i64) { bind(m, action, BIND_KEY, key) }

// Binds a mouse button (MOUSE_*) to the action.
fn bind_mouse(m *ActionMap, action i64, button i64) { bind(m, action, BIND_MOUSE, button) }

// Binds a gamepad button (PAD_*) to the action.
fn bind_pad(m *ActionMap, action i64, button i64) { bind(m, action, BIND_PAD, button) }

// Removes every binding of the action.
fn unbind(m *ActionMap, action i64) {
    n := 0
    for k in 0..m.binds.len {
        if m.binds.buf[k].action != action {
            m.binds.buf[n] = m.binds.buf[k]
            n += 1
        }
    }
    m.binds.len = n
}

fn input_action_bits(m *ActionMap, i *Input, action i64) u8 {
    var bits u8 = 0
    for k in 0..m.binds.len {
        b := m.binds.buf[k]
        if b.action != action {
            continue
        }
        bits |= match b.source {
            BIND_KEY => input_key_state(i, b.code)
            BIND_MOUSE => input_button_state(i, b.code)
            _ => input_pad_state(&i.pad, b.code)
        }
    }
    bits
}

// True while any input bound to the action is held.
fn action_down(m *ActionMap, i *Input, action i64) bool {
    input_action_bits(m, i, action) & INPUT_DOWN != 0
}

// True in the frame any input bound to the action went down.
fn action_pressed(m *ActionMap, i *Input, action i64) bool {
    input_action_bits(m, i, action) & INPUT_PRESSED != 0
}

// True in the frame an input bound to the action went up and none of them is held any more.
fn action_released(m *ActionMap, i *Input, action i64) bool {
    input_action_bits(m, i, action) & (INPUT_RELEASED | INPUT_DOWN) == INPUT_RELEASED
}

// -1, 0 or +1 from a pair of actions (both or neither held: 0).
fn action_axis(m *ActionMap, i *Input, negative i64, positive i64) f32 {
    var v f32 = 0.0
    if action_down(m, i, positive) {
        v += 1.0
    }
    if action_down(m, i, negative) {
        v -= 1.0
    }
    v
}

// A direction from four actions as (x, y) with length 0 or 1 (diagonals are normalized).
fn action_vec2(m *ActionMap, i *Input, left i64, right i64, down i64, up i64) vec2 {
    v := vec2(action_axis(m, i, left, right), action_axis(m, i, down, up))
    if v.x != 0.0 && v.y != 0.0 {
        return v * 0.70710678
    }
    v
}
