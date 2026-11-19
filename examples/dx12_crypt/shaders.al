// Crypt's HLSL (compiled at start-up with D3DCompile, see render.al): the lit scene, the
// additive effects (flames, glows, sparks, runes, the exit's beam) and the post-processing
// passes (bloom, then tone mapping and grading). The constant buffers here must match the AL
// structs DrawConsts, FrameConsts and PostConsts in render.al, which hlsl_cbuffer_size checks.

// What every scene shader sees: the per-frame constants (b1). The maze is passed as 17 rows of
// wall bits (row r is component r % 4 of map_rows[r / 4], as a float: exact up to 2^24), so a
// pixel can walk the grid towards a light and find out whether a wall is in the way.
priv const FRAME_HLSL = `
cbuffer Frame : register(b1) {
    float4x4 view_proj;
    float4 eye;              // xyz: the camera; w: the time in seconds
    float4 fog;              // rgb: the colour of the dark; w: its density per metre
    float4 params;           // x: unused, y: the number of lights
    float4 cam_right;        // the camera's axes in the world (billboards)
    float4 cam_up;
    float4 map_rows[5];
    float4 light_pos[16];    // xyz: position; w: radius (no light beyond it)
    float4 light_color[16];  // rgb: intensity; w: how fast it falls off, negative if the maze casts no shadows of it
};
static const float CELL = 2.0;
static const float WALL_H = 2.4;

float hash12(float2 p) {
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}
float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(lerp(hash12(i), hash12(i + float2(1.0, 0.0)), f.x), lerp(hash12(i + float2(0.0, 1.0)), hash12(i + 1.0), f.x), f.y);
}
`

// The scene: one vertex format for everything, the material picked by the vertex colour's
// alpha (0 floor, 1 wall, 2 ceiling: textured; 3 wood, 8 iron: plain; 4 gem; 5 a wraith's robe;
// 6 emissive; 7 stone with the wall texture laid over it by world position).
priv const SCENE_BODY = `
cbuffer Draw : register(b0) { float4x4 model; float4 tint; float4 fx; };   // fx: x emission, y roughness, w phase
Texture2DArray materials : register(t0);   // layers 0-2: albedo + roughness, 3-5: normal + cavity
SamplerState aniso : register(s0);

struct V {
    float4 pos : SV_POSITION;
    float3 world : WORLD;
    float3 normal : NORMAL;
    float3 color : COLOR;
    float3 local : LOCAL;
    nointerpolation uint id : MATERIAL;
};

V vs_main(float3 pos : POSITION, float3 normal : NORMAL, float4 color : COLOR) {
    V o;
    uint id = (uint)round(color.a * 255.0);
    float3 p = pos;
    if (id == 5) {
        // a wraith's robe ripples, more towards the hem
        float k = saturate(0.3 - pos.y);
        p.x += sin(eye.w * 3.1 + pos.y * 6.0 + fx.w) * 0.08 * k;
        p.z += cos(eye.w * 2.6 + pos.y * 5.0 + fx.w * 1.7) * 0.08 * k;
    }
    float4 w = mul(model, float4(p, 1.0));
    o.pos = mul(view_proj, w);
    o.world = w.xyz;
    o.normal = mul((float3x3)model, normal);
    o.color = color.rgb * tint.rgb;
    o.local = pos;
    o.id = id;
    return o;
}

bool is_wall(int2 c) {
    if (c.x < 0 || c.y < 0 || c.x >= 17 || c.y >= 17) return true;
    uint bits = (uint)map_rows[c.y >> 2][c.y & 3];
    return ((bits >> c.x) & 1) != 0;
}

// 1 if no wall lies between two points on the floor, else 0: a walk through the grid cells
// the segment crosses (Amanatides and Woo's traversal). The walls are as high as the ceiling,
// so this 2D test is exact for the maze, and every torch casts the maze's shadows.
float maze_shadow(float2 from, float2 to) {
    float2 p = from / CELL;
    float2 q = to / CELL;
    int2 c = (int2)floor(p);
    float2 d = q - p;
    int2 s = int2(d.x >= 0.0 ? 1 : -1, d.y >= 0.0 ? 1 : -1);
    float2 inv = 1.0 / max(abs(d), 1e-5);
    float2 t = float2(d.x >= 0.0 ? (c.x + 1.0 - p.x) : (p.x - c.x), d.y >= 0.0 ? (c.y + 1.0 - p.y) : (p.y - c.y)) * inv;
    [loop] for (int i = 0; i < 12; i++) {
        if (min(t.x, t.y) >= 1.0) return 1.0;
        if (t.x < t.y) { c.x += s.x; t.x += inv.x; } else { c.y += s.y; t.y += inv.y; }
        if (is_wall(c)) return 0.0;
    }
    return 1.0;
}

// Ambient occlusion from the maze itself, worked out per pixel: wall blocks near the point
// and in front of the surface darken it (corners twice), and so do the floor and the ceiling
// along the foot and the top of the walls.
float maze_ao(float3 p, float3 n) {
    float occ = 0.0;
    int2 c = (int2)floor(p.xz / CELL);
    [unroll] for (int dz = -1; dz <= 1; dz++) {
        [unroll] for (int dx = -1; dx <= 1; dx++) {
            int2 k = c + int2(dx, dz);
            if (!is_wall(k)) continue;
            float2 lo = float2(k) * CELL;
            float2 q = clamp(p.xz, lo, lo + CELL);
            float dist = length(q - p.xz);
            float3 centre = float3(lo.x + CELL * 0.5, WALL_H * 0.5, lo.y + CELL * 0.5) - p;
            float facing = saturate(dot(n, normalize(centre)) * 1.6);
            float f = saturate(1.0 - dist / 0.95);
            occ += facing * f * f;
        }
    }
    float side = 1.0 - abs(n.y);
    float fy = saturate(1.0 - p.y / 0.8);
    float fc = saturate(1.0 - (WALL_H - p.y) / 0.6);
    occ += side * (fy * fy + fc * fc * 0.7);
    return exp(-occ * 0.8);
}

// Lighting: every light of the frame's list, a Lambert diffuse term and a GGX specular one
// (Hammon's approximation of the visibility term, Schlick's Fresnel), inverse-square
// falloff windowed to the light's radius, and the maze's shadows for the lights that cast them.
float3 shade(float3 world, float3 n, float3 ng, float3 v, float3 albedo, float rough, float metal, float ao, float spec_scale) {
    float3 diffuse = 0.0;
    float3 spec = 0.0;
    int count = (int)params.y;
    float a = max(rough * rough, 0.002);
    float a2 = a * a;
    float3 f0 = lerp(float3(0.04, 0.04, 0.04), albedo, metal);
    float nv = saturate(dot(n, v)) + 1e-3;
    // the shadow rays start inside the floor cell the surface faces: a point on a wall's
    // corner could round into the wall block and see light through it
    float2 home = floor((world.xz + ng.xz * 0.5) / CELL) * CELL;
    float2 from = clamp(world.xz + ng.xz * 0.05, home + 0.01, home + CELL - 0.01);
    [loop] for (int k = 0; k < count; k++) {
        float4 lp = light_pos[k];
        float3 L = lp.xyz - world;
        float d2 = dot(L, L);
        if (d2 > lp.w * lp.w) continue;
        float d = sqrt(d2);
        L /= d;
        float nl = saturate(dot(n, L));
        if (nl <= 0.0 || dot(ng, L) < -0.1) continue;
        // falloff 1 / (1 + k d^2): k = 1 is about the inverse square, smaller is softer (the
        // lantern lights a corridor, not a spot); brought smoothly to zero at the radius
        float4 lc = light_color[k];
        float r = d / lp.w;
        float win = saturate(1.0 - r * r * r * r);
        float att = win * win / (1.0 + d2 * abs(lc.w));
        if (lc.w > 0.0) {
            att *= maze_shadow(from, lp.xz);
            if (att <= 0.0) continue;
        } else {
            // the player's lantern: its iron roof keeps most of the light off the ceiling
            att *= lerp(1.0, 0.3, smoothstep(0.45, 0.9, -L.y));
        }
        float3 h = normalize(L + v);
        float nh = saturate(dot(n, h));
        float dd = nh * nh * (a2 - 1.0) + 1.0;
        float D = a2 / (3.14159 * dd * dd);
        float3 F = f0 + (1.0 - f0) * pow(1.0 - saturate(dot(v, h)), 5.0);
        float G = 0.5 / lerp(2.0 * nl * nv, nl + nv, a);
        spec += lc.rgb * (att * nl * D * G) * F;
        diffuse += lc.rgb * (att * nl);
    }
    float3 ambient = float3(0.006, 0.009, 0.018) * (0.6 + 0.4 * n.y);
    return (albedo * (1.0 - metal) * (diffuse + ambient) + spec * spec_scale) * ao;
}

float4 ps_main(V i) : SV_TARGET {
    float3 ng = normalize(i.normal);
    float3 v = eye.xyz - i.world;
    float dist = length(v);
    v /= dist;
    float3 n = ng;
    float3 albedo = i.color;
    float rough = fx.y;
    float metal = 0.0;
    float ao = 1.0;
    float spec_scale = 1.0;
    float3 emit = 0.0;
    uint id = i.id;
    if (id <= 2) {
        // the maze: texture coordinates and tangents from the face's direction; a wall tile
        // spans one cell across and the whole height
        float2 uv;
        float3 t;
        float3 b;
        if (abs(ng.y) > 0.5) {
            uv = i.world.xz / CELL;
            t = float3(1.0, 0.0, 0.0);
            b = float3(0.0, 0.0, 1.0);
        } else if (abs(ng.x) > 0.5) {
            uv = float2(i.world.z / CELL, (WALL_H - i.world.y) / WALL_H);
            t = float3(0.0, 0.0, 1.0);
            b = float3(0.0, -1.0, 0.0);
        } else {
            uv = float2(i.world.x / CELL, (WALL_H - i.world.y) / WALL_H);
            t = float3(1.0, 0.0, 0.0);
            b = float3(0.0, -1.0, 0.0);
        }
        float4 a = materials.Sample(aniso, float3(uv, id));
        float4 nm = materials.Sample(aniso, float3(uv, id + 3));
        albedo = pow(a.rgb, 2.2) * i.color;
        float3 tn = nm.xyz * 2.0 - 1.0;
        // Toksvig: where the mipmaps average bumpy normals, the averaged normal is shorter than
        // 1; that spread becomes roughness, so distant relief does not sparkle
        float len = clamp(length(tn), 0.05, 1.0);
        rough = sqrt(saturate(a.a * a.a + (1.0 - len) / len));
        n = normalize(t * tn.x + b * tn.y + ng * tn.z);
        ao = (0.55 + 0.45 * nm.a) * maze_ao(i.world + ng * 0.01, ng);
    } else if (id == 7) {
        float2 uv = float2(i.world.x + i.world.z, i.world.y * 2.0) * 0.45;
        albedo = pow(materials.Sample(aniso, float3(uv, 1)).rgb, 2.2) * i.color;
        rough = 0.8;
        ao = maze_ao(i.world + ng * 0.01, ng);
    } else if (id == 8) {
        metal = 0.75;
        rough = 0.38;
    } else if (id == 4) {
        // a gem: light from inside, brightest at the glancing facets, and a sharp highlight
        // (each facet its own brightness, which changes as the gem turns: it sparkles)
        float fres = pow(1.0 - saturate(dot(ng, v)), 2.0);
        float facet = hash12(floor(ng.xz * 7.0 + ng.y * 3.0) + floor(ng.y * 5.0));
        float glint = pow(saturate(dot(reflect(-v, ng), normalize(float3(0.4, 1.0, 0.3)))), 16.0);
        emit = i.color * fx.x * (0.25 + 1.0 * facet * facet * facet + 0.6 * fres) + glint * fx.x * 3.0;
        albedo = i.color * 0.25;
        rough = 0.1;
        spec_scale = 3.0;
    } else if (id == 5) {
        // a wraith: a dark robe that frays into nothing at the hem, a cold glow at its rim
        float ang = atan2(i.local.z, i.local.x);
        float rag = vnoise(float2(ang * 3.0 + fx.w, eye.w * 1.3)) * 0.5 + vnoise(float2(ang * 9.0, eye.w * 2.1 + fx.w)) * 0.25;
        clip(i.local.y + 0.88 - rag * 0.45);
        float fres = pow(1.0 - saturate(abs(dot(ng, v))), 5.0);
        float swirl = vnoise(float2(ang * 2.0, i.local.y * 5.0 + eye.w * 1.5 + fx.w));
        float fade = saturate((i.local.y + 0.9) * 0.9);
        // folds of the robe: dark and pale streaks running down it, drifting slowly
        float folds = vnoise(float2(ang * 5.0 + fx.w, i.local.y * 1.5 - eye.w * 0.3));
        emit = i.color * fx.x * (fres * 1.6 + swirl * swirl * swirl * 0.06 + 0.06 * folds * folds + 0.012) * fade;
        albedo = i.color * 0.012;
        rough = 0.95;
        spec_scale = 0.2;
    } else if (id == 6) {
        // light itself: a torch's embers, a wraith's eyes, and (fx.z = 1) the lantern's glass,
        // amber with the shape of a flame inside it, flickering
        float3 e = i.color * fx.x;
        if (fx.z > 0.5) {
            float h = abs(i.local.x) > abs(i.local.z) ? i.local.z : i.local.x;
            float y = i.local.y + 0.012;
            float sway = 0.004 * sin(eye.w * 7.0) + 0.003 * sin(eye.w * 13.0);
            float flame = exp(-(h - sway * (y + 0.03) * 30.0) * (h - sway * (y + 0.03) * 30.0) * 2600.0 / (1.0 + max(-y, 0.0) * 30.0) - y * y * 700.0);
            e = i.color * fx.x * (0.22 + 2.2 * flame) + float3(1.0, 0.9, 0.7) * fx.x * flame * flame * 1.5;
        }
        float fd = 1.0 - exp(-dist * fog.w);
        return float4(lerp(e, fog.rgb, fd), 1.0);
    }
    float3 c = shade(i.world, n, ng, v, albedo, rough, metal, ao, spec_scale) + emit;
    float f = 1.0 - exp(-dist * fog.w);
    c = lerp(c, fog.rgb, f);
    return float4(c, 1.0);
}
`

// The effects: camera-facing quads added to the picture (blend one + one), tested against the
// depth buffer but not written to it. Each quad's kind picks a shape: 0 a soft glow, 1 a
// flame (a teardrop of scrolling noise, white-yellow at the core, orange-red at the edge), 2 a
// spark, 3 a ring of runes lying on the floor, 4 a beam of light. color.a is a random phase.
priv const FX_BODY = `
struct F { float4 pos : SV_POSITION; float2 uv : TEXCOORD; float4 color : COLOR; float kind : KIND; };
F vs_fx(float3 pos : POSITION, float2 uv : TEXCOORD, float kind : KIND, float4 color : COLOR) {
    F o;
    o.pos = mul(view_proj, float4(pos, 1.0));
    o.uv = uv;
    o.color = color;
    o.kind = kind;
    return o;
}
float4 ps_fx(F i) : SV_TARGET {
    float r2 = dot(i.uv, i.uv);
    float t = eye.w;
    float seed = i.color.a;
    int kind = (int)(i.kind + 0.5);
    float3 c = 0.0;
    if (kind == 0) {
        c = i.color.rgb * (exp(-r2 * 5.0) * saturate(1.0 - r2));
    } else if (kind == 1) {
        float y = i.uv.y * 0.5 + 0.5;
        float n1 = vnoise(float2(i.uv.x * 2.0 + seed * 13.0, y * 3.0 - t * 5.5));
        float n2 = vnoise(float2(i.uv.x * 5.0 - seed * 7.0, y * 7.0 - t * 9.0));
        float x = i.uv.x + ((n1 - 0.5) * 0.7 + (n2 - 0.5) * 0.35) * y;
        float width = 0.85 * (1.0 - y) * sqrt(saturate(y * 5.0)) + 0.01;
        float body = saturate(1.0 - abs(x) / width);
        body *= saturate((1.0 - y) * 2.5) * saturate(y * 12.0);
        float core = pow(body, 2.5) * saturate(1.0 - y * 1.4);
        float3 hot = lerp(float3(0.9, 0.16, 0.02), float3(1.0, 0.45, 0.08), body);
        c = i.color.rgb * (hot * body * body * 2.2 + float3(1.0, 0.62, 0.25) * core * 2.0);
    } else if (kind == 2) {
        float a = saturate(1.0 - sqrt(r2));
        c = i.color.rgb * (a * a * a);
    } else if (kind == 3) {
        float r = sqrt(r2);
        float ang = atan2(i.uv.y, i.uv.x) / 6.28318 + 0.5;
        float rings = smoothstep(0.035, 0.0, abs(r - 0.93)) + smoothstep(0.025, 0.0, abs(r - 0.68)) * 0.8;
        float turn = frac(ang + t * 0.02);
        float seg = frac(turn * 20.0);
        float cellv = floor(turn * 20.0);
        float glyph = step(0.5, vnoise(float2(cellv * 3.7 + floor(seg * 4.0) * 1.3, floor((r - 0.7) * 40.0))));
        float band = step(0.72, r) * step(r, 0.89) * step(0.12, seg) * step(seg, 0.88);
        float star = 0.0;
        [unroll] for (int k = 0; k < 3; k++) {
            float a = (k / 3.0 + t * 0.01) * 6.28318;
            float2 d = float2(cos(a), sin(a));
            star += smoothstep(0.02, 0.0, abs(dot(i.uv, d))) * step(r, 0.68);
        }
        float pulse = 0.75 + 0.25 * sin(t * 2.0);
        c = i.color.rgb * ((rings + band * glyph * 0.9 + star * 0.5) * pulse + exp(-r2 * 4.0) * 0.35) * step(r, 1.0);
    } else {
        float x = i.uv.x;
        float y = i.uv.y * 0.5 + 0.5;
        float a = pow(saturate(1.0 - x * x), 3.0) * (1.0 - y) * (0.6 + 0.4 * vnoise(float2(x * 3.0, y * 5.0 - t * 1.5)));
        c = i.color.rgb * a;
    }
    return float4(c, 0.0);
}
`

fn scene_shader() -> str { concat(FRAME_HLSL, SCENE_BODY) }
fn fx_shader() -> str { concat(FRAME_HLSL, FX_BODY) }

// Post-processing: one full-screen triangle per pass (no vertex buffer: the vertex id makes the
// corners), reading up to three textures. The constants per pass are three float4s.
const POST_SHADER = `
cbuffer Post : register(b0) { float4 p0; float4 p1; float4 p2; };
Texture2D t0 : register(t0);
Texture2D t1 : register(t1);
Texture2D t2 : register(t2);
SamplerState linear_clamp : register(s0);
struct P { float4 pos : SV_POSITION; float2 uv : TEXCOORD; };

P vs_full(uint id : SV_VertexID) {
    P o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    o.uv = uv;
    return o;
}

// The bright pass, at half the size: the average of 4 bilinear taps (16 texels), of which only
// what is brighter than the threshold p1.x stays (a soft knee, so nothing pops).
float4 ps_bright(P i) : SV_TARGET {
    float2 d = p0.xy;
    float3 c = (t0.Sample(linear_clamp, i.uv + float2(-d.x, -d.y)).rgb + t0.Sample(linear_clamp, i.uv + float2(d.x, -d.y)).rgb +
        t0.Sample(linear_clamp, i.uv + float2(-d.x, d.y)).rgb + t0.Sample(linear_clamp, i.uv + float2(d.x, d.y)).rgb) * 0.25;
    float br = max(c.r, max(c.g, c.b));
    float knee = p1.x * 0.5;
    float soft = clamp(br - p1.x + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    float k = max(soft, br - p1.x) / max(br, 1e-4);
    return float4(c * k, 1.0);
}

// A 9-tap Gaussian blur along p0.zw (texels of the source: p0.xy) in 5 bilinear taps.
float4 ps_blur(P i) : SV_TARGET {
    float2 d = p0.xy * p0.zw;
    float3 c = t0.Sample(linear_clamp, i.uv).rgb * 0.2270270;
    c += (t0.Sample(linear_clamp, i.uv + d * 1.3846154).rgb + t0.Sample(linear_clamp, i.uv - d * 1.3846154).rgb) * 0.3162162;
    c += (t0.Sample(linear_clamp, i.uv + d * 3.2307692).rgb + t0.Sample(linear_clamp, i.uv - d * 3.2307692).rgb) * 0.0702703;
    return float4(c, 1.0);
}

// Half the size again: 4 bilinear taps.
float4 ps_down(P i) : SV_TARGET {
    float2 d = p0.xy;
    float3 c = (t0.Sample(linear_clamp, i.uv + float2(-d.x, -d.y)).rgb + t0.Sample(linear_clamp, i.uv + float2(d.x, -d.y)).rgb +
        t0.Sample(linear_clamp, i.uv + float2(-d.x, d.y)).rgb + t0.Sample(linear_clamp, i.uv + float2(d.x, d.y)).rgb) * 0.25;
    return float4(c, 1.0);
}

float hash12(float2 p) {
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

// The tone-mapped picture: the scene plus its two blurred bright parts (bloom), exposure, ACES
// tone mapping (Narkowicz's fit), a grade (cool shadows, warm highlights), desaturation behind
// the menus, red at the edges when hurt, a vignette, gamma.
// p0.x: time; p1: bloom strength, exposure, vignette; p2: desaturation, hurt, flash.
float4 ps_composite(P i) : SV_TARGET {
    float3 c = t0.Sample(linear_clamp, i.uv).rgb;
    float3 b1 = t1.Sample(linear_clamp, i.uv).rgb;
    float3 b2 = t2.Sample(linear_clamp, i.uv).rgb;
    c += (b1 * 0.55 + b2 * 0.8) * p1.x;
    c *= p1.y * (1.0 + p2.z * 1.5);
    c = saturate((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14));
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    float3 cool = c * float3(0.82, 0.96, 1.18) + float3(0.0, 0.004, 0.012);
    float3 warm = c * float3(1.06, 1.0, 0.9);
    c = lerp(cool, warm, smoothstep(0.03, 0.5, l));
    c = lerp(c, float3(l, l, l) * 0.55, p2.x);
    float2 q = i.uv - 0.5;
    q.x *= 1.3;
    float vig = dot(q, q);
    c = lerp(c, float3(0.45, 0.0, 0.0), saturate(p2.y * smoothstep(0.0, 0.7, vig) * 1.4));
    c *= 1.0 - p1.z * smoothstep(0.08, 0.6, vig);
    c = pow(saturate(c), 1.0 / 2.2);
    return float4(c, 1.0);
}

// FXAA (Lottes' original, "FXAA 2"), on the tone-mapped picture: where the luminance of the
// four diagonal neighbours says there is an edge, blend along it (two taps, or four if those
// stay within the local range); then a little film grain, which also hides banding in the
// dark gradients. p0.xy: 1 / the size, p0.z: time, p0.w: grain.
float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }
float4 ps_fxaa(P i) : SV_TARGET {
    float2 px = p0.xy;
    float3 nw = t0.SampleLevel(linear_clamp, i.uv + float2(-0.5, -0.5) * px, 0).rgb;
    float3 ne = t0.SampleLevel(linear_clamp, i.uv + float2(0.5, -0.5) * px, 0).rgb;
    float3 sw = t0.SampleLevel(linear_clamp, i.uv + float2(-0.5, 0.5) * px, 0).rgb;
    float3 se = t0.SampleLevel(linear_clamp, i.uv + float2(0.5, 0.5) * px, 0).rgb;
    float3 m = t0.SampleLevel(linear_clamp, i.uv, 0).rgb;
    float lnw = luma(nw), lne = luma(ne), lsw = luma(sw), lse = luma(se), lm = luma(m);
    float lmin = min(lm, min(min(lnw, lne), min(lsw, lse)));
    float lmax = max(lm, max(max(lnw, lne), max(lsw, lse)));
    float2 dir = float2(-((lnw + lne) - (lsw + lse)), (lnw + lsw) - (lne + lse));
    float reduce = max((lnw + lne + lsw + lse) * 0.25 * (1.0 / 8.0), 1.0 / 128.0);
    float rcp_min = 1.0 / (min(abs(dir.x), abs(dir.y)) + reduce);
    dir = clamp(dir * rcp_min, -8.0, 8.0) * px;
    float3 a = 0.5 * (t0.SampleLevel(linear_clamp, i.uv + dir * (1.0 / 3.0 - 0.5), 0).rgb +
        t0.SampleLevel(linear_clamp, i.uv + dir * (2.0 / 3.0 - 0.5), 0).rgb);
    float3 b = a * 0.5 + 0.25 * (t0.SampleLevel(linear_clamp, i.uv - dir * 0.5, 0).rgb +
        t0.SampleLevel(linear_clamp, i.uv + dir * 0.5, 0).rgb);
    float lb = luma(b);
    float3 c = (lb < lmin || lb > lmax) ? a : b;
    c += (hash12(i.pos.xy + frac(p0.z * 7.13) * 917.0) - 0.5) * p0.w;
    return float4(c, 1.0);
}
`

// The MSAA resolve: the samples of a pixel averaged with weights 1 / (1 + brightest channel)
// (Karis), which is about averaging them after tone mapping: a bright sample next to a dark one
// gives a pixel in between, as it looks, instead of one nearly as bright as the bright sample.
// p0.x: the number of samples.
fn resolve_shader() -> str { concat(POST_COMMON, `
Texture2DMS<float4> ms : register(t0);
float4 ps_resolve(P i) : SV_TARGET {
    int2 xy = int2(i.pos.xy);
    int n = (int)p0.x;
    float3 sum = 0.0;
    float wsum = 0.0;
    for (int k = 0; k < n; k++) {
        float3 c = ms.Load(xy, k).rgb;
        float w = 1.0 / (1.0 + max(c.r, max(c.g, c.b)));
        sum += c * w;
        wsum += w;
    }
    return float4(sum / wsum, 1.0);
}
`) }

// The part every full-screen pass shares: the constants and the vertex shader.
priv const POST_COMMON = `
cbuffer Post : register(b0) { float4 p0; float4 p1; float4 p2; };
SamplerState linear_clamp : register(s0);
struct P { float4 pos : SV_POSITION; float2 uv : TEXCOORD; };
P vs_full(uint id : SV_VertexID) {
    P o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    o.uv = uv;
    return o;
}
`
