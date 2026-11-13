// std.input on Windows: XInput controller states translated into the Linux joystick numbering
// (gamepad_xinput applies a state as gamepad_poll does), and gamepad_open without a controller.
use std.input

fn show(g: *Gamepad) {
    put("down")
    for b in 0..PAD_BUTTON_COUNT {
        if pad_down(g, b) {
            put(" ", b)
        }
    }
    put(" pressed")
    for b in 0..PAD_BUTTON_COUNT {
        if pad_pressed(g, b) {
            put(" ", b)
        }
    }
    put(" released")
    for b in 0..PAD_BUTTON_COUNT {
        if pad_released(g, b) {
            put(" ", b)
        }
    }
    put(" axes")
    for a in 0..PAD_AXIS_COUNT {
        put(" ", fmtf(f64(pad_axis(g, a)), 3))
    }
    print()
}

fn main() {
    inp: Input
    g := &inp.pad
    // XInput reports no controller here (Wine without devices): not connected
    print("open:", gamepad_open(g, 0), g.connected, "bad index:", gamepad_open(g, 4), gamepad_open(g, -1))
    print("poll closed:", gamepad_poll(g))
    // every button alone: A B X Y LB RB Back Start Guide LStick RStick, then the D-pad
    for bits in []u16{0x1000, 0x2000, 0x4000, 0x8000, 0x0100, 0x0200, 0x0020, 0x0010, 0x0400, 0x0040, 0x0080, 0x0001, 0x0002, 0x0004, 0x0008, 0x0009, 0x0006} {
        inp.begin_frame()
        gamepad_xinput(g, bits, 0, 0, 0, 0, 0, 0)
        show(g)
    }
    // held across frames: pressed only once; released in the frame it goes up
    inp.begin_frame()
    gamepad_xinput(g, 0x1000, 0, 0, 0, 0, 0, 0)
    show(g)
    inp.begin_frame()
    gamepad_xinput(g, 0x1000, 0, 0, 0, 0, 0, 0)
    show(g)
    inp.begin_frame()
    gamepad_xinput(g, 0, 0, 0, 0, 0, 0, 0)
    show(g)
    // sticks (XInput: up positive; here down positive) and triggers (-1 released .. 1)
    inp.begin_frame()
    gamepad_xinput(g, 0, 255, 128, 32767, 32767, -32768, -32768)
    show(g)
    inp.begin_frame()
    gamepad_xinput(g, 0, 0, 255, -16384, -8192, 4096, 0)
    show(g)
    print("stick:", pad_stick(g, PAD_AXIS_LX, PAD_AXIS_LY, 0.2), pad_stick(g, PAD_AXIS_RX, PAD_AXIS_RY, 0.2))
    // an ActionMap sees the pad through Input.pad
    m := action_map()
    jump := m.action("jump")
    m.bind_pad(jump, PAD_A)
    inp.begin_frame()
    gamepad_xinput(g, 0x1000, 0, 0, 0, 0, 0, 0)
    print("jump:", m.action_pressed(&inp, jump), m.action_down(&inp, jump))
    gamepad_close(g)
    print("closed:", g.connected, pad_down(g, PAD_A))
}
