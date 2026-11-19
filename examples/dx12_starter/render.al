// The starter's Direct3D 12 renderer (Windows only), on the device code of ../gamekit/dx12_gpu.al.
// A frame goes through these passes:
//
//   scene     HDR target (RGBA16F) the size of the game's area in the window: the nebula
//             background (a shader over art.al's noise texture), then the sprites of the world
//             in one indexed draw. Sprites are premultiplied, blended ONE / INV_SRC_ALPHA, so
//             a vertex colour with alpha 0 adds light (glows, fire, sparks) and alpha 1 covers
//             (ship, rocks, smoke), in painter's order in one batch, and colours may exceed 1.
//   bloom     what is brighter than a threshold, at a quarter of the size, blurred (separable
//             Gaussian, horizontal then vertical), and again at an eighth for a wide halo.
//   composite into the back buffer: scene + bloom, a tone curve that lets hot colours burn
//             to white, damage flash, colour fringes while the screen shakes, vignette,
//             dither; black bars around the game's area (aspect ratio kept).
//   HUD       the sprites added after batch_hud, over the finished picture (not bloomed).
//
// It draws into a window's swap chain (two frames in flight) or into a texture of its own
// (offscreen: screenshots), and can read the finished picture back. On WARP the scene is drawn
// at most WARP_SCALE times the virtual resolution and scaled up by the composite (60 fps in a
// 960 x 540 window; about 20 fullscreen at 1920 x 1200). With the debug layer on, the messages
// it stores are printed after each frame, and renderer_close reports any live objects.
use std.window
use std.image
use "../gamekit/dx12_gpu.al"
use "art.al"

const SCENE_FORMAT = DXGI_FORMAT_R16G16B16A16_FLOAT
const OUT_FORMAT = DXGI_FORMAT_R8G8B8A8_UNORM
const RENDER_FRAMES = 2
const SPRITE_CAP = 8192           // sprites per frame (four vertices each: 16-bit indices)
const WARP_SCALE = 3              // the software rasterizer draws the scene at most this sharp

// One corner of a sprite: virtual pixels, atlas coordinates, premultiplied colour (may exceed 1),
// and how the shader reads the texel: 0 as it is, SDF_TEXT / SDF_HALO as a distance field.
struct GlowVertex { pos: vec2, uv: vec2, color: vec4, mode: f32 }

// The sprites of one frame, written straight into the mapped upload buffer.
struct Batch {
    verts: []GlowVertex           // this frame's region
    count: i64
    hud_start: i64                // the first sprite of the HUD
    texel: vec2                   // 1 / the atlas size
    offset: vec2                  // added to every position (the shake of the screen)
    mode: f32                     // the mode of the sprites added (text.al sets it while it draws)
    white: Tile
}

// What the passes after the scene do with it in this frame.
struct Post {
    time: f32
    bloom: f32                    // strength of the halo
    exposure: f32
    flash: f32                    // 0..1: the damage flash
    flash_color: vec3
    fringe: f32                   // colour fringes, in virtual pixels
    desaturate: f32               // 0..1
}

// Root constants of every pass: three float4 (the shader's cbuffer K).
struct PassConsts { k0: vec4, k1: vec4, k2: vec4 }
const PASS_VALUES = hlsl_cbuffer_size[PassConsts]() / 4

// Descriptor tables: three shader resource views each (t0, t1, t2).
priv const SLOT_SPRITES = 0       // atlas, nebula
priv const SLOT_SCENE = 1
priv const SLOT_A = 2
priv const SLOT_B = 3
priv const SLOT_C = 4
priv const SLOT_D = 5
priv const SLOT_COMPOSITE = 6     // scene, bloom A, bloom C
priv const SLOTS = 7
// Render-target views: the back buffers, then these.
priv const RTV_SCENE = RENDER_FRAMES
priv const RTV_BLOOM = RENDER_FRAMES + 1   // A, B, C, D
priv const RTVS = RENDER_FRAMES + 5

struct Renderer {
    w: *Window                    // nil: offscreen
    g: Gpu
    swap: *IDXGISwapChain3        // nil: offscreen
    frames: i64
    back: [RENDER_FRAMES]*ID3D12Resource
    allocators: [RENDER_FRAMES]*ID3D12CommandAllocator
    done: [RENDER_FRAMES]u64      // the fence value of the last frame drawn into each back buffer
    list: *ID3D12GraphicsCommandList
    rtv_heap: *ID3D12DescriptorHeap
    srv_heap: *ID3D12DescriptorHeap   // shader visible: SLOTS tables of three views
    srv_step: u64
    root: *ID3D12RootSignature
    pso_scene: *ID3D12PipelineState   // sprites into the HDR scene
    pso_hud: *ID3D12PipelineState     // sprites into the back buffer
    pso_background: *ID3D12PipelineState
    pso_bright: *ID3D12PipelineState
    pso_blur: *ID3D12PipelineState
    pso_composite: *ID3D12PipelineState
    atlas: *ID3D12Resource
    nebula: *ID3D12Resource
    vertices: *ID3D12Resource
    mapped: []GlowVertex
    indices: *ID3D12Resource
    scene: *ID3D12Resource
    bloom: [4]*ID3D12Resource     // A, B: a quarter of the scene; C, D: an eighth
    bloom_size: [4](i64, i64)
    width: i64                    // of the back buffers
    height: i64
    view: (i64, i64, i64, i64)    // the game's area in them: x, y, width, height
    scene_w: i64                  // the scene's size: the view's, at most WARP_SCALE times the
    scene_h: i64                  // virtual resolution on WARP (the composite scales it up)
    view_w: i64                   // the virtual resolution
    view_h: i64
    batch: Batch
    frame: i64
    vsync: bool
    resizes: i64
    info: *ID3D12InfoQueue        // the debug layer's messages, or nil
    messages: i64                 // how many were printed
}

priv const SHADERS = `
cbuffer K : register(b0) { float4 k0; float4 k1; float4 k2; };
Texture2D t0 : register(t0);
Texture2D t1 : register(t1);
Texture2D t2 : register(t2);
SamplerState clamp_s : register(s0);
SamplerState wrap_s : register(s1);

struct SV { float4 pos : SV_POSITION; float2 uv : TEXCOORD; float4 color : COLOR; float mode : MODE; };
SV vs_sprite(float2 pos : POSITION, float2 uv : TEXCOORD, float4 color : COLOR, float mode : MODE) {
    SV o;
    o.pos = float4(pos.x * k0.x - 1.0, 1.0 - pos.y * k0.y, 0.0, 1.0);
    o.uv = uv;
    o.color = color;
    o.mode = mode;
    return o;
}
// mode 1: a distance field (0.5 on the edge) cut with a smooth step one screen pixel wide;
// mode 2: the distance outside the edge as a soft halo, fading inside the letters
float4 ps_sprite(SV i) : SV_TARGET {
    float4 t = t0.Sample(clamp_s, i.uv);
    if (i.mode > 0.5) {
        float d = t.a;
        float w = max(fwidth(d) * 0.7, 0.002);
        float a = i.mode < 1.5 ? smoothstep(0.5 - w, 0.5 + w, d) : pow(saturate(d * 2.0), 3.5) * (1.0 - 0.8 * smoothstep(0.5, 0.65, d));
        t = float4(a, a, a, a);
    }
    return t * i.color;
}

// one triangle that covers the target; uv 0..1 from the top left
struct FV { float4 pos : SV_POSITION; float2 uv : TEXCOORD; };
FV vs_full(uint id : SV_VertexID) {
    FV o;
    o.uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(o.uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return o;
}

// k0: time, -, virtual width, height. Deep space with two drifting cloud layers and dust.
float4 ps_background(FV i) : SV_TARGET {
    float2 p = i.uv * k0.zw;
    float t = k0.x;
    float3 c = lerp(float3(0.008, 0.009, 0.026), float3(0.024, 0.010, 0.036), i.uv.y);
    float a = smoothstep(0.42, 0.78, t1.Sample(wrap_s, p / 300.0 + float2(0.17, -t * 0.0060)).r);
    float b = smoothstep(0.45, 0.80, t1.Sample(wrap_s, p / 210.0 + float2(0.61, -t * 0.0105)).g);
    float d = smoothstep(0.45, 0.75, t1.Sample(wrap_s, p / 120.0 + float2(0.33, -t * 0.0190)).b);
    float a2 = a * a;
    float b2 = b * b;
    c += float3(0.30, 0.06, 0.34) * a2 * 0.85;
    c += float3(0.02, 0.20, 0.34) * b2 * 1.3;
    c += float3(0.70, 0.30, 0.55) * a2 * b2 * 0.9;
    c *= 1.0 - 0.6 * d * saturate(a + b);
    return float4(c, 1.0);
}

// k0.xy: source texel size times the tap offset, k0.z: threshold, k0.w: knee.
// Four bilinear taps (a 4 x 4 box when shrinking by 4), then the bright part only.
float4 ps_bright(FV i) : SV_TARGET {
    float2 o = k0.xy;
    float3 c = t0.Sample(clamp_s, i.uv + float2(-o.x, -o.y)).rgb + t0.Sample(clamp_s, i.uv + float2(o.x, -o.y)).rgb
             + t0.Sample(clamp_s, i.uv + float2(-o.x, o.y)).rgb + t0.Sample(clamp_s, i.uv + float2(o.x, o.y)).rgb;
    c *= 0.25;
    float br = max(c.r, max(c.g, c.b));
    float soft = clamp(br - k0.z + k0.w, 0.0, 2.0 * k0.w);
    soft = soft * soft / (4.0 * k0.w + 1e-5);
    return float4(c * max(soft, br - k0.z) / max(br, 1e-4), 1.0);
}

// k0.xy: one texel along the blur's direction. Nine taps of a Gaussian in five bilinear ones.
float4 ps_blur(FV i) : SV_TARGET {
    float2 d = k0.xy;
    float3 c = t0.Sample(clamp_s, i.uv).rgb * 0.2270270270;
    c += (t0.Sample(clamp_s, i.uv + d * 1.3846153846).rgb + t0.Sample(clamp_s, i.uv - d * 1.3846153846).rgb) * 0.3162162162;
    c += (t0.Sample(clamp_s, i.uv + d * 3.2307692308).rgb + t0.Sample(clamp_s, i.uv - d * 3.2307692308).rgb) * 0.0702702703;
    return float4(c, 1.0);
}

// k0: bloom near, bloom wide, exposure, time; k1: flash, vignette, fringe (uv), desaturation;
// k2: flash colour, target width in pixels.
float3 shoulder(float3 x) {
    float k = 0.68;
    float3 over = max(x - k, 0.0);
    return min(x, k) + (1.0 - k) * (1.0 - exp(-over / (1.0 - k)));
}
float4 ps_composite(FV i) : SV_TARGET {
    float2 uv = i.uv;
    float2 d = uv - 0.5;
    float2 f = d * k1.z;
    float3 s;
    s.r = t0.Sample(clamp_s, uv - f).r;
    s.g = t0.Sample(clamp_s, uv).g;
    s.b = t0.Sample(clamp_s, uv + f).b;
    float3 c = s + t1.Sample(clamp_s, uv).rgb * k0.x + t2.Sample(clamp_s, uv).rgb * k0.y;
    c *= k0.z;
    float v = dot(d, d);
    c = lerp(c, c * float3(1.2, 0.75, 0.75), k1.x * 0.5);
    c += k2.rgb * k1.x * smoothstep(0.08, 0.5, v) * 1.1;
    float hot = max(c.r, max(c.g, c.b));
    c = shoulder(c);
    c = lerp(c, float3(1.0, 1.0, 1.0), saturate((hot - 1.6) * 0.18));
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    c = lerp(c, float3(lum, lum, lum) * float3(0.85, 0.9, 1.1), k1.w);
    c *= 1.0 - k1.y * v * 1.7;
    float2 px = uv * float2(k2.w, k2.w * 0.5625) + frac(k0.w * 7.31);
    float n = frac(sin(dot(px, float2(12.9898, 78.233))) * 43758.5453);
    c += (n - 0.5) / 255.0;
    return float4(c, 1.0);
}
`

// ---- set-up ----------------------------------------------------------------------------------

// A texture holding an RGBA8 image, uploaded before it returns; left as a shader resource.
priv fn upload_texture(g: *Gpu, img: Image) -> *ID3D12Resource {
    tex := gpu_texture(g, img.w, img.h, DXGI_FORMAT_R8G8B8A8_UNORM, D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST, nil)
    desc := tex.GetDesc()
    footprint: D3D12_PLACED_SUBRESOURCE_FOOTPRINT
    total: u64
    g.device.GetCopyableFootprints(&desc, 0, 1, 0, &footprint, nil, nil, &total)
    staging := gpu_buffer(g, D3D12_HEAP_TYPE_UPLOAD, i64(total), D3D12_RESOURCE_STATE_GENERIC_READ)
    mapped: *u8
    none := D3D12_RANGE{0, 0}
    dx_check(staging.Map(0, &none, &mapped), "ID3D12Resource::Map (texture upload)")
    rows := mkslice[u8](mapped, i64(total))
    pitch := i64(footprint.Footprint.RowPitch)
    for y in 0..img.h {
        copy(rows[y * pitch..y * pitch + img.w * 4], img.pix[y * img.w * 4..(y + 1) * img.w * 4])
    }
    staging.Unmap(0, nil)
    allocator, list := gpu_command_list(g)
    gpu_reset(allocator, list)
    dst := D3D12_TEXTURE_COPY_LOCATION{pResource: tex, Type: D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}
    src := D3D12_TEXTURE_COPY_LOCATION{pResource: staging, Type: D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT}
    *src.u_PlacedFootprint() = footprint
    list.CopyTextureRegion(&dst, 0, 0, 0, &src, nil)
    dx_barrier(list, tex, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
    gpu_execute(g, list)
    gpu_flush(g)
    com_release(&list)
    com_release(&allocator)
    com_release(&staging)
    tex
}

// A pipeline from two entry points of SHADERS. Sprites have the vertex layout and blending of
// premultiplied colour; the full-screen passes have neither. "" or what failed.
priv fn make_pipeline(r: *Renderer, vs_name: str, ps_name: str, format: i32, sprites: bool, out: **ID3D12PipelineState) -> str {
    vs, verr := dx_compile(SHADERS, vs_name, "vs_5_0")
    if verr != "" { return verr }
    ps, perr := dx_compile(SHADERS, ps_name, "ps_5_0")
    if perr != "" {
        com_release(&vs)
        return perr
    }
    layout := [4]D3D12_INPUT_ELEMENT_DESC{
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("POSITION"), Format: DXGI_FORMAT_R32G32_FLOAT, AlignedByteOffset: u32(offsetof[GlowVertex](pos))},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("TEXCOORD"), Format: DXGI_FORMAT_R32G32_FLOAT, AlignedByteOffset: u32(offsetof[GlowVertex](uv))},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("COLOR"), Format: DXGI_FORMAT_R32G32B32A32_FLOAT, AlignedByteOffset: u32(offsetof[GlowVertex](color))},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("MODE"), Format: DXGI_FORMAT_R32_FLOAT, AlignedByteOffset: u32(offsetof[GlowVertex](mode))},
    }
    desc := dx_pipeline_desc(r.root, vs, ps, format)
    if sprites {
        desc.InputLayout = D3D12_INPUT_LAYOUT_DESC{ptr(layout), 4}
        blend := &desc.BlendState.RenderTarget[0]
        blend.BlendEnable = 1
        blend.SrcBlend = D3D12_BLEND_ONE
        blend.DestBlend = D3D12_BLEND_INV_SRC_ALPHA
        blend.SrcBlendAlpha = D3D12_BLEND_ONE
        blend.DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA
    }
    hr := r.g.device.CreateGraphicsPipelineState(&desc, &IID_ID3D12PipelineState, out)
    com_release(&vs)
    com_release(&ps)
    if FAILED(hr) { return hresult_text(fmt("CreateGraphicsPipelineState (", ps_name, ")"), hr) }
    ""
}

// Everything that does not depend on the size of the picture. "" or what failed.
priv fn renderer_setup(r: *Renderer, art: *Art, debug: bool) -> str {
    g := &r.g
    if debug && SUCCEEDED(g.device.QueryInterface(&IID_ID3D12InfoQueue, &r.info)) {
        r.info.SetMessageCountLimit(4096)
    }
    // root signature: 12 constants (b0), a table of three views (t0..t2), two linear samplers
    params: [2]D3D12_ROOT_PARAMETER
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS
    params[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL
    params[0].u_Constants().Num32BitValues = u32(PASS_VALUES)
    range := D3D12_DESCRIPTOR_RANGE{RangeType: D3D12_DESCRIPTOR_RANGE_TYPE_SRV, NumDescriptors: 3}
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE
    params[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL
    params[1].u_DescriptorTable().NumDescriptorRanges = 1
    params[1].u_DescriptorTable().pDescriptorRanges = &range
    samplers: [2]D3D12_STATIC_SAMPLER_DESC
    for i in 0..2 {
        mode := if i == 0 { D3D12_TEXTURE_ADDRESS_MODE_CLAMP } else { D3D12_TEXTURE_ADDRESS_MODE_WRAP }
        samplers[i] = D3D12_STATIC_SAMPLER_DESC{
            Filter: D3D12_FILTER_MIN_MAG_MIP_LINEAR, AddressU: mode, AddressV: mode, AddressW: mode,
            ComparisonFunc: D3D12_COMPARISON_FUNC_NEVER, MaxLOD: 3.4e38, ShaderRegister: u32(i),
            ShaderVisibility: D3D12_SHADER_VISIBILITY_PIXEL,
        }
    }
    root_desc := D3D12_ROOT_SIGNATURE_DESC{NumParameters: 2, pParameters: ptr(params), NumStaticSamplers: 2,
        pStaticSamplers: ptr(samplers), Flags: D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT}
    root, err := dx_root_signature(g, &root_desc)
    if err != "" { return err }
    r.root = root
    err = make_pipeline(r, "vs_sprite", "ps_sprite", SCENE_FORMAT, true, &r.pso_scene)
    if err == "" { err = make_pipeline(r, "vs_sprite", "ps_sprite", OUT_FORMAT, true, &r.pso_hud) }
    if err == "" { err = make_pipeline(r, "vs_full", "ps_background", SCENE_FORMAT, false, &r.pso_background) }
    if err == "" { err = make_pipeline(r, "vs_full", "ps_bright", SCENE_FORMAT, false, &r.pso_bright) }
    if err == "" { err = make_pipeline(r, "vs_full", "ps_blur", SCENE_FORMAT, false, &r.pso_blur) }
    if err == "" { err = make_pipeline(r, "vs_full", "ps_composite", OUT_FORMAT, false, &r.pso_composite) }
    if err != "" { return err }

    r.atlas = upload_texture(g, art.atlas)
    r.nebula = upload_texture(g, art.nebula)
    // the sprites' vertices: one region per frame in flight, persistently mapped; and the
    // indices of every quad, the same for all frames
    none := D3D12_RANGE{0, 0}
    count := r.frames * SPRITE_CAP * 4
    r.vertices = gpu_buffer(g, D3D12_HEAP_TYPE_UPLOAD, count * sizeof[GlowVertex](), D3D12_RESOURCE_STATE_GENERIC_READ)
    vmapped: *u8
    dx_check(r.vertices.Map(0, &none, &vmapped), "ID3D12Resource::Map (sprite vertices)")
    r.mapped = mkslice[GlowVertex](cast[*GlowVertex](vmapped), count)
    quads := alloc[u16](SPRITE_CAP * 6)
    for i in 0..SPRITE_CAP {
        b := u16(i * 4)
        quads[i * 6] = b
        quads[i * 6 + 1] = b + 1
        quads[i * 6 + 2] = b + 2
        quads[i * 6 + 3] = b + 2
        quads[i * 6 + 4] = b + 1
        quads[i * 6 + 5] = b + 3
    }
    r.indices = gpu_upload(g, as_bytes(quads))

    for i in 0..r.frames {
        gpu_check(g, g.device.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator,
            &r.allocators[i]), "CreateCommandAllocator")
    }
    gpu_check(g, g.device.CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, r.allocators[0], nil,
        &IID_ID3D12GraphicsCommandList, &r.list), "CreateCommandList")
    gpu_check(g, r.list.Close(), "ID3D12GraphicsCommandList::Close")
    r.rtv_heap = gpu_descriptor_heap(g, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, RTVS, false)
    r.srv_heap = gpu_descriptor_heap(g, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, SLOTS * 3, true)
    r.srv_step = u64(g.device.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV))
    r.batch.texel = vec2(1.0) / vec2(f32(art.atlas.w), f32(art.atlas.h))
    r.batch.white = art.white
    ""
}

priv fn put_view(r: *Renderer, slot: i64, k: i64, tex: *ID3D12Resource) {
    desc := tex.GetDesc()
    view := D3D12_SHADER_RESOURCE_VIEW_DESC{Format: desc.Format, ViewDimension: D3D12_SRV_DIMENSION_TEXTURE2D,
        Shader4ComponentMapping: D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING}
    view.u_Texture2D().MipLevels = 1
    h := r.srv_heap.GetCPUDescriptorHandleForHeapStart()
    h.ptr += u64(slot * 3 + k) * r.srv_step
    r.g.device.CreateShaderResourceView(tex, &view, h)
}

priv fn put_slot(r: *Renderer, slot: i64, a: *ID3D12Resource, b: *ID3D12Resource, c: *ID3D12Resource) {
    put_view(r, slot, 0, a)
    put_view(r, slot, 1, b)
    put_view(r, slot, 2, c)
}

// The back buffers' views, and the scene and bloom targets for the current size.
priv fn create_targets(r: *Renderer) {
    g := &r.g
    for i in 0..r.frames {
        if r.swap != nil {
            gpu_check(g, r.swap.GetBuffer(u32(i), &IID_ID3D12Resource, &r.back[i]), "IDXGISwapChain::GetBuffer")
        }
        g.device.CreateRenderTargetView(r.back[i], nil, gpu_cpu_handle(g, r.rtv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, i))
    }
    r.view = fit_rect(r.width, r.height, r.view_w, r.view_h)
    _, _, vw, vh := r.view
    if g.warp && vw > r.view_w * WARP_SCALE {
        vw = r.view_w * WARP_SCALE
        vh = r.view_h * WARP_SCALE
    }
    r.scene_w = vw
    r.scene_h = vh
    black := [4]f32{0.0, 0.0, 0.0, 1.0}
    r.scene = gpu_texture(g, vw, vh, SCENE_FORMAT, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, &black)
    g.device.CreateRenderTargetView(r.scene, nil, gpu_cpu_handle(g, r.rtv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, RTV_SCENE))
    for k in 0..4 {
        div := if k < 2 { 4 } else { 8 }
        r.bloom_size[k] = (max(vw / div, 1), max(vh / div, 1))
        r.bloom[k] = gpu_texture(g, r.bloom_size[k].0, r.bloom_size[k].1, SCENE_FORMAT, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
            D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, &black)
        g.device.CreateRenderTargetView(r.bloom[k], nil, gpu_cpu_handle(g, r.rtv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, RTV_BLOOM + k))
    }
    put_slot(r, SLOT_SPRITES, r.atlas, r.nebula, r.atlas)
    put_slot(r, SLOT_SCENE, r.scene, r.scene, r.scene)
    for k in 0..4 {
        put_slot(r, SLOT_A + k, r.bloom[k], r.bloom[k], r.bloom[k])
    }
    put_slot(r, SLOT_COMPOSITE, r.scene, r.bloom[0], r.bloom[2])
}

priv fn release_targets(r: *Renderer) {
    for i in 0..RENDER_FRAMES {
        if r.swap != nil {
            com_release(&r.back[i])
        }
    }
    com_release(&r.scene)
    for k in 0..4 {
        com_release(&r.bloom[k])
    }
}

priv fn renderer_new(warp: bool, debug: bool) -> (*Renderer, str) {
    gpu, err := gpu_open(debug, warp)
    if err != "" {
        return (nil, fmt("no Direct3D 12 device: ", err))
    }
    r := new[Renderer]()
    r.g = gpu
    r.vsync = true
    (r, "")
}

// A renderer on a window, for a game of view_w x view_h virtual pixels: a flip-model swap
// chain on its HWND. `debug`: the D3D12 debug layer, if it is installed. (renderer, "") or
// (nil, why).
fn renderer_window(w: *Window, view_w: i64, view_h: i64, art: *Art, warp: bool, debug: bool) -> (*Renderer, str) {
    r, err := renderer_new(warp, debug)
    if err != "" { return (nil, err) }
    r.w = w
    r.frames = RENDER_FRAMES
    r.view_w = view_w
    r.view_h = view_h
    width, height := w.size()
    r.width = max(width, 1)
    r.height = max(height, 1)
    desc := DXGI_SWAP_CHAIN_DESC1{
        Width: u32(r.width), Height: u32(r.height), Format: OUT_FORMAT, SampleDesc: DXGI_SAMPLE_DESC{Count: 1},
        BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT, BufferCount: RENDER_FRAMES, SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
    }
    swap1: *IDXGISwapChain1
    hr := r.g.factory.CreateSwapChainForHwnd(cast[*IUnknown](r.g.queue), win32_hwnd(w), &desc, nil, nil, &swap1)
    if FAILED(hr) {
        gpu_close(&r.g)
        return (nil, hresult_text("CreateSwapChainForHwnd", hr))
    }
    gpu_check(&r.g, swap1.QueryInterface(&IID_IDXGISwapChain3, &r.swap), "QueryInterface IDXGISwapChain3")
    com_release(&swap1)
    // fullscreen is std.window's borderless window (set_fullscreen), not DXGI's Alt+Enter
    r.g.factory.MakeWindowAssociation(win32_hwnd(w), DXGI_MWA_NO_ALT_ENTER)
    serr := renderer_setup(r, art, debug)
    if serr != "" {
        renderer_close(r)
        return (nil, serr)
    }
    create_targets(r)
    (r, "")
}

// A renderer that draws into a texture of width x height (one frame in flight): screenshots.
fn renderer_offscreen(width: i64, height: i64, view_w: i64, view_h: i64, art: *Art, warp: bool, debug: bool) -> (*Renderer, str) {
    r, err := renderer_new(warp, debug)
    if err != "" { return (nil, err) }
    r.frames = 1
    r.view_w = view_w
    r.view_h = view_h
    r.width = width
    r.height = height
    serr := renderer_setup(r, art, debug)
    if serr != "" {
        renderer_close(r)
        return (nil, serr)
    }
    black := [4]f32{0.0, 0.0, 0.0, 1.0}
    r.back[0] = gpu_texture(&r.g, width, height, OUT_FORMAT, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT, &black)
    create_targets(r)
    (r, "")
}

priv fn resize(r: *Renderer, width: i64, height: i64) {
    gpu_flush(&r.g)
    release_targets(r)
    gpu_check(&r.g, r.swap.ResizeBuffers(u32(r.frames), u32(width), u32(height), DXGI_FORMAT_UNKNOWN, 0), "IDXGISwapChain::ResizeBuffers")
    r.width = width
    r.height = height
    r.resizes += 1
    create_targets(r)
}

// Waits for the GPU and releases everything (not the window).
fn renderer_close(r: *Renderer) {
    if r.g.queue != nil {
        gpu_flush(&r.g)
    }
    print_messages(r)
    if r.vertices != nil && len(r.mapped) > 0 {
        r.vertices.Unmap(0, nil)
        r.mapped = nil
    }
    release_targets(r)
    for i in 0..RENDER_FRAMES {
        com_release(&r.allocators[i])
        com_release(&r.back[i])
    }
    com_release(&r.list)
    com_release(&r.vertices)
    com_release(&r.indices)
    com_release(&r.atlas)
    com_release(&r.nebula)
    com_release(&r.rtv_heap)
    com_release(&r.srv_heap)
    com_release(&r.pso_scene)
    com_release(&r.pso_hud)
    com_release(&r.pso_background)
    com_release(&r.pso_bright)
    com_release(&r.pso_blur)
    com_release(&r.pso_composite)
    com_release(&r.root)
    com_release(&r.swap)
    // with the debug layer: what is still alive now, other than the device with its queue and
    // fence (gpu_close releases those), has leaked
    if r.info != nil {
        dbg: *ID3D12DebugDevice
        if SUCCEEDED(r.g.device.QueryInterface(&IID_ID3D12DebugDevice, &dbg)) {
            eprint("d3d12 debug layer: objects alive before the device, its queue and fence are released:")
            dbg.ReportLiveDeviceObjects(D3D12_RLDO_DETAIL | D3D12_RLDO_IGNORE_INTERNAL)
            com_release(&dbg)
            print_messages(r)
        }
    }
    com_release(&r.info)
    gpu_close(&r.g)
}

// Prints the debug layer's new messages (with --debug-layer).
priv fn print_messages(r: *Renderer) {
    if r.info == nil {
        return
    }
    n := i64(r.info.GetNumStoredMessages())
    for i in 0..n {
        size: u64
        r.info.GetMessage(u64(i), nil, &size)
        m := mark()
        buf := alloc[u8](i64(size))
        msg := cast[*D3D12_MESSAGE](ptr(buf))
        if SUCCEEDED(r.info.GetMessage(u64(i), msg, &size)) {
            text := mkslice[u8](msg.pDescription, i64(msg.DescriptionByteLength))
            eprint(fmt("d3d12 debug layer: ", trim_right(text, "\0")))
        }
        release(m)
        r.messages += 1
    }
    r.info.ClearStoredMessages()
}

// ---- the batch -------------------------------------------------------------------------------

// A colour that covers what is below: rgb with opacity a.
fn cover(rgb: vec3, a: f32) -> vec4 { vec4(rgb * a, a) }

// A colour that adds light: rgb times intensity k (above 1: into the bloom).
fn light(rgb: vec3, k: f32) -> vec4 { vec4(rgb * k, 0.0) }

// A sprite: tile `t` drawn centred at c, half-size `half`, turned so that its x axis points
// along `dir` (a unit vector; vec2(1, 0) is upright).
fn quad(b: *Batch, c: vec2, half: vec2, dir: vec2, t: Tile, color: vec4) {
    if b.count >= SPRITE_CAP {
        return
    }
    ax := dir * half.x
    ay := vec2(-dir.y, dir.x) * half.y
    c = c + b.offset
    u0 := vec2(t.x, t.y) * b.texel
    u1 := vec2(t.x + t.w, t.y + t.h) * b.texel
    i := b.count * 4
    m := b.mode
    b.verts[i] = GlowVertex{c - ax - ay, u0, color, m}
    b.verts[i + 1] = GlowVertex{c + ax - ay, vec2(u1.x, u0.y), color, m}
    b.verts[i + 2] = GlowVertex{c - ax + ay, vec2(u0.x, u1.y), color, m}
    b.verts[i + 3] = GlowVertex{c + ax + ay, u1, color, m}
    b.count += 1
}

// An upright sprite with its top left corner at (x, y).
fn sprite(b: *Batch, x: f32, y: f32, w: f32, h: f32, t: Tile, color: vec4) {
    quad(b, vec2(x + w / 2.0, y + h / 2.0), vec2(w / 2.0, h / 2.0), vec2(1.0, 0.0), t, color)
}

// A rectangle of one colour.
fn rect(b: *Batch, x: f32, y: f32, w: f32, h: f32, color: vec4) { sprite(b, x, y, w, h, b.white, color) }

// The sprites added from now on are the HUD: drawn over the finished picture.
fn batch_hud(b: *Batch) {
    b.hud_start = b.count
    b.offset = vec2(0.0)
}

// ---- the frame -------------------------------------------------------------------------------

// Starts a frame: follows the window's size and waits until the GPU is done with the frame
// that last used this back buffer. Returns the batch to add the world's sprites to.
fn render_begin(r: *Renderer) -> *Batch {
    if r.w != nil {
        width, height := r.w.size()
        if width > 0 && height > 0 && (width != r.width || height != r.height) {
            resize(r, width, height)
        }
    }
    i := if r.swap != nil { i64(r.swap.GetCurrentBackBufferIndex()) } else { 0 }
    r.frame = i
    gpu_wait(&r.g, r.done[i])
    b := &r.batch
    b.verts = r.mapped[i * SPRITE_CAP * 4..(i + 1) * SPRITE_CAP * 4]
    b.count = 0
    b.hud_start = -1
    b.offset = vec2(0.0)
    b.mode = 0.0
    b
}

priv fn rtv(r: *Renderer, k: i64) -> D3D12_CPU_DESCRIPTOR_HANDLE { gpu_cpu_handle(&r.g, r.rtv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, k) }

priv fn table(r: *Renderer, slot: i64) -> D3D12_GPU_DESCRIPTOR_HANDLE {
    h := r.srv_heap.GetGPUDescriptorHandleForHeapStart()
    h.ptr += u64(slot * 3) * r.srv_step
    h
}

priv fn set_area(list: *ID3D12GraphicsCommandList, x: i64, y: i64, w: i64, h: i64) {
    viewport := D3D12_VIEWPORT{f32(x), f32(y), f32(w), f32(h), 0.0, 1.0}
    scissor := D3D12_RECT{i32(x), i32(y), i32(x + w), i32(y + h)}
    list.RSSetViewports(1, &viewport)
    list.RSSetScissorRects(1, &scissor)
}

priv fn constants(list: *ID3D12GraphicsCommandList, c: PassConsts) {
    list.SetGraphicsRoot32BitConstants(0, u32(PASS_VALUES), cast[*u8](&c), 0)
}

// A full-screen pass: `target` (bloom texture k) from the views of `slot`.
priv fn pass(r: *Renderer, pso: *ID3D12PipelineState, k: i64, slot: i64, c: PassConsts) {
    list := r.list
    target := r.bloom[k]
    dx_barrier(list, target, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET)
    handle := rtv(r, RTV_BLOOM + k)
    list.OMSetRenderTargets(1, &handle, 0, nil)
    set_area(list, 0, 0, r.bloom_size[k].0, r.bloom_size[k].1)
    list.SetPipelineState(pso)
    list.SetGraphicsRootDescriptorTable(1, table(r, slot))
    constants(list, c)
    list.DrawInstanced(3, 1, 0, 0)
    dx_barrier(list, target, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
}

// Draws `n` sprites of the batch from sprite `first` with `pso`, in virtual pixels.
priv fn draw_sprites(r: *Renderer, pso: *ID3D12PipelineState, first: i64, n: i64) {
    if n <= 0 {
        return
    }
    list := r.list
    list.SetPipelineState(pso)
    list.SetGraphicsRootDescriptorTable(1, table(r, SLOT_SPRITES))
    constants(list, PassConsts{k0: vec4(2.0 / f32(r.view_w), 2.0 / f32(r.view_h), 0.0, 0.0)})
    stride := sizeof[GlowVertex]()
    vb := D3D12_VERTEX_BUFFER_VIEW{r.vertices.GetGPUVirtualAddress() + u64(r.frame * SPRITE_CAP * 4 * stride),
        u32(SPRITE_CAP * 4 * stride), u32(stride)}
    ib := D3D12_INDEX_BUFFER_VIEW{r.indices.GetGPUVirtualAddress(), u32(SPRITE_CAP * 6 * 2), DXGI_FORMAT_R16_UINT}
    list.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST)
    list.IASetVertexBuffers(0, 1, &vb)
    list.IASetIndexBuffer(&ib)
    list.DrawIndexedInstanced(u32(n * 6), 1, u32(first * 6), 0, 0)
}

// Records and submits the frame and presents it. With `capture`, the finished picture is read
// back (the call then waits for the GPU) and returned. The text is "" or what failed (the
// device was removed: the reason).
fn render_end(r: *Renderer, post: Post, capture: bool) -> (Image, str) {
    shot: Image
    b := &r.batch
    scene_n := if b.hud_start < 0 { b.count } else { b.hud_start }
    i := r.frame
    g := &r.g
    list := r.list
    gpu_check(g, r.allocators[i].Reset(), "ID3D12CommandAllocator::Reset")
    gpu_check(g, list.Reset(r.allocators[i], nil), "ID3D12GraphicsCommandList::Reset")
    heaps := [1]*ID3D12DescriptorHeap{r.srv_heap}
    list.SetDescriptorHeaps(1, ptr(heaps))
    list.SetGraphicsRootSignature(r.root)
    list.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST)
    vx, vy, vw, vh := r.view

    // the scene: background, then the world's sprites
    dx_barrier(list, r.scene, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET)
    scene_rtv := rtv(r, RTV_SCENE)
    list.OMSetRenderTargets(1, &scene_rtv, 0, nil)
    set_area(list, 0, 0, r.scene_w, r.scene_h)
    list.SetPipelineState(r.pso_background)
    list.SetGraphicsRootDescriptorTable(1, table(r, SLOT_SPRITES))
    constants(list, PassConsts{k0: vec4(post.time, 0.0, f32(r.view_w), f32(r.view_h))})
    list.DrawInstanced(3, 1, 0, 0)
    draw_sprites(r, r.pso_scene, 0, scene_n)
    dx_barrier(list, r.scene, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)

    // bloom: bright parts at a quarter, blurred; again at an eighth for the wide halo
    sw := 1.0 / f32(r.scene_w)
    sh := 1.0 / f32(r.scene_h)
    pass(r, r.pso_bright, 0, SLOT_SCENE, PassConsts{k0: vec4(sw, sh, 0.85, 0.5)})
    for k in [_]i64{0, 2} {
        if k == 2 {
            a := 0.5 / vec2(f32(r.bloom_size[0].0), f32(r.bloom_size[0].1))
            pass(r, r.pso_bright, 2, SLOT_A, PassConsts{k0: vec4(a.x, a.y, 0.0, 0.0001)})
        }
        tw := 1.0 / f32(r.bloom_size[k].0)
        th := 1.0 / f32(r.bloom_size[k].1)
        pass(r, r.pso_blur, k + 1, SLOT_A + k, PassConsts{k0: vec4(tw, 0.0, 0.0, 0.0)})
        pass(r, r.pso_blur, k, SLOT_A + k + 1, PassConsts{k0: vec4(0.0, th, 0.0, 0.0)})
    }

    // the picture: composite into the back buffer, then the HUD over it
    target := r.back[i]
    dx_barrier(list, target, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET)
    back_rtv := rtv(r, i)
    list.OMSetRenderTargets(1, &back_rtv, 0, nil)
    black := [4]f32{0.0, 0.0, 0.0, 1.0}
    list.ClearRenderTargetView(back_rtv, ptr(black), 0, nil)
    set_area(list, vx, vy, vw, vh)
    list.SetPipelineState(r.pso_composite)
    list.SetGraphicsRootDescriptorTable(1, table(r, SLOT_COMPOSITE))
    fringe := post.fringe / f32(r.view_w)
    constants(list, PassConsts{
        k0: vec4(post.bloom, post.bloom * 0.8, post.exposure, post.time),
        k1: vec4(post.flash, 0.55, fringe, post.desaturate),
        k2: vec4(post.flash_color, f32(vw)),
    })
    list.DrawInstanced(3, 1, 0, 0)
    if b.hud_start >= 0 {
        draw_sprites(r, r.pso_hud, b.hud_start, b.count - b.hud_start)
    }

    rb: Readback
    if capture {
        rb = gpu_readback(g, list, target, D3D12_RESOURCE_STATE_RENDER_TARGET)
    }
    dx_barrier(list, target, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT)
    gpu_execute(g, list)
    if r.swap != nil {
        hr := r.swap.Present(if r.vsync { 1 } else { 0 }, 0)
        if FAILED(hr) {
            removed := gpu_removed(g)
            return (shot, if removed == "" { hresult_text("IDXGISwapChain::Present", hr) } else { removed })
        }
        if hr == DXGI_STATUS_OCCLUDED {
            sleep_ms(16)                      // minimized: no vsync paces the loop
        }
    }
    r.done[i] = gpu_signal(g)
    print_messages(r)
    if capture {
        gpu_wait(g, r.done[i])
        removed := gpu_removed(g)
        if removed != "" {
            return (shot, removed)
        }
        shot = Image{rb.width, rb.height, 4, readback_pixels(&rb)}
        readback_free(&rb)
        for k in 0..rb.width * rb.height {
            shot.pix[k * 4 + 3] = 255
        }
    }
    (shot, "")
}
