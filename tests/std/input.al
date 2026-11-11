// std.input: key / mouse state machine, text queue, event queue, key names, gamepad events.
use std.input

key :: (kind: EventKind, k: i64) -> Event { Event{kind: kind, key: k} }

show :: (i: *Input, k: i64) {
    print(key_name(k), i.key_down(k), i.key_pressed(k), i.key_released(k), i.key_repeated(k))
}

main :: () {
    i: Input
    // frame 1: press A, tap B (down and up within the frame)
    i.begin_frame()
    i.feed(key(EventKeyDown, KEY_A))
    i.feed(key(EventKeyDown, KEY_B))
    i.feed(key(EventKeyUp, KEY_B))
    show(&i, KEY_A)
    show(&i, KEY_B)
    show(&i, KEY_C)
    // frame 2: A still held, auto-repeat arrives
    i.begin_frame()
    show(&i, KEY_A)
    i.feed(Event{kind: EventKeyDown, key: KEY_A, repeat: true})
    show(&i, KEY_A)
    show(&i, KEY_B)
    // frame 3: release A; release of a key that is not down is ignored
    i.begin_frame()
    i.feed(key(EventKeyUp, KEY_A))
    i.feed(key(EventKeyUp, KEY_Z))
    show(&i, KEY_A)
    show(&i, KEY_Z)
    // out-of-range key codes are ignored everywhere
    i.feed(key(EventKeyDown, 9999))
    i.feed(key(EventKeyDown, -1))
    i.feed(key(EventKeyDown, KEY_UNKNOWN))
    print(i.key_down(9999), i.key_down(-1), i.key_down(KEY_UNKNOWN))
    // modifiers
    i.begin_frame()
    i.feed(key(EventKeyDown, KEY_RSHIFT))
    i.feed(key(EventKeyDown, KEY_LCTRL))
    print("mods", i.shift_down(), i.ctrl_down(), i.alt_down())

    // mouse: the first position gives no delta, later moves accumulate within a frame
    i.feed(Event{kind: EventMouseMove, x: 100, y: 50})
    print(i.mouse_pos(), i.mouse_delta())
    i.feed(Event{kind: EventMouseMove, x: 110, y: 45})
    i.feed(Event{kind: EventMouseDown, key: MOUSE_LEFT, x: 112, y: 44})
    i.feed(Event{kind: EventWheel, y: 1})
    i.feed(Event{kind: EventWheel, x: -1, y: 1})
    print(i.mouse_pos(), i.mouse_delta(), i.wheel())
    print(i.mouse_down(MOUSE_LEFT), i.mouse_pressed(MOUSE_LEFT), i.mouse_down(MOUSE_RIGHT), i.mouse_down(17))
    i.begin_frame()
    print(i.mouse_pos(), i.mouse_delta(), i.wheel(), i.mouse_down(MOUSE_LEFT), i.mouse_pressed(MOUSE_LEFT))
    i.feed(Event{kind: EventMouseUp, key: MOUSE_LEFT, x: 112, y: 44})
    print(i.mouse_down(MOUSE_LEFT), i.mouse_released(MOUSE_LEFT))

    // losing focus releases everything that is held
    i.feed(Event{kind: EventFocus})
    i.feed(key(EventKeyDown, KEY_W))
    i.feed(Event{kind: EventMouseDown, key: MOUSE_RIGHT, x: 1, y: 1})
    i.begin_frame()
    print("focus", i.focused, i.key_down(KEY_W), i.key_down(KEY_RSHIFT), i.mouse_down(MOUSE_RIGHT))
    i.feed(Event{kind: EventUnfocus})
    print("focus", i.focused, i.key_down(KEY_W), i.key_released(KEY_W), i.key_down(KEY_RSHIFT), i.mouse_released(MOUSE_RIGHT))

    // text input
    i.begin_frame()
    for c in "Hi" {
        i.feed(Event{kind: EventText, codepoint: u32(c)})
    }
    i.feed(Event{kind: EventText, codepoint: 0xE9})
    i.feed(Event{kind: EventText, codepoint: 0x20AC})
    i.feed(Event{kind: EventText, codepoint: 0x1F600})
    buf: [16]u8
    t := i.text_utf8(buf[..])
    print(i.text(), len(t), t)
    small: [4]u8
    print(len(i.text_utf8(small[..])))
    for k in 0..40 {
        i.feed(Event{kind: EventText, codepoint: 'x'})
    }
    print(len(i.text()))
    i.begin_frame()
    print(len(i.text()))

    // key names
    print(key_name(KEY_A), key_name(KEY_9), key_name(KEY_F12), key_name(KEY_KP_DECIMAL), key_name(KEY_MENU), key_name(-3), key_name(KEY_COUNT))
    print(key_from_name("space") == KEY_SPACE, key_from_name("PAGEUP") == KEY_PAGE_UP, key_from_name("f1") == KEY_F1, key_from_name("nope"), key_from_name(""))
    names_ok := true
    for k in 1..KEY_COUNT {
        if key_from_name(key_name(k)) != k {
            names_ok = false
        }
    }
    print("names round trip", names_ok, KEY_COUNT)

    // event queue: FIFO, fixed capacity, wraps around
    q := new[EventQueue]()
    for round in 0..3 {
        for k in 0..200 {
            q.push_event(Event{kind: EventKeyDown, key: round * 1000 + k})
        }
        sum := 0
        n := 0
        loop {
            e, ok := q.next_event()
            if !ok {
                break
            }
            if n == 0 {
                put(e.key, " ")
            }
            sum += e.key
            n += 1
        }
        print(n, sum, q.len)
    }
    for k in 0..300 {
        q.push_event(Event{kind: EventKeyUp, key: k})
    }
    e, _ := q.next_event()
    print(q.len, q.dropped, e.kind, e.key)
    q.clear_events()
    _, more := q.next_event()
    print(q.len, more, q.dropped)

    // gamepad: raw joystick events (kind 1 button, 2 axis, 0x80 initial state)
    g := &i.pad
    gamepad_event(g, 0x81, 3, 1)
    gamepad_event(g, 1, 0, 1)
    gamepad_event(g, 2, 0, 32767)
    gamepad_event(g, 2, 1, -32768)
    gamepad_event(g, 2, 3, 16384)
    gamepad_event(g, 1, 200, 1)
    gamepad_event(g, 2, 200, 1)
    print(g.pad_down(PAD_Y), g.pad_pressed(PAD_Y), g.pad_down(PAD_A), g.pad_pressed(PAD_A), g.pad_down(99))
    print(g.pad_axis(PAD_AXIS_LX), g.pad_axis(PAD_AXIS_LY), g.pad_axis(99))
    putf(f64(g.pad_axis(PAD_AXIS_RX)), 4)
    print()
    i.begin_frame()
    gamepad_event(g, 1, 0, 0)
    print(g.pad_down(PAD_A), g.pad_released(PAD_A), g.pad_down(PAD_Y), g.pad_pressed(PAD_Y))
    gamepad_event(g, 2, 0, 3000)
    gamepad_event(g, 2, 1, 0)
    print(g.pad_stick(PAD_AXIS_LX, PAD_AXIS_LY, 0.2))
    gamepad_event(g, 2, 0, 32767)
    s := g.pad_stick(PAD_AXIS_LX, PAD_AXIS_LY, 0.2)
    putf(f64(s.x), 4)
    put(" ")
    putf(f64(s.y), 4)
    print()
    gamepad_event(g, 2, 0, 19660)
    s = g.pad_stick(PAD_AXIS_LX, PAD_AXIS_LY, 0.2)
    putf(f64(s.x), 3)
    print()
    // no device with this number: open fails, poll reports disconnected
    none: Gamepad
    print(gamepad_open(&none, 987654), gamepad_poll(&none), none.connected)
}
