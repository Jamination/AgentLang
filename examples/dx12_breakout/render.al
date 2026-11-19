// Breakout's renderer, Direct3D 12 (Windows only), on the device code of ../gamekit/dx12_gpu.al.
// It draws into a window's swap chain (two frames in flight) or into a texture of its own
// (offscreen: screenshots), and can read the finished picture back.
//
// A frame, in the game's virtual resolution (320 x 180) scaled to the picture's size:
//   1. background   a pixel shader: dark nebula, a drifting grid that ripples where the ball
//                   last hit something, stars, the playfield darker with a soft inner shadow
//                   and a haze along its open bottom
//   2. sprites      one batch from the sprite sheet (sheet.al), bilinear, premultiplied alpha:
//                   a vertex with alpha 0 adds its light instead of covering (glows, sparks),
//                   colours above 1 feed the bloom, and glyphs are a signed distance field
//   3. bloom        what is brighter than a threshold, at half and at a quarter of the size,
//                   blurred (separable Gaussian, both sizes)
//   4. composite    scene + bloom, a full-screen flash, hot colours run to white, a soft
//                   shoulder instead of clipping, vignette and dither, into the letterboxed view
// Steps 1 to 3 draw into 16-bit float targets the size of the view's rectangle in the window.
//
//   r, err := renderer_window(w, VIEW_W, VIEW_H, sheet, warp, debug)   (or renderer_offscreen)
//   b := render_begin(r, &look)       waits for a free frame, records the background
//   sprite(b, ...) text(...)          fill the batch (view pixels, origin top left)
//   img, err := render_end(r, &look, capture)   records the rest, presents; the picture if captured
//   renderer_close(r)
use std.window
use std.image
use "../gamekit/dx12_gpu.al"
use "sheet.al"
use "glyphs.al"

const OUT_FORMAT = DXGI_FORMAT_R8G8B8A8_UNORM
const HDR_FORMAT = DXGI_FORMAT_R16G16B16A16_FLOAT
const MAX_FRAMES = 2
const MAX_QUADS = 12288            // sprites per frame

// One corner of a sprite: position in view pixels, sheet coordinates, colour (premultiplied,
// may exceed 1), and mode: x 1 for a glyph of the distance field, y how much bolder (font
// pixels), z the width of a soft glow instead of a sharp edge (font pixels, 0: sharp).
struct Vertex { pos: vec2, uv: vec2, color: vec4, mode: vec4 }

// The root constants of a pass (the cbuffer of the shaders, register b0); what the four
// vectors mean depends on the pass (see SHADERS).
struct PassConsts { a: vec4, b: vec4, c: vec4, d: vec4 }
const PASS_VALUES = hlsl_cbuffer_size[PassConsts]() / 4

// What a frame looks like apart from its sprites.
struct Look {
    time: f32            // seconds, for the background's motion
    shake: vec2          // view pixels the playfield is moved by
    ripple: vec3         // where the last ripple started (x, y) and its age in seconds (>= 1: none)
    field: vec4          // the playfield: left, top, right, bottom
    tint: vec3           // the background's colour is multiplied by it
    flash: vec4          // a full-screen flash: colour and strength
    bloom: f32           // strength of the glow
}

// The sprites of a frame.
struct Batch {
    verts: []Vertex      // this frame's region of the vertex buffer
    count: i64           // sprites so far
    cap: i64
    cam: vec2            // added to every position (the screen shake)
    texel: vec2          // 1 / the sheet's size
}

// The render targets and the descriptor slots of the passes.
priv const RTV_SCENE = MAX_FRAMES
priv const RTV_BLOOM = MAX_FRAMES + 1      // 4 of them: half, half, quarter, quarter
priv const RTV_COUNT = MAX_FRAMES + 5
// Every pass reads a table of three views; these are the first slot of each table.
priv const SRV_SHEET = 0
priv const SRV_SCENE = 3
priv const SRV_BLOOM = 6                   // a table per bloom target: 6, 9, 12, 15
priv const SRV_FINAL = 18                  // scene, half bloom, quarter bloom
priv const SRV_COUNT = 21

struct Renderer {
    w: *Window                       // nil: offscreen
    g: Gpu
    swap: *IDXGISwapChain3           // nil: offscreen
    frames: i64
    out: [MAX_FRAMES]*ID3D12Resource // the back buffers, or the offscreen picture
    allocators: [MAX_FRAMES]*ID3D12CommandAllocator
    done: [MAX_FRAMES]u64            // the fence value of the last frame drawn into each
    list: *ID3D12GraphicsCommandList
    rtv_heap: *ID3D12DescriptorHeap
    srv_heap: *ID3D12DescriptorHeap  // shader-visible
    root: *ID3D12RootSignature
    pso_sprite: *ID3D12PipelineState
    pso_back: *ID3D12PipelineState
    pso_bright: *ID3D12PipelineState
    pso_blur: *ID3D12PipelineState
    pso_final: *ID3D12PipelineState
    sheet: *ID3D12Resource
    sheet_size: vec2
    vertices: *ID3D12Resource
    mapped: []Vertex                 // the whole vertex buffer, mapped
    batch: Batch
    scene: *ID3D12Resource
    bloom: [4]*ID3D12Resource
    width: i64                       // of the picture (the window's client area)
    height: i64
    view: (i64, i64, i64, i64)       // the letterboxed rectangle of the game in it
    view_w: i64                      // the game's virtual resolution
    view_h: i64
    inner_w: i64                     // of the scene target (the view rectangle's size)
    inner_h: i64
    frame: i64
    vsync: bool
    resizes: i64
    info: *ID3D12InfoQueue           // the debug layer's messages (nil without it)
    messages: i64                    // debug messages printed
}

priv const SHADERS = `
cbuffer Consts : register(b0) { float4 a; float4 b; float4 c; float4 d; };
Texture2D t0 : register(t0);
Texture2D t1 : register(t1);
Texture2D t2 : register(t2);
SamplerState lin : register(s0);

// ---- sprites: a.xy = 2 / the view's size
struct SV { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; float4 color : COLOR; float4 mode : TEXCOORD1; };
SV vs_sprite(float2 pos : POSITION, float2 uv : TEXCOORD0, float4 color : COLOR, float4 mode : TEXCOORD1) {
    SV o;
    o.pos = float4(pos.x * a.x - 1.0, 1.0 - pos.y * a.y, 0.0, 1.0);
    o.uv = uv;
    o.color = color;
    o.mode = mode;
    return o;
}
float4 ps_sprite(SV i) : SV_TARGET {
    float4 t = t0.Sample(lin, i.uv);
    // a glyph: alpha is the distance to its edge, 2 font pixels to 0 or 1
    float dist = (t.a - 0.5) * 4.0 + i.mode.y;
    float w = max(fwidth(dist), 0.0001);
    float sharp = saturate(dist / w + 0.5);
    float soft = smoothstep(-max(i.mode.z, 0.001), 0.7, dist);
    float cover = i.mode.z > 0.0 ? soft : sharp;
    return i.mode.x > 0.5 ? i.color * cover : t * i.color;
}

// ---- passes over the whole target: a triangle that covers it
struct FV { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };
FV vs_full(uint id : SV_VertexID) {
    FV o;
    float2 uv = float2(float((id << 1) & 2), float(id & 2));
    o.pos = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    o.uv = uv;
    return o;
}

float hash21(float2 p) {
    p = frac(p * float2(233.34, 851.73));
    p += dot(p, p + 23.45);
    return frac(p.x * p.y);
}
float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(lerp(hash21(i), hash21(i + float2(1.0, 0.0)), f.x), lerp(hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)), f.x), f.y);
}

// ---- the background: a = (view w, view h, time, -), b = (shake, ripple x y),
//      c = (ripple age, tint rgb), d = the playfield (left, top, right, bottom)
float4 ps_back(FV i) : SV_TARGET {
    float2 p = i.uv * a.xy;
    float t = a.z;
    float2 w = p - b.xy;
    float2 q = p - b.xy * 0.3;
    float3 col = lerp(float3(0.055, 0.032, 0.115), float3(0.012, 0.008, 0.032), saturate(i.uv.y * 1.15));
    // two slow layers of nebula
    float n1 = vnoise(q * 0.020 + float2(t * 0.020, t * 0.008)) * 0.65 + vnoise(q * 0.052 - float2(t * 0.025, 0.0)) * 0.35;
    float n2 = vnoise(q * 0.030 + float2(-t * 0.012, t * 0.018) + 31.7);
    col += float3(0.17, 0.03, 0.22) * smoothstep(0.40, 1.0, n1) * 0.85;
    col += float3(0.00, 0.08, 0.17) * smoothstep(0.48, 1.0, n2) * 0.85;
    // the grid, pushed aside by the ripple
    float2 rv = w - b.zw;
    float rd = length(rv);
    float age = c.x;
    float rx = (rd - age * 170.0) / 10.0;
    float ring = exp(-rx * rx) * saturate(1.0 - age);
    float2 g = w + (rd > 0.01 ? rv / rd : float2(0.0, 0.0)) * ring * 5.0;
    g.y += t * 5.0;
    float2 cell = abs(frac(g / 16.0 + 0.5) - 0.5) * 16.0;
    float2 fw = max(fwidth(g), float2(0.3, 0.3)) * 1.3;
    float lx = 1.0 - smoothstep(0.0, fw.x, cell.x);
    float ly = 1.0 - smoothstep(0.0, fw.y, cell.y);
    float lines = max(lx, ly);
    col += float3(0.22, 0.11, 0.50) * (lines * 0.20 + lx * ly * 0.3) * (0.7 + 0.8 * smoothstep(40.0, a.y, w.y));
    col += float3(0.25, 0.75, 1.0) * ring * (0.06 + lines * 0.5);
    // stars
    float2 sc = floor(q / 6.0);
    float h = hash21(sc);
    float2 sp = (sc + 0.2 + 0.6 * float2(hash21(sc + 7.1), hash21(sc + 3.3))) * 6.0;
    float sd = length(q - sp);
    float twinkle = 0.55 + 0.45 * sin(t * (0.8 + h * 3.0) + h * 40.0);
    col += float3(0.75, 0.82, 1.0) * exp(-sd * sd * 2.5) * twinkle * step(0.93, h) * (h - 0.9) * 12.0;
    // the playfield: darker, with a soft shadow under its frame
    float e = min(min(w.x - d.x, d.z - w.x), w.y - d.y);
    if (e > 0.0) {
        col = col * 0.55 * lerp(0.22, 1.0, smoothstep(0.0, 14.0, e)) + float3(0.004, 0.006, 0.018);
        col += float3(0.10, 0.02, 0.13) * smoothstep(a.y - 80.0, a.y + 10.0, w.y) * 0.7;
    }
    return float4(col * c.yzw, 1.0);
}

// ---- the bright pass and the downsampling: a = (a source texel, threshold, knee)
float4 ps_bright(FV i) : SV_TARGET {
    float2 o = a.xy;
    float3 col = (t0.Sample(lin, i.uv + float2(-o.x, -o.y)).rgb + t0.Sample(lin, i.uv + float2(o.x, -o.y)).rgb
        + t0.Sample(lin, i.uv + float2(-o.x, o.y)).rgb + t0.Sample(lin, i.uv + float2(o.x, o.y)).rgb) * 0.25;
    float l = max(col.r, max(col.g, col.b));
    float soft = clamp(l - a.z + a.w, 0.0, 2.0 * a.w);
    soft = soft * soft / (4.0 * a.w + 0.0001);
    return float4(col * (max(soft, l - a.z) / max(l, 0.0001)), 1.0);
}

// ---- a Gaussian blur along a.xy (a texel in that direction): 9 taps in 5 samples
float4 ps_blur(FV i) : SV_TARGET {
    float2 o = a.xy;
    float3 col = t0.Sample(lin, i.uv).rgb * 0.2270270270;
    col += (t0.Sample(lin, i.uv + o * 1.3846153846).rgb + t0.Sample(lin, i.uv - o * 1.3846153846).rgb) * 0.3162162162;
    col += (t0.Sample(lin, i.uv + o * 3.2307692308).rgb + t0.Sample(lin, i.uv - o * 3.2307692308).rgb) * 0.0702702703;
    return float4(col, 1.0);
}

// ---- the picture: a = (half bloom, quarter bloom, vignette, time), b = flash (rgb, strength)
float3 shoulder(float3 x) {
    float k = 0.72;
    return min(x, k) + (1.0 - k) * (1.0 - exp(-max(x - k, 0.0) / (1.0 - k)));
}
float4 ps_final(FV i) : SV_TARGET {
    float3 col = t0.Sample(lin, i.uv).rgb + t1.Sample(lin, i.uv).rgb * a.x + t2.Sample(lin, i.uv).rgb * a.y;
    col += b.rgb * b.a;
    float hot = max(col.r, max(col.g, col.b));
    col += max(hot - 1.0, 0.0) * 0.35;
    col = shoulder(col);
    float2 v = (i.uv - 0.5) * float2(1.0, 0.85);
    col *= saturate(1.0 - dot(v, v) * a.z);
    col += (hash21(i.pos.xy + frac(a.w) * 61.0) - 0.5) / 255.0;
    return float4(col, 1.0);
}
`

// ---- set-up ----------------------------------------------------------------------------------

priv fn pipeline(r: *Renderer, vs_name: str, ps_name: str, format: i32, sprites: bool) -> (*ID3D12PipelineState, str) {
    pso: *ID3D12PipelineState
    vs, verr := dx_compile(SHADERS, vs_name, "vs_5_0")
    if verr != "" { return (pso, verr) }
    ps, perr := dx_compile(SHADERS, ps_name, "ps_5_0")
    if perr != "" {
        com_release(&vs)
        return (pso, perr)
    }
    layout := [4]D3D12_INPUT_ELEMENT_DESC{
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("POSITION"), Format: DXGI_FORMAT_R32G32_FLOAT, AlignedByteOffset: u32(offsetof[Vertex](pos))},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("TEXCOORD"), Format: DXGI_FORMAT_R32G32_FLOAT, AlignedByteOffset: u32(offsetof[Vertex](uv))},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("COLOR"), Format: DXGI_FORMAT_R32G32B32A32_FLOAT, AlignedByteOffset: u32(offsetof[Vertex](color))},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("TEXCOORD"), SemanticIndex: 1, Format: DXGI_FORMAT_R32G32B32A32_FLOAT, AlignedByteOffset: u32(offsetof[Vertex](mode))},
    }
    desc := dx_pipeline_desc(r.root, vs, ps, format)
    if sprites {
        desc.InputLayout = D3D12_INPUT_LAYOUT_DESC{ptr(layout), 4}
        // premultiplied alpha: a colour with alpha 0 is added
        blend := &desc.BlendState.RenderTarget[0]
        blend.BlendEnable = 1
        blend.SrcBlend = D3D12_BLEND_ONE
        blend.DestBlend = D3D12_BLEND_INV_SRC_ALPHA
        blend.SrcBlendAlpha = D3D12_BLEND_ONE
        blend.DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA
    }
    hr := r.g.device.CreateGraphicsPipelineState(&desc, &IID_ID3D12PipelineState, &pso)
    com_release(&vs)
    com_release(&ps)
    if FAILED(hr) { return (pso, hresult_text(fmt("CreateGraphicsPipelineState (", ps_name, ")"), hr)) }
    (pso, "")
}

// The sheet (premultiplied RGBA) in a texture, uploaded before it returns.
priv fn upload_sheet(r: *Renderer, img: Image) {
    g := &r.g
    r.sheet = gpu_texture(g, img.w, img.h, DXGI_FORMAT_R8G8B8A8_UNORM, D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST, nil)
    r.sheet_size = vec2(f32(img.w), f32(img.h))
    desc := r.sheet.GetDesc()
    footprint: D3D12_PLACED_SUBRESOURCE_FOOTPRINT
    total: u64
    g.device.GetCopyableFootprints(&desc, 0, 1, 0, &footprint, nil, nil, &total)
    staging := gpu_buffer(g, D3D12_HEAP_TYPE_UPLOAD, i64(total), D3D12_RESOURCE_STATE_GENERIC_READ)
    mapped: *u8
    none := D3D12_RANGE{0, 0}
    dx_check(staging.Map(0, &none, &mapped), "ID3D12Resource::Map (sheet)")
    rows := mkslice[u8](mapped, i64(total))
    pitch := i64(footprint.Footprint.RowPitch)
    for y in 0..img.h {
        copy(rows[y * pitch..y * pitch + img.w * 4], img.pix[y * img.w * 4..(y + 1) * img.w * 4])
    }
    staging.Unmap(0, nil)
    allocator, list := gpu_command_list(g)
    gpu_reset(allocator, list)
    dst := D3D12_TEXTURE_COPY_LOCATION{pResource: r.sheet, Type: D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}
    src := D3D12_TEXTURE_COPY_LOCATION{pResource: staging, Type: D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT}
    *src.u_PlacedFootprint() = footprint
    list.CopyTextureRegion(&dst, 0, 0, 0, &src, nil)
    dx_barrier(list, r.sheet, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
    gpu_execute(g, list)
    gpu_flush(g)
    com_release(&list)
    com_release(&allocator)
    com_release(&staging)
}

priv fn srv(r: *Renderer, res: *ID3D12Resource, format: i32, slot: i64) {
    view := D3D12_SHADER_RESOURCE_VIEW_DESC{Format: format, ViewDimension: D3D12_SRV_DIMENSION_TEXTURE2D,
        Shader4ComponentMapping: D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING}
    view.u_Texture2D().MipLevels = 1
    r.g.device.CreateShaderResourceView(res, &view, gpu_cpu_handle(&r.g, r.srv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, slot))
}

priv fn rtv(r: *Renderer, slot: i64) -> D3D12_CPU_DESCRIPTOR_HANDLE {
    gpu_cpu_handle(&r.g, r.rtv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, slot)
}

priv fn table(r: *Renderer, slot: i64) -> D3D12_GPU_DESCRIPTOR_HANDLE {
    h := r.srv_heap.GetGPUDescriptorHandleForHeapStart()
    h.ptr += u64(slot) * u64(r.g.device.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV))
    h
}

// Everything both kinds of renderer have. "" or what failed.
priv fn renderer_setup(r: *Renderer, sheet: Image) -> str {
    g := &r.g
    if r.info != nil {
        r.info.SetBreakOnSeverity(D3D12_MESSAGE_SEVERITY_ERROR, 0)
    }
    params: [2]D3D12_ROOT_PARAMETER
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS
    params[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL
    params[0].u_Constants().Num32BitValues = PASS_VALUES
    range := D3D12_DESCRIPTOR_RANGE{RangeType: D3D12_DESCRIPTOR_RANGE_TYPE_SRV, NumDescriptors: 3}
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE
    params[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL
    params[1].u_DescriptorTable().NumDescriptorRanges = 1
    params[1].u_DescriptorTable().pDescriptorRanges = &range
    sampler := D3D12_STATIC_SAMPLER_DESC{
        Filter: D3D12_FILTER_MIN_MAG_MIP_LINEAR, AddressU: D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        AddressV: D3D12_TEXTURE_ADDRESS_MODE_CLAMP, AddressW: D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        ComparisonFunc: D3D12_COMPARISON_FUNC_NEVER, MaxLOD: 3.4e38, ShaderVisibility: D3D12_SHADER_VISIBILITY_PIXEL,
    }
    root_desc := D3D12_ROOT_SIGNATURE_DESC{NumParameters: 2, pParameters: ptr(params), NumStaticSamplers: 1,
        pStaticSamplers: &sampler, Flags: D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT}
    root, err := dx_root_signature(g, &root_desc)
    if err != "" { return err }
    r.root = root
    e := ""
    r.pso_sprite, e = pipeline(r, "vs_sprite", "ps_sprite", HDR_FORMAT, true)
    if e != "" { return e }
    r.pso_back, e = pipeline(r, "vs_full", "ps_back", HDR_FORMAT, false)
    if e != "" { return e }
    r.pso_bright, e = pipeline(r, "vs_full", "ps_bright", HDR_FORMAT, false)
    if e != "" { return e }
    r.pso_blur, e = pipeline(r, "vs_full", "ps_blur", HDR_FORMAT, false)
    if e != "" { return e }
    r.pso_final, e = pipeline(r, "vs_full", "ps_final", OUT_FORMAT, false)
    if e != "" { return e }

    for i in 0..r.frames {
        gpu_check(g, g.device.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator,
            &r.allocators[i]), "CreateCommandAllocator")
    }
    gpu_check(g, g.device.CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, r.allocators[0], nil,
        &IID_ID3D12GraphicsCommandList, &r.list), "CreateCommandList")
    gpu_check(g, r.list.Close(), "ID3D12GraphicsCommandList::Close")
    r.rtv_heap = gpu_descriptor_heap(g, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, RTV_COUNT, false)
    r.srv_heap = gpu_descriptor_heap(g, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, SRV_COUNT, true)

    upload_sheet(r, sheet)
    for k in 0..3 {
        srv(r, r.sheet, DXGI_FORMAT_R8G8B8A8_UNORM, SRV_SHEET + k)
    }
    count := r.frames * MAX_QUADS * 6
    r.vertices = gpu_buffer(g, D3D12_HEAP_TYPE_UPLOAD, count * sizeof[Vertex](), D3D12_RESOURCE_STATE_GENERIC_READ)
    mapped: *u8
    none := D3D12_RANGE{0, 0}
    dx_check(r.vertices.Map(0, &none, &mapped), "ID3D12Resource::Map (vertices)")
    r.mapped = mkslice[Vertex](cast[*Vertex](mapped), count)
    ""
}

// The picture's views, and the scene and bloom targets for the current size of the view.
priv fn create_targets(r: *Renderer) {
    g := &r.g
    for i in 0..r.frames {
        if r.swap != nil {
            gpu_check(g, r.swap.GetBuffer(u32(i), &IID_ID3D12Resource, &r.out[i]), "IDXGISwapChain::GetBuffer")
        }
        g.device.CreateRenderTargetView(r.out[i], nil, rtv(r, i))
    }
    r.view = fit_rect(r.width, r.height, r.view_w, r.view_h)
    _, _, vw, vh := r.view
    r.inner_w = max(vw, 16)
    r.inner_h = max(vh, 16)
    black := [4]f32{0.0, 0.0, 0.0, 1.0}
    r.scene = gpu_texture(g, r.inner_w, r.inner_h, HDR_FORMAT, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
        D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, &black)
    g.device.CreateRenderTargetView(r.scene, nil, rtv(r, RTV_SCENE))
    for k in 0..3 {
        srv(r, r.scene, HDR_FORMAT, SRV_SCENE + k)
    }
    for k in 0..4 {
        div := if k < 2 { 2 } else { 4 }
        r.bloom[k] = gpu_texture(g, max(r.inner_w / div, 1), max(r.inner_h / div, 1), HDR_FORMAT,
            D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, &black)
        g.device.CreateRenderTargetView(r.bloom[k], nil, rtv(r, RTV_BLOOM + k))
        for j in 0..3 {
            srv(r, r.bloom[k], HDR_FORMAT, SRV_BLOOM + k * 3 + j)
        }
    }
    srv(r, r.scene, HDR_FORMAT, SRV_FINAL)
    srv(r, r.bloom[0], HDR_FORMAT, SRV_FINAL + 1)
    srv(r, r.bloom[2], HDR_FORMAT, SRV_FINAL + 2)
}

priv fn release_targets(r: *Renderer) {
    for i in 0..MAX_FRAMES {
        if r.swap != nil {
            com_release(&r.out[i])
        }
    }
    com_release(&r.scene)
    for k in 0..4 {
        com_release(&r.bloom[k])
    }
}

priv fn open_gpu(warp: bool, debug: bool) -> (Gpu, *ID3D12InfoQueue, str) {
    info: *ID3D12InfoQueue
    gpu, err := gpu_open(debug, warp)
    if err != "" {
        return (gpu, info, fmt("no Direct3D 12 device: ", err))
    }
    if debug && FAILED(gpu.device.QueryInterface(&IID_ID3D12InfoQueue, &info)) {
        eprint("the Direct3D 12 debug layer is not installed (Windows: Settings, Optional features, Graphics Tools)")
        info = nil
    }
    (gpu, info, "")
}

// A renderer on a window: a flip-model swap chain on its HWND; the game draws in a view of
// view_w x view_h pixels. `debug` turns on the Direct3D debug layer and prints its messages.
// (renderer, "") or (nil, why).
fn renderer_window(w: *Window, view_w: i64, view_h: i64, sheet: Image, warp: bool, debug: bool) -> (*Renderer, str) {
    gpu, info, err := open_gpu(warp, debug)
    if err != "" {
        return (nil, err)
    }
    r := new[Renderer]()
    r.w = w
    r.g = gpu
    r.info = info
    r.frames = MAX_FRAMES
    r.vsync = true
    r.view_w = view_w
    r.view_h = view_h
    width, height := w.size()
    r.width = max(width, 1)
    r.height = max(height, 1)
    desc := DXGI_SWAP_CHAIN_DESC1{
        Width: u32(r.width), Height: u32(r.height), Format: OUT_FORMAT, SampleDesc: DXGI_SAMPLE_DESC{Count: 1},
        BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT, BufferCount: MAX_FRAMES, SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
    }
    // a Direct3D 12 swap chain presents through the command queue
    swap1: *IDXGISwapChain1
    hr := r.g.factory.CreateSwapChainForHwnd(cast[*IUnknown](r.g.queue), win32_hwnd(w), &desc, nil, nil, &swap1)
    if FAILED(hr) {
        renderer_close(r)
        return (nil, hresult_text("CreateSwapChainForHwnd", hr))
    }
    gpu_check(&r.g, swap1.QueryInterface(&IID_IDXGISwapChain3, &r.swap), "QueryInterface IDXGISwapChain3")
    com_release(&swap1)
    // fullscreen is std.window's borderless window (set_fullscreen), not DXGI's Alt+Enter
    r.g.factory.MakeWindowAssociation(win32_hwnd(w), DXGI_MWA_NO_ALT_ENTER)
    serr := renderer_setup(r, sheet)
    if serr != "" {
        renderer_close(r)
        return (nil, serr)
    }
    create_targets(r)
    (r, "")
}

// A renderer that draws into a picture of its own, width x height (one frame in flight).
fn renderer_offscreen(width: i64, height: i64, view_w: i64, view_h: i64, sheet: Image, warp: bool, debug: bool) -> (*Renderer, str) {
    gpu, info, err := open_gpu(warp, debug)
    if err != "" {
        return (nil, err)
    }
    r := new[Renderer]()
    r.g = gpu
    r.info = info
    r.frames = 1
    r.view_w = view_w
    r.view_h = view_h
    r.width = width
    r.height = height
    serr := renderer_setup(r, sheet)
    if serr != "" {
        renderer_close(r)
        return (nil, serr)
    }
    black := [4]f32{0.0, 0.0, 0.0, 1.0}
    r.out[0] = gpu_texture(&r.g, width, height, OUT_FORMAT, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
        D3D12_RESOURCE_STATE_PRESENT, &black)
    create_targets(r)
    (r, "")
}

// The window's size changed: new back buffers, and targets for the new view.
priv fn resize(r: *Renderer, width: i64, height: i64) {
    gpu_flush(&r.g)
    release_targets(r)
    gpu_check(&r.g, r.swap.ResizeBuffers(u32(r.frames), u32(width), u32(height), DXGI_FORMAT_UNKNOWN, 0), "IDXGISwapChain::ResizeBuffers")
    r.width = width
    r.height = height
    r.resizes += 1
    create_targets(r)
}

// Waits for the GPU and releases everything (not the window). Safe on a half-made renderer.
fn renderer_close(r: *Renderer) {
    if r.g.queue != nil {
        gpu_flush(&r.g)
    }
    print_debug_messages(r)
    if r.vertices != nil && len(r.mapped) > 0 {
        r.vertices.Unmap(0, nil)
        r.mapped = nil
    }
    com_release(&r.vertices)
    release_targets(r)
    com_release(&r.out[0])                    // offscreen: the picture
    com_release(&r.sheet)
    com_release(&r.list)
    for i in 0..MAX_FRAMES {
        com_release(&r.allocators[i])
    }
    com_release(&r.pso_sprite)
    com_release(&r.pso_back)
    com_release(&r.pso_bright)
    com_release(&r.pso_blur)
    com_release(&r.pso_final)
    com_release(&r.root)
    com_release(&r.srv_heap)
    com_release(&r.rtv_heap)
    com_release(&r.swap)
    com_release(&r.info)
    gpu_close(&r.g)
}

// Prints the debug layer's messages so far (with --d3d-debug) to standard error.
fn print_debug_messages(r: *Renderer) {
    if r.info == nil {
        return
    }
    n := r.info.GetNumStoredMessages()
    for k in 0..n {
        size: u64
        r.info.GetMessage(k, nil, &size)
        buf := alloc[u64](i64(size) / 8 + 1)
        msg := cast[*D3D12_MESSAGE](ptr(buf))
        if SUCCEEDED(r.info.GetMessage(k, msg, &size)) {
            text := mkslice[u8](msg.pDescription, max(i64(msg.DescriptionByteLength) - 1, 0))
            eprint(fmt("D3D12 debug (severity ", msg.Severity, "): ", text))
            r.messages += 1
        }
    }
    r.info.ClearStoredMessages()
}

// ---- the frame -------------------------------------------------------------------------------

priv fn set_target(list: *ID3D12GraphicsCommandList, handle: D3D12_CPU_DESCRIPTOR_HANDLE, x: i64, y: i64, w: i64, h: i64) {
    list.OMSetRenderTargets(1, &handle, 0, nil)
    viewport := D3D12_VIEWPORT{f32(x), f32(y), f32(w), f32(h), 0.0, 1.0}
    scissor := D3D12_RECT{i32(x), i32(y), i32(x + w), i32(y + h)}
    list.RSSetViewports(1, &viewport)
    list.RSSetScissorRects(1, &scissor)
}

priv fn constants(list: *ID3D12GraphicsCommandList, c: PassConsts) {
    list.SetGraphicsRoot32BitConstants(0, PASS_VALUES, cast[*u8](&c), 0)
}

// A pass over a whole bloom target `k` reading the table at `slot`.
priv fn bloom_pass(r: *Renderer, k: i64, pso: *ID3D12PipelineState, slot: i64, c: PassConsts) {
    list := r.list
    dx_barrier(list, r.bloom[k], D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET)
    div := if k < 2 { 2 } else { 4 }
    set_target(list, rtv(r, RTV_BLOOM + k), 0, 0, max(r.inner_w / div, 1), max(r.inner_h / div, 1))
    list.SetPipelineState(pso)
    constants(list, c)
    list.SetGraphicsRootDescriptorTable(1, table(r, slot))
    list.DrawInstanced(3, 1, 0, 0)
    dx_barrier(list, r.bloom[k], D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
}

// Starts a frame: follows the window's size, waits until the GPU is done with the frame's
// buffers, records the background. Returns the batch for the sprites.
fn render_begin(r: *Renderer, look: *Look) -> *Batch {
    if r.w != nil {
        width, height := r.w.size()
        if width > 0 && height > 0 && (width != r.width || height != r.height) {
            resize(r, width, height)
        }
    }
    i := if r.swap != nil { i64(r.swap.GetCurrentBackBufferIndex()) } else { 0 }
    r.frame = i
    gpu_wait(&r.g, r.done[i])
    list := r.list
    gpu_check(&r.g, r.allocators[i].Reset(), "ID3D12CommandAllocator::Reset")
    gpu_check(&r.g, list.Reset(r.allocators[i], nil), "ID3D12GraphicsCommandList::Reset")
    heaps := [1]*ID3D12DescriptorHeap{r.srv_heap}
    list.SetDescriptorHeaps(1, ptr(heaps))
    list.SetGraphicsRootSignature(r.root)
    list.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST)

    dx_barrier(list, r.scene, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET)
    set_target(list, rtv(r, RTV_SCENE), 0, 0, r.inner_w, r.inner_h)
    list.SetPipelineState(r.pso_back)
    constants(list, PassConsts{
        vec4(f32(r.view_w), f32(r.view_h), look.time, 0.0),
        vec4(look.shake.x, look.shake.y, look.ripple.x, look.ripple.y),
        vec4(look.ripple.z, look.tint.x, look.tint.y, look.tint.z),
        look.field})
    list.SetGraphicsRootDescriptorTable(1, table(r, SRV_SHEET))
    list.DrawInstanced(3, 1, 0, 0)

    b := &r.batch
    b.cap = MAX_QUADS
    b.verts = r.mapped[i * MAX_QUADS * 6..(i + 1) * MAX_QUADS * 6]
    b.count = 0
    b.cam = vec2(0.0)
    b.texel = vec2(1.0) / r.sheet_size
    b
}

// Draws the sprites, the bloom and the picture, and presents it (with vsync unless r.vsync is
// false). With `capture` the finished picture is read back (the call then waits for the GPU).
// The text is "" or what failed (the device was removed: the reason).
fn render_end(r: *Renderer, look: *Look, capture: bool) -> (Image, str) {
    shot: Image
    i := r.frame
    list := r.list
    b := &r.batch
    n := min(b.count, b.cap)
    if n > 0 {
        list.SetPipelineState(r.pso_sprite)
        constants(list, PassConsts{a: vec4(2.0 / f32(r.view_w), 2.0 / f32(r.view_h), 0.0, 0.0)})
        list.SetGraphicsRootDescriptorTable(1, table(r, SRV_SHEET))
        stride := sizeof[Vertex]()
        view := D3D12_VERTEX_BUFFER_VIEW{r.vertices.GetGPUVirtualAddress() + u64(i * MAX_QUADS * 6 * stride),
            u32(n * 6 * stride), u32(stride)}
        list.IASetVertexBuffers(0, 1, &view)
        list.DrawInstanced(u32(n * 6), 1, 0, 0)
    }
    dx_barrier(list, r.scene, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)

    // bloom: bright pass to half size, blur; down to a quarter, blur
    half := vec2(1.0 / f32(max(r.inner_w / 2, 1)), 1.0 / f32(max(r.inner_h / 2, 1)))
    quarter := vec2(1.0 / f32(max(r.inner_w / 4, 1)), 1.0 / f32(max(r.inner_h / 4, 1)))
    bloom_pass(r, 0, r.pso_bright, SRV_SCENE, PassConsts{a: vec4(1.0 / f32(r.inner_w), 1.0 / f32(r.inner_h), 0.8, 0.3)})
    bloom_pass(r, 1, r.pso_blur, SRV_BLOOM, PassConsts{a: vec4(half.x, 0.0, 0.0, 0.0)})
    bloom_pass(r, 0, r.pso_blur, SRV_BLOOM + 3, PassConsts{a: vec4(0.0, half.y, 0.0, 0.0)})
    bloom_pass(r, 2, r.pso_bright, SRV_BLOOM, PassConsts{a: vec4(half.x, half.y, 0.0, 0.0)})
    bloom_pass(r, 3, r.pso_blur, SRV_BLOOM + 6, PassConsts{a: vec4(quarter.x * 1.5, 0.0, 0.0, 0.0)})
    bloom_pass(r, 2, r.pso_blur, SRV_BLOOM + 9, PassConsts{a: vec4(0.0, quarter.y * 1.5, 0.0, 0.0)})

    // the picture
    target := r.out[i]
    dx_barrier(list, target, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET)
    black := [4]f32{0.0, 0.0, 0.0, 1.0}
    list.ClearRenderTargetView(rtv(r, i), ptr(black), 0, nil)
    vx, vy, vw, vh := r.view
    set_target(list, rtv(r, i), vx, vy, vw, vh)
    list.SetPipelineState(r.pso_final)
    constants(list, PassConsts{a: vec4(0.7 * look.bloom, 0.9 * look.bloom, 0.55, look.time), b: look.flash})
    list.SetGraphicsRootDescriptorTable(1, table(r, SRV_FINAL))
    list.DrawInstanced(3, 1, 0, 0)

    rb: Readback
    if capture {
        rb = gpu_readback(&r.g, list, target, D3D12_RESOURCE_STATE_RENDER_TARGET)
    }
    dx_barrier(list, target, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT)
    gpu_execute(&r.g, list)
    if r.swap != nil {
        hr := r.swap.Present(if r.vsync { 1 } else { 0 }, 0)
        if FAILED(hr) {
            removed := gpu_removed(&r.g)
            return (shot, if removed == "" { hresult_text("IDXGISwapChain::Present", hr) } else { removed })
        }
        if hr == DXGI_STATUS_OCCLUDED {
            sleep_ms(16)                      // minimized: no vsync paces the loop
        }
    }
    r.done[i] = gpu_signal(&r.g)
    if capture {
        gpu_wait(&r.g, r.done[i])
        removed := gpu_removed(&r.g)
        if removed != "" {
            return (shot, removed)
        }
        shot = Image{rb.width, rb.height, 4, readback_pixels(&rb)}
        readback_free(&rb)
        for k in 0..shot.w * shot.h {
            shot.pix[k * 4 + 3] = 255
        }
    }
    print_debug_messages(r)
    (shot, "")
}

// ---- sprites ---------------------------------------------------------------------------------
// Colours are premultiplied: paint(rgb, a) covers what is below by a, glow(rgb, k) adds rgb * k
// to it. A component may exceed 1: brighter than white feeds the bloom.

fn paint(rgb: vec3, a: f32) -> vec4 { vec4(rgb * a, a) }
fn glow(rgb: vec3, k: f32) -> vec4 { vec4(rgb * k, 0.0) }

priv const NO_MODE = vec4(0.0, 0.0, 0.0, 0.0)

// A quad from its corners (top left, top right, bottom left, bottom right) showing the sheet's
// rectangle uv0 .. uv1, with a colour at each corner.
fn quad4(b: *Batch, p0: vec2, p1: vec2, p2: vec2, p3: vec2, uv0: vec2, uv1: vec2, c0: vec4, c1: vec4, c2: vec4, c3: vec4, mode: vec4) {
    if b.count >= b.cap {
        return
    }
    v := b.verts
    k := b.count * 6
    o := b.cam
    a := Vertex{p0 + o, uv0, c0, mode}
    e1 := Vertex{p1 + o, vec2(uv1.x, uv0.y), c1, mode}
    e2 := Vertex{p2 + o, vec2(uv0.x, uv1.y), c2, mode}
    d := Vertex{p3 + o, uv1, c3, mode}
    v[k] = a
    v[k + 1] = e1
    v[k + 2] = e2
    v[k + 3] = e2
    v[k + 4] = e1
    v[k + 5] = d
    b.count += 1
}

priv fn uv0(b: *Batch, t: Tile) -> vec2 { vec2(t.x, t.y) * b.texel }
priv fn uv1(b: *Batch, t: Tile) -> vec2 { vec2(t.x + t.w, t.y + t.h) * b.texel }

// Tile t stretched over the rectangle x, y, w, h, with a colour at its top and its bottom.
fn sprite2(b: *Batch, t: Tile, x: f32, y: f32, w: f32, h: f32, top: vec4, bottom: vec4) {
    quad4(b, vec2(x, y), vec2(x + w, y), vec2(x, y + h), vec2(x + w, y + h), uv0(b, t), uv1(b, t), top, top, bottom, bottom, NO_MODE)
}

fn sprite(b: *Batch, t: Tile, x: f32, y: f32, w: f32, h: f32, c: vec4) { sprite2(b, t, x, y, w, h, c, c) }

// Tile t centred on c, `size` large, turned by `angle` (radians, clockwise on the screen).
fn sprite_turned(b: *Batch, t: Tile, c: vec2, size: vec2, angle: f32, col: vec4) {
    ax := vec2(cos(angle), sin(angle)) * (size.x / 2.0)
    ay := vec2(-sin(angle), cos(angle)) * (size.y / 2.0)
    quad4(b, c - ax - ay, c + ax - ay, c - ax + ay, c + ax + ay, uv0(b, t), uv1(b, t), col, col, col, col, NO_MODE)
}

// A rectangle of one colour, or of one colour at the top and another at the bottom.
fn rect(b: *Batch, x: f32, y: f32, w: f32, h: f32, c: vec4) { sprite2(b, TILE_WHITE, x, y, w, h, c, c) }
fn rect2(b: *Batch, x: f32, y: f32, w: f32, h: f32, top: vec4, bottom: vec4) { sprite2(b, TILE_WHITE, x, y, w, h, top, bottom) }

// A profile tile (TILE_BEAM, TILE_RAIL) laid from p0 to p1, `width` across, coloured c0 at p0
// and c1 at p1; the tile's top side is on the left of the direction p0 -> p1.
fn strip2(b: *Batch, t: Tile, p0: vec2, p1: vec2, width: f32, c0: vec4, c1: vec4) {
    d := p1 - p0
    l := length(d)
    if l < 0.001 {
        return
    }
    n := vec2(d.y, -d.x) / l * (width / 2.0)
    quad4(b, p0 + n, p1 + n, p0 - n, p1 - n, uv0(b, t), uv1(b, t), c0, c1, c0, c1, NO_MODE)
}

fn strip(b: *Batch, t: Tile, p0: vec2, p1: vec2, width: f32, c: vec4) { strip2(b, t, p0, p1, width, c, c) }

// A nine-slice panel (TILE_PANEL, TILE_EDGE): corners `corner` view pixels large, the edges and
// the middle stretched; coloured from `top` to `bottom`.
fn panel(b: *Batch, t: Tile, x: f32, y: f32, w: f32, h: f32, corner: f32, top: vec4, bottom: vec4) {
    xs := [4]f32{x, x + corner, x + w - corner, x + w}
    ys := [4]f32{y, y + corner, y + h - corner, y + h}
    us := [4]f32{t.x, t.x + PANEL_CORNER, t.x + t.w - PANEL_CORNER, t.x + t.w}
    vs := [4]f32{t.y, t.y + PANEL_CORNER, t.y + t.h - PANEL_CORNER, t.y + t.h}
    for j in 0..3 {
        c0 := lerp(top, bottom, (ys[j] - y) / h)
        c1 := lerp(top, bottom, (ys[j + 1] - y) / h)
        for i in 0..3 {
            quad4(b, vec2(xs[i], ys[j]), vec2(xs[i + 1], ys[j]), vec2(xs[i], ys[j + 1]), vec2(xs[i + 1], ys[j + 1]),
                vec2(us[i], vs[j]) * b.texel, vec2(us[i + 1], vs[j + 1]) * b.texel, c0, c0, c1, c1, NO_MODE)
        }
    }
}

// ---- text ------------------------------------------------------------------------------------

// The letters are glyphs.al's: a capital is 7 font pixels high.

// The pen's position after character i of s (where character i + 1 starts), in font pixels.
fn text_pen(s: str, i: i64, spacing: f32) -> f32 {
    x: f32 = 0.0
    for k in 0..min(i + 1, len(s)) {
        next: u8 = if k + 1 < len(s) { s[k + 1] } else { 0 }
        x += letter_step(s[k], next) + spacing
    }
    x
}

// The width of a line of text, `size` view pixels per font pixel, `spacing` extra font pixels
// between characters.
fn text_w(s: str, size: f32, spacing: f32) -> f32 {
    if len(s) == 0 { 0.0 } else { (text_pen(s, len(s) - 1, spacing) - spacing) * size }
}

// A line of text with the top of its capitals at y and its pen starting at x: `size` view
// pixels per font pixel, colours at the top and the bottom of the capitals, `bold` font pixels
// thicker, and `soft` > 0 for a glow `soft` font pixels wide instead of the sharp glyph.
fn text(b: *Batch, x: f32, y: f32, size: f32, s: str, top: vec4, bottom: vec4, bold: f32, soft: f32, spacing: f32) {
    mode := vec4(1.0, bold, soft, 0.0)
    k := size / letters.unit                     // view pixels per raster pixel
    base := y + 7.0 * size
    cx := x
    for i in 0..len(s) {
        c := s[i]
        g := letter(c)
        if c != ' ' {
            gx := cx + g.x * k
            gy := base + g.y * k
            w := g.tile.w * k
            h := g.tile.h * k
            // the colours run from the top of a capital to the baseline
            t0 := lerp(top, bottom, (gy - y) / (7.0 * size))
            t1 := lerp(top, bottom, (gy + h - y) / (7.0 * size))
            quad4(b, vec2(gx, gy), vec2(gx + w, gy), vec2(gx, gy + h), vec2(gx + w, gy + h), uv0(b, g.tile), uv1(b, g.tile), t0, t0, t1, t1, mode)
        }
        next: u8 = if i + 1 < len(s) { s[i + 1] } else { 0 }
        cx += (letter_step(c, next) + spacing) * size
    }
}
