// The GPU-free half of std.gfx (std/gfx_core.al): the 2D transforms and the batcher, driven
// through the internal __gfx_new / __gfx_begin with vertex memory of the test's own. The
// backends replay exactly these commands and vertices (tests/sys/gfx_offscreen.al).
use std.gfx_core

fn near(a: vec2, b: vec2) -> bool { approx_eq(a, b, 1e-4) }

// A Gfx of 100 x 50 pixels without a GPU, room for `quads` quads, with two 4 x 2 textures.
fn recorder(quads: i64) -> (*Gfx, Texture, Texture) {
    g := __gfx_new(100, 50, GfxDesc{max_quads: quads, max_textures: 4})
    a := Texture{g.__gfx_tex_new(4, 2, FilterNearest, false, false), 4, 2}
    b := Texture{g.__gfx_tex_new(4, 2, FilterLinear, true, false), 4, 2}
    __gfx_begin(g, alloc[GfxVertex](__gfx_max_vertices(GfxDesc{max_quads: quads})), 0xFF000000)
    (g, a, b)
}

fn draws(g: *Gfx) -> []GfxCmd { g.cmds[..g.ncmds] }

test "transform identity, order and inverse" {
    p := vec2(3.0, -2.0)
    assert near(apply(xform_identity(), p), p)
    assert near(apply(xform_translate(vec2(10.0, 20.0)), p), vec2(13.0, 18.0))
    assert near(apply(xform_scale(vec2(2.0, 3.0)), p), vec2(6.0, -6.0))
    // a quarter turn: x axis to y axis (clockwise on screen, y down)
    assert near(apply(xform_rotate(HALF_PI), vec2(1.0, 0.0)), vec2(0.0, 1.0))
    // xform_mul(a, b): b first
    m := xform_mul(xform_translate(vec2(10.0, 0.0)), xform_scale(vec2(2.0)))
    assert near(apply(m, p), vec2(16.0, -4.0))
    m2 := xform_mul(xform_mul(xform_rotate(0.7), xform_scale(vec2(2.0, 0.5))), xform_translate(vec2(-4.0, 9.0)))
    assert near(apply(inverse(m2), apply(m2, p)), p)
    assert near(apply(xform_mul(m2, inverse(m2)), p), p)
}

test "camera" {
    cam := camera(vec2(500.0, 300.0), 2.0, 0.0, vec2(320.0, 180.0))
    assert near(apply(cam, vec2(500.0, 300.0)), vec2(160.0, 90.0))
    assert near(apply(cam, vec2(510.0, 300.0)), vec2(180.0, 90.0))
    turned := camera(vec2(0.0), 1.0, HALF_PI, vec2(100.0))
    // the camera turns clockwise: a point to the right of the centre appears above it
    assert near(apply(turned, vec2(10.0, 0.0)), vec2(50.0, 40.0))
    assert near(apply(inverse(turned), vec2(50.0, 40.0)), vec2(10.0, 0.0))
}

test "fit_view letterboxes" {
    m, x, y, w, h := fit_view(320.0, 180.0, 1000, 1000)
    assert x == 0 && w == 1000 && h == 563 && y == 218, fmt(x, " ", y, " ", w, " ", h)
    assert near(apply(m, vec2(0.0)), vec2(0.0, 218.0)) && near(apply(m, vec2(320.0, 180.0)), vec2(1000.0, 780.5))
    _, x2, y2, w2, h2 := fit_view(320.0, 180.0, 640, 1080)
    assert x2 == 0 && y2 == 360 && w2 == 640 && h2 == 360
}

test "sprites of one texture and shapes share a draw" {
    g, a, b := recorder(64)
    g.rect(vec4(0.0, 0.0, 10.0, 10.0), 0xFF0000FF)                 // white texture 1
    g.sprite(a, 1.0, 2.0)
    g.rect(vec4(5.0, 5.0, 1.0, 1.0), 0xFFFFFFFF)                   // joins a
    g.line(vec2(0.0), vec2(10.0, 0.0), 2.0, 0xFFFFFFFF)            // joins a
    g.triangle(vec2(0.0), vec2(1.0, 0.0), vec2(0.0, 1.0), 1, 2, 3) // joins a
    g.sprite(a, 3.0, 4.0)
    g.sprite(b, 0.0, 0.0)
    g.sprite(a, 0.0, 0.0)
    d := draws(g)
    assert d.len == 4, fmt(d.len)
    assert d[0].tex == 1 && d[0].first == 0 && d[0].count == 6
    assert i64(d[1].tex) == a.id && d[1].first == 6 && d[1].count == 6 + 6 + 6 + 3 + 6
    assert i64(d[2].tex) == b.id && d[2].count == 6 && i64(d[3].tex) == a.id
    assert g.nverts == 45
    __gfx_end(g)
    assert g.stats.draw_calls == 4 && g.stats.vertices == 45 && g.stats.passes == 1 && g.stats.dropped == 0 && g.stats.frames == 1
}

test "state changes start a new draw" {
    g, a, b := recorder(64)
    g.sprite(a, 0.0, 0.0)
    g.set_blend(BlendAlpha)                  // unchanged: same draw
    g.sprite(a, 0.0, 0.0)
    g.set_blend(BlendAdd)
    g.sprite(a, 0.0, 0.0)
    g.set_scissor(-5, 10, 50, 100)           // clamped to the 100 x 50 target
    g.sprite(a, 0.0, 0.0)
    g.reset_scissor()
    g.sprite(a, 0.0, 0.0)
    g.set_transform(xform_translate(vec2(1.0)))   // transforms do not split draws
    g.sprite(a, 0.0, 0.0)
    d := draws(g)
    assert d.len == 4, fmt(d.len)
    assert d[0].count == 12 && d[0].blend == 0 && d[0].clip[2] < 0
    assert d[1].blend == 1 && d[1].clip[2] < 0
    assert d[2].blend == 1 && d[2].clip == [4]i32{0, 10, 45, 40}
    assert d[3].clip[2] < 0 && d[3].count == 12
}

test "sprite vertices: rectangles, mirroring, rotation, transform" {
    g, a, _ := recorder(64)
    g.sprite(a, vec4(1.0, 0.0, 2.0, 2.0), vec4(10.0, 20.0, 8.0, 4.0), 0x80FFFFFF)
    v := g.verts
    // corners: top left, top right, bottom left, (bottom left, top right), bottom right
    assert near(v[0].pos, vec2(10.0, 20.0)) && near(v[1].pos, vec2(18.0, 20.0)) && near(v[2].pos, vec2(10.0, 24.0)) && near(v[5].pos, vec2(18.0, 24.0))
    assert near(v[0].uv, vec2(0.25, 0.0)) && near(v[5].uv, vec2(0.75, 1.0)) && v[3] == v[2] && v[4] == v[1]
    assert v[0].color == 0x80FFFFFF
    // a negative source width mirrors: the left corners get the right texels
    g.sprite(a, vec4(4.0, 0.0, -4.0, 2.0), vec4(0.0, 0.0, 4.0, 2.0), 0xFFFFFFFF)
    assert near(v[6].uv, vec2(1.0, 0.0)) && near(v[7].uv, vec2(0.0, 0.0))
    // turned a quarter about its centre: the top left corner goes to the top right
    g.sprite(a, vec4(0.0, 0.0, 4.0, 2.0), vec2(50.0, 30.0), vec2(4.0, 2.0), HALF_PI, vec2(2.0, 1.0), 0xFFFFFFFF)
    assert near(v[12].pos, vec2(51.0, 28.0)) && near(v[17].pos, vec2(49.0, 32.0)), fmt(v[12].pos, v[17].pos)
    // the transform applies to everything
    g.set_transform(xform_mul(xform_translate(vec2(100.0, 0.0)), xform_scale(vec2(2.0))))
    g.rect(vec4(1.0, 1.0, 2.0, 3.0), 0xFF00FF00)
    assert near(v[18].pos, vec2(102.0, 2.0)) && near(v[23].pos, vec2(106.0, 8.0)) && v[18].uv.x < -1.0
    // a line has its width across it
    g.set_transform(xform_identity())
    g.line(vec2(0.0, 10.0), vec2(20.0, 10.0), 4.0, 0xFFFFFFFF)
    assert near(v[24].pos, vec2(0.0, 12.0)) && near(v[25].pos, vec2(20.0, 12.0)) && near(v[26].pos, vec2(0.0, 8.0))
}

test "render targets and clears are commands" {
    g, a, _ := recorder(64)
    rt := Texture{g.__gfx_tex_new(16, 8, FilterNearest, false, true), 16, 8}
    g.set_target(rt)
    assert g.tw == 16 && g.th == 8
    g.clear(0xFF00FF00)
    g.sprite(a, 0.0, 0.0)
    g.reset_target()
    g.sprite(rt, 0.0, 0.0)
    d := draws(g)
    assert d.len == 5
    assert d[0].kind == __GFX_TARGET && i64(d[0].tex) == rt.id
    assert d[1].kind == __GFX_CLEAR && d[1].color == 0xFF00FF00
    assert d[2].kind == __GFX_DRAW && i64(d[2].tex) == a.id
    assert d[3].kind == __GFX_TARGET && d[3].tex == 0 && g.tw == 100
    assert d[4].kind == __GFX_DRAW && i64(d[4].tex) == rt.id
    __gfx_end(g)
    assert g.stats.passes == 3
}

test "what does not fit is dropped and counted" {
    g, a, _ := recorder(2)
    for i in 0..5 { g.sprite(a, 0.0, 0.0) }
    assert g.nverts == 12
    __gfx_end(g)
    assert g.stats.dropped == 3 && g.stats.vertices == 12
}

test "textures: ids are reused, all slots can be used" {
    g := __gfx_new(10, 10, GfxDesc{max_textures: 2})
    t1 := g.__gfx_tex_new(1, 1, FilterNearest, false, false)
    t2 := g.__gfx_tex_new(1, 1, FilterNearest, false, false)
    assert t1 == 2 && t2 == 3 && g.__gfx_tex_new(1, 1, FilterNearest, false, false) == 0
    g.texs[t1].live = false
    assert g.__gfx_tex_new(1, 1, FilterNearest, false, false) == t1
}
