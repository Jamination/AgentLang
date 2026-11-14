# std.input: input state, events and action mapping

`use std.input` provides the platform-independent half of input handling:

- `Event` / `EventQueue`: window and input events as plain data,
- `Input`: the keyboard, mouse, text and gamepad state of the current frame, driven by events,
- `ActionMap`: bindings from game actions to keys and buttons, so game code never names a key,
- `Gamepad`: one game controller: Linux joystick devices (`/dev/input/js*`), XInput on
  Windows.

Everything except the gamepad device is pure AL and the same on Linux and Windows; the device
functions (`gamepad_open`, `gamepad_poll`, `gamepad_close`) are in the module's OS layer
(`std/input_linux.al`: plain system calls, so programs stay static executables;
`std/input_windows.al`: XInput). Everything except opening a gamepad device is testable by
feeding events by hand. `std.window` includes this module, owns an `Input` and an
`EventQueue` per window and fills both in `poll`.

No function here allocates per frame. `action_map`, `action` and the `bind` functions allocate
(set-up time); `gamepad_open` allocates temporarily and releases it again.

## The frame protocol

```
begin_frame(&inp)        // forget last frame's edges, mouse delta, wheel and text
feed(&inp, event) ...    // apply this frame's events
key_pressed(&inp, ...)   // query
```

`poll(window)` does the first two steps. "Pressed" and "released" are *edges*: true only in
the frame in which the event arrived. A key that goes down and up within one frame reports
`key_pressed` and `key_released` in that frame and `key_down` false, so quick taps are never
lost. When the window loses focus (`EventUnfocus`) every held key and button is released, so
nothing stays stuck.

If the simulation runs in fixed steps (several or zero steps per rendered frame), read edges
once per frame and latch them until a step consumes them; see the game loop in
[window.md](window.md).

## Constants

| Group | Values |
|-------|--------|
| Key codes | `KEY_UNKNOWN` (0), `KEY_A` .. `KEY_Z`, `KEY_0` .. `KEY_9`, `KEY_SPACE`, `KEY_ESCAPE`, `KEY_ENTER`, `KEY_TAB`, `KEY_BACKSPACE`, `KEY_INSERT`, `KEY_DELETE`, `KEY_HOME`, `KEY_END`, `KEY_PAGE_UP`, `KEY_PAGE_DOWN`, `KEY_LEFT`, `KEY_RIGHT`, `KEY_UP`, `KEY_DOWN`, `KEY_LSHIFT`, `KEY_RSHIFT`, `KEY_LCTRL`, `KEY_RCTRL`, `KEY_LALT`, `KEY_RALT`, `KEY_LSUPER`, `KEY_RSUPER`, `KEY_CAPS_LOCK`, `KEY_F1` .. `KEY_F12`, `KEY_MINUS`, `KEY_EQUAL`, `KEY_LBRACKET`, `KEY_RBRACKET`, `KEY_BACKSLASH`, `KEY_SEMICOLON`, `KEY_APOSTROPHE`, `KEY_GRAVE`, `KEY_COMMA`, `KEY_PERIOD`, `KEY_SLASH`, `KEY_KP_0` .. `KEY_KP_9`, `KEY_KP_ADD`, `KEY_KP_SUBTRACT`, `KEY_KP_MULTIPLY`, `KEY_KP_DIVIDE`, `KEY_KP_ENTER`, `KEY_KP_DECIMAL`, `KEY_PRINT_SCREEN`, `KEY_SCROLL_LOCK`, `KEY_PAUSE`, `KEY_NUM_LOCK`, `KEY_MENU`; `KEY_COUNT` is one more than the largest code |
| Mouse buttons | `MOUSE_LEFT`, `MOUSE_RIGHT`, `MOUSE_MIDDLE`, `MOUSE_X1`, `MOUSE_X2`; `MOUSE_BUTTON_COUNT` |
| Modifier bits (`Event.mods`) | `MOD_SHIFT`, `MOD_CTRL`, `MOD_ALT`, `MOD_SUPER` |
| Gamepad buttons | `PAD_A`, `PAD_B`, `PAD_X`, `PAD_Y`, `PAD_LB`, `PAD_RB`, `PAD_BACK`, `PAD_START`, `PAD_GUIDE`, `PAD_LSTICK`, `PAD_RSTICK`; `PAD_BUTTON_COUNT` (16) |
| Gamepad axes | `PAD_AXIS_LX`, `PAD_AXIS_LY`, `PAD_AXIS_LT`, `PAD_AXIS_RX`, `PAD_AXIS_RY`, `PAD_AXIS_RT`, `PAD_AXIS_DPAD_X`, `PAD_AXIS_DPAD_Y`; `PAD_AXIS_COUNT` (8) |
| State bits | `INPUT_DOWN`, `INPUT_PRESSED`, `INPUT_RELEASED`, `INPUT_REPEATED` (the bytes in `Input.keys`, `Input.buttons`, `Gamepad.buttons`) |
| Binding sources | `BIND_KEY`, `BIND_MOUSE`, `BIND_PAD` |
| Capacities | `INPUT_TEXT_MAX` (32 code points of text per frame), `EVENT_QUEUE_CAP` (256 events) |

Key codes are dense small integers, the same on every platform; they name the key by its
unshifted US-layout meaning on the user's layout (the key that types `a` is `KEY_A`). The
letters and digits are consecutive: `KEY_A + 3 == KEY_D`, `KEY_0 + 7 == KEY_7`.

## Events

```
enum EventKind { EventNone, EventClose, EventResize, EventFocus, EventUnfocus, EventKeyDown,
                 EventKeyUp, EventText, EventMouseMove, EventMouseDown, EventMouseUp, EventWheel }
struct Event { kind: EventKind, key: i64, x: i64, y: i64, codepoint: u32, mods: u8, repeat: bool }
```

| Kind | Fields |
|------|--------|
| `EventClose` | the user asked to close the window |
| `EventResize` | `x`, `y`: new width and height |
| `EventFocus`, `EventUnfocus` | keyboard focus gained / lost |
| `EventKeyDown`, `EventKeyUp` | `key`: `KEY_*`; `repeat`: auto-repeat of a held key; `mods` |
| `EventText` | `codepoint`: one Unicode character typed (layout, shift, dead keys applied) |
| `EventMouseMove` | `x`, `y`: pointer position in window pixels |
| `EventMouseDown`, `EventMouseUp` | `key`: `MOUSE_*`; `x`, `y`; `mods` |
| `EventWheel` | `x`, `y`: scroll steps (`y > 0`: away from the user) |

| Function | |
|----------|---|
| `push_event(q: *EventQueue, e: Event) -> bool` | append; false and `q.dropped += 1` when full |
| `next_event(q: *EventQueue) -> (Event, bool)` | remove the oldest; false when empty |
| `clear_events(q: *EventQueue)` | empty the queue |

`EventQueue` is a fixed ring buffer (`items`, `head`, `len`, `dropped`) of about 10 KB; keep
it in a struct or allocate it with `new[EventQueue]()` rather than passing it by value.

## Input

`struct Input` (zero value is ready to use) has public fields `keys`, `buttons` (state bits
per key / mouse button), `mouse_x/y`, `mouse_dx/dy`, `wheel_x/y`, `focused`, `text`,
`text_len` and `pad` (a `Gamepad`). Usually it is read through:

| Function | |
|----------|---|
| `begin_frame(i: *Input)` | start a new frame |
| `feed(i: *Input, e: Event)` | apply one event |
| `release_all(i: *Input)` | release every held key and mouse button |
| `key_down(i, key) -> bool` | the key is held |
| `key_pressed(i, key) -> bool` | it went down this frame |
| `key_released(i, key) -> bool` | it went up this frame |
| `key_repeated(i, key) -> bool` | it auto-repeated this frame |
| `shift_down(i)`, `ctrl_down(i)`, `alt_down(i)` | either of the two modifier keys is held |
| `mouse_down(i, button)`, `mouse_pressed(i, button)`, `mouse_released(i, button)` | the same for `MOUSE_*` buttons |
| `mouse_pos(i) -> vec2` | pointer position in window pixels |
| `mouse_delta(i) -> vec2` | pointer movement during this frame |
| `wheel(i) -> vec2` | wheel steps during this frame |
| `text(i) -> []u32` | code points typed this frame (view, valid until `begin_frame`) |
| `text_utf8(i, buf: []u8) -> str` | the same as UTF-8 written into `buf`; returns the used part |
| `key_name(key) -> str` | `"A"`, `"Space"`, `"LShift"`, `"Kp7"`, ...; `"Unknown"` otherwise |
| `key_from_name(name) -> i64` | inverse of `key_name`, ignoring letter case; `KEY_UNKNOWN` if none |

Unknown key or button numbers are never an error: queries return false, events are ignored.

## ActionMap

An action is a small integer the game defines (`const ACT_JUMP = 4`). Any number of keys,
mouse buttons and gamepad buttons can be bound to it; the game asks only about actions, and
rebinding is a data change.

| Function | |
|----------|---|
| `action_map() -> ActionMap` | an empty map |
| `action(m, name: str) -> i64` | id of a named action; registers the name on first use (ids count from 0 in registration order) |
| `action_name(m, action) -> str` | the registered name, `""` if none |
| `bind_key(m, action, key)`, `bind_mouse(m, action, button)`, `bind_pad(m, action, button)` | add a binding |
| `bind(m, action, source, code)` | the same with an explicit `BIND_*` source |
| `unbind(m, action)` | remove all bindings of an action |
| `action_down(m, i: *Input, action) -> bool` | any bound input is held |
| `action_pressed(m, i, action) -> bool` | any bound input went down this frame |
| `action_released(m, i, action) -> bool` | a bound input went up this frame and none is held |
| `action_axis(m, i, negative, positive) -> f32` | -1, 0 or 1 from two actions |
| `action_vec2(m, i, left, right, up, down) -> vec2` | a direction of length 0 or 1 (diagonals normalized); x is +1 for right, y is +1 for **up** (negate y for screen coordinates, where y grows downwards) |

Use either your own constants or `action("name")` ids; if both are used for the same actions,
register the names in the order of the constants. Gamepad bindings read `Input.pad`.

## Gamepad

`struct Gamepad { fd, connected, buttons, axes }` holds one controller. Button and axis
numbers follow the Linux joystick numbering of an Xbox-style pad (xpad); on Linux they are
those of the driver (other pads may differ), on Windows XInput's state is translated into
them. Triggers are axes from -1 (released) to 1.

| Function | |
|----------|---|
| `gamepad_open(g: *Gamepad, index: i64) -> bool` | Linux: open `/dev/input/js<index>` non-blocking; Windows: XInput controller `index` (0..3); false if absent |
| `gamepad_poll(g) -> bool` | read all pending events; false once unplugged. Call after `begin_frame` / `poll(window)` each frame |
| `gamepad_close(g)` | close and clear |
| `gamepad_xinput(g, buttons: u16, left_trigger: u8, right_trigger: u8, lx, ly, rx, ry: i16)` | Windows: apply one XInput state (the fields of `XINPUT_GAMEPAD`) as `gamepad_poll` does (tests, replays) |
| `gamepad_event(g, kind: u8, number: u8, value: i16)` | apply one raw joystick event, as `gamepad_poll` does per event; useful for tests and replays. `kind` 1 = button (`value` non-zero = down), 2 = axis (`value` -32767..32767, mapped to -1..1); `kind \| 0x80` marks the initial state reported when a pad is opened. `number` is the button or axis index (`PAD_*` constants) |
| `pad_down(g, button)`, `pad_pressed(g, button)`, `pad_released(g, button)` | button state |
| `pad_axis(g, axis) -> f32` | axis in -1..1 (sticks: right / down positive) |
| `pad_stick(g, axis_x, axis_y, deadzone: f32) -> vec2` | two axes with a radial dead zone, rescaled to length 0..1 |

`begin_frame` clears the pressed / released edges of `Input.pad` together with the keyboard's,
so the pad embedded in the window's `Input` needs only `gamepad_open(&w.input.pad, 0)` once and
`gamepad_poll(&w.input.pad)` per frame. Hot-plugging is not detected automatically: when
`gamepad_poll` returns false, try `gamepad_open` again from time to time.

**Windows (XInput).** The controller is read with `XInputGetState` of `xinput1_4.dll`
(Windows 8 and later), else `xinput9_1_0.dll`, loaded when the first gamepad is opened (a
program without gamepads never loads it); the guide button (`PAD_GUIDE`) comes from the
undocumented `XInputGetStateEx` where the DLL has it, else it is never pressed. `gamepad_poll`
reads the current state each frame and turns changes of the buttons into pressed / released
edges; the state at `gamepad_open` counts as the initial state (no edges), like the initial
events of a Linux device. Mapping: A, B, X, Y, LB, RB, Back, Start, Guide, left / right stick
button as `PAD_A` .. `PAD_RSTICK`; sticks as `PAD_AXIS_LX` / `LY` / `RX` / `RY` (right / down
positive, so XInput's y is negated; raw values without a dead zone, use `pad_stick`); triggers
as `PAD_AXIS_LT` / `RT` from -1 to 1; the D-pad as `PAD_AXIS_DPAD_X` / `DPAD_Y` with values -1,
0, 1 (right / down positive), as xpad reports it. Only XInput controllers (Xbox-compatible) are
seen; other HID gamepads need a driver that offers XInput.

## Example

```
// Action mapping on a scripted input sequence (no window needed).
use std.input

const ACT_LEFT = 0
const ACT_RIGHT = 1
const ACT_JUMP = 2

fn main() {
    inp: Input
    actions := action_map()
    actions.bind_key(ACT_LEFT, KEY_A)
    actions.bind_key(ACT_RIGHT, KEY_D)
    actions.bind_key(ACT_JUMP, KEY_SPACE)
    actions.bind_key(ACT_JUMP, key_from_name("Up"))      // e.g. read from a settings file

    // three frames of events, as a window would deliver them
    script := [][]Event{
        []Event{Event{kind: EventKeyDown, key: KEY_D}, Event{kind: EventKeyDown, key: KEY_SPACE}},
        []Event{Event{kind: EventKeyUp, key: KEY_SPACE}, Event{kind: EventText, codepoint: 'x'}},
        []Event{Event{kind: EventKeyUp, key: KEY_D}, Event{kind: EventKeyDown, key: KEY_A}}
    }
    for frame, events in script {
        inp.begin_frame()                                 // std.window's poll() does this and the feeding
        for e in events {
            inp.feed(e)
        }
        print("frame", frame, "move", actions.action_axis(&inp, ACT_LEFT, ACT_RIGHT),
            "jump pressed", actions.action_pressed(&inp, ACT_JUMP),
            "jump held", actions.action_down(&inp, ACT_JUMP), "typed", len(inp.text()))
    }
}
```

Output:

```
frame 0 move 1.0 jump pressed true jump held true typed 0
frame 1 move 1.0 jump pressed false jump held false typed 1
frame 2 move -1.0 jump pressed false jump held false typed 0
```

Note: `in` is a keyword in AL, so call the variable `inp` or `input`.
