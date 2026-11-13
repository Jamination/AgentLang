// A complete small game showing the structure recommended in docs/GAMES.md. The rules are in
// logic.al (shared with the Direct3D 12 version, examples/dx12_starter); this file is the
// software front end: it draws into a framebuffer that std.window scales to the window.
//   - rendering reads the state and never changes it
//   - the platform layer (window) is a thin shell around `update` / `render`
//
//   alc run examples/starter/game.al                  play it (arrows / WASD / pad move, space / A shoots)
//   alc run examples/starter/game.al -- --headless    no window: scripted input, prints a checksum
use std.window
use "logic.al"

const FB_W = WORLD_W
const FB_H = WORLD_H

fn disc(fb: []u32, at: vec2, r: f32, color: u32) {
    x0 := max(i64(floor(at.x - r)), 0)
    x1 := min(i64(ceil(at.x + r)), FB_W - 1)
    y0 := max(i64(floor(at.y - r)), 0)
    y1 := min(i64(ceil(at.y + r)), FB_H - 1)
    for y in y0..=y1 {
        for x in x0..=x1 {
            if length_sq(vec2(f32(x), f32(y)) - at) <= r * r {
                fb[y * FB_W + x] = color
            }
        }
    }
}

// Drawing only reads the game. `alpha` is how far the display is between two simulation steps.
fn render(g: *Game, fb: []u32, alpha: f32) {
    fill(fb, 0xFF201810)
    for i in 0..g.ents.len {
        if g.ents.is_live(i) {
            e := &g.ents.items[i]
            disc(fb, e.pos + e.vel * (alpha / f32(HZ)), e.radius, e.color)
        }
    }
    for i in 0..min(g.score / 10, FB_W / 4) {
        disc(fb, vec2(f32(i * 4 + 3), 3.0), 1.0, 0xFF60FF60)
    }
}

fn checksum(fb: []u32) -> u64 {
    h: u64 = 1469598103934665603
    for p in fb {
        h = (h ^ u64(p)) * 1099511628211
    }
    return h
}

// Headless run: the same update/render driven by scripted input instead of a window.
fn run_headless() {
    g := game_new(2024)
    inp: Input
    fb := alloc[u32](FB_W * FB_H)
    for step in 0..2400 {
        inp.begin_frame()
        // a little script: weave left and right, hold fire
        if step == 0 {
            inp.feed(Event{kind: EventKeyDown, key: KEY_SPACE})
        }
        if step % 240 == 0 {
            inp.feed(Event{kind: EventKeyUp, key: KEY_RIGHT})
            inp.feed(Event{kind: EventKeyDown, key: KEY_LEFT})
        }
        if step % 240 == 120 {
            inp.feed(Event{kind: EventKeyUp, key: KEY_LEFT})
            inp.feed(Event{kind: EventKeyDown, key: KEY_RIGHT})
        }
        update(&g, &inp, 1.0 / f32(HZ))
        g.events.clear()                       // no sound in this version
    }
    render(&g, fb, 0.0)
    print("steps", g.step_no, "score", g.score, "entities", g.ents.used, "over", g.over)
    print("frame", hex(checksum(fb)))
}

fn run_window() {
    w, ok := window_open(WindowDesc{title: "AL starter", width: FB_W * 3, height: FB_H * 3, resizable: true})
    if !ok {
        eprint("cannot open a window (no display?): `--headless` runs the scripted demo without one")
        exit(1)
    }
    gamepad_open(&w.input.pad, 0)
    g := game_new(u64(time_ns()))
    fb := alloc[u32](FB_W * FB_H)
    clock := frame_clock()
    steps := fixed_step(HZ)
    while !w.should_close() {
        w.poll()
        gamepad_poll(&w.input.pad)
        if g.keys.action_pressed(&w.input, g.act.quit) {
            w.closing = true
        }
        for k in 0..steps.advance(clock.tick()) {
            update(&g, &w.input, f32(steps.step))
        }
        g.events.clear()
        render(&g, fb, steps.alpha())
        w.present(as_bytes(fb), FB_W, FB_H)
        sleep_ms(4)
    }
    w.close()
    print("score", g.score)
}

fn main() {
    for a in args() {
        if a == "--headless" {
            run_headless()
            return
        }
    }
    run_window()
}
