// std.input: ActionMap (named / numbered actions bound to keys, mouse and gamepad buttons).
use std.input

const ACT_LEFT = 0
const ACT_RIGHT = 1
const ACT_DOWN = 2
const ACT_UP = 3
const ACT_JUMP = 4
const ACT_FIRE = 5

fn down(i *Input, k i64) { i.feed(Event{kind: EventKeyDown, key: k}) }
fn up(i *Input, k i64) { i.feed(Event{kind: EventKeyUp, key: k}) }

fn show(m *ActionMap, i *Input, a i64) {
    print(m.action_name(a), m.action_down(i, a), m.action_pressed(i, a), m.action_released(i, a))
}

fn main() {
    var i Input
    m := action_map()
    // names get ids in registration order, so they can match constants
    print(m.action("left"), m.action("right"), m.action("down"), m.action("up"), m.action("jump"), m.action("fire"), m.action("up"))
    print(m.action_name(ACT_JUMP), len(m.action_name(77)), len(m.action_name(-1)))
    m.bind_key(ACT_LEFT, KEY_A)
    m.bind_key(ACT_LEFT, KEY_LEFT)
    m.bind_key(ACT_RIGHT, KEY_D)
    m.bind_key(ACT_RIGHT, KEY_RIGHT)
    m.bind_key(ACT_DOWN, KEY_S)
    m.bind_key(ACT_UP, KEY_W)
    m.bind_key(ACT_JUMP, KEY_SPACE)
    m.bind_pad(ACT_JUMP, PAD_A)
    m.bind_mouse(ACT_FIRE, MOUSE_LEFT)
    // bindings from text, as a configuration file would give them
    m.bind_key(m.action("pause"), key_from_name("Escape"))
    print(m.binds.len, m.names.len)

    i.begin_frame()
    show(&m, &i, ACT_JUMP)
    down(&i, KEY_SPACE)
    show(&m, &i, ACT_JUMP)
    i.begin_frame()
    show(&m, &i, ACT_JUMP)
    // second source for the same action goes down, first goes up: still down, not released
    gamepad_event(&i.pad, 1, 0, 1)
    up(&i, KEY_SPACE)
    show(&m, &i, ACT_JUMP)
    i.begin_frame()
    gamepad_event(&i.pad, 1, 0, 0)
    show(&m, &i, ACT_JUMP)
    i.begin_frame()
    show(&m, &i, ACT_JUMP)

    i.feed(Event{kind: EventMouseDown, key: MOUSE_LEFT, x: 5, y: 5})
    show(&m, &i, ACT_FIRE)
    down(&i, KEY_ESCAPE)
    show(&m, &i, m.action("pause"))

    // axes
    i.begin_frame()
    print(m.action_axis(&i, ACT_LEFT, ACT_RIGHT), m.action_vec2(&i, ACT_LEFT, ACT_RIGHT, ACT_DOWN, ACT_UP))
    down(&i, KEY_D)
    print(m.action_axis(&i, ACT_LEFT, ACT_RIGHT), m.action_vec2(&i, ACT_LEFT, ACT_RIGHT, ACT_DOWN, ACT_UP))
    down(&i, KEY_LEFT)
    print(m.action_axis(&i, ACT_LEFT, ACT_RIGHT))
    up(&i, KEY_D)
    down(&i, KEY_W)
    v := m.action_vec2(&i, ACT_LEFT, ACT_RIGHT, ACT_DOWN, ACT_UP)
    putf(f64(v.x), 4)
    put(" ")
    putf(f64(v.y), 4)
    put(" ")
    putf(f64(v.x * v.x + v.y * v.y), 4)
    print()

    // rebinding
    m.unbind(ACT_LEFT)
    print(m.binds.len, m.action_down(&i, ACT_LEFT), m.action_down(&i, ACT_UP))
    m.bind_key(ACT_LEFT, KEY_Q)
    down(&i, KEY_Q)
    print(m.binds.len, m.action_down(&i, ACT_LEFT), m.action_down(&i, 12345))
}
