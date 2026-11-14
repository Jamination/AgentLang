// Direct3D 12 set-up code shared by the DX12 examples, on top of std.dx12 (Windows only): a
// device with its queue and fence (hardware adapter, else WARP), fence waits, device removal
// text, HLSL compilation with the compiler's messages, buffers, textures, barriers, and a sprite
// batcher for 2D games. Example code to read, copy and change: not part of the standard library.
use std.dx12

// ---- device ----------------------------------------------------------------------------------

// A device with one direct command queue and a fence to wait for it.
struct Gpu {
    factory: *IDXGIFactory4
    adapter: *IDXGIAdapter1
    device: *ID3D12Device
    queue: *ID3D12CommandQueue
    fence: *ID3D12Fence
    fence_event: *u8
    fence_value: u64      // the last value signalled on the queue
    warp: bool            // the device is WARP, the software rasterizer of Windows
    adapter_name: str
}

// Stops the program with the HRESULT and its name if `hr` is a failure code.
fn dx_check(hr: i32, what: str) {
    if FAILED(hr) {
        panic(hresult_text(what, hr))
    }
}

// UTF-8 of a NUL-terminated UTF-16 array (adapter names); characters outside ASCII become '?'.
priv fn ascii_of(w: []u16) -> str {
    out := vec[u8]()
    for c in w {
        if c == 0 { break }
        out.push(if c < 0x80 { u8(c) } else { '?' })
    }
    out.items()
}

// Opens a device: the first hardware adapter that supports feature level 11.0, else WARP
// (`warp_only` goes straight to WARP). `debug` turns on the debug layer if it is installed.
// The result has a direct queue and a fence; the text is "" on success, else what failed.
fn gpu_open(debug: bool, warp_only: bool) -> (Gpu, str) {
    g: Gpu
    flags: u32
    if debug {
        layer: *ID3D12Debug
        if SUCCEEDED(D3D12GetDebugInterface(&IID_ID3D12Debug, ppv(&layer))) {
            layer.EnableDebugLayer()
            flags = DXGI_CREATE_FACTORY_DEBUG
            com_release(&layer)
        }
    }
    hr := CreateDXGIFactory2(flags, &IID_IDXGIFactory4, ppv(&g.factory))
    if FAILED(hr) && flags != 0 {
        hr = CreateDXGIFactory2(0, &IID_IDXGIFactory4, ppv(&g.factory))
    }
    if FAILED(hr) { return (g, hresult_text("CreateDXGIFactory2", hr)) }
    desc: DXGI_ADAPTER_DESC1
    index: u32
    while !warp_only {
        adapter: *IDXGIAdapter1
        if FAILED(g.factory.EnumAdapters1(index, &adapter)) { break }
        index += 1
        adapter.GetDesc1(&desc)
        if desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE == 0 &&
            SUCCEEDED(D3D12CreateDevice(cast[*IUnknown](adapter), D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, ppv(&g.device))) {
            g.adapter = adapter
            break
        }
        com_release(&adapter)
    }
    if g.device == nil {
        hr = g.factory.EnumWarpAdapter(&IID_IDXGIAdapter1, &g.adapter)
        if FAILED(hr) {
            gpu_close(&g)
            return (g, hresult_text("EnumWarpAdapter", hr))
        }
        hr = D3D12CreateDevice(cast[*IUnknown](g.adapter), D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, ppv(&g.device))
        if FAILED(hr) {
            gpu_close(&g)
            return (g, hresult_text("D3D12CreateDevice (WARP)", hr))
        }
        g.adapter.GetDesc1(&desc)
        g.warp = true
    }
    g.adapter_name = ascii_of(desc.Description[..])
    queue_desc := D3D12_COMMAND_QUEUE_DESC{Type: D3D12_COMMAND_LIST_TYPE_DIRECT}
    hr = g.device.CreateCommandQueue(&queue_desc, &IID_ID3D12CommandQueue, &g.queue)
    if SUCCEEDED(hr) {
        hr = g.device.CreateFence(0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, &g.fence)
    }
    if FAILED(hr) {
        gpu_close(&g)
        return (g, hresult_text("CreateCommandQueue / CreateFence", hr))
    }
    g.fence_event = CreateEventW(nil, 0, 0, nil)
    if g.fence_event == nil {
        gpu_close(&g)
        return (g, fmt("CreateEventW failed: error ", GetLastError()))
    }
    (g, "")
}

// Like dx_check, and if the device has been removed the message also gives the reason.
fn gpu_check(g: *Gpu, hr: i32, what: str) {
    if hr < 0 {
        removed := if g.device != nil { gpu_removed(g) } else { "" }
        panic(if removed == "" { hresult_text(what, hr) } else { fmt(hresult_text(what, hr), "; ", removed) })
    }
}

// Signals the next fence value on the queue (after the work submitted so far) and returns it.
fn gpu_signal(g: *Gpu) -> u64 {
    g.fence_value += 1
    gpu_check(g, g.queue.Signal(g.fence, g.fence_value), "ID3D12CommandQueue::Signal")
    g.fence_value
}

// Blocks until the GPU has passed fence value `value`. Returns at once if the device was removed
// (its fence then reads as all ones): check gpu_removed.
fn gpu_wait(g: *Gpu, value: u64) {
    if g.fence.GetCompletedValue() < value {
        gpu_check(g, g.fence.SetEventOnCompletion(value, g.fence_event), "ID3D12Fence::SetEventOnCompletion")
        WaitForSingleObject(g.fence_event, INFINITE)
    }
}

// Blocks until the GPU has finished everything submitted so far.
fn gpu_flush(g: *Gpu) { g.gpu_wait(g.gpu_signal()) }

// "" while the device works; once it has been removed (driver crash or update, GPU hang, TDR,
// unplugged), the reason from GetDeviceRemovedReason as text.
fn gpu_removed(g: *Gpu) -> str {
    hr := g.device.GetDeviceRemovedReason()
    if hr == S_OK { "" } else { fmt("the device was removed, reason: HRESULT ", hresult_code(hr)) }
}

// Closes a recorded command list and submits it to the queue.
fn gpu_execute(g: *Gpu, list: *ID3D12GraphicsCommandList) {
    gpu_check(g, list.Close(), "ID3D12GraphicsCommandList::Close")
    lists := [1]*ID3D12CommandList{cast[*ID3D12CommandList](list)}
    g.queue.ExecuteCommandLists(1, ptr(lists))
}

// A command allocator and a closed command list on it, for the direct queue.
fn gpu_command_list(g: *Gpu) -> (*ID3D12CommandAllocator, *ID3D12GraphicsCommandList) {
    allocator: *ID3D12CommandAllocator
    list: *ID3D12GraphicsCommandList
    gpu_check(g, g.device.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, &allocator), "CreateCommandAllocator")
    gpu_check(g, g.device.CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, nil, &IID_ID3D12GraphicsCommandList, &list), "CreateCommandList")
    dx_check(list.Close(), "ID3D12GraphicsCommandList::Close")
    (allocator, list)
}

// Resets an allocator and its list for recording (the GPU must be done with what they held).
fn gpu_reset(allocator: *ID3D12CommandAllocator, list: *ID3D12GraphicsCommandList) {
    dx_check(allocator.Reset(), "ID3D12CommandAllocator::Reset")
    dx_check(list.Reset(allocator, nil), "ID3D12GraphicsCommandList::Reset")
}

// Waits for the GPU, then releases everything gpu_open made. Safe on a half-opened Gpu.
fn gpu_close(g: *Gpu) {
    if g.queue != nil && g.fence != nil && g.fence_event != nil { g.gpu_flush() }
    if g.fence_event != nil {
        CloseHandle(g.fence_event)
        g.fence_event = nil
    }
    com_release(&g.fence)
    com_release(&g.queue)
    com_release(&g.device)
    com_release(&g.adapter)
    com_release(&g.factory)
}

// ---- shaders and root signatures -------------------------------------------------------------

// Compiles one entry point of HLSL source (`target` "vs_5_0", "ps_5_0", ...). On failure the
// blob is nil and the text holds the compiler's messages.
fn dx_compile(source: str, entry: str, target: str) -> (*ID3DBlob, str) {
    code: *ID3DBlob
    errors: *ID3DBlob
    hr := D3DCompile(ptr(source), u64(len(source)), ptr("shader.hlsl"), nil, nil, cstr(entry), cstr(target),
        D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errors)
    text := ""
    if FAILED(hr) {
        text = if errors != nil { clone(trim_right(blob_bytes(errors), "\0\r\n")) } else { hresult_text("D3DCompile", hr) }
        com_release(&code)
    }
    com_release(&errors)
    (code, text)
}

// The bytecode of a compiled blob, for a pipeline description.
fn dx_bytecode(blob: *ID3DBlob) -> D3D12_SHADER_BYTECODE {
    if blob == nil { D3D12_SHADER_BYTECODE{} } else { D3D12_SHADER_BYTECODE{blob.GetBufferPointer(), blob.GetBufferSize()} }
}

// Serializes and creates a root signature (version 1.0). On failure: nil and the messages.
fn dx_root_signature(g: *Gpu, desc: *D3D12_ROOT_SIGNATURE_DESC) -> (*ID3D12RootSignature, str) {
    blob: *ID3DBlob
    errors: *ID3DBlob
    root: *ID3D12RootSignature
    hr := D3D12SerializeRootSignature(desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors)
    text := ""
    if FAILED(hr) {
        text = if errors != nil { clone(trim_right(blob_bytes(errors), "\0\r\n")) } else { hresult_text("D3D12SerializeRootSignature", hr) }
    } else {
        hr = g.device.CreateRootSignature(0, blob.GetBufferPointer(), blob.GetBufferSize(), &IID_ID3D12RootSignature, &root)
        if FAILED(hr) { text = hresult_text("CreateRootSignature", hr) }
    }
    com_release(&blob)
    com_release(&errors)
    (root, text)
}

// A pipeline description with the usual defaults: solid fill, no culling, depth off, blending
// off, all colour channels written, triangles, one render target of `format`, no multisampling.
fn dx_pipeline_desc(root: *ID3D12RootSignature, vs: *ID3DBlob, ps: *ID3DBlob, format: i32) -> D3D12_GRAPHICS_PIPELINE_STATE_DESC {
    desc: D3D12_GRAPHICS_PIPELINE_STATE_DESC
    desc.pRootSignature = root
    desc.VS = dx_bytecode(vs)
    desc.PS = dx_bytecode(ps)
    desc.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID
    desc.RasterizerState.CullMode = D3D12_CULL_MODE_NONE
    desc.RasterizerState.DepthClipEnable = 1
    for i in 0..8 {
        desc.BlendState.RenderTarget[i].SrcBlend = D3D12_BLEND_ONE
        desc.BlendState.RenderTarget[i].DestBlend = D3D12_BLEND_ZERO
        desc.BlendState.RenderTarget[i].BlendOp = D3D12_BLEND_OP_ADD
        desc.BlendState.RenderTarget[i].SrcBlendAlpha = D3D12_BLEND_ONE
        desc.BlendState.RenderTarget[i].DestBlendAlpha = D3D12_BLEND_ZERO
        desc.BlendState.RenderTarget[i].BlendOpAlpha = D3D12_BLEND_OP_ADD
        desc.BlendState.RenderTarget[i].LogicOp = D3D12_LOGIC_OP_NOOP
        desc.BlendState.RenderTarget[i].RenderTargetWriteMask = u8(D3D12_COLOR_WRITE_ENABLE_ALL)
    }
    desc.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS
    desc.SampleMask = 0xffffffff
    desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE
    desc.NumRenderTargets = 1
    desc.RTVFormats[0] = format
    desc.SampleDesc.Count = 1
    desc
}

// ---- resources -------------------------------------------------------------------------------

// A buffer of `size` bytes in a heap of type `heap` (D3D12_HEAP_TYPE_UPLOAD: CPU-writable,
// D3D12_HEAP_TYPE_READBACK: CPU-readable, D3D12_HEAP_TYPE_DEFAULT: GPU only), created in `state`.
fn gpu_buffer(g: *Gpu, heap: i32, size: i64, state: u32) -> *ID3D12Resource {
    props := D3D12_HEAP_PROPERTIES{Type: heap, CreationNodeMask: 1, VisibleNodeMask: 1}
    desc := D3D12_RESOURCE_DESC{
        Dimension: D3D12_RESOURCE_DIMENSION_BUFFER, Width: u64(size), Height: 1, DepthOrArraySize: 1, MipLevels: 1,
        SampleDesc: DXGI_SAMPLE_DESC{Count: 1}, Layout: D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
    }
    buffer: *ID3D12Resource
    gpu_check(g, g.device.CreateCommittedResource(&props, D3D12_HEAP_FLAG_NONE, &desc, state, nil, &IID_ID3D12Resource, &buffer), "CreateCommittedResource (buffer)")
    buffer
}

// An upload-heap buffer holding a copy of `data` (vertices, indices, constants).
fn gpu_upload(g: *Gpu, data: []u8) -> *ID3D12Resource {
    buffer := gpu_buffer(g, D3D12_HEAP_TYPE_UPLOAD, max(len(data), 1), D3D12_RESOURCE_STATE_GENERIC_READ)
    mapped: *u8
    none := D3D12_RANGE{0, 0}
    dx_check(buffer.Map(0, &none, &mapped), "ID3D12Resource::Map")
    memcopy(mapped, ptr(data), len(data))
    buffer.Unmap(0, nil)
    buffer
}

// A 2D texture in the default heap: `flags` D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET for a render
// target (then `clear` is its optimized clear colour, or nil), created in `state`.
fn gpu_texture(g: *Gpu, width: i64, height: i64, format: i32, flags: u32, state: u32, clear: *[4]f32) -> *ID3D12Resource {
    props := D3D12_HEAP_PROPERTIES{Type: D3D12_HEAP_TYPE_DEFAULT, CreationNodeMask: 1, VisibleNodeMask: 1}
    desc := D3D12_RESOURCE_DESC{
        Dimension: D3D12_RESOURCE_DIMENSION_TEXTURE2D, Width: u64(width), Height: u32(height), DepthOrArraySize: 1,
        MipLevels: 1, Format: format, SampleDesc: DXGI_SAMPLE_DESC{Count: 1}, Flags: flags,
    }
    value := D3D12_CLEAR_VALUE{Format: format}
    if clear != nil { *value.u_Color() = *clear }
    texture: *ID3D12Resource
    gpu_check(g, g.device.CreateCommittedResource(&props, D3D12_HEAP_FLAG_NONE, &desc, state, if clear != nil { &value } else { nil },
        &IID_ID3D12Resource, &texture), "CreateCommittedResource (texture)")
    texture
}

// A descriptor heap of `count` descriptors of `kind` (D3D12_DESCRIPTOR_HEAP_TYPE_RTV, ...).
fn gpu_descriptor_heap(g: *Gpu, kind: i32, count: i64, shader_visible: bool) -> *ID3D12DescriptorHeap {
    desc := D3D12_DESCRIPTOR_HEAP_DESC{Type: kind, NumDescriptors: u32(count),
        Flags: if shader_visible { D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE } else { D3D12_DESCRIPTOR_HEAP_FLAG_NONE }}
    heap: *ID3D12DescriptorHeap
    gpu_check(g, g.device.CreateDescriptorHeap(&desc, &IID_ID3D12DescriptorHeap, &heap), "CreateDescriptorHeap")
    heap
}

// The CPU handle of descriptor `index` of a heap of descriptors of `kind`.
fn gpu_cpu_handle(g: *Gpu, heap: *ID3D12DescriptorHeap, kind: i32, index: i64) -> D3D12_CPU_DESCRIPTOR_HANDLE {
    h := heap.GetCPUDescriptorHandleForHeapStart()
    h.ptr += u64(index) * u64(g.device.GetDescriptorHandleIncrementSize(kind))
    h
}

// Records a transition barrier of all subresources of `resource`.
fn dx_barrier(list: *ID3D12GraphicsCommandList, resource: *ID3D12Resource, before: u32, after: u32) {
    barrier := D3D12_RESOURCE_BARRIER{Type: D3D12_RESOURCE_BARRIER_TYPE_TRANSITION}
    t := barrier.u_Transition()
    t.pResource = resource
    t.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES
    t.StateBefore = before
    t.StateAfter = after
    list.ResourceBarrier(1, &barrier)
}

// ---- sprites ---------------------------------------------------------------------------------

// One corner of a sprite: position in pixels, texture coordinates, colour (RGBA8, red in the
// lowest byte: color_u32 of std.math).
struct SpriteVertex { pos: vec2, uv: vec2, color: u32 }

// A sprite batcher: textured, tinted, alpha-blended rectangles from one atlas texture, drawn in
// pixel coordinates (origin top left) with point sampling, one draw call per sprites_draw.
// Vertices go to a persistently mapped upload buffer with one region per frame in flight.
struct Sprites {
    root: *ID3D12RootSignature
    pipeline: *ID3D12PipelineState
    heap: *ID3D12DescriptorHeap   // shader-visible: the atlas view
    atlas: *ID3D12Resource
    atlas_size: vec2
    vertices: *ID3D12Resource
    mapped: []SpriteVertex        // the whole buffer, mapped
    capacity: i64                 // sprites per frame
    frames: i64
    base: i64                     // first vertex of the current frame's region
    count: i64                    // sprites added in this frame
    drawn: i64                    // of which already drawn
    scale: vec2                   // 2 / target size
}

priv const SPRITE_SHADER = `
cbuffer View : register(b0) { float2 scale; };
Texture2D atlas : register(t0);
SamplerState point_sampler : register(s0);
struct V { float4 pos : SV_POSITION; float2 uv : TEXCOORD; float4 color : COLOR; };
V vs_main(float2 pos : POSITION, float2 uv : TEXCOORD, float4 color : COLOR) {
    V o;
    o.pos = float4(pos.x * scale.x - 1.0, 1.0 - pos.y * scale.y, 0.0, 1.0);
    o.uv = uv;
    o.color = color;
    return o;
}
float4 ps_main(V i) : SV_TARGET {
    float4 t = atlas.Sample(point_sampler, i.uv);
    return (i.uv.x < 0.0 ? float4(1.0, 1.0, 1.0, 1.0) : t) * i.color;
}
`

// Makes a batcher for render targets of `format`: up to `capacity` sprites per frame, `frames`
// frames in flight, and the atlas: `width` x `height` RGBA8 pixels (`rgba`, rows packed; red
// first). The atlas is uploaded before it returns. "" or what failed.
fn sprites_new(g: *Gpu, format: i32, capacity: i64, frames: i64, width: i64, height: i64, rgba: []u8) -> (Sprites, str) {
    assert capacity > 0 && frames > 0 && width > 0 && height > 0 && len(rgba) >= width * height * 4, "sprites_new: bad arguments"
    s: Sprites
    s.capacity = capacity
    s.frames = frames
    s.atlas_size = vec2(f32(width), f32(height))

    // root signature: the view scale (b0, vertex shader), the atlas (t0), a point sampler (s0)
    params: [2]D3D12_ROOT_PARAMETER
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS
    params[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX
    params[0].u_Constants().Num32BitValues = 2
    range := D3D12_DESCRIPTOR_RANGE{RangeType: D3D12_DESCRIPTOR_RANGE_TYPE_SRV, NumDescriptors: 1}
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE
    params[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL
    params[1].u_DescriptorTable().NumDescriptorRanges = 1
    params[1].u_DescriptorTable().pDescriptorRanges = &range
    sampler := D3D12_STATIC_SAMPLER_DESC{
        Filter: D3D12_FILTER_MIN_MAG_MIP_POINT, AddressU: D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        AddressV: D3D12_TEXTURE_ADDRESS_MODE_CLAMP, AddressW: D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        ComparisonFunc: D3D12_COMPARISON_FUNC_NEVER, MaxLOD: 3.4e38, ShaderVisibility: D3D12_SHADER_VISIBILITY_PIXEL,
    }
    root_desc := D3D12_ROOT_SIGNATURE_DESC{NumParameters: 2, pParameters: ptr(params), NumStaticSamplers: 1,
        pStaticSamplers: &sampler, Flags: D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT}
    root, err := dx_root_signature(g, &root_desc)
    if err != "" { return (s, err) }
    s.root = root

    vs, verr := dx_compile(SPRITE_SHADER, "vs_main", "vs_5_0")
    if verr != "" { return (s, verr) }
    ps, perr := dx_compile(SPRITE_SHADER, "ps_main", "ps_5_0")
    if perr != "" {
        com_release(&vs)
        return (s, perr)
    }
    layout := [3]D3D12_INPUT_ELEMENT_DESC{
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("POSITION"), Format: DXGI_FORMAT_R32G32_FLOAT, AlignedByteOffset: 0},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("TEXCOORD"), Format: DXGI_FORMAT_R32G32_FLOAT, AlignedByteOffset: 8},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("COLOR"), Format: DXGI_FORMAT_R8G8B8A8_UNORM, AlignedByteOffset: 16},
    }
    desc := dx_pipeline_desc(s.root, vs, ps, format)
    desc.InputLayout = D3D12_INPUT_LAYOUT_DESC{ptr(layout), 3}
    blend := &desc.BlendState.RenderTarget[0]
    blend.BlendEnable = 1
    blend.SrcBlend = D3D12_BLEND_SRC_ALPHA
    blend.DestBlend = D3D12_BLEND_INV_SRC_ALPHA
    blend.SrcBlendAlpha = D3D12_BLEND_ONE
    blend.DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA
    hr := g.device.CreateGraphicsPipelineState(&desc, &IID_ID3D12PipelineState, &s.pipeline)
    com_release(&vs)
    com_release(&ps)
    if FAILED(hr) { return (s, hresult_text("CreateGraphicsPipelineState (sprites)", hr)) }

    // the atlas: copied through an upload buffer laid out as the copy engine wants it
    s.atlas = gpu_texture(g, width, height, DXGI_FORMAT_R8G8B8A8_UNORM, D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST, nil)
    tex_desc := s.atlas.GetDesc()
    footprint: D3D12_PLACED_SUBRESOURCE_FOOTPRINT
    total: u64
    g.device.GetCopyableFootprints(&tex_desc, 0, 1, 0, &footprint, nil, nil, &total)
    staging := gpu_buffer(g, D3D12_HEAP_TYPE_UPLOAD, i64(total), D3D12_RESOURCE_STATE_GENERIC_READ)
    mapped: *u8
    none := D3D12_RANGE{0, 0}
    dx_check(staging.Map(0, &none, &mapped), "ID3D12Resource::Map (atlas)")
    pitch := i64(footprint.Footprint.RowPitch)
    for y in 0..height {
        memcopy(cast[*u8](cast[i64](mapped) + y * pitch), &rgba[y * width * 4], width * 4)
    }
    staging.Unmap(0, nil)
    allocator, list := gpu_command_list(g)
    gpu_reset(allocator, list)
    dst := D3D12_TEXTURE_COPY_LOCATION{pResource: s.atlas, Type: D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}
    src := D3D12_TEXTURE_COPY_LOCATION{pResource: staging, Type: D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT}
    *src.u_PlacedFootprint() = footprint
    list.CopyTextureRegion(&dst, 0, 0, 0, &src, nil)
    dx_barrier(list, s.atlas, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
    gpu_execute(g, list)
    gpu_flush(g)
    com_release(&list)
    com_release(&allocator)
    com_release(&staging)

    s.heap = gpu_descriptor_heap(g, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 1, true)
    view := D3D12_SHADER_RESOURCE_VIEW_DESC{Format: DXGI_FORMAT_R8G8B8A8_UNORM, ViewDimension: D3D12_SRV_DIMENSION_TEXTURE2D,
        Shader4ComponentMapping: D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING}
    view.u_Texture2D().MipLevels = 1
    g.device.CreateShaderResourceView(s.atlas, &view, s.heap.GetCPUDescriptorHandleForHeapStart())

    s.vertices = gpu_buffer(g, D3D12_HEAP_TYPE_UPLOAD, frames * capacity * 6 * sizeof[SpriteVertex](), D3D12_RESOURCE_STATE_GENERIC_READ)
    vmapped: *u8
    dx_check(s.vertices.Map(0, &none, &vmapped), "ID3D12Resource::Map (sprite vertices)")
    s.mapped = mkslice[SpriteVertex](cast[*SpriteVertex](vmapped), frames * capacity * 6)
    (s, "")
}

// Starts the sprites of frame `frame` (0 .. frames-1; the GPU must be done with the frame that
// last used this number) for a render target of `width` x `height` pixels.
fn sprites_begin(s: *Sprites, frame: i64, width: i64, height: i64) {
    assert frame >= 0 && frame < s.frames, "sprites_begin: frame out of range"
    s.base = frame * s.capacity * 6
    s.count = 0
    s.drawn = 0
    s.scale = vec2(2.0 / f32(width), 2.0 / f32(height))
}

// Adds a sprite: the atlas rectangle (sx, sy, sw, sh) in atlas pixels drawn at (x, y) with size
// (w, h) in target pixels, tinted by `color` (0xffffffff: as it is). A negative sw or sh mirrors.
// Sprites beyond the capacity are dropped.
fn sprite(s: *Sprites, x: f32, y: f32, w: f32, h: f32, sx: f32, sy: f32, sw: f32, sh: f32, color: u32) {
    uv0 := vec2(sx, sy) / s.atlas_size
    uv1 := vec2(sx + sw, sy + sh) / s.atlas_size
    s.quad(x, y, w, h, uv0, uv1, color)
}

// Adds a rectangle of one colour (alpha-blended by its alpha).
fn sprite_rect(s: *Sprites, x: f32, y: f32, w: f32, h: f32, color: u32) {
    s.quad(x, y, w, h, vec2(-1.0), vec2(-1.0), color)
}

priv fn quad(s: *Sprites, x: f32, y: f32, w: f32, h: f32, uv0: vec2, uv1: vec2, color: u32) {
    if s.count >= s.capacity {
        return
    }
    v := s.mapped
    i := s.base + s.count * 6
    a := SpriteVertex{vec2(x, y), uv0, color}
    b := SpriteVertex{vec2(x + w, y), vec2(uv1.x, uv0.y), color}
    c := SpriteVertex{vec2(x, y + h), vec2(uv0.x, uv1.y), color}
    d := SpriteVertex{vec2(x + w, y + h), uv1, color}
    v[i] = a
    v[i + 1] = b
    v[i + 2] = c
    v[i + 3] = c
    v[i + 4] = b
    v[i + 5] = d
    s.count += 1
}

// Records the sprites added since the last sprites_draw of this frame (one draw call), over
// whatever the list renders to. Sets the pipeline, root signature, descriptor heap, topology
// and vertex buffer of the list.
fn sprites_draw(s: *Sprites, list: *ID3D12GraphicsCommandList) {
    n := min(s.count, s.capacity) - s.drawn
    if n <= 0 { return }
    list.SetPipelineState(s.pipeline)
    list.SetGraphicsRootSignature(s.root)
    heaps := [1]*ID3D12DescriptorHeap{s.heap}
    list.SetDescriptorHeaps(1, ptr(heaps))
    scale := [2]f32{s.scale.x, s.scale.y}
    list.SetGraphicsRoot32BitConstants(0, 2, cast[*u8](ptr(scale)), 0)
    list.SetGraphicsRootDescriptorTable(1, s.heap.GetGPUDescriptorHandleForHeapStart())
    list.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST)
    stride := sizeof[SpriteVertex]()
    view := D3D12_VERTEX_BUFFER_VIEW{s.vertices.GetGPUVirtualAddress() + u64((s.base + s.drawn * 6) * stride),
        u32(n * 6 * stride), u32(stride)}
    list.IASetVertexBuffers(0, 1, &view)
    list.DrawInstanced(u32(n * 6), 1, 0, 0)
    s.drawn += n
}

// Releases the batcher's objects (the GPU must be done with them).
fn sprites_free(s: *Sprites) {
    if s.vertices != nil && len(s.mapped) > 0 {
        s.vertices.Unmap(0, nil)
        s.mapped = nil
    }
    com_release(&s.vertices)
    com_release(&s.heap)
    com_release(&s.atlas)
    com_release(&s.pipeline)
    com_release(&s.root)
}
