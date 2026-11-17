// The windowed part of the std.gfx backend tests (tests/sys/gfx_window.al: the backend of the
// target; tests/sys/gfx_window_vk.al: Vulkan on Windows): a std.window window, frames with
// vsync and without, fullscreen and back (the swap chain follows the window's size), closing.
use std.window

// Draws `n` frames; false if one failed.
fn frames(g: *Gfx, w: *Window, t: Texture, n: i64) -> bool {
    for i in 0..n {
        w.poll()
        if !g.begin_frame(0xFF402010) { continue }
        g.sprite(t, vec4(0.0, 0.0, 2.0, 2.0), vec4(f32(i), 10.0, 32.0, 32.0), 0xFFFFFFFF)
        g.rect(vec4(0.0, 0.0, f32(g.width), 8.0), 0xFF00FF00)
        err := g.end_frame()
        if err != "" {
            print("end_frame:", err)
            return false
        }
    }
    true
}

// Switches fullscreen and draws until the renderer has the window's new size (at most 120 frames).
fn follow(g: *Gfx, w: *Window, t: Texture, on: bool) -> bool {
    before := g.width
    w.set_fullscreen(on)
    for k in 0..120 {
        if !frames(g, w, t, 1) { return false }
        if g.width == w.width && g.height == w.height && g.width != before { return true }
    }
    print("size not followed: renderer", g.width, g.height, "window", w.width, w.height)
    false
}

fn run_window(desc: GfxDesc) -> i64 {
    w, ok := window_open(WindowDesc{title: "std.gfx test", width: 240, height: 160, resizable: true})
    if !ok {
        print("no window")
        return 77
    }
    g, err := gfx_open(w, desc)
    if err != "" {
        print("no device for std.gfx:", err)
        w.close()
        return 77
    }
    eprint(concat("device: ", g.device))
    t := g.texture(Image{2, 2, 4, []u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255}}, FilterNearest)
    good := frames(g, w, t, 10)
    print("size", g.width, g.height, "frames ok:", good)
    g.vsync = false
    good = good && frames(g, w, t, 10)
    g.vsync = true
    print("without vsync and back:", good)
    full := follow(g, w, t, true)
    back := follow(g, w, t, false)
    print("fullscreen followed:", full, "back:", back, "size", g.width, g.height)
    print("device lost:", g.lost != "")
    gfx_close(g)
    w.close()
    if good && full && back { 0 } else { 1 }
}
