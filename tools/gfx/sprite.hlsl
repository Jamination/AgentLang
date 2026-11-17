// The one shader of std.gfx, Direct3D 12 (std/gfx_dx12.al). Compiled by tools/gen_gfx_shaders.al
// into std/gfx_shaders.al; tools/gfx/sprite.vert and sprite.frag are the same for Vulkan.
//
// Vertices are in target pixels (origin top left); `view` maps them to clip space (xy: scale,
// zw: offset). A texture coordinate below -1 means "no texture": the vertex colour alone.
// A coverage texture (one channel) is read as (1, 1, 1, coverage) through its view's swizzle.
cbuffer View : register(b0) { float4 view; };
Texture2D tex : register(t0);
SamplerState samp : register(s0);

struct V {
    float4 pos : SV_POSITION;
    float2 uv : TEXCOORD;
    float4 color : COLOR;
};

V vs_main(float2 pos : POSITION, float2 uv : TEXCOORD, float4 color : COLOR) {
    V o;
    o.pos = float4(pos * view.xy + view.zw, 0.0, 1.0);
    o.uv = uv;
    o.color = color;
    return o;
}

float4 ps_main(V i) : SV_TARGET {
    float4 t = tex.SampleLevel(samp, i.uv, 0.0);
    return (i.uv.x < -1.0 ? float4(1.0, 1.0, 1.0, 1.0) : t) * i.color;
}
