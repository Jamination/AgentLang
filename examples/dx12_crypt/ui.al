// Crypt's 2D layer (Windows only): a sprite batcher for the HUD and the menus, and the texture
// it draws from. It is ../gamekit's batcher changed in three ways: the texture is sampled with
// linear filtering and mipmaps, colours are blended premultiplied (so one draw call can mix
// ordinary alpha-blended sprites with additive glows), and a quad may have any four corners
// (the arrow on the map turns).
//
// The texture has two parts. The painted part is made once at start-up: the title "CRYPT"
// drawn from strokes of our own (a distance field, chiselled into bevelled gold with a bronze
// extrusion and a glow) and a few icons. Below it, the text: a TrueType font (a system font,
// see FONT_PATHS) rasterised by std.font at the sizes the text has on the screen, so it is
// sharp at any window size; the renderer makes this part again when the window's size changes.
use std.image
use std.font
use "../gamekit/dx12_gpu.al"

const UI_ATLAS_W = 1024
const UI_PAINTED_H = 512            // the painted part: the top rows of the texture
const UI_ATLAS_MIPS = 3

// Where things are in the painted part (texels).
const LOGO_X = 512
const LOGO_Y = 8
const LOGO_W = 480                  // the box of the letters (they are centred in it)
const LOGO_H = 112
const LOGO_M = 8                    // texels of outline and extrusion around the box
const GLOW_X = 496                  // the title's glow: the box and 16 texels around it
const GLOW_Y = 136
const ICON_Y = 300
const ICON_HEART = 512
const ICON_FLAME = 544
const ICON_DIAMOND = 576
const ICON_GEM = 608
const ICON_DISK = 640               // 64 x 64: a soft round glow
const ICON_FADE = 704               // 16 x 64: opaque at the top, transparent at the bottom
const WHITE_X = 1000                // a block of opaque white for plain rectangles
const WHITE_Y = 488

// ---- the font --------------------------------------------------------------------------------

// The fonts tried, in order: a bold serif suits a crypt (Palatino and Cambria have lining
// figures, which read better in counters than Georgia's old-style ones); then common fonts of
// Windows and Linux. Without any, the small test font of std.font (it has only a few glyphs).
const FONT_PATHS = [_]str{
    "C:/Windows/Fonts/palab.ttf",
    "C:/Windows/Fonts/cambriab.ttf",
    "C:/Windows/Fonts/georgiab.ttf",
    "C:/Windows/Fonts/segoeuib.ttf",
    "C:/Windows/Fonts/arialbd.ttf",
    "C:/Windows/Fonts/arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
}
const TEST_FONT = embed("../../tests/std/data/font_test.ttf")

fn load_font() -> Font {
    for p in FONT_PATHS {
        f, err := font_load(p)
        if err == "" {
            return f
        }
    }
    eprint("no system font found: the text is drawn with the test font of std.font")
    f, _ := font_parse(TEST_FONT)
    f
}

// The text sizes: the em size in HUD units of small (help lines, menu items), medium (the
// counters, prompts), large (PAUSED) and extra large (the end of a game) text.
const TEXT_S = 0
const TEXT_M = 1
const TEXT_L = 2
const TEXT_XL = 3
const TEXT_SIZES = 4
const TEXT_EM = [TEXT_SIZES]f32{10.5, 19.0, 28.0, 27.0}
const MAX_TEXT_SCALE: f32 = 4.0     // larger targets magnify the 1080p glyphs

// ---- painting --------------------------------------------------------------------------------

// Box blur of radius r over a w x h field, `passes` times (about a Gaussian), in place.
priv fn blur(f: []f32, w: i64, h: i64, r: i64, passes: i64) {
    tmp := alloc[f32](w * h)
    for p in 0..passes {
        for y in 0..h {
            for x in 0..w {
                s: f32 = 0.0
                for k in -r..r + 1 {
                    s += f[y * w + clamp(x + k, 0, w - 1)]
                }
                tmp[y * w + x] = s / f32(2 * r + 1)
            }
        }
        for y in 0..h {
            for x in 0..w {
                s: f32 = 0.0
                for k in -r..r + 1 {
                    s += tmp[clamp(y + k, 0, h - 1) * w + x]
                }
                f[y * w + x] = s / f32(2 * r + 1)
            }
        }
    }
}

// A stroke of the title's letters: a segment with round ends, `t` thick (letter units: a
// letter is 100 wide and 140 high, y down).
struct Stroke { a: vec2, b: vec2, t: f32 }

priv fn line(s: *Vec[Stroke], x0: f32, y0: f32, x1: f32, y1: f32, t: f32) {
    s.push(Stroke{vec2(x0, y0), vec2(x1, y1), t})
}

// An arc of an ellipse in segments; the stroke is thin where it runs across (at the top and the
// bottom) and thick where it runs down, as a broad pen draws it.
priv fn arc(s: *Vec[Stroke], c: vec2, r: vec2, a0: f32, a1: f32, thin: f32, thick: f32) {
    n := 24
    for k in 0..n {
        p := a0 + (a1 - a0) * f32(k) / f32(n)
        q := a0 + (a1 - a0) * f32(k + 1) / f32(n)
        m := (p + q) * 0.5
        s.push(Stroke{c + vec2(cos(p), sin(p)) * r, c + vec2(cos(q), sin(q)) * r, lerp(thin, thick, fabs(cos(m)))})
    }
}

// The letters of CRYPT, serifed capitals, each moved `dx` along.
priv fn title_strokes() -> Vec[Stroke] {
    s := vec[Stroke]()
    stem: f32 = 24.0
    serif: f32 = 10.0
    // C
    arc(&s, vec2(55.0, 70.0), vec2(45.0, 63.0), radians(40.0), radians(320.0), 13.0, 26.0)
    line(&s, 87.0, 24.0, 90.0, 6.0, serif)
    line(&s, 87.0, 116.0, 90.0, 134.0, serif)
    // R
    o: f32 = 112.0
    line(&s, o + 16.0, 6.0, o + 16.0, 134.0, stem)
    line(&s, o + 0.0, 134.0, o + 34.0, 134.0, serif)
    line(&s, o + 0.0, 6.0, o + 52.0, 6.0, 12.0)
    arc(&s, vec2(o + 52.0, 38.0), vec2(34.0, 32.0), radians(-90.0), radians(90.0), 12.0, 22.0)
    line(&s, o + 16.0, 70.0, o + 52.0, 70.0, 12.0)
    line(&s, o + 46.0, 70.0, o + 88.0, 132.0, 22.0)
    line(&s, o + 76.0, 134.0, o + 100.0, 134.0, serif)
    // Y
    o = 224.0
    line(&s, o + 8.0, 6.0, o + 50.0, 74.0, 22.0)
    line(&s, o + 92.0, 6.0, o + 50.0, 74.0, 13.0)
    line(&s, o + 50.0, 74.0, o + 50.0, 134.0, stem)
    line(&s, o + 0.0, 6.0, o + 26.0, 6.0, serif)
    line(&s, o + 76.0, 6.0, o + 100.0, 6.0, serif)
    line(&s, o + 32.0, 134.0, o + 68.0, 134.0, serif)
    // P
    o = 336.0
    line(&s, o + 16.0, 6.0, o + 16.0, 134.0, stem)
    line(&s, o + 0.0, 134.0, o + 34.0, 134.0, serif)
    line(&s, o + 0.0, 6.0, o + 54.0, 6.0, 12.0)
    arc(&s, vec2(o + 54.0, 40.0), vec2(36.0, 34.0), radians(-90.0), radians(90.0), 12.0, 22.0)
    line(&s, o + 16.0, 74.0, o + 54.0, 74.0, 12.0)
    // T
    o = 448.0
    line(&s, o + 2.0, 8.0, o + 98.0, 8.0, 16.0)
    line(&s, o + 4.0, 2.0, o + 4.0, 28.0, serif)
    line(&s, o + 96.0, 2.0, o + 96.0, 28.0, serif)
    line(&s, o + 50.0, 8.0, o + 50.0, 134.0, stem)
    line(&s, o + 32.0, 134.0, o + 68.0, 134.0, serif)
    s
}

priv fn segment_distance(p: vec2, a: vec2, b: vec2) -> f32 {
    ab := b - a
    t := saturate(dot(p - a, ab) / fmax(dot(ab, ab), 0.0001))
    length(p - (a + ab * t))
}

// The title: the letters as a signed distance field (distance to the nearest stroke less half
// its thickness), cut with a one-texel soft edge; the depth inside the letters makes a chiselled
// bevel lit from the top left; a gold gradient, a dark bronze extrusion below and to the right
// and a fine dark outline; and a wide soft glow of the same shape.
priv fn paint_logo(atlas: *Image) {
    pad := 16
    w := LOGO_W + 2 * pad
    h := LOGO_H + 2 * pad
    strokes := title_strokes()
    units: f32 = 548.0                                     // 5 letters 100 wide, 12 apart
    k := f32(LOGO_H) / 140.0                               // texels per letter unit
    left := f32(pad) + (f32(LOGO_W) - units * k) * 0.5
    dist := alloc[f32](w * h)
    for y in 0..h {
        for x in 0..w {
            p := vec2((f32(x) + 0.5 - left) / k, (f32(y) + 0.5 - f32(pad)) / k)
            d: f32 = 1.0e9
            for s in strokes {
                if p.x < fmin(s.a.x, s.b.x) - 40.0 || p.x > fmax(s.a.x, s.b.x) + 40.0 {
                    continue
                }
                d = fmin(d, segment_distance(p, s.a, s.b) - s.t * 0.5)
            }
            dist[y * w + x] = d * k                        // in texels
        }
    }
    mask := alloc[f32](w * h)
    for i in 0..w * h {
        mask[i] = saturate(0.5 - dist[i])
    }
    // the extrusion: the letters moved down and right, behind them
    ext := alloc[f32](w * h)
    for y in 0..h {
        for x in 0..w {
            for j in 1..6 {
                ext[y * w + x] = fmax(ext[y * w + x], mask[clamp(y - j, 0, h - 1) * w + clamp(x - j / 2, 0, w - 1)])
            }
        }
    }
    outline := alloc[f32](w * h)
    for i in 0..w * h {
        outline[i] = fmax(mask[i], ext[i])
    }
    blur(outline, w, h, 2, 2)
    glow := clone(mask)
    blur(glow, w, h, 7, 3)
    light := normalize(vec3(-0.55, -0.75, 0.6))
    for y in 0..h {
        for x in 0..w {
            i := y * w + x
            m := mask[i]
            e := ext[i]
            // the chisel: the height rises from the edge to a ridge 4 texels in
            hx := saturate(-dist[y * w + clamp(x + 1, 0, w - 1)] / 4.0) - saturate(-dist[y * w + clamp(x - 1, 0, w - 1)] / 4.0)
            hy := saturate(-dist[clamp(y + 1, 0, h - 1) * w + x] / 4.0) - saturate(-dist[clamp(y - 1, 0, h - 1) * w + x] / 4.0)
            n := normalize(vec3(-hx * 1.6, -hy * 1.6, 1.0))
            shade := 0.9 + 0.32 * (dot(n, light) - 0.55)
            t := saturate(f32(y - pad) / f32(LOGO_H))
            gold := lerp(vec3(1.0, 0.95, 0.3), vec3(1.0, 0.84, 0.18), t)
            // a bright band across the middle of the letters, as on polished metal
            gold = gold * (0.94 + 0.1 * smoothstep(0.3, 0.45, t) * smoothstep(0.62, 0.47, t))
            col := min(gold * shade, vec3(1.0))
            // back to front, premultiplied: outline, extrusion (darker further down), letters
            o := smoothstep(0.02, 0.3, outline[i]) * 0.85
            pa := o
            prgb := vec3(0.0)
            bronze := vec3(0.42, 0.24, 0.06) * (1.0 - 0.4 * t)
            prgb = bronze * e + prgb * (1.0 - e)
            pa = e + pa * (1.0 - e)
            prgb = col * m + prgb * (1.0 - m)
            pa = m + pa * (1.0 - m)
            rgb := if pa > 0.001 { prgb / pa } else { vec3(0.0) }
            if x >= pad - LOGO_M && y >= pad - LOGO_M && x < pad + LOGO_W + LOGO_M && y < pad + LOGO_H + LOGO_M {
                atlas.set(LOGO_X + x - pad, LOGO_Y + y - pad, vec4(rgb, pa))
            }
            atlas.set(GLOW_X + x, GLOW_Y + y, vec4(1.0, 1.0, 1.0, saturate(glow[i] * 1.4)))
        }
    }
}

// Coverage of a shape over a texel, 4 x 4 samples; `inside` gets coordinates -1..1 (y up).
priv fn paint_icon(atlas: *Image, x0: i64, y0: i64, size: i64, inside: fn(vec2) -> f32) {
    for y in 0..size {
        for x in 0..size {
            sum: f32 = 0.0
            for sy in 0..4 {
                for sx in 0..4 {
                    p := vec2((f32(x) + (f32(sx) + 0.5) / 4.0) / f32(size) * 2.0 - 1.0,
                        1.0 - (f32(y) + (f32(sy) + 0.5) / 4.0) / f32(size) * 2.0)
                    sum += inside(p)
                }
            }
            atlas.set(x0 + x, y0 + y, vec4(1.0, 1.0, 1.0, sum / 16.0))
        }
    }
}

// The icons are white, shaded by brightness so that a tint keeps their shape readable.
priv fn heart(p: vec2) -> f32 {
    q := vec2(p.x * 1.18, p.y * 1.2 + 0.18)
    a := q.x * q.x + q.y * q.y - 1.0
    if a * a * a - q.x * q.x * q.y * q.y * q.y <= 0.0 { 1.0 } else { 0.0 }
}
priv fn flame(p: vec2) -> f32 {
    y := (p.y + 1.0) * 0.5
    wid := 0.62 * sqrt(saturate(y * 2.5)) * (1.0 - y) * 1.6
    if fabs(p.x + 0.12 * sin(y * 5.0) * y) < wid && y > 0.04 { 1.0 } else { 0.0 }
}
priv fn diamond(p: vec2) -> f32 { if fabs(p.x) + fabs(p.y) < 0.9 { 1.0 } else { 0.0 } }
// a cut gem seen from the side: a flat crown over a pointed pavilion
priv fn gem(p: vec2) -> f32 {
    if p.y > 0.3 {
        if fabs(p.x) < 0.95 - (p.y - 0.3) * 0.9 && p.y < 0.75 { 1.0 } else { 0.0 }
    } else {
        if fabs(p.x) < (p.y + 0.95) * 0.76 { 1.0 } else { 0.0 }
    }
}

// Shading inside an icon already painted: brighter towards the top left, with a small
// highlight (and for the gem, facets). The alpha stays.
priv fn shade_icon(atlas: *Image, x0: i64, y0: i64, size: i64, facets: bool) {
    for y in 0..size {
        for x in 0..size {
            c := atlas.get(x0 + x, y0 + y)
            p := vec2(f32(x) / f32(size) * 2.0 - 1.0, 1.0 - f32(y) / f32(size) * 2.0)
            s := 0.78 + 0.22 * saturate(0.6 - p.x * 0.5 + p.y * 0.5)
            if facets {
                s = if p.y > 0.3 { if fabs(p.x) < 0.35 { 1.0 } else { 0.94 } } else { if p.x < 0.0 { 0.97 } else { 0.9 } }
            }
            hl := smoothstep(0.3, 0.0, length(p - vec2(-0.35, 0.35)))
            v := fmin(s + hl * 0.25, 1.0)
            atlas.set(x0 + x, y0 + y, vec4(v, v, v, c.a))
        }
    }
}

// The painted part of the texture (UI_ATLAS_W x UI_PAINTED_H): the title and the icons.
fn ui_painted() -> Image {
    atlas := image_new(UI_ATLAS_W, UI_PAINTED_H, 4)
    paint_logo(&atlas)
    paint_icon(&atlas, ICON_HEART, ICON_Y, 32, heart)
    shade_icon(&atlas, ICON_HEART, ICON_Y, 32, false)
    paint_icon(&atlas, ICON_FLAME, ICON_Y, 32, flame)
    shade_icon(&atlas, ICON_FLAME, ICON_Y, 32, false)
    paint_icon(&atlas, ICON_DIAMOND, ICON_Y, 32, diamond)
    paint_icon(&atlas, ICON_GEM, ICON_Y, 32, gem)
    shade_icon(&atlas, ICON_GEM, ICON_Y, 32, true)
    for y in 0..64 {
        for x in 0..64 {
            p := vec2(f32(x) - 31.5, f32(y) - 31.5) / 32.0
            atlas.set(ICON_DISK + x, ICON_Y + y, vec4(1.0, 1.0, 1.0, exp(-dot(p, p) * 4.0) * saturate(1.0 - length(p))))
        }
    }
    for y in 0..64 {
        for x in 0..16 {
            atlas.set(ICON_FADE + x, ICON_Y + y, vec4(1.0, 1.0, 1.0, 1.0 - f32(y) / 63.0))
        }
    }
    for y in 0..24 {
        for x in 0..24 {
            atlas.set(WHITE_X + x, WHITE_Y + y, vec4(1.0))
        }
    }
    atlas
}

// The whole texture for a target whose HUD unit is `px` pixels: the painted part, then the font
// rasterised at each text size times px (at most MAX_TEXT_SCALE), one atlas under the other.
// Remembers in `u` where each size is. Returns the mipmaps (UI_ATLAS_MIPS levels); allocates
// (the caller keeps it in a region that it resets when the size changes again).
fn ui_texture(u: *Ui, painted: Image, px: f32) -> []Image {
    u.fscale = clamp(px, 0.5, MAX_TEXT_SCALE)
    y := UI_PAINTED_H
    for s in 0..TEXT_SIZES {
        a, err := atlas_build(u.font, TEXT_EM[s] * u.fscale, char_range(32, 126), UI_ATLAS_W, 4)
        assert err == "", err
        u.fonts[s] = a
        u.font_y[s] = f32(y)
        h := atlas_glyph(a, 'H')
        u.cap[s] = f32(-h.yoff)
        y += a.img.h + 2
    }
    total := (y + 3) / 4 * 4
    img := image_new(UI_ATLAS_W, total, 4)
    blit(&img, painted, 0, 0)
    for s in 0..TEXT_SIZES {
        blit(&img, u.fonts[s].img, 0, i64(u.font_y[s]))
    }
    u.atlas_h = f32(total)
    chain := mipmap_chain(img)
    chain[..UI_ATLAS_MIPS]
}

// ---- the batcher -------------------------------------------------------------------------------

// One corner of a quad: position in HUD units, texture coordinates (0..1), colour (RGBA8, red in
// the lowest byte, straight alpha) and 1 for an additive quad (its colour is added to the picture).
struct UiVertex { pos: vec2, uv: vec2, color: u32, add: f32 }

struct Ui {
    root: *ID3D12RootSignature
    pipeline: *ID3D12PipelineState
    vertices: *ID3D12Resource
    mapped: []UiVertex            // the whole buffer, mapped
    capacity: i64                 // quads per frame
    base: i64                     // first vertex of the current frame's region
    count: i64                    // quads added in this frame
    drawn: i64                    // of which already drawn
    scale: vec2                   // 2 / view size
    px: f32                       // pixels of the target per HUD unit
    font: Font
    fonts: [TEXT_SIZES]Atlas      // the font at each text size (in the texture at font_y)
    font_y: [TEXT_SIZES]f32
    cap: [TEXT_SIZES]f32          // the height of a capital, atlas pixels
    fscale: f32                   // atlas pixels per HUD unit the fonts were made for
    atlas_h: f32                  // the texture's height
}

priv const UI_SHADER = `
cbuffer View : register(b0) { float2 scale; };
Texture2D atlas : register(t0);
SamplerState linear_sampler : register(s0);
struct V { float4 pos : SV_POSITION; float2 uv : TEXCOORD; float4 color : COLOR; float add : ADD; };
V vs_main(float2 pos : POSITION, float2 uv : TEXCOORD, float4 color : COLOR, float add : ADD) {
    V o;
    o.pos = float4(pos.x * scale.x - 1.0, 1.0 - pos.y * scale.y, 0.0, 1.0);
    o.uv = uv;
    o.color = color;
    o.add = add;
    return o;
}
// premultiplied alpha: the blend adds rgb and keeps (1 - alpha) of the picture; an additive
// quad has alpha 0, so it only adds
float4 ps_main(V i) : SV_TARGET {
    float4 c = atlas.Sample(linear_sampler, i.uv) * i.color;
    return float4(c.rgb * c.a, c.a * (1.0 - i.add));
}
`

// A batcher for render targets of `format`, `capacity` quads a frame, `frames` frames in flight.
fn ui_new(g: *Gpu, format: i32, capacity: i64, frames: i64) -> (Ui, str) {
    u: Ui
    u.capacity = capacity
    u.font = load_font()
    params: [2]D3D12_ROOT_PARAMETER
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS
    params[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX
    params[0].u_Constants().Num32BitValues = 2
    range := D3D12_DESCRIPTOR_RANGE{RangeType: D3D12_DESCRIPTOR_RANGE_TYPE_SRV, NumDescriptors: 1}
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE
    params[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL
    params[1].u_DescriptorTable().NumDescriptorRanges = 1
    params[1].u_DescriptorTable().pDescriptorRanges = &range
    // trilinear: the icons are drawn at many sizes (text comes out at its own size: mip 0)
    sampler := D3D12_STATIC_SAMPLER_DESC{
        Filter: D3D12_FILTER_MIN_MAG_MIP_LINEAR, AddressU: D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        AddressV: D3D12_TEXTURE_ADDRESS_MODE_CLAMP, AddressW: D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        ComparisonFunc: D3D12_COMPARISON_FUNC_NEVER, MaxLOD: 3.4e38, ShaderVisibility: D3D12_SHADER_VISIBILITY_PIXEL,
    }
    root_desc := D3D12_ROOT_SIGNATURE_DESC{NumParameters: 2, pParameters: ptr(params), NumStaticSamplers: 1,
        pStaticSamplers: &sampler, Flags: D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT}
    root, err := dx_root_signature(g, &root_desc)
    if err != "" { return (u, err) }
    u.root = root
    vs, verr := dx_compile(UI_SHADER, "vs_main", "vs_5_0")
    if verr != "" { return (u, verr) }
    ps, perr := dx_compile(UI_SHADER, "ps_main", "ps_5_0")
    if perr != "" {
        com_release(&vs)
        return (u, perr)
    }
    layout := [4]D3D12_INPUT_ELEMENT_DESC{
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("POSITION"), Format: DXGI_FORMAT_R32G32_FLOAT, AlignedByteOffset: u32(offsetof[UiVertex](pos))},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("TEXCOORD"), Format: DXGI_FORMAT_R32G32_FLOAT, AlignedByteOffset: u32(offsetof[UiVertex](uv))},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("COLOR"), Format: DXGI_FORMAT_R8G8B8A8_UNORM, AlignedByteOffset: u32(offsetof[UiVertex](color))},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("ADD"), Format: DXGI_FORMAT_R32_FLOAT, AlignedByteOffset: u32(offsetof[UiVertex](add))},
    }
    desc := dx_pipeline_desc(u.root, vs, ps, format)
    desc.InputLayout = D3D12_INPUT_LAYOUT_DESC{ptr(layout), 4}
    blend := &desc.BlendState.RenderTarget[0]
    blend.BlendEnable = 1
    blend.SrcBlend = D3D12_BLEND_ONE
    blend.DestBlend = D3D12_BLEND_INV_SRC_ALPHA
    blend.SrcBlendAlpha = D3D12_BLEND_ONE
    blend.DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA
    hr := g.device.CreateGraphicsPipelineState(&desc, &IID_ID3D12PipelineState, &u.pipeline)
    com_release(&vs)
    com_release(&ps)
    if FAILED(hr) { return (u, hresult_text("CreateGraphicsPipelineState (ui)", hr)) }

    u.vertices = gpu_buffer(g, D3D12_HEAP_TYPE_UPLOAD, frames * capacity * 6 * sizeof[UiVertex](), D3D12_RESOURCE_STATE_GENERIC_READ)
    mapped: *u8
    none := D3D12_RANGE{0, 0}
    gpu_check(g, u.vertices.Map(0, &none, &mapped), "ID3D12Resource::Map (ui vertices)")
    u.mapped = mkslice[UiVertex](cast[*UiVertex](mapped), frames * capacity * 6)
    (u, "")
}

// Starts the quads of frame slot `frame` in a view of `width` x `height` HUD units on a target
// `pixels` pixels high.
fn ui_begin(u: *Ui, frame: i64, width: f32, height: f32, pixels: f32) {
    u.base = frame * u.capacity * 6
    u.count = 0
    u.drawn = 0
    u.scale = vec2(2.0 / width, 2.0 / height)
    u.px = pixels / height
}

// A quad with corners a (top left), b (top right), c (bottom left), d (bottom right) showing
// the texture's rectangle (sx, sy, sw, sh) in texels. Quads beyond the capacity are dropped.
fn ui_quad4(u: *Ui, a: vec2, b: vec2, c: vec2, d: vec2, sx: f32, sy: f32, sw: f32, sh: f32, color: u32, add: bool) {
    if u.count >= u.capacity {
        return
    }
    uv0 := vec2(sx / f32(UI_ATLAS_W), sy / u.atlas_h)
    uv1 := vec2((sx + sw) / f32(UI_ATLAS_W), (sy + sh) / u.atlas_h)
    k: f32 = if add { 1.0 } else { 0.0 }
    v := u.mapped
    i := u.base + u.count * 6
    va := UiVertex{a, uv0, color, k}
    vb := UiVertex{b, vec2(uv1.x, uv0.y), color, k}
    vc := UiVertex{c, vec2(uv0.x, uv1.y), color, k}
    vd := UiVertex{d, uv1, color, k}
    v[i] = va
    v[i + 1] = vb
    v[i + 2] = vc
    v[i + 3] = vc
    v[i + 4] = vb
    v[i + 5] = vd
    u.count += 1
}

// An axis-aligned quad at (x, y), w x h HUD units, of the texture's rectangle (sx, sy, sw, sh).
fn ui_sprite(u: *Ui, x: f32, y: f32, w: f32, h: f32, sx: f32, sy: f32, sw: f32, sh: f32, color: u32) {
    u.ui_quad4(vec2(x, y), vec2(x + w, y), vec2(x, y + h), vec2(x + w, y + h), sx, sy, sw, sh, color, false)
}

// The same, added to the picture (glows).
fn ui_glow(u: *Ui, x: f32, y: f32, w: f32, h: f32, sx: f32, sy: f32, sw: f32, sh: f32, color: u32) {
    u.ui_quad4(vec2(x, y), vec2(x + w, y), vec2(x, y + h), vec2(x + w, y + h), sx, sy, sw, sh, color, true)
}

// A rectangle of one colour (alpha-blended by its alpha).
fn ui_rect(u: *Ui, x: f32, y: f32, w: f32, h: f32, color: u32) {
    u.ui_sprite(x, y, w, h, f32(WHITE_X + 8), f32(WHITE_Y + 8), 8.0, 8.0, color)
}

// A rectangle whose colour fades from `color` at the top to nothing at the bottom.
fn ui_fade(u: *Ui, x: f32, y: f32, w: f32, h: f32, color: u32) {
    u.ui_sprite(x, y, w, h, f32(ICON_FADE + 4), f32(ICON_Y) + 0.5, 8.0, 63.0, color)
}

// The same upside down: nothing at the top, `color` at the bottom.
fn ui_fade_up(u: *Ui, x: f32, y: f32, w: f32, h: f32, color: u32) {
    u.ui_sprite(x, y + h, w, -h, f32(ICON_FADE + 4), f32(ICON_Y) + 0.5, 8.0, 63.0, color)
}

// ---- text ------------------------------------------------------------------------------------

// The width of a line of text at text size `size`, in HUD units (kerning included).
fn ui_text_width(u: *Ui, size: i64, text: str) -> f32 {
    a := u.fonts[size]
    pen: f32 = 0.0
    prev := -1
    for c in text {
        g := atlas_glyph(a, i64(c))
        if prev >= 0 {
            pen += f32(kerning(a.font, prev, g.glyph)) * a.scale
        }
        pen += g.advance
        prev = g.glyph
    }
    pen / u.fscale
}

// A line of text at text size `size` with the top of its capitals at y and its pen starting
// at x. Each glyph is drawn at the size it was rasterised for, its corner on a whole pixel of
// the target (the font's own layout, with kerning). Text is ASCII here.
fn ui_text(u: *Ui, x: f32, y: f32, size: i64, text: str, color: u32) {
    a := u.fonts[size]
    m := u.px / u.fscale                  // target pixels per atlas pixel (1 up to 1080p)
    ox := round(x * u.px)
    base := round(y * u.px + u.cap[size] * m)
    sy := u.font_y[size]
    pen: f32 = 0.0
    prev := -1
    for c in text {
        g := atlas_glyph(a, i64(c))
        if prev >= 0 {
            pen += f32(kerning(a.font, prev, g.glyph)) * a.scale
        }
        if g.w > 0 && c != ' ' {
            gx := ox + floor(pen * m + 0.5) + f32(g.xoff) * m
            gy := base + f32(g.yoff) * m
            u.ui_sprite(gx / u.px, gy / u.px, f32(g.w) * m / u.px, f32(g.h) * m / u.px, f32(g.x), sy + f32(g.y), f32(g.w), f32(g.h), color)
        }
        pen += g.advance
        prev = g.glyph
    }
}

// The text over its shadow: the same text in translucent black, a pixel or two down and right.
fn ui_text_shadow(u: *Ui, x: f32, y: f32, size: i64, text: str, color: u32) {
    d := fmax(round(TEXT_EM[size] * u.px * 0.05), 1.0) / u.px
    u.ui_text(x + d, y + d, size, text, rgba8(0, 0, 0, 190))
    u.ui_text(x, y, size, text, color)
}

// Text with its shadow, centred on x.
fn ui_text_centered(u: *Ui, x: f32, y: f32, size: i64, text: str, color: u32) {
    u.ui_text_shadow(x - u.ui_text_width(size, text) / 2.0, y, size, text, color)
}

// ---- drawing -----------------------------------------------------------------------------------

// Records the quads added since the last ui_draw of this frame (one draw call). The texture's
// view is `atlas` in the shader-visible heap that the list has set.
fn ui_draw(u: *Ui, list: *ID3D12GraphicsCommandList, atlas: D3D12_GPU_DESCRIPTOR_HANDLE) {
    n := min(u.count, u.capacity) - u.drawn
    if n <= 0 { return }
    list.SetPipelineState(u.pipeline)
    list.SetGraphicsRootSignature(u.root)
    scale := [2]f32{u.scale.x, u.scale.y}
    list.SetGraphicsRoot32BitConstants(0, 2, cast[*u8](ptr(scale)), 0)
    list.SetGraphicsRootDescriptorTable(1, atlas)
    list.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST)
    stride := sizeof[UiVertex]()
    view := D3D12_VERTEX_BUFFER_VIEW{u.vertices.GetGPUVirtualAddress() + u64((u.base + u.drawn * 6) * stride),
        u32(n * 6 * stride), u32(stride)}
    list.IASetVertexBuffers(0, 1, &view)
    list.DrawInstanced(u32(n * 6), 1, 0, 0)
    u.drawn += n
}

fn ui_free(u: *Ui) {
    if u.vertices != nil && len(u.mapped) > 0 {
        u.vertices.Unmap(0, nil)
        u.mapped = nil
    }
    com_release(&u.vertices)
    com_release(&u.pipeline)
    com_release(&u.root)
}
