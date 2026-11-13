// std.window on Linux: the X11 parts that need no display: keysym / button / modifier
// translation and XEvent accessors (the framebuffer fit is tested by window_fit).
use std.window

fn main() {
    // keysyms -> key codes
    print(key_name(key_from_keysym('a')), key_name(key_from_keysym('Z')), key_name(key_from_keysym('0')), key_name(key_from_keysym('9')))
    syms := []u64{0x20, 0xFF1B, 0xFF0D, 0xFF09, 0xFF08, 0xFF51, 0xFF52, 0xFF53, 0xFF54, 0xFFE1, 0xFFE2, 0xFFE3, 0xFFE4,
        0xFFE9, 0xFFEA, 0xFE03, 0xFFEB, 0xFFBE, 0xFFC9, 0xFFB0, 0xFFB9, 0xFF9E, 0xFF95, 0xFF8D, 0xFFFF, 0x2D, 0x60, 0xFF61}
    for s in syms {
        put(key_name(key_from_keysym(s)), " ")
    }
    print()
    print(key_from_keysym(0xFFFF) == KEY_DELETE, key_from_keysym(0xFF63) == KEY_INSERT, key_from_keysym(0x1008FF11), key_from_keysym(0xE9), key_from_keysym(0))
    // every key code is reachable from some keysym
    seen: [KEY_COUNT]bool
    for s in 0..0x10000 {
        seen[key_from_keysym(u64(s))] = true
    }
    missing := 0
    for k in 1..KEY_COUNT {
        if !seen[k] {
            missing += 1
            print("no keysym for", key_name(k))
        }
    }
    print("unmapped key codes:", missing)

    // modifiers and buttons
    print(mods_from_x11(0), mods_from_x11(X_SHIFT_MASK | X_CONTROL_MASK), mods_from_x11(X_MOD1_MASK | X_MOD4_MASK | X_LOCK_MASK), mods_from_x11(0xFF))
    for b in 0..11 {
        e := event_from_x11_button(b, true, 7, 9, MOD_SHIFT)
        r := event_from_x11_button(b, false, 7, 9, 0)
        print(b, e.kind, e.key, e.x, e.y, e.mods, r.kind)
    }

    // XEvent accessors: layout of the C union
    ev: XEvent
    x_client_message(&ev, 0x1234, 77, 5, 6, 7, 8, 9)
    print(sizeof[XEvent](), sizeof[XSizeHints](), sizeof[XColor]())
    print(x_event_type(&ev) == X_CLIENT_MESSAGE, x_event_window(&ev), x_event_message_type(&ev), x_event_message_data(&ev, 0), x_event_message_data(&ev, 4))
    raw := mkslice[u8](cast[*u8](&ev), 192)
    print(raw[0], raw[32], raw[33], raw[40], raw[48], raw[56], raw[88])
    raw[64] = 0x2C
    raw[65] = 0x01
    raw[68] = 0xFE
    raw[69] = 0xFF
    raw[70] = 0xFF
    raw[71] = 0xFF
    raw[80] = 5
    raw[84] = 38
    print(x_event_x(&ev), x_event_y(&ev), x_event_state(&ev), x_event_detail(&ev))
    raw[56] = 0x80
    raw[57] = 0x02
    raw[60] = 0xE0
    raw[61] = 0x01
    print(x_event_configure_width(&ev), x_event_configure_height(&ev))
}
