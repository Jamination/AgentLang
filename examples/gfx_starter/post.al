// Post-processing of the std.gfx starter with nothing but render textures and sprites (std.gfx
// has no shaders of the program's own):
//   - the world is drawn into `scene`, a render texture as large as the view on the screen;
//   - what emits light is drawn a second time into `glow` (the virtual resolution, 320 x 180)
//     and halved three times into `bloom`; each halving draws its source four times, offset
//     by a texel diagonally, a quarter each, so that the linear filter blurs as it shrinks;
//   - on the screen: the scene, the bloom levels added on top (the small ones spread the
//     light wide), the vignette; while a panel is up, the scene shrunk the same way (`blur`)
//     is laid over it as a frosted backdrop.
use std.gfx
use "../starter/logic.al"
use "art.al"

const BLOOM_LEVELS = 3

struct Post {
    scene: Texture
    glow: Texture
    bloom: [BLOOM_LEVELS]Texture  // 160 x 90, 80 x 45, 40 x 22
    blur: [3]Texture              // 320 x 180, 160 x 90, 80 x 45
}

fn post_new(g: *Gfx) -> Post {
    p: Post
    p.glow = g.render_texture(WORLD_W, WORLD_H, FilterLinear)
    for i in 0..BLOOM_LEVELS {
        p.bloom[i] = g.render_texture(WORLD_W >> (i + 1), WORLD_H >> (i + 1), FilterLinear)
    }
    for i in 0..3 {
        p.blur[i] = g.render_texture(WORLD_W >> i, WORLD_H >> i, FilterLinear)
    }
    p
}

// Makes the scene texture w x h pixels (the view's area on the screen), anew when the size
// changes. Between frames.
fn post_size(g: *Gfx, p: *Post, w: i64, h: i64) {
    if w <= 0 || h <= 0 || (p.scene.w == w && p.scene.h == h) {
        return
    }
    if p.scene.id != 0 {
        g.free_texture(p.scene)
    }
    p.scene = g.render_texture(w, h, FilterLinear)
}

// Draws src into dst (cleared first) through four taps: a shrink and a blur in one pass.
priv fn shrink(g: *Gfx, src: Texture, dst: Texture) {
    g.set_target(dst)
    g.clear(0xFF000000)
    g.set_blend(BlendAdd)
    whole := vec4(0.0, 0.0, f32(src.w), f32(src.h))
    o := f32(dst.w) / f32(src.w)                       // one source texel, in target pixels
    for k in 0..4 {
        d := vec2(if k & 1 == 0 { -o } else { o }, if k & 2 == 0 { -o } else { o })
        g.sprite(src, whole, vec4(d.x, d.y, f32(dst.w), f32(dst.h)), 0x40FFFFFF)
    }
}

// The bloom chain from the glow texture; with `frost`, the blur chain from the scene too.
fn post_blur(g: *Gfx, p: *Post, frost: bool) {
    shrink(g, p.glow, p.bloom[0])
    for i in 1..BLOOM_LEVELS {
        shrink(g, p.bloom[i - 1], p.bloom[i])
    }
    if frost {
        shrink(g, p.scene, p.blur[0])
        shrink(g, p.blur[0], p.blur[1])
        shrink(g, p.blur[1], p.blur[2])
    }
}

// On the screen, in the virtual resolution (set_view): the scene, its bloom, a frosted
// backdrop (`frost` 0..1) and the vignette. `flash` tints the edges red after a hit.
fn post_composite(g: *Gfx, p: *Post, art: *Art, frost: f32, flash: f32) {
    all := vec4(0.0, 0.0, f32(WORLD_W), f32(WORLD_H))
    g.set_blend(BlendAlpha)
    g.sprite(p.scene, vec4(0.0, 0.0, f32(p.scene.w), f32(p.scene.h)), all, 0xFFFFFFFF)
    if frost > 0.0 {
        b1 := p.blur[1]
        b2 := p.blur[2]
        g.sprite(b1, vec4(0.0, 0.0, f32(b1.w), f32(b1.h)), all, color_u32(vec4(1.0, 1.0, 1.0, frost)))
        g.sprite(b2, vec4(0.0, 0.0, f32(b2.w), f32(b2.h)), all, color_u32(vec4(1.0, 1.0, 1.0, frost * 0.6)))
        g.rect(all, color_u32(vec4(0.02, 0.03, 0.08, frost * 0.45)))
    }
    g.set_blend(BlendAdd)
    gains := [BLOOM_LEVELS]f32{0.55, 0.65, 0.8}
    for i in 0..BLOOM_LEVELS {
        t := p.bloom[i]
        g.sprite(t, vec4(0.0, 0.0, f32(t.w), f32(t.h)), all, color_u32(vec4(1.0, 1.0, 1.0, gains[i])))
    }
    g.set_blend(BlendAlpha)
    g.sprite(art.tex, art.vignette, all, 0xFF000000)
    if flash > 0.0 {
        g.sprite(art.tex, art.vignette, all, color_u32(vec4(0.85, 0.06, 0.04, flash * flash * 0.45)))
    }
}
