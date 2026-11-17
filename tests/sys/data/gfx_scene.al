// The scene of the std.gfx backend tests (tests/sys/gfx_offscreen.al: the backend of the
// target; tests/sys/gfx_vulkan.al: Vulkan on Windows): one 64 x 64 offscreen frame that uses
// every feature, and the pixels it must have. Written against the API only, so the same file
// checks every backend. Not a test by itself (tests/sys/data is not scanned).
use std.image

const SIZE = 64

// A pixel to check: where, the colour expected there (R, G, B, A), and what is drawn there.
struct Probe { x: i64, y: i64, want: [4]i64, what: str }

const BG = [4]i64{51, 102, 153, 255}

const PROBES = [_]Probe{
    Probe{60, 2, BG, "clear colour"},
    Probe{4, 4, [4]i64{255, 0, 0, 255}, "sprite: atlas texel (0, 0)"},
    Probe{12, 4, [4]i64{0, 255, 0, 255}, "sprite: atlas texel (1, 0)"},
    Probe{4, 12, [4]i64{0, 0, 255, 255}, "sprite: atlas texel (0, 1)"},
    Probe{12, 12, [4]i64{255, 255, 0, 255}, "sprite: atlas texel (1, 1), updated during the frame"},
    Probe{18, 4, BG, "clear colour beside the sprite"},
    Probe{28, 4, [4]i64{0, 255, 0, 255}, "mirrored sprite: texel (1, 0) on the left"},
    Probe{36, 4, [4]i64{255, 0, 0, 255}, "mirrored sprite: texel (0, 0) on the right"},
    Probe{56, 56, [4]i64{0, 255, 0, 255}, "opaque rectangle"},
    Probe{4, 52, [4]i64{153, 179, 204, 255}, "half-transparent white, alpha blending"},
    Probe{12, 52, [4]i64{115, 102, 153, 255}, "additive red 64"},
    Probe{18, 17, BG, "coverage 0: nothing"},
    Probe{22, 17, [4]i64{153, 178, 76, 255}, "coverage 128 of yellow"},
    Probe{26, 17, [4]i64{255, 255, 0, 255}, "coverage 255 of yellow"},
    Probe{41, 17, [4]i64{255, 0, 0, 255}, "inside the scissor"},
    Probe{46, 17, BG, "right of the scissor"},
    Probe{41, 22, BG, "below the scissor"},
    Probe{33, 25, [4]i64{0, 0, 255, 255}, "transformed rectangle (translate, scale 2)"},
    Probe{39, 27, [4]i64{0, 0, 255, 255}, "transformed rectangle, far corner"},
    Probe{41, 25, BG, "beside the transformed rectangle"},
    Probe{15, 33, [4]i64{255, 255, 255, 255}, "line, 2 pixels wide"},
    Probe{15, 36, BG, "below the line"},
    Probe{33, 40, [4]i64{199, 24, 32, 255}, "triangle: colours interpolated"},
    Probe{49, 33, [4]i64{255, 0, 0, 255}, "render texture: its clear colour"},
    Probe{53, 37, [4]i64{0, 255, 0, 255}, "render texture: a rectangle drawn into it"},
    Probe{16, 58, [4]i64{0, 0, 0, 255}, "linear filter: the black texel"},
    Probe{20, 58, [4]i64{159, 159, 159, 255}, "linear filter: between black and white"},
    Probe{23, 58, [4]i64{255, 255, 255, 255}, "linear filter: the white texel"},
}

// Draws the scene (one frame). Returns false if begin_frame did not start a frame.
fn draw_scene(g: *Gfx) -> bool {
    atlas := Image{2, 2, 4, []u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255}}
    tex := g.texture(atlas, FilterNearest)
    coverage := g.texture(Image{4, 1, 1, []u8{0, 128, 255, 255}}, FilterNearest)
    ramp := g.texture(Image{2, 1, 4, []u8{0, 0, 0, 255, 255, 255, 255, 255}}, FilterLinear)
    rt := g.render_texture(8, 8, FilterNearest)
    if !g.begin_frame(color_u32(vec4(0.2, 0.4, 0.6, 1.0))) { return false }
    g.sprite(tex, vec4(0.0, 0.0, 2.0, 2.0), vec4(0.0, 0.0, 16.0, 16.0), 0xFFFFFFFF)
    g.sprite(tex, vec4(2.0, 0.0, -2.0, 1.0), vec4(24.0, 0.0, 16.0, 8.0), 0xFFFFFFFF)
    g.rect(vec4(48.0, 48.0, 16.0, 16.0), 0xFF00FF00)
    g.rect(vec4(0.0, 48.0, 8.0, 8.0), color_u32(vec4(1.0, 1.0, 1.0, 0.5)))
    g.set_blend(BlendAdd)
    g.rect(vec4(8.0, 48.0, 8.0, 8.0), 0xFF000040)
    g.set_blend(BlendAlpha)
    g.sprite(coverage, vec4(0.0, 0.0, 4.0, 1.0), vec4(16.0, 16.0, 16.0, 4.0), 0xFF00FFFF)
    g.set_scissor(40, 16, 4, 4)
    g.rect(vec4(32.0, 16.0, 16.0, 16.0), 0xFF0000FF)
    g.reset_scissor()
    g.set_transform(xform_mul(xform_translate(vec2(32.0, 24.0)), xform_scale(vec2(2.0))))
    g.rect(vec4(0.0, 0.0, 4.0, 2.0), 0xFFFF0000)
    g.set_transform(xform_identity())
    g.line(vec2(0.0, 34.0), vec2(30.0, 34.0), 2.0, 0xFFFFFFFF)
    g.triangle(vec2(32.0, 40.0), vec2(48.0, 40.0), vec2(32.0, 44.0), 0xFF0000FF, 0xFF00FF00, 0xFFFF0000)
    g.set_target(rt)
    g.clear(0xFF0000FF)
    g.rect(vec4(4.0, 4.0, 4.0, 4.0), 0xFF00FF00)
    g.reset_target()
    g.sprite(rt, 48.0, 32.0)
    g.sprite(ramp, vec4(0.0, 0.0, 2.0, 1.0), vec4(16.0, 56.0, 8.0, 4.0), 0xFFFFFFFF)
    // a texture updated after it was drawn: the whole frame shows the new pixels
    g.update_texture(tex, 1, 1, Image{1, 1, 4, []u8{255, 255, 0, 255}})
    err := g.end_frame()
    assert err == "", err
    true
}

// Prints one line per probe; returns the number of wrong pixels (more than 2 off per channel).
fn check_scene(img: Image) -> i64 {
    assert img.w == SIZE && img.h == SIZE && img.channels == 4
    wrong := 0
    for p in PROBES {
        i := (p.y * SIZE + p.x) * 4
        good := true
        for c in 0..4 {
            if abs(i64(img.pix[i + c]) - p.want[c]) > 2 { good = false }
        }
        if good {
            print("  ok", p.x, p.y, p.what)
        } else {
            print("  WRONG", p.x, p.y, p.what, "want", p.want, "got", img.pix[i..i + 4])
            wrong += 1
        }
    }
    wrong
}

// Renders the scene on a new offscreen renderer and checks it. (wrong pixels, "") or (0, why
// there is no device). `save`: also write the frame there as PNG ("" not).
fn run_scene(desc: GfxDesc, save: str) -> (i64, str) {
    g, err := gfx_offscreen(SIZE, SIZE, desc)
    if err != "" { return (0, err) }
    eprint(concat("device: ", g.device))
    assert draw_scene(g), "begin_frame refused an offscreen frame"
    img := g.read_pixels()
    if save != "" { png_save(save, img) }
    wrong := check_scene(img)
    // a second frame reuses the other frame slot; the stats are of the last frame
    assert g.begin_frame(0xFF000000)
    g.rect(vec4(0.0, 0.0, 1.0, 1.0), 0xFFFFFFFF)
    assert g.end_frame() == ""
    second := g.read_pixels()
    if second.pix[0..4] != []u8{255, 255, 255, 255} || second.pix[4..8] != []u8{0, 0, 0, 255} {
        print("  WRONG second frame", second.pix[0..8])
        wrong += 1
    }
    print("  stats: frames", g.stats.frames, "draw calls", g.stats.draw_calls, "vertices", g.stats.vertices, "passes", g.stats.passes,
        "dropped", g.stats.dropped)
    gfx_close(g)
    (wrong, "")
}
