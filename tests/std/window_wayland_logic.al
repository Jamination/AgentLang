// std.window on Linux: the Wayland helpers that need no compositor: the choice of the window
// system, evdev buttons, xkb modifiers, wheel steps, key repeat timing, buffer scale and sizes.
use std.window

fn show(s: WindowSystems) -> str {
    fmt(if s.wayland { fmt("wayland(", s.wayland_name, ")") } else { "-" }, " ", if s.x11 { fmt("x11(", s.x11_name, ")") } else { "-" })
}

fn main() {
    // WindowDesc.display and $WAYLAND_DISPLAY
    for d in []str{"", "x11", "wayland", ":1", "host:0.0", "wayland-1", "/run/user/1000/wayland-0"} {
        print(fmt("\"", d, "\""), show(window_systems(d, "wayland-0")), "|", show(window_systems(d, "")))
    }

    // evdev buttons
    for code in []u32{0x110, 0x111, 0x112, 0x113, 0x114, 0x115, 0x116, 0x117, 0x10F, 0} {
        put(button_from_evdev(code), " ")
    }
    print()
    e := event_from_wl_button(0x111, true, 7, -3, MOD_CTRL)
    r := event_from_wl_button(0x110, false, 0, 0, 0)
    n := event_from_wl_button(0x200, true, 1, 1, 0)
    print(e.kind, e.key, e.x, e.y, e.mods, r.kind, r.key, n.kind)

    // xkb modifier mask with the indices of a usual keymap: Shift 0, Lock 1, Control 2, Mod1 3, Mod2 4, Mod4 6
    print(mods_from_xkb(0, 0, 2, 3, 6), mods_from_xkb(1, 0, 2, 3, 6), mods_from_xkb(0x4D, 0, 2, 3, 6),
        mods_from_xkb(0x12, 0, 2, 3, 6), mods_from_xkb(0xFFFFFFFF, 0, 2, 3, 0xFFFFFFFF), mods_from_xkb(0xFFFFFFFF, 40, 2, 3, 31))

    // wheel: notches (value120), a high-resolution wheel, a touchpad (continuous pixels)
    acc: i64 = 0
    for v in []i64{120, 120, -120, 30, 30, 30, 30, 30, -60, -60, -60, 240, -1} {
        put(wheel_steps(&acc, v), "/", acc, " ")
    }
    print()
    print(wheel_v120_from_axis(wl_fixed_from_int(10)), wheel_v120_from_axis(wl_fixed_from_double(15.0)),
        wheel_v120_from_axis(wl_fixed_from_double(-2.5)), wheel_v120_from_axis(0))
    acc = 0
    steps := 0
    for i in 0..25 {
        steps += wheel_steps(&acc, wheel_v120_from_axis(wl_fixed_from_double(2.0)))     // 2 px at a time
    }
    print("touchpad 50 px:", steps, acc)

    // key repeat: 25 per second after 600 ms
    ms := 1_000_000
    for t in []i64{0, 599, 600, 639, 640, 679, 680, 1000, 10_600} {
        put(repeats_due(t * ms, 0, 600, 25, 0), " ")
    }
    print()
    print(repeats_due(700 * ms, 0, 600, 25, 2), repeats_due(700 * ms, 0, 600, 25, 3), repeats_due(700 * ms, 0, 600, 25, 9),
        repeats_due(5000 * ms, 0, 600, 0, 0), repeats_due(5000 * ms, 0, 600, -1, 0))

    // scale and sizes
    print(scale_from_outputs([]i64{}), scale_from_outputs([]i64{1}), scale_from_outputs([]i64{1, 2}), scale_from_outputs([]i64{3, 2}), scale_from_outputs([]i64{0}))
    for p in [_](i64, i64){(1280, 1), (1280, 2), (1281, 2), (641, 3), (1, 2), (0, 1)} {
        lw := surface_size_for_pixels(p.0, p.1)
        put(lw, "x", p.1, "=", lw * p.1, " ")
    }
    print()
    for f in []f64{0.0, 10.5, 10.99, -0.5, -1.0, 639.996} {
        put(pixels_from_wl_fixed(wl_fixed_from_double(f), 1), ",", pixels_from_wl_fixed(wl_fixed_from_double(f), 2), " ")
    }
    print()
    print(size_after_configure(0, 0, true, 1280, 720, 2), size_after_configure(800, 600, true, 1280, 720, 2),
        size_after_configure(800, 600, false, 1280, 720, 2), size_after_configure(800, 0, true, 1281, 721, 2))
}
