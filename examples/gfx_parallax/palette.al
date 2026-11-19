// The colours of the day. Every colour that changes with the time of day comes from a ramp of
// hand-picked keys (night, first light, sunrise, golden morning, morning, noon, afternoon,
// golden evening, sunset, dusk, night again), interpolated with a smoothstep between keys so
// the sky lingers at each key a little. Colours are written 0xRRGGBB here, as a pixel artist
// reads them (std.gfx's u32 colours are 0xAABBGGRR: `col` converts).

// Times of the keys: 0 is midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset.
priv const KEY_T = [_]f32{0.0, 0.205, 0.25, 0.29, 0.36, 0.5, 0.64, 0.71, 0.75, 0.79, 0.835, 1.0}

priv const SKY_TOP = [_]u32{0x090b22, 0x1a1c4a, 0x2e3a7a, 0x4468b0, 0x3d84d6, 0x2c70d6, 0x3878cc,
    0x4a5eaa, 0x342f78, 0x1b1a4c, 0x090b22, 0x090b22}
priv const SKY_MID = [_]u32{0x121838, 0x34346a, 0x9a5a88, 0xd89c98, 0x86bce8, 0x64a8f0, 0x7ab0e8,
    0xd29a9e, 0xc4547a, 0x4a3678, 0x121838, 0x121838}
priv const SKY_HOR = [_]u32{0x222a56, 0x6a4880, 0xff946a, 0xffd49a, 0xd4ecf4, 0xc2e4ff, 0xd8ecf6,
    0xffc488, 0xff8040, 0x9a466a, 0x222a56, 0x222a56}
// Haze: the colour distant layers fade into.
priv const FOG = [_]u32{0x1c2450, 0x4a3c78, 0xd68494, 0xe8b8a8, 0xa6cae6, 0x9ac4ec, 0xaecae2,
    0xdcaaa8, 0xd06478, 0x58386c, 0x1c2450, 0x1c2450}
// Ambient light: multiplies the colours of everything near.
priv const AMB = [_]u32{0x2c3664, 0x5c5490, 0xd89aa8, 0xffe2c4, 0xf4f8ff, 0xffffff, 0xfff8ec,
    0xffd4a8, 0xf09478, 0x7c5e94, 0x2c3664, 0x2c3664}
// Key light: multiplies the lit side of everything (moonlight at night).
priv const RIM = [_]u32{0x5c6cac, 0x9a88c0, 0xffa888, 0xffe0a0, 0xfff4dc, 0xfffcf0, 0xfff2d4,
    0xffcc78, 0xff9448, 0xc06c90, 0x5c6cac, 0x5c6cac}
// Clouds: lit top, body, shaded underside.
priv const CLOUD_LIT = [_]u32{0x5c6aa8, 0x9a7ab0, 0xffc4a0, 0xfff0d8, 0xffffff, 0xffffff, 0xfffcf4,
    0xffe0b0, 0xffb070, 0xc07890, 0x5c6aa8, 0x5c6aa8}
priv const CLOUD_BODY = [_]u32{0x2c3462, 0x5a4a86, 0xe48c98, 0xf4cab8, 0xe8f2fc, 0xeef6ff, 0xf0f2f6,
    0xf0b8a8, 0xe07880, 0x6c4878, 0x2c3462, 0x2c3462}
priv const CLOUD_SHADE = [_]u32{0x1a2048, 0x3a3268, 0x9a5880, 0xc4909a, 0xa8bedc, 0xaec4e4, 0xb4bed4,
    0xa87890, 0x8a4470, 0x3e2c5a, 0x1a2048, 0x1a2048}

// A colour 0xRRGGBB as components 0..1.
fn rgb(c: u32) -> vec3 {
    vec3(f32((c >> 16) & 0xFF), f32((c >> 8) & 0xFF), f32(c & 0xFF)) / 255.0
}

// std.gfx's colour of components 0..1.
fn col(c: vec3) -> u32 {
    color_u32(vec4(c, 1.0))
}

fn cola(c: vec3, a: f32) -> u32 {
    color_u32(vec4(c, a))
}

// The colour of a ramp at time t (0..1).
fn ramp(keys: []u32, t: f32) -> vec3 {
    t = fract(t)
    k := 0
    while k + 2 < len(KEY_T) && t >= KEY_T[k + 1] {
        k += 1
    }
    f := smoothstep(0.0, 1.0, (t - KEY_T[k]) / (KEY_T[k + 1] - KEY_T[k]))
    lerp(rgb(keys[k]), rgb(keys[k + 1]), f)
}

// Everything the renderer needs to know about the light at one moment.
struct Light {
    t: f32               // time of day, 0..1
    sky_top: vec3
    sky_mid: vec3
    sky_hor: vec3
    fog: vec3
    amb: vec3
    rim: vec3
    cloud_lit: vec3
    cloud_body: vec3
    cloud_shade: vec3
    sun_elev: f32        // sine of the sun's height: 1 at noon, -1 at midnight
    day: f32             // 1 by day, 0 by night, smooth around sunrise and sunset
    night: f32           // how visible the stars are
    sun: vec2            // position of the sun and the moon on the screen (virtual pixels)
    moon: vec2
    sun_col: vec3
    from_right: f32      // 0: the key light comes from the left, 1: from the right
}

const VIEW_W = 480
const VIEW_H = 270
const HORIZON_Y: f32 = 122.0     // where the sun and the moon rise and set (behind the far mountains)

fn light_at(t: f32) -> Light {
    l := Light{t: fract(t)}
    l.sky_top = ramp(SKY_TOP[..], t)
    l.sky_mid = ramp(SKY_MID[..], t)
    l.sky_hor = ramp(SKY_HOR[..], t)
    l.fog = ramp(FOG[..], t)
    l.amb = ramp(AMB[..], t)
    l.rim = ramp(RIM[..], t)
    l.cloud_lit = ramp(CLOUD_LIT[..], t)
    l.cloud_body = ramp(CLOUD_BODY[..], t)
    l.cloud_shade = ramp(CLOUD_SHADE[..], t)
    a := (l.t - 0.25) * TAU                      // 0 at sunrise, PI/2 at noon, PI at sunset
    l.sun_elev = sin(a)
    l.day = smoothstep(-0.12, 0.18, l.sun_elev)
    l.night = 1.0 - smoothstep(-0.32, -0.02, l.sun_elev)
    cx := f32(VIEW_W) * 0.5
    // the arc is flattened at the top: sun and moon stay above the mountains until late,
    // then sink behind them
    lift := sign(l.sun_elev) * pow(fabs(l.sun_elev), 0.55)
    l.sun = vec2(cx - cos(a) * 170.0, HORIZON_Y - lift * 104.0)
    l.moon = vec2(cx + cos(a) * 170.0, HORIZON_Y + lift * 96.0)
    low := 1.0 - smoothstep(0.0, 0.45, l.sun_elev)       // red near the horizon
    l.sun_col = lerp(rgb(0xfff4d0), rgb(0xff7a30), low)
    // By day the sun is the key light, by night the moon.
    kx := if l.sun_elev > -0.05 { l.sun.x } else { l.moon.x }
    l.from_right = smoothstep(cx - 10.0, cx + 10.0, kx)
    l
}

// "06:42" for a time of day.
fn clock_text(t: f32) -> str {
    mins := i64(fract(t) * 1440.0)
    fmt(fmti(mins / 60, 2, '0'), ":", fmti(mins % 60, 2, '0'))
}

fn period_name(t: f32) -> str {
    t = fract(t)
    names := [_]str{"Night", "Dawn", "Morning", "Noon", "Afternoon", "Dusk", "Night"}
    ends := [_]f32{0.21, 0.29, 0.45, 0.58, 0.71, 0.8, 2.0}
    k := 0
    while t >= ends[k] {
        k += 1
    }
    names[k]
}

// The colour of the horizon at time t (the HUD's strip of the day).
fn horizon_at(t: f32) -> vec3 {
    ramp(SKY_HOR[..], t)
}
