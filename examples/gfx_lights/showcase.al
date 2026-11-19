// The showcase recording (`--record FILE.rgba`): a visitor exploring the demo, scripted. The
// pointer drifts on a smooth path around the pillars and crates with the lantern following it
// (its shadows sweep the room), clicks to add two lights, shows the light map for a moment,
// switches the shadows off and on again. Each 60 Hz step is one frame, drawn offscreen at
// 1280 x 720 and written raw (R, G, B, A bytes, top row first: what a video encoder takes).
// AL has no call that appends to a file, so the frames go into numbered parts of one second,
// FILE.rgba.000, FILE.rgba.001, ...; join them in order (Windows:
// `copy /b FILE.rgba.000+FILE.rgba.001+... FILE.rgba`, Linux: `cat FILE.rgba.* > FILE.rgba`).

const RECORD_SECONDS: f32 = 24.0
const WARM_UP = 150                      // steps before the first frame: embers in the air

// Where the pointer is at a time (seconds), the first point being where the lantern starts.
const PATH = [_]vec3{
    vec3(1.5, 230.0, 470.0),
    vec3(3.0, 300.0, 392.0),
    vec3(4.5, 470.0, 380.0),
    vec3(6.0, 472.0, 166.0),
    vec3(7.5, 292.0, 186.0),
    vec3(9.0, 205.0, 250.0),
    vec3(10.5, 250.0, 470.0),
    vec3(12.0, 196.0, 548.0),
    vec3(13.5, 470.0, 604.0),
    vec3(15.0, 660.0, 566.0),
    vec3(16.5, 815.0, 420.0),
    vec3(18.0, 1000.0, 382.0),
    vec3(19.5, 1006.0, 300.0),
    vec3(21.0, 990.0, 160.0),
    vec3(22.5, 760.0, 150.0),
    vec3(24.0, 640.0, 255.0),
}
const CLICKS = [_]f32{10.5, 18.0}        // when the pointer clicks (it is at a PATH point then)
const LIGHT_MAP_FROM: f32 = 13.4         // the light map is shown in between
const LIGHT_MAP_TO: f32 = 15.8
const DARK_FROM: f32 = 16.3              // shadows off in between
const DARK_TO: f32 = 17.6

// The pointer at time t: a Catmull-Rom spline through the PATH points, eased in and out of
// each so that it slows down at them as a hand does, with a slight tremor.
fn pointer(t: f32, start: vec2) -> vec2 {
    n := len(PATH)
    fn at(i: i64, start: vec2) -> vec2 {
        if i <= 0 { return start }
        PATH[min(i, len(PATH)) - 1].yz
    }
    fn time_of(i: i64) -> f32 { if i <= 0 { 0.0 } else { PATH[min(i, len(PATH)) - 1].x } }
    i := 0                                                // the segment from point i to i + 1
    while i < n && t > time_of(i + 1) {
        i += 1
    }
    if i >= n {
        return at(n, start)
    }
    u := saturate((t - time_of(i)) / (time_of(i + 1) - time_of(i)))
    u = u * u * (3.0 - 2.0 * u) * 0.6 + u * 0.4
    p0 := at(i - 1, start)
    p1 := at(i, start)
    p2 := at(i + 1, start)
    p3 := at(i + 2, start)
    u2 := u * u
    u3 := u2 * u
    p := (p1 * 2.0 + (p2 - p0) * u + (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * u2 + (p1 * 3.0 - p0 - p2 * 3.0 + p3) * u3) * 0.5
    p + vec2(noise2(t * 1.7, 3.0), noise2(t * 1.9, 8.0)) * 2.0
}

// A mouse pointer (an arrow with a dark outline) and the ring of a recent click.
fn draw_cursor(g: *Gfx, sp: *Sprites, p: vec2, click_age: f32) {
    if click_age < 0.6 {
        f := click_age / 0.6
        g.set_blend(BlendAdd)
        glow_at(g, sp, p, 20.0 + 70.0 * f, vec3(1.0, 0.95, 0.8), 0.5 * (1.0 - f))
    }
    g.set_blend(BlendAlpha)
    tip := p
    a := p + vec2(0.0, 19.0)
    b := p + vec2(13.0, 13.5)
    o: u32 = 0xE0000000
    g.triangle(tip + vec2(-1.6, -2.4), a + vec2(-1.6, 2.2), b + vec2(2.6, 1.0), o, o, o)
    w: u32 = 0xFFF4F4F4
    g.triangle(tip, a, b, w, w, 0xFFC8C8C8)
}

fn run_record(o: Options) -> i64 {
    g, err := gfx_offscreen(VW, VH, GfxDesc{max_quads: MAX_QUADS, software: o.warp})
    if err != "" {
        print("no device for std.gfx:", err)
        return 77
    }
    scene := scene_new(g, o.seed)
    fonts_for(g, &scene.hud, 1.0)
    scene.show_cursor = true
    scene.click_age = 10.0
    world := world_new(o.seed)
    for k in 0..WARM_UP {
        world_update(&world, Control{}, f32(1.0 / HZ))
    }
    start := vec2(0.0)
    for l in world.lights {
        if l.kind == Lantern { start = l.pos }
    }
    frames := i64(RECORD_SECONDS * f32(HZ))
    frame_bytes := VW * VH * 4
    per_part := i64(HZ)
    buf := alloc[u8](per_part * frame_bytes)
    n := 0
    part := 0
    dropped := 0
    for f in 0..frames {
        t := f32(f) / f32(HZ)
        dt := 1.0 / f32(HZ)
        click := false
        for c in CLICKS {
            if t <= c && t + dt > c { click = true }
        }
        mouse := pointer(t, start)
        world_update(&world, Control{mouse: mouse, mouse_moved: true, click: click}, dt)
        scene.cursor = mouse
        scene.click_age = if click { 0.0 } else { scene.click_age + dt }
        scene.view = if t >= LIGHT_MAP_FROM && t < LIGHT_MAP_TO { LightMap } else { Lit }
        scene.lt.shadows = !(t >= DARK_FROM && t < DARK_TO)
        frame_begin()
        rerr := render(g, &scene, &world, 1.0, 0.0)
        if rerr != "" {
            panic(rerr)
        }
        img := g.read_pixels()
        assert img.channels == 4 && len(img.pix) == frame_bytes
        copy(buf[n * frame_bytes..(n + 1) * frame_bytes], img.pix)
        frame_end()
        dropped += g.stats.dropped
        n += 1
        if n == per_part || f + 1 == frames {
            name := fmt(o.record, ".", fmti(part, 3, '0'))
            if !write_bytes(name, buf[..n * frame_bytes]) {
                eprint(fmt("cannot write ", name))
                return 1
            }
            part += 1
            n = 0
        }
    }
    print("frames", frames, "parts", part, "lights", world.lights.len, "added", world.added, "dropped", dropped)
    gfx_close(g)
    0
}
