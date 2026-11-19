// Crypt's renderer, Direct3D 12 (Windows only). A frame goes through these passes:
//
//   1. the scene, into a floating-point (HDR) target with 4x MSAA and a depth buffer (on WARP
//      no MSAA, and in a window half the size: the software rasterizer is slow): the maze (one static mesh with its torches) with procedural stone, flagstone and
//      wood materials (materials.al: albedo, roughness and normal maps in one texture array,
//      mipmapped, sampled anisotropically), lit per pixel by up to 16 point lights (the player's
//      lantern, the wall torches, the gems, the exit, the wraiths) with GGX highlights, the
//      maze's own shadows and ambient occlusion worked out from the map in the shader, and fog;
//      then gems, wraiths and additive effects (flames, glows, sparks, dust, runes); then, over
//      a cleared depth buffer, the lantern in the player's hand;
//   2. the MSAA target resolved into a plain one by our own pass, which weights the samples
//      by their brightness (an HDR-aware resolve: edges stay smooth after tone mapping);
//   3. bloom: the bright parts at half size, blurred, and again at a quarter size;
//   4. the picture: scene plus bloom, tone mapped, graded, vignetted (into an 8-bit target);
//      then FXAA and film grain into the window's back buffer (or a texture of our own:
//      offscreen). FXAA catches what MSAA cannot: shading edges, and the WARP path without MSAA;
//   5. the HUD and menus over it (hud.al, ui.al).
//
// It draws into a window's swap chain (two frames in flight) or into a texture of its own
// (offscreen, one frame: the scripted test and --still), and can read the finished picture back
// for a screenshot. render_frame reads the game and never changes it. The shaders are in
// shaders.al, the meshes, lights and effects in scene.al.
use std.window
use std.image
use "logic.al"
use "../gamekit/dx12_gpu.al"
use "materials.al"
use "shaders.al"
use "scene.al"
use "ui.al"
use "hud.al"

const RENDER_FORMAT = DXGI_FORMAT_R8G8B8A8_UNORM
const SCENE_FORMAT = DXGI_FORMAT_R16G16B16A16_FLOAT
const DEPTH_FORMAT = DXGI_FORMAT_D32_FLOAT
const MAX_FRAMES = 2
const FOG = vec4(0.004, 0.005, 0.009, 0.075)     // the colour of the dark, and its density per metre
const FX_QUADS = 1024                            // effect quads a frame
const FRAME_CB = 1024                            // bytes of frame constants per frame in flight (a multiple of 256)

// The shader-visible descriptors: materials, the scene, the bloom targets (in this order, so
// that a table of three starting at SRV_SCENE is scene, half-size bloom, quarter-size bloom),
// the HUD's atlas, the tone-mapped picture (for FXAA), the MSAA scene (for the resolve), and
// empty ones that close the tables starting near the end.
const SRV_MATERIALS = 0
const SRV_SCENE = 1
const SRV_UI = 6
const SRV_LDR = 7
const SRV_MSAA = 8
const SRV_COUNT = 11
const BLOOM_SRV = [4]i64{2, 4, 3, 5}             // bloom targets A, B (half size), C, D (quarter)
// The render-target views: the back buffers, the scene (MSAA, or the plain one without MSAA),
// the bloom targets, the tone-mapped picture, the resolved scene.
const RTV_SCENE = MAX_FRAMES
const RTV_BLOOM = MAX_FRAMES + 1
const RTV_LDR = MAX_FRAMES + 5
const RTV_RESOLVED = MAX_FRAMES + 6
const RTV_COUNT = MAX_FRAMES + 7

// The root constants of one scene draw call (the shader's cbuffer Draw, register b0).
struct DrawConsts {
    model: mat4
    tint: vec4
    fx: vec4              // x: emission, y: roughness, z: 1 for the lantern's glass, w: a phase
}
const DRAW_VALUES = hlsl_cbuffer_size[DrawConsts]() / 4

// The constants of a frame (cbuffer Frame, register b1), in an upload buffer.
struct FrameConsts {
    view_proj: mat4
    eye: vec4
    fog: vec4
    params: vec4
    cam_right: vec4
    cam_up: vec4
    map_rows: [5]vec4
    light_pos: [MAX_LIGHTS]vec4
    light_color: [MAX_LIGHTS]vec4
}
const FRAME_SIZE = hlsl_cbuffer_size[FrameConsts]()

// The root constants of a post-processing pass (cbuffer Post).
struct PostConsts { p0: vec4, p1: vec4, p2: vec4 }
const POST_VALUES = hlsl_cbuffer_size[PostConsts]() / 4

struct Renderer {
    w: *Window                       // nil: offscreen
    g: Gpu
    info: *ID3D12InfoQueue           // the debug layer's messages (nil without --debug)
    messages: i64                    // debug messages printed so far
    swap: *IDXGISwapChain3           // nil: offscreen
    frames: i64
    samples: i64                     // MSAA samples of the scene (1: none)
    targets: [MAX_FRAMES]*ID3D12Resource
    allocators: [MAX_FRAMES]*ID3D12CommandAllocator
    done: [MAX_FRAMES]u64            // the fence value of the last frame drawn into each target
    list: *ID3D12GraphicsCommandList
    rtv_heap: *ID3D12DescriptorHeap
    dsv_heap: *ID3D12DescriptorHeap
    srv_heap: *ID3D12DescriptorHeap  // shader-visible
    depth: *ID3D12Resource
    scene_msaa: *ID3D12Resource      // nil without MSAA
    scene: *ID3D12Resource
    bloom: [4]*ID3D12Resource
    ldr: *ID3D12Resource             // the tone-mapped picture before FXAA
    grain: f32                       // film grain strength of the final pass
    materials: *ID3D12Resource
    atlas: *ID3D12Resource           // the HUD's texture, for HUD units of ui_px pixels
    ui_px: f32
    painted: Image                   // its painted part
    scene_root: *ID3D12RootSignature
    post_root: *ID3D12RootSignature
    mesh_pso: *ID3D12PipelineState
    fx_pso: *ID3D12PipelineState
    bright_pso: *ID3D12PipelineState
    blur_pso: *ID3D12PipelineState
    down_pso: *ID3D12PipelineState
    composite_pso: *ID3D12PipelineState
    resolve_pso: *ID3D12PipelineState
    fxaa_pso: *ID3D12PipelineState
    vertices: *ID3D12Resource
    vertex_view: D3D12_VERTEX_BUFFER_VIEW
    meshes: Meshes
    frame_cb: *ID3D12Resource        // FRAME_CB bytes per frame in flight, mapped
    frame_mem: []u8
    fx_buffer: *ID3D12Resource       // FX_QUADS quads per frame in flight, mapped
    fx_mem: []FxVertex
    torches: [MAX_TORCHES]Torch
    n_torches: i64
    map_rows: [5]vec4
    lights: Lights
    ui: Ui
    width: i64                       // of the frame's target
    height: i64
    scene_div: i64                   // the scene is drawn at 1 / scene_div of that size (2 on WARP in a window)
    scene_w: i64
    scene_h: i64
    frame: i64
    vsync: bool
    resizes: i64
}

// ---- set-up ----------------------------------------------------------------------------------

priv fn srv_cpu(r: *Renderer, slot: i64) -> D3D12_CPU_DESCRIPTOR_HANDLE {
    gpu_cpu_handle(&r.g, r.srv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, slot)
}

priv fn srv_gpu(r: *Renderer, slot: i64) -> D3D12_GPU_DESCRIPTOR_HANDLE {
    h := r.srv_heap.GetGPUDescriptorHandleForHeapStart()
    h.ptr += u64(slot) * u64(r.g.device.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV))
    h
}

priv fn rtv(r: *Renderer, slot: i64) -> D3D12_CPU_DESCRIPTOR_HANDLE {
    gpu_cpu_handle(&r.g, r.rtv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, slot)
}

// A 2D texture of `samples` samples per pixel in the default heap.
priv fn make_texture(g: *Gpu, w: i64, h: i64, format: i32, samples: i64, flags: u32, state: u32, clear: *D3D12_CLEAR_VALUE) -> *ID3D12Resource {
    props := D3D12_HEAP_PROPERTIES{Type: D3D12_HEAP_TYPE_DEFAULT, CreationNodeMask: 1, VisibleNodeMask: 1}
    desc := D3D12_RESOURCE_DESC{Dimension: D3D12_RESOURCE_DIMENSION_TEXTURE2D, Width: u64(w), Height: u32(h), DepthOrArraySize: 1,
        MipLevels: 1, Format: format, SampleDesc: DXGI_SAMPLE_DESC{Count: u32(samples)}, Flags: flags}
    t: *ID3D12Resource
    gpu_check(g, g.device.CreateCommittedResource(&props, D3D12_HEAP_FLAG_NONE, &desc, state, clear, &IID_ID3D12Resource, &t),
        "CreateCommittedResource (target)")
    t
}

// A shader resource view of a plain 2D texture (nil: an empty one) in descriptor `slot`.
priv fn srv_2d(r: *Renderer, res: *ID3D12Resource, format: i32, mips: i64, slot: i64) {
    view := D3D12_SHADER_RESOURCE_VIEW_DESC{Format: format, ViewDimension: D3D12_SRV_DIMENSION_TEXTURE2D,
        Shader4ComponentMapping: D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING}
    view.u_Texture2D().MipLevels = u32(mips)
    r.g.device.CreateShaderResourceView(res, &view, srv_cpu(r, slot))
}

// Uploads an RGBA8 texture (an array of `layers` textures of `mips` levels; subresource
// layer * mips + mip is subs[layer * mips + mip]) through one staging buffer laid out by
// GetCopyableFootprints, and waits for the copy. The texture ends in the pixel-shader state.
priv fn upload_texture(g: *Gpu, subs: []Image, layers: i64, mips: i64) -> *ID3D12Resource {
    props := D3D12_HEAP_PROPERTIES{Type: D3D12_HEAP_TYPE_DEFAULT, CreationNodeMask: 1, VisibleNodeMask: 1}
    desc := D3D12_RESOURCE_DESC{Dimension: D3D12_RESOURCE_DIMENSION_TEXTURE2D, Width: u64(subs[0].w), Height: u32(subs[0].h),
        DepthOrArraySize: u16(layers), MipLevels: u16(mips), Format: DXGI_FORMAT_R8G8B8A8_UNORM, SampleDesc: DXGI_SAMPLE_DESC{Count: 1}}
    tex: *ID3D12Resource
    gpu_check(g, g.device.CreateCommittedResource(&props, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_COPY_DEST, nil,
        &IID_ID3D12Resource, &tex), "CreateCommittedResource (texture)")
    n := layers * mips
    layouts := alloc[D3D12_PLACED_SUBRESOURCE_FOOTPRINT](n)
    total: u64
    g.device.GetCopyableFootprints(&desc, 0, u32(n), 0, ptr(layouts), nil, nil, &total)
    staging := gpu_buffer(g, D3D12_HEAP_TYPE_UPLOAD, i64(total), D3D12_RESOURCE_STATE_GENERIC_READ)
    mapped: *u8
    none := D3D12_RANGE{0, 0}
    gpu_check(g, staging.Map(0, &none, &mapped), "ID3D12Resource::Map (staging)")
    mem := mkslice[u8](mapped, i64(total))
    for s in 0..n {
        img := subs[s]
        at := i64(layouts[s].Offset)
        pitch := i64(layouts[s].Footprint.RowPitch)
        for y in 0..img.h {
            copy(mem[at + y * pitch..at + y * pitch + img.w * 4], img.pix[y * img.w * 4..(y + 1) * img.w * 4])
        }
    }
    staging.Unmap(0, nil)
    allocator, list := gpu_command_list(g)
    gpu_reset(allocator, list)
    for s in 0..n {
        dst := D3D12_TEXTURE_COPY_LOCATION{pResource: tex, Type: D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}
        *dst.u_SubresourceIndex() = u32(s)
        src := D3D12_TEXTURE_COPY_LOCATION{pResource: staging, Type: D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT}
        *src.u_PlacedFootprint() = layouts[s]
        list.CopyTextureRegion(&dst, 0, 0, 0, &src, nil)
    }
    dx_barrier(list, tex, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
    gpu_execute(g, list)
    gpu_flush(g)
    com_release(&list)
    com_release(&allocator)
    com_release(&staging)
    tex
}

// The kinds of pipeline: lit meshes, additive effects, full-screen passes.
enum PipeKind { PipeMesh, PipeFx, PipePost }

// A pipeline from HLSL source: the vertex and pixel entry points compiled, and what differs
// from dx_pipeline_desc's defaults for its kind.
priv fn pipeline(g: *Gpu, root: *ID3D12RootSignature, source: str, vs_entry: str, ps_entry: str, format: i32, samples: i64,
    kind: PipeKind, what: str) -> (*ID3D12PipelineState, str) {
    pso: *ID3D12PipelineState
    vs, verr := dx_compile(source, vs_entry, "vs_5_0")
    if verr != "" { return (pso, fmt(what, ": ", verr)) }
    ps, perr := dx_compile(source, ps_entry, "ps_5_0")
    if perr != "" {
        com_release(&vs)
        return (pso, fmt(what, ": ", perr))
    }
    desc := dx_pipeline_desc(root, vs, ps, format)
    desc.SampleDesc.Count = u32(samples)
    mesh_layout := [3]D3D12_INPUT_ELEMENT_DESC{
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("POSITION"), Format: DXGI_FORMAT_R32G32B32_FLOAT, AlignedByteOffset: u32(offsetof[MeshVertex](pos))},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("NORMAL"), Format: DXGI_FORMAT_R32G32B32_FLOAT, AlignedByteOffset: u32(offsetof[MeshVertex](normal))},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("COLOR"), Format: DXGI_FORMAT_R8G8B8A8_UNORM, AlignedByteOffset: u32(offsetof[MeshVertex](color))},
    }
    fx_layout := [4]D3D12_INPUT_ELEMENT_DESC{
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("POSITION"), Format: DXGI_FORMAT_R32G32B32_FLOAT, AlignedByteOffset: u32(offsetof[FxVertex](pos))},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("TEXCOORD"), Format: DXGI_FORMAT_R32G32_FLOAT, AlignedByteOffset: u32(offsetof[FxVertex](uv))},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("KIND"), Format: DXGI_FORMAT_R32_FLOAT, AlignedByteOffset: u32(offsetof[FxVertex](kind))},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("COLOR"), Format: DXGI_FORMAT_R32G32B32A32_FLOAT, AlignedByteOffset: u32(offsetof[FxVertex](color))},
    }
    match kind {
        PipeMesh => {
            desc.InputLayout = D3D12_INPUT_LAYOUT_DESC{ptr(mesh_layout), 3}
            desc.DepthStencilState.DepthEnable = 1
            desc.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL
            desc.DSVFormat = DEPTH_FORMAT
        }
        PipeFx => {
            desc.InputLayout = D3D12_INPUT_LAYOUT_DESC{ptr(fx_layout), 4}
            desc.DepthStencilState.DepthEnable = 1
            desc.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO
            desc.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS_EQUAL
            desc.DSVFormat = DEPTH_FORMAT
            // added light: one + one, the alpha left alone
            b := &desc.BlendState.RenderTarget[0]
            b.BlendEnable = 1
            b.SrcBlend = D3D12_BLEND_ONE
            b.DestBlend = D3D12_BLEND_ONE
            b.SrcBlendAlpha = D3D12_BLEND_ZERO
            b.DestBlendAlpha = D3D12_BLEND_ONE
        }
        PipePost => {}
    }
    hr := g.device.CreateGraphicsPipelineState(&desc, &IID_ID3D12PipelineState, &pso)
    com_release(&vs)
    com_release(&ps)
    if FAILED(hr) { return (pso, hresult_text(fmt("CreateGraphicsPipelineState (", what, ")"), hr)) }
    (pso, "")
}

// The root signatures, pipelines, textures, meshes and buffers shared by both kinds of
// renderer. "" or what failed.
priv fn renderer_setup(r: *Renderer) -> str {
    g := &r.g
    if !g.warp {
        // 4x MSAA if the format allows it (every Direct3D 12 device should)
        q := D3D12_FEATURE_DATA_MULTISAMPLE_QUALITY_LEVELS{Format: SCENE_FORMAT, SampleCount: 4}
        hr := g.device.CheckFeatureSupport(D3D12_FEATURE_MULTISAMPLE_QUALITY_LEVELS, cast[*u8](&q),
            u32(sizeof[D3D12_FEATURE_DATA_MULTISAMPLE_QUALITY_LEVELS]()))
        r.samples = if SUCCEEDED(hr) && q.NumQualityLevels > 0 { 4 } else { 1 }
    } else {
        r.samples = 1
    }

    // the scene's root signature: the draw's constants (b0), the frame's constant buffer
    // (b1), the material array (t0) and an anisotropic, wrapping sampler (s0)
    params: [3]D3D12_ROOT_PARAMETER
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS
    params[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL
    params[0].u_Constants().Num32BitValues = DRAW_VALUES
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV
    params[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL
    params[1].u_Descriptor().ShaderRegister = 1
    range := D3D12_DESCRIPTOR_RANGE{RangeType: D3D12_DESCRIPTOR_RANGE_TYPE_SRV, NumDescriptors: 1}
    params[2].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE
    params[2].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL
    params[2].u_DescriptorTable().NumDescriptorRanges = 1
    params[2].u_DescriptorTable().pDescriptorRanges = &range
    aniso := D3D12_STATIC_SAMPLER_DESC{Filter: D3D12_FILTER_ANISOTROPIC, AddressU: D3D12_TEXTURE_ADDRESS_MODE_WRAP,
        AddressV: D3D12_TEXTURE_ADDRESS_MODE_WRAP, AddressW: D3D12_TEXTURE_ADDRESS_MODE_WRAP, MaxAnisotropy: 8,
        ComparisonFunc: D3D12_COMPARISON_FUNC_NEVER, MaxLOD: 3.4e38, ShaderVisibility: D3D12_SHADER_VISIBILITY_PIXEL}
    root_desc := D3D12_ROOT_SIGNATURE_DESC{NumParameters: 3, pParameters: ptr(params), NumStaticSamplers: 1, pStaticSamplers: &aniso,
        Flags: D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT}
    root, err := dx_root_signature(g, &root_desc)
    if err != "" { return err }
    r.scene_root = root

    // post-processing: constants (b0), three textures (t0-t2), a linear clamping sampler
    pparams: [2]D3D12_ROOT_PARAMETER
    pparams[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS
    pparams[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL
    pparams[0].u_Constants().Num32BitValues = POST_VALUES
    prange := D3D12_DESCRIPTOR_RANGE{RangeType: D3D12_DESCRIPTOR_RANGE_TYPE_SRV, NumDescriptors: 3}
    pparams[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE
    pparams[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL
    pparams[1].u_DescriptorTable().NumDescriptorRanges = 1
    pparams[1].u_DescriptorTable().pDescriptorRanges = &prange
    clamp_s := D3D12_STATIC_SAMPLER_DESC{Filter: D3D12_FILTER_MIN_MAG_MIP_LINEAR, AddressU: D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        AddressV: D3D12_TEXTURE_ADDRESS_MODE_CLAMP, AddressW: D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        ComparisonFunc: D3D12_COMPARISON_FUNC_NEVER, MaxLOD: 3.4e38, ShaderVisibility: D3D12_SHADER_VISIBILITY_PIXEL}
    proot_desc := D3D12_ROOT_SIGNATURE_DESC{NumParameters: 2, pParameters: ptr(pparams), NumStaticSamplers: 1, pStaticSamplers: &clamp_s}
    proot, perr := dx_root_signature(g, &proot_desc)
    if perr != "" { return perr }
    r.post_root = proot

    // the pipelines
    mesh, e1 := pipeline(g, r.scene_root, scene_shader(), "vs_main", "ps_main", SCENE_FORMAT, r.samples, PipeMesh, "meshes")
    if e1 != "" { return e1 }
    r.mesh_pso = mesh
    fxp, e2 := pipeline(g, r.scene_root, fx_shader(), "vs_fx", "ps_fx", SCENE_FORMAT, r.samples, PipeFx, "effects")
    if e2 != "" { return e2 }
    r.fx_pso = fxp
    bright, e3 := pipeline(g, r.post_root, POST_SHADER, "vs_full", "ps_bright", SCENE_FORMAT, 1, PipePost, "bright pass")
    if e3 != "" { return e3 }
    r.bright_pso = bright
    blur, e4 := pipeline(g, r.post_root, POST_SHADER, "vs_full", "ps_blur", SCENE_FORMAT, 1, PipePost, "blur")
    if e4 != "" { return e4 }
    r.blur_pso = blur
    down, e5 := pipeline(g, r.post_root, POST_SHADER, "vs_full", "ps_down", SCENE_FORMAT, 1, PipePost, "downsample")
    if e5 != "" { return e5 }
    r.down_pso = down
    comp, e6 := pipeline(g, r.post_root, POST_SHADER, "vs_full", "ps_composite", RENDER_FORMAT, 1, PipePost, "composite")
    if e6 != "" { return e6 }
    r.composite_pso = comp
    fxaa, e7 := pipeline(g, r.post_root, POST_SHADER, "vs_full", "ps_fxaa", RENDER_FORMAT, 1, PipePost, "fxaa")
    if e7 != "" { return e7 }
    r.fxaa_pso = fxaa
    if r.samples > 1 {
        res, e8 := pipeline(g, r.post_root, resolve_shader(), "vs_full", "ps_resolve", SCENE_FORMAT, 1, PipePost, "resolve")
        if e8 != "" { return e8 }
        r.resolve_pso = res
    }
    r.grain = 0.035

    assert FRAME_SIZE <= FRAME_CB, "the frame constants outgrew their slot"
    // the world: torches, meshes, the map as bits for the shader
    r.n_torches = place_torches(&r.torches)
    probe := game_new(1)
    v := vec[MeshVertex]()
    r.meshes = build_meshes(&v, r.torches[..r.n_torches], probe.exit)
    r.vertices = gpu_upload(g, as_bytes(v.items()))
    r.vertex_view = D3D12_VERTEX_BUFFER_VIEW{r.vertices.GetGPUVirtualAddress(), u32(v.len * sizeof[MeshVertex]()), u32(sizeof[MeshVertex]())}
    for row in 0..MAP_H {
        bits := 0
        for c in 0..MAP_W {
            if is_wall(c, row) {
                bits |= 1 << c
            }
        }
        r.map_rows[row / 4][row % 4] = f32(bits)
    }

    // the materials: 3 albedo layers, then 3 normal layers, each with its mipmaps
    mats := make_materials()
    mips := 1
    while TEX_SIZE >> (mips - 1) > 1 {
        mips += 1
    }
    subs := alloc[Image](2 * MATERIALS * mips)
    for k in 0..MATERIALS {
        a := mipmap_chain(mats[k].albedo)
        n := mipmap_chain(mats[k].normal)
        assert len(a) == mips, "materials: unexpected mipmap count"
        for m in 0..mips {
            subs[k * mips + m] = a[m]
            subs[(MATERIALS + k) * mips + m] = n[m]
        }
    }
    r.materials = upload_texture(g, subs, 2 * MATERIALS, mips)

    r.srv_heap = gpu_descriptor_heap(g, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, SRV_COUNT, true)
    view := D3D12_SHADER_RESOURCE_VIEW_DESC{Format: DXGI_FORMAT_R8G8B8A8_UNORM, ViewDimension: D3D12_SRV_DIMENSION_TEXTURE2DARRAY,
        Shader4ComponentMapping: D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING}
    view.u_Texture2DArray().MipLevels = u32(mips)
    view.u_Texture2DArray().ArraySize = u32(2 * MATERIALS)
    g.device.CreateShaderResourceView(r.materials, &view, srv_cpu(r, SRV_MATERIALS))
    for slot in SRV_UI + 1..SRV_COUNT {
        srv_2d(r, nil, SCENE_FORMAT, 1, slot)
    }

    // per-frame memory, mapped once: the frame's constants and its effect quads
    none := D3D12_RANGE{0, 0}
    r.frame_cb = gpu_buffer(g, D3D12_HEAP_TYPE_UPLOAD, MAX_FRAMES * FRAME_CB, D3D12_RESOURCE_STATE_GENERIC_READ)
    cb: *u8
    gpu_check(g, r.frame_cb.Map(0, &none, &cb), "ID3D12Resource::Map (frame constants)")
    r.frame_mem = mkslice[u8](cb, MAX_FRAMES * FRAME_CB)
    r.fx_buffer = gpu_buffer(g, D3D12_HEAP_TYPE_UPLOAD, MAX_FRAMES * FX_QUADS * 6 * sizeof[FxVertex](), D3D12_RESOURCE_STATE_GENERIC_READ)
    fxm: *u8
    gpu_check(g, r.fx_buffer.Map(0, &none, &fxm), "ID3D12Resource::Map (effects)")
    r.fx_mem = mkslice[FxVertex](cast[*FxVertex](fxm), MAX_FRAMES * FX_QUADS * 6)

    for i in 0..r.frames {
        gpu_check(g, g.device.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator,
            &r.allocators[i]), "CreateCommandAllocator")
    }
    gpu_check(g, g.device.CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, r.allocators[0], nil,
        &IID_ID3D12GraphicsCommandList, &r.list), "CreateCommandList")
    gpu_check(g, r.list.Close(), "ID3D12GraphicsCommandList::Close")
    r.rtv_heap = gpu_descriptor_heap(g, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, RTV_COUNT, false)
    r.dsv_heap = gpu_descriptor_heap(g, D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 1, false)

    ui, uerr := ui_new(g, RENDER_FORMAT, 6000, r.frames)
    if uerr != "" { return uerr }
    r.ui = ui
    r.painted = ui_painted()
    make_ui_texture(r)
    ""
}

// The HUD's texture (ui.al): the painted part and the font rasterised for the target's size.
// Made again when the size changes; what it allocates lives in ui_mem until then.
ui_mem: Region

priv fn make_ui_texture(r: *Renderer) {
    px := f32(r.height) / f32(HUD_H)
    if r.atlas != nil && px == r.ui_px {
        return
    }
    gpu_flush(&r.g)                       // the GPU may still be reading the old one
    com_release(&r.atlas)
    reset(&ui_mem)
    enter(&ui_mem)
    chain := ui_texture(&r.ui, r.painted, px)
    r.atlas = upload_texture(&r.g, chain, 1, UI_ATLAS_MIPS)
    leave()
    r.ui_px = px
    srv_2d(r, r.atlas, DXGI_FORMAT_R8G8B8A8_UNORM, UI_ATLAS_MIPS, SRV_UI)
}

// The targets that depend on the size: the back buffers' views, the depth buffer, the scene
// (MSAA and resolved) and the bloom targets, with their views.
priv fn create_views(r: *Renderer) {
    g := &r.g
    for i in 0..r.frames {
        if r.swap != nil {
            gpu_check(g, r.swap.GetBuffer(u32(i), &IID_ID3D12Resource, &r.targets[i]), "IDXGISwapChain::GetBuffer")
        }
        g.device.CreateRenderTargetView(r.targets[i], nil, rtv(r, i))
    }
    dclear := D3D12_CLEAR_VALUE{Format: DEPTH_FORMAT}
    dclear.u_DepthStencil().Depth = 1.0
    r.scene_w = max(r.width / r.scene_div, 1)
    r.scene_h = max(r.height / r.scene_div, 1)
    r.depth = make_texture(g, r.scene_w, r.scene_h, DEPTH_FORMAT, r.samples, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL,
        D3D12_RESOURCE_STATE_DEPTH_WRITE, &dclear)
    g.device.CreateDepthStencilView(r.depth, nil, gpu_cpu_handle(g, r.dsv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 0))
    cclear := D3D12_CLEAR_VALUE{Format: SCENE_FORMAT}
    *cclear.u_Color() = [4]f32{FOG.x, FOG.y, FOG.z, 1.0}
    if r.samples > 1 {
        r.scene_msaa = make_texture(g, r.scene_w, r.scene_h, SCENE_FORMAT, r.samples, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
            D3D12_RESOURCE_STATE_RENDER_TARGET, &cclear)
        r.scene = make_texture(g, r.scene_w, r.scene_h, SCENE_FORMAT, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
            D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, nil)
        g.device.CreateRenderTargetView(r.scene_msaa, nil, rtv(r, RTV_SCENE))
        g.device.CreateRenderTargetView(r.scene, nil, rtv(r, RTV_RESOLVED))
        ms := D3D12_SHADER_RESOURCE_VIEW_DESC{Format: SCENE_FORMAT, ViewDimension: D3D12_SRV_DIMENSION_TEXTURE2DMS,
            Shader4ComponentMapping: D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING}
        g.device.CreateShaderResourceView(r.scene_msaa, &ms, srv_cpu(r, SRV_MSAA))
    } else {
        r.scene = make_texture(g, r.scene_w, r.scene_h, SCENE_FORMAT, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
            D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, &cclear)
        g.device.CreateRenderTargetView(r.scene, nil, rtv(r, RTV_SCENE))
    }
    srv_2d(r, r.scene, SCENE_FORMAT, 1, SRV_SCENE)
    for k in 0..4 {
        div := if k < 2 { 2 } else { 4 }
        r.bloom[k] = make_texture(g, max(r.scene_w / div, 1), max(r.scene_h / div, 1), SCENE_FORMAT, 1,
            D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, nil)
        g.device.CreateRenderTargetView(r.bloom[k], nil, rtv(r, RTV_BLOOM + k))
        srv_2d(r, r.bloom[k], SCENE_FORMAT, 1, BLOOM_SRV[k])
    }
    r.ldr = make_texture(g, r.width, r.height, RENDER_FORMAT, 1, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
        D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, nil)
    g.device.CreateRenderTargetView(r.ldr, nil, rtv(r, RTV_LDR))
    srv_2d(r, r.ldr, RENDER_FORMAT, 1, SRV_LDR)
}

priv fn release_views(r: *Renderer) {
    for i in 0..MAX_FRAMES {
        com_release(&r.targets[i])
    }
    com_release(&r.depth)
    com_release(&r.scene_msaa)
    com_release(&r.scene)
    com_release(&r.ldr)
    for k in 0..4 {
        com_release(&r.bloom[k])
    }
}

priv fn open_gpu(r: *Renderer, warp: bool, debug: bool) -> str {
    gpu, err := gpu_open(debug, warp)
    if err != "" {
        return fmt("no Direct3D 12 device: ", err)
    }
    r.g = gpu
    if debug {
        // the debug layer's messages are read back and printed (debug_messages)
        if FAILED(r.g.device.QueryInterface(&IID_ID3D12InfoQueue, &r.info)) {
            eprint("no ID3D12InfoQueue: is the debug layer (Graphics Tools) installed?")
        }
    }
    ""
}

// A renderer on a window: a flip-model swap chain on its HWND. (renderer, "") or (nil, why).
// `debug` turns the Direct3D debug layer on and prints its messages.
fn renderer_window(w: *Window, warp: bool, debug: bool) -> (*Renderer, str) {
    r := new[Renderer]()
    err := open_gpu(r, warp, debug)
    if err != "" {
        return (nil, err)
    }
    r.w = w
    r.frames = MAX_FRAMES
    r.vsync = true
    // the software rasterizer cannot keep up with the full size: the scene at half of it,
    // stretched by the final pass (the HUD stays sharp)
    r.scene_div = if r.g.warp { 2 } else { 1 }
    width, height := w.size()
    r.width = max(width, 1)
    r.height = max(height, 1)
    desc := DXGI_SWAP_CHAIN_DESC1{
        Width: u32(r.width), Height: u32(r.height), Format: RENDER_FORMAT, SampleDesc: DXGI_SAMPLE_DESC{Count: 1},
        BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT, BufferCount: MAX_FRAMES, SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
    }
    swap1: *IDXGISwapChain1
    hr := r.g.factory.CreateSwapChainForHwnd(cast[*IUnknown](r.g.queue), win32_hwnd(w), &desc, nil, nil, &swap1)
    if FAILED(hr) {
        renderer_close(r)
        return (nil, hresult_text("CreateSwapChainForHwnd", hr))
    }
    gpu_check(&r.g, swap1.QueryInterface(&IID_IDXGISwapChain3, &r.swap), "QueryInterface IDXGISwapChain3")
    com_release(&swap1)
    r.g.factory.MakeWindowAssociation(win32_hwnd(w), DXGI_MWA_NO_ALT_ENTER)
    serr := renderer_setup(r)
    if serr != "" {
        renderer_close(r)
        return (nil, serr)
    }
    create_views(r)
    debug_messages(r)
    (r, "")
}

// A renderer that draws into a texture of `width` x `height` (one frame in flight).
fn renderer_offscreen(width: i64, height: i64, warp: bool, debug: bool) -> (*Renderer, str) {
    r := new[Renderer]()
    err := open_gpu(r, warp, debug)
    if err != "" {
        return (nil, err)
    }
    r.frames = 1
    r.scene_div = 1
    r.width = width
    r.height = height
    serr := renderer_setup(r)
    if serr != "" {
        renderer_close(r)
        return (nil, serr)
    }
    clear := [4]f32{0.0, 0.0, 0.0, 1.0}
    r.targets[0] = gpu_texture(&r.g, width, height, RENDER_FORMAT, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
        D3D12_RESOURCE_STATE_PRESENT, &clear)
    create_views(r)
    debug_messages(r)
    (r, "")
}

priv fn resize(r: *Renderer, width: i64, height: i64) {
    gpu_flush(&r.g)
    release_views(r)
    gpu_check(&r.g, r.swap.ResizeBuffers(u32(r.frames), u32(width), u32(height), DXGI_FORMAT_UNKNOWN, 0), "IDXGISwapChain::ResizeBuffers")
    r.width = width
    r.height = height
    r.resizes += 1
    create_views(r)
    make_ui_texture(r)
}

fn renderer_close(r: *Renderer) {
    if r.g.queue != nil {
        gpu_flush(&r.g)
    }
    debug_messages(r)
    ui_free(&r.ui)
    if r.frame_cb != nil && len(r.frame_mem) > 0 {
        r.frame_cb.Unmap(0, nil)
        r.frame_mem = nil
    }
    if r.fx_buffer != nil && len(r.fx_mem) > 0 {
        r.fx_buffer.Unmap(0, nil)
        r.fx_mem = nil
    }
    com_release(&r.frame_cb)
    com_release(&r.fx_buffer)
    com_release(&r.list)
    for i in 0..MAX_FRAMES {
        com_release(&r.allocators[i])
    }
    release_views(r)
    com_release(&r.rtv_heap)
    com_release(&r.dsv_heap)
    com_release(&r.srv_heap)
    com_release(&r.materials)
    com_release(&r.atlas)
    com_release(&r.vertices)
    com_release(&r.mesh_pso)
    com_release(&r.fx_pso)
    com_release(&r.bright_pso)
    com_release(&r.blur_pso)
    com_release(&r.down_pso)
    com_release(&r.composite_pso)
    com_release(&r.resolve_pso)
    com_release(&r.fxaa_pso)
    com_release(&r.scene_root)
    com_release(&r.post_root)
    com_release(&r.swap)
    com_release(&r.info)
    gpu_close(&r.g)
}

// Prints what the debug layer has said since the last call (nothing without --debug). The
// message buffer is a stack array: no memory is taken per frame.
fn debug_messages(r: *Renderer) {
    if r.info == nil {
        return
    }
    n := r.info.GetNumStoredMessages()
    buf: [4096]u8
    for k in 0..n {
        size: u64
        r.info.GetMessage(k, nil, &size)
        if size > 4096 {
            print("D3D12: (a message too long to show)")
            continue
        }
        m := cast[*D3D12_MESSAGE](ptr(buf))
        if SUCCEEDED(r.info.GetMessage(k, m, &size)) {
            text := mkslice[u8](m.pDescription, max(i64(m.DescriptionByteLength) - 1, 0))
            print("D3D12:", if m.Severity <= D3D12_MESSAGE_SEVERITY_ERROR { "ERROR" } else if m.Severity == D3D12_MESSAGE_SEVERITY_WARNING { "WARNING" } else { "INFO" }, text)
            r.messages += 1
        }
    }
    r.info.ClearStoredMessages()
}

// ---- reading the picture back ----------------------------------------------------------------

// The copy itself is the gamekit's (gpu_readback, readback_pixels in ../gamekit/dx12_gpu.al).

// The pixels of a finished readback as an RGBA image (allocates), and the buffer released.
priv fn readback_image(rb: *Readback) -> Image {
    img := Image{rb.width, rb.height, 4, readback_pixels(rb)}
    readback_free(rb)
    // the alpha of the target is whatever blending left there: a screenshot is opaque
    for i in 0..rb.width * rb.height {
        img.pix[i * 4 + 3] = 255
    }
    img
}

// ---- the camera ------------------------------------------------------------------------------

// The camera of the frame: where the eye is and the view matrix. Walking bobs the head once a
// footstep (the game's footstep counter, so the bob and the footstep sounds agree).
fn camera_view(g: *Game, alpha: f32) -> (vec3, mat4) {
    p := lerp(g.prev_pos, g.pos, alpha)
    yaw := g.yaw
    pitch := g.pitch
    bob: f32 = 0.0
    if g.mode == Title {
        // the title screen drifts slowly up and down the long corridor of the first column,
        // looking north towards the gem at its end
        t := f32(g.time)
        p = vec2(cell_center(1, 13).x, cell_center(1, 13).y - 2.2 - 2.0 * sin(t * 0.07))
        yaw = 0.22 * sin(t * 0.11)
        pitch = -0.04 + 0.03 * sin(t * 0.09)
    } else {
        bob = -0.035 * (0.5 + 0.5 * cos(g.walked / 1.7 * TAU))
    }
    eye := vec3(p.x, EYE_H + bob, p.y)
    f := forward_of(yaw)
    dir := vec3(f.x * cos(pitch), sin(pitch), f.y * cos(pitch))
    (eye, look_at(eye, eye + dir, vec3(0.0, 1.0, 0.0)))
}

// Where the lantern hangs (its world matrix): low at the left of the view, swinging gently,
// lagging a little behind the player's movement and lifted with the flash.
priv fn lantern_frame(g: *Game, cam: mat4) -> mat4 {
    t := f32(g.time)
    vel := (g.pos - g.prev_pos) * f32(HZ)
    // the movement in the camera's frame: right and forward
    right := vec3(cam[0])
    fwd := -vec3(cam[2])
    side := dot(vec3(vel.x, 0.0, vel.y), right)
    ahead := dot(vec3(vel.x, 0.0, vel.y), fwd)
    step := g.walked / 1.7 * TAU
    flash := if g.flash > 0.0 { g.flash / FLASH_TIME } else { 0.0 }
    off := vec3(-0.27 - side * 0.006 + 0.01 * sin(step), -0.28 + 0.012 * fabs(sin(step)) + 0.05 * flash, -0.62 + ahead * 0.008)
    swing := 0.06 * sin(t * 1.3) + side * 0.02
    cam * translate(off) * rotate_z(swing) * rotate_x(0.05 * sin(t * 0.9) - ahead * 0.01) * rotate_y(0.5) * scale(vec3(0.72))
}

// ---- the frame -------------------------------------------------------------------------------

priv fn draw(list: *ID3D12GraphicsCommandList, c: *DrawConsts, m: Mesh) {
    list.SetGraphicsRoot32BitConstants(0, DRAW_VALUES, cast[*u8](c), 0)
    list.DrawInstanced(u32(m.count), 1, u32(m.first), 0)
}

priv fn bind_scene(r: *Renderer, pso: *ID3D12PipelineState, cb: u64) {
    list := r.list
    list.SetPipelineState(pso)
    list.SetGraphicsRootSignature(r.scene_root)
    list.SetGraphicsRootConstantBufferView(1, cb)
    list.SetGraphicsRootDescriptorTable(2, srv_gpu(r, SRV_MATERIALS))
    list.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST)
}

// Draws effect quads first .. first + count - 1 of this frame's region.
priv fn draw_fx(r: *Renderer, cb: u64, base: i64, first: i64, count: i64) {
    if count <= 0 {
        return
    }
    bind_scene(r, r.fx_pso, cb)
    stride := sizeof[FxVertex]()
    view := D3D12_VERTEX_BUFFER_VIEW{r.fx_buffer.GetGPUVirtualAddress() + u64((base + first * 6) * stride), u32(count * 6 * stride), u32(stride)}
    r.list.IASetVertexBuffers(0, 1, &view)
    r.list.DrawInstanced(u32(count * 6), 1, 0, 0)
}

priv fn draw_world(r: *Renderer, g: *Game, alpha: f32, cb: u64) {
    list := r.list
    t := f32(g.time)
    bind_scene(r, r.mesh_pso, cb)
    list.IASetVertexBuffers(0, 1, &r.vertex_view)
    m := r.meshes
    // the maze; fx.x is the glow of the torches' heads
    c := DrawConsts{model: mat4(1.0), tint: vec4(1.0), fx: vec4(2.5, 0.65, 0.0, 0.0)}
    draw(list, &c, m.maze)

    // gems: spinning, bobbing, lit from inside
    for i in 0..g.n_gems {
        gem := g.gems[i]
        if gem.taken && g.mode != Title {
            continue
        }
        c.model = translate(vec3(gem.pos.x, gem_height(t, i), gem.pos.y)) * rotate_y(t * 1.5 + f32(i)) * scale(vec3(1.15))
        c.tint = vec4(GEM_COLORS[i], 1.0)
        c.fx = vec4(0.7, 0.1, 0.0, 0.0)
        draw(list, &c, m.gem)
    }

    // wraiths: the robe, then two eyes, red while hunting, dull when stunned
    for i in 0..g.n_enemies {
        e := g.enemies[i]
        stunned := e.stun > 0.0
        body := wraith_frame(g, i, alpha)
        c.model = body
        // stunned, it turns a pale icy blue and dims
        c.tint = if stunned { vec4(0.3, 0.42, 0.9, 1.0) } else { vec4(0.16, 0.28, 1.0, 1.0) }
        c.fx = vec4(if stunned { 0.65 } else { 1.0 }, 0.9, 0.0, f32(i) * 2.3)
        draw(list, &c, m.wraith)
        c.tint = if stunned { vec4(0.3, 0.3, 0.45, 1.0) } else { vec4(1.0, 0.05, 0.02, 1.0) }
        c.fx = vec4(if stunned { 0.5 } else { 1.2 }, 0.5, 0.0, 0.0)
        for eye in WRAITH_EYES {
            c.model = body * translate(eye)
            draw(list, &c, m.eye)
        }
    }
}

// One post-processing pass into bloom target `dst` (or, dst < 0, into the frame's target,
// already bound) reading the descriptors from `src_slot` on.
priv fn post(r: *Renderer, pso: *ID3D12PipelineState, src_slot: i64, dst: i64, w: i64, h: i64, k: PostConsts) {
    list := r.list
    if dst >= 0 {
        dx_barrier(list, r.bloom[dst], D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET)
        target := rtv(r, RTV_BLOOM + dst)
        list.OMSetRenderTargets(1, &target, 0, nil)
    }
    viewport := D3D12_VIEWPORT{0.0, 0.0, f32(w), f32(h), 0.0, 1.0}
    scissor := D3D12_RECT{0, 0, i32(w), i32(h)}
    list.RSSetViewports(1, &viewport)
    list.RSSetScissorRects(1, &scissor)
    list.SetPipelineState(pso)
    list.SetGraphicsRootSignature(r.post_root)
    list.SetGraphicsRoot32BitConstants(0, POST_VALUES, cast[*u8](&k), 0)
    list.SetGraphicsRootDescriptorTable(1, srv_gpu(r, src_slot))
    list.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST)
    list.DrawInstanced(3, 1, 0, 0)
    if dst >= 0 {
        dx_barrier(list, r.bloom[dst], D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
    }
}

// Draws a frame of the game, `alpha` of the way from the last step to the next. With
// `capture`, the finished picture is read back (the call then waits for the GPU) and returned.
// The text is "" or what failed (the device was removed: the reason).
fn render_frame(r: *Renderer, g: *Game, alpha: f32, note: str, capture: bool) -> (Image, str) {
    shot: Image
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

    // the frame's constants: camera, lights, the map
    t := f32(g.time)
    eye, view := camera_view(g, alpha)
    proj := perspective(radians(70.0), f32(r.width) / f32(max(r.height, 1)), 0.05, 80.0)
    cam := inverse_affine(view)
    title := g.mode == Title
    lantern := lantern_frame(g, cam)
    lamp := if title { eye + vec3(0.0, 0.25, 0.0) } else { transform_point(lantern, vec3(0.0)) }
    flash := if g.flash > 0.0 { g.flash / FLASH_TIME } else { 0.0 }
    gather_lights(&r.lights, g, r.torches[..r.n_torches], lamp, flash, alpha)
    fc: FrameConsts
    fc.view_proj = proj * view
    fc.eye = vec4(eye, t)
    fc.fog = FOG
    fc.cam_right = vec4(vec3(cam[0]), 0.0)
    fc.cam_up = vec4(vec3(cam[1]), 0.0)
    fc.map_rows = r.map_rows
    fc.params = vec4(0.0, f32(pick_lights(&r.lights, eye, &fc.light_pos, &fc.light_color)), 0.0, 0.0)
    memcopy(&r.frame_mem[i * FRAME_CB], &fc, FRAME_SIZE)
    cb := r.frame_cb.GetGPUVirtualAddress() + u64(i * FRAME_CB)

    // the effects of the frame: the world's, then the lantern's (drawn after its mesh)
    fx := FxBatch{v: r.fx_mem, base: i * FX_QUADS * 6, capacity: FX_QUADS, eye: eye, right: vec3(cam[0]), up: vec3(cam[1])}
    world_fx(&fx, g, r.torches[..r.n_torches], lamp, alpha)
    world_quads := fx.count
    if !title {
        f := flicker(t * 0.7, 9.0)
        fx_billboard(&fx, lamp, 0.16, FX_GLOW, vec4(vec3(1.0, 0.5, 0.18) * (0.45 * f), 0.0))
        if flash > 0.0 {
            fx_billboard(&fx, lamp, 1.2, FX_GLOW, vec4(vec3(0.8, 0.9, 1.0) * (4.0 * flash), 0.0))
        }
    }

    // 1. the scene
    scene_target := if r.samples > 1 { r.scene_msaa } else { r.scene }
    if r.samples == 1 {
        dx_barrier(list, r.scene, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET)
    }
    srtv := rtv(r, RTV_SCENE)
    dsv := gpu_cpu_handle(&r.g, r.dsv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 0)
    list.OMSetRenderTargets(1, &srtv, 0, &dsv)
    fog := [4]f32{FOG.x, FOG.y, FOG.z, 1.0}
    list.ClearRenderTargetView(srtv, ptr(fog), 0, nil)
    list.ClearDepthStencilView(dsv, D3D12_CLEAR_FLAG_DEPTH, 1.0, 0, 0, nil)
    viewport := D3D12_VIEWPORT{0.0, 0.0, f32(r.scene_w), f32(r.scene_h), 0.0, 1.0}
    scissor := D3D12_RECT{0, 0, i32(r.scene_w), i32(r.scene_h)}
    list.RSSetViewports(1, &viewport)
    list.RSSetScissorRects(1, &scissor)
    draw_world(r, g, alpha, cb)
    draw_fx(r, cb, fx.base, 0, world_quads)
    if !title {
        // the lantern in the hand, over everything: its own depth
        list.ClearDepthStencilView(dsv, D3D12_CLEAR_FLAG_DEPTH, 1.0, 0, 0, nil)
        bind_scene(r, r.mesh_pso, cb)
        list.IASetVertexBuffers(0, 1, &r.vertex_view)
        c := DrawConsts{model: lantern, tint: vec4(1.0), fx: vec4(1.4 * flicker(t * 0.7, 9.0) * (1.0 + 3.0 * flash), 0.5, 1.0, 0.0)}
        draw(list, &c, r.meshes.lantern)
        draw_fx(r, cb, fx.base, world_quads, fx.count - world_quads)
    }

    // 2. resolve the samples with our own pass, weighting each sample by 1 / (1 + brightness):
    // a plain average of HDR samples lets a bright one dominate the pixel, and the edge comes
    // out as stair steps again after tone mapping
    if r.samples > 1 {
        dx_barrier(list, scene_target, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
        dx_barrier(list, r.scene, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET)
        rrtv := rtv(r, RTV_RESOLVED)
        list.OMSetRenderTargets(1, &rrtv, 0, nil)
        post(r, r.resolve_pso, SRV_MSAA, -1, r.scene_w, r.scene_h, PostConsts{vec4(f32(r.samples), 0.0, 0.0, 0.0), vec4(0.0), vec4(0.0)})
        dx_barrier(list, scene_target, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET)
        dx_barrier(list, r.scene, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
    } else {
        dx_barrier(list, r.scene, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
    }

    // 3. bloom: bright pass to half size (A), blur across (B) and down (A), a quarter (C),
    // blur across (D) and down (C)
    hw := max(r.scene_w / 2, 1)
    hh := max(r.scene_h / 2, 1)
    qw := max(r.scene_w / 4, 1)
    qh := max(r.scene_h / 4, 1)
    full := vec2(1.0 / f32(r.scene_w), 1.0 / f32(r.scene_h))
    half := vec2(1.0 / f32(hw), 1.0 / f32(hh))
    quarter := vec2(1.0 / f32(qw), 1.0 / f32(qh))
    post(r, r.bright_pso, SRV_SCENE, 0, hw, hh, PostConsts{vec4(full, 0.0, 0.0), vec4(1.0, 0.0, 0.0, 0.0), vec4(0.0)})
    post(r, r.blur_pso, BLOOM_SRV[0], 1, hw, hh, PostConsts{vec4(half, 1.0, 0.0), vec4(0.0), vec4(0.0)})
    post(r, r.blur_pso, BLOOM_SRV[1], 0, hw, hh, PostConsts{vec4(half, 0.0, 1.0), vec4(0.0), vec4(0.0)})
    post(r, r.down_pso, BLOOM_SRV[0], 2, qw, qh, PostConsts{vec4(half, 0.0, 0.0), vec4(0.0), vec4(0.0)})
    post(r, r.blur_pso, BLOOM_SRV[2], 3, qw, qh, PostConsts{vec4(quarter, 1.0, 0.0), vec4(0.0), vec4(0.0)})
    post(r, r.blur_pso, BLOOM_SRV[3], 2, qw, qh, PostConsts{vec4(quarter, 0.0, 1.0), vec4(0.0), vec4(0.0)})

    // 4. the picture tone mapped (into ldr), then FXAA and grain into the frame's target: FXAA
    // smooths what MSAA cannot (shading edges, the WARP path without MSAA)
    dx_barrier(list, r.ldr, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET)
    lrtv := rtv(r, RTV_LDR)
    list.OMSetRenderTargets(1, &lrtv, 0, nil)
    desat: f32 = match g.mode { Paused => 0.65; Lost => 0.6; Won => 0.25; _ => 0.0 }
    hurt := clamp(g.hurt / 1.5, 0.0, 1.0)
    if g.mode == Lost {
        hurt += 0.5
    }
    post(r, r.composite_pso, SRV_SCENE, -1, r.width, r.height,
        PostConsts{vec4(t, 0.0, 0.0, 0.0), vec4(0.55, 2.0, 0.55, 0.0), vec4(desat, hurt, flash, 0.0)})
    dx_barrier(list, r.ldr, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
    target := r.targets[i]
    dx_barrier(list, target, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET)
    trtv := rtv(r, i)
    list.OMSetRenderTargets(1, &trtv, 0, nil)
    post(r, r.fxaa_pso, SRV_LDR, -1, r.width, r.height,
        PostConsts{vec4(1.0 / f32(r.width), 1.0 / f32(r.height), t, r.grain), vec4(0.0), vec4(0.0)})

    // 5. the HUD over it
    hud_w := f32(HUD_H) * f32(r.width) / f32(max(r.height, 1))
    u := &r.ui
    u.ui_begin(i, hud_w, f32(HUD_H), f32(r.height))
    draw_hud(u, g, hud_w, note)
    u.ui_draw(list, srv_gpu(r, SRV_UI))

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
    debug_messages(r)
    if capture {
        gpu_wait(&r.g, r.done[i])
        removed := gpu_removed(&r.g)
        if removed != "" {
            return (shot, removed)
        }
        shot = readback_image(&rb)
    }
    (shot, "")
}
