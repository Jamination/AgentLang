// std.gfx on Direct3D 12 (Windows): the backend `use std.gfx` picks on Windows. Derived from
// examples/gamekit (dx12_gpu.al, screen.al). One direct queue, two frames in flight, a
// flip-model swap chain on the std.window window (or, for gfx_offscreen, a render texture as
// the screen), one root signature (view constants, texture table, sampler table) and two
// pipeline states (alpha, additive). The shaders are DXBC compiled ahead of time
// (std/gfx_shaders.al), so d3dcompiler_47.dll is not needed.
use std.gfx_core
use std.gfx_shaders
use std.window
use std.image
use std.dx12

priv const FRAMES = 2
priv const FORMAT = DXGI_FORMAT_R8G8B8A8_UNORM
// SRV component mapping (1, 1, 1, red) for coverage textures: D3D12_ENCODE_SHADER_4_COMPONENT_MAPPING
// of FORCE_VALUE_1 (5) three times and component 0
priv const COVERAGE_MAPPING: u32 = 5 | 5 << 3 | 5 << 6 | 0 << 9 | 1 << 12

priv struct Dx {
    factory: *IDXGIFactory4
    adapter: *IDXGIAdapter1
    device: *ID3D12Device
    queue: *ID3D12CommandQueue
    fence: *ID3D12Fence
    fence_event: *u8
    fence_value: u64
    win: *Window
    swap: *IDXGISwapChain3          // nil offscreen
    backs: [FRAMES]*ID3D12Resource
    screen_tex: i64                 // offscreen: the texture that is the screen
    rtv_heap: *ID3D12DescriptorHeap // [0, FRAMES): back buffers; FRAMES + id: render textures
    srv_heap: *ID3D12DescriptorHeap // id: textures (shader visible)
    sampler_heap: *ID3D12DescriptorHeap   // 0 nearest, 1 linear (shader visible)
    rtv_inc: u64
    srv_inc: u64
    sampler_inc: u64
    root: *ID3D12RootSignature
    pipelines: [2]*ID3D12PipelineState   // by Blend
    allocators: [FRAMES]*ID3D12CommandAllocator
    list: *ID3D12GraphicsCommandList
    done: [FRAMES]u64               // the fence value that ends the last frame of each slot
    frame: i64                      // the slot of the frame being recorded
    vbuf: *ID3D12Resource
    mapped: []GfxVertex             // FRAMES regions of max_vertices
    max_vertices: i64
    texs: []*ID3D12Resource         // by texture id
    upload_allocator: *ID3D12CommandAllocator
    upload_list: *ID3D12GraphicsCommandList
    staging: *ID3D12Resource
    staging_size: i64
}

priv fn dx(g: *Gfx) -> *Dx { cast[*Dx](g.os) }

// "" while the device works, else the removal reason.
priv fn removed(d: *Dx) -> str {
    hr := d.device.GetDeviceRemovedReason()
    if hr == S_OK { "" } else { fmt("the Direct3D 12 device was removed, reason: HRESULT ", hresult_code(hr)) }
}

// Stops the program on a failed call that only fails in a broken program; a removed device is
// named in the message.
priv fn check(d: *Dx, hr: i32, what: str) {
    if FAILED(hr) {
        r := if d.device != nil { removed(d) } else { "" }
        panic(if r == "" { concat("gfx: ", hresult_text(what, hr)) } else { fmt("gfx: ", hresult_text(what, hr), "; ", r) })
    }
}

priv fn signal(d: *Dx) -> u64 {
    d.fence_value += 1
    check(d, d.queue.Signal(d.fence, d.fence_value), "ID3D12CommandQueue::Signal")
    d.fence_value
}

// Waits until the GPU has passed `value` (returns at once on a removed device: its fence reads all ones).
priv fn wait(d: *Dx, value: u64) {
    if d.fence.GetCompletedValue() < value {
        check(d, d.fence.SetEventOnCompletion(value, d.fence_event), "ID3D12Fence::SetEventOnCompletion")
        WaitForSingleObject(d.fence_event, INFINITE)
    }
}

priv fn flush(d: *Dx) { wait(d, signal(d)) }

priv fn ascii_of(w: []u16) -> str {
    out := vec[u8]()
    for c in w {
        if c == 0 { break }
        out.push(if c < 0x80 { u8(c) } else { '?' })
    }
    out.items()
}

priv fn heap(d: *Dx, kind: i32, count: i64, visible: bool) -> *ID3D12DescriptorHeap {
    desc := D3D12_DESCRIPTOR_HEAP_DESC{Type: kind, NumDescriptors: u32(count),
        Flags: if visible { D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE } else { D3D12_DESCRIPTOR_HEAP_FLAG_NONE }}
    h: *ID3D12DescriptorHeap
    check(d, d.device.CreateDescriptorHeap(&desc, &IID_ID3D12DescriptorHeap, &h), "CreateDescriptorHeap")
    h
}

priv fn cpu(h: *ID3D12DescriptorHeap, inc: u64, i: i64) -> D3D12_CPU_DESCRIPTOR_HANDLE {
    c := h.GetCPUDescriptorHandleForHeapStart()
    c.ptr += u64(i) * inc
    c
}

priv fn gpu(h: *ID3D12DescriptorHeap, inc: u64, i: i64) -> D3D12_GPU_DESCRIPTOR_HANDLE {
    c := h.GetGPUDescriptorHandleForHeapStart()
    c.ptr += u64(i) * inc
    c
}

priv fn barrier(list: *ID3D12GraphicsCommandList, r: *ID3D12Resource, before: u32, after: u32) {
    b := D3D12_RESOURCE_BARRIER{Type: D3D12_RESOURCE_BARRIER_TYPE_TRANSITION}
    t := b.u_Transition()
    t.pResource = r
    t.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES
    t.StateBefore = before
    t.StateAfter = after
    list.ResourceBarrier(1, &b)
}

priv fn buffer(d: *Dx, kind: i32, size: i64, state: u32) -> *ID3D12Resource {
    props := D3D12_HEAP_PROPERTIES{Type: kind, CreationNodeMask: 1, VisibleNodeMask: 1}
    desc := D3D12_RESOURCE_DESC{
        Dimension: D3D12_RESOURCE_DIMENSION_BUFFER, Width: u64(size), Height: 1, DepthOrArraySize: 1, MipLevels: 1,
        SampleDesc: DXGI_SAMPLE_DESC{Count: 1}, Layout: D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
    }
    b: *ID3D12Resource
    check(d, d.device.CreateCommittedResource(&props, D3D12_HEAP_FLAG_NONE, &desc, state, nil, &IID_ID3D12Resource, &b), "CreateCommittedResource (buffer)")
    b
}

// ---- device ----------------------------------------------------------------------------------

// The device, queue, fence, heaps, root signature, pipelines and vertex buffer. "" or what failed.
priv fn open_device(g: *Gfx, d: *Dx, desc: GfxDesc) -> str {
    flags: u32
    if desc.debug {
        layer: *ID3D12Debug
        if SUCCEEDED(D3D12GetDebugInterface(&IID_ID3D12Debug, ppv(&layer))) {
            layer.EnableDebugLayer()
            flags = DXGI_CREATE_FACTORY_DEBUG
            com_release(&layer)
        }
    }
    hr := CreateDXGIFactory2(flags, &IID_IDXGIFactory4, ppv(&d.factory))
    if FAILED(hr) && flags != 0 { hr = CreateDXGIFactory2(0, &IID_IDXGIFactory4, ppv(&d.factory)) }
    if FAILED(hr) { return hresult_text("CreateDXGIFactory2", hr) }
    adesc: DXGI_ADAPTER_DESC1
    index: u32
    while !desc.software {
        adapter: *IDXGIAdapter1
        if FAILED(d.factory.EnumAdapters1(index, &adapter)) { break }
        index += 1
        adapter.GetDesc1(&adesc)
        if adesc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE == 0 &&
            SUCCEEDED(D3D12CreateDevice(cast[*IUnknown](adapter), D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, ppv(&d.device))) {
            d.adapter = adapter
            break
        }
        com_release(&adapter)
    }
    warp := false
    if d.device == nil {
        hr = d.factory.EnumWarpAdapter(&IID_IDXGIAdapter1, &d.adapter)
        if FAILED(hr) { return hresult_text("EnumWarpAdapter", hr) }
        hr = D3D12CreateDevice(cast[*IUnknown](d.adapter), D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, ppv(&d.device))
        if FAILED(hr) { return hresult_text("D3D12CreateDevice (WARP)", hr) }
        d.adapter.GetDesc1(&adesc)
        warp = true
    }
    g.device = concat(ascii_of(adesc.Description[..]), if warp { " (WARP)" } else { "" })
    qdesc := D3D12_COMMAND_QUEUE_DESC{Type: D3D12_COMMAND_LIST_TYPE_DIRECT}
    hr = d.device.CreateCommandQueue(&qdesc, &IID_ID3D12CommandQueue, &d.queue)
    if SUCCEEDED(hr) { hr = d.device.CreateFence(0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, &d.fence) }
    if FAILED(hr) { return hresult_text("CreateCommandQueue / CreateFence", hr) }
    d.fence_event = CreateEventW(nil, 0, 0, nil)
    if d.fence_event == nil { return fmt("CreateEventW failed: error ", GetLastError()) }

    ntex := len(g.texs)
    d.texs = alloc[*ID3D12Resource](ntex)
    d.rtv_heap = heap(d, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, FRAMES + ntex, false)
    d.srv_heap = heap(d, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, ntex, true)
    d.sampler_heap = heap(d, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, 2, true)
    d.rtv_inc = u64(d.device.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV))
    d.srv_inc = u64(d.device.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV))
    d.sampler_inc = u64(d.device.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER))
    for i in 0..2 {
        s := D3D12_SAMPLER_DESC{
            Filter: if i == 0 { D3D12_FILTER_MIN_MAG_MIP_POINT } else { D3D12_FILTER_MIN_MAG_MIP_LINEAR },
            AddressU: D3D12_TEXTURE_ADDRESS_MODE_CLAMP, AddressV: D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
            AddressW: D3D12_TEXTURE_ADDRESS_MODE_CLAMP, MaxAnisotropy: 1, ComparisonFunc: D3D12_COMPARISON_FUNC_NEVER, MaxLOD: 3.4e38,
        }
        d.device.CreateSampler(&s, cpu(d.sampler_heap, d.sampler_inc, i))
    }

    // root signature: view constants (b0, vertex shader), texture table (t0), sampler table (s0)
    params: [3]D3D12_ROOT_PARAMETER
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS
    params[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX
    params[0].u_Constants().Num32BitValues = 4
    srv_range := D3D12_DESCRIPTOR_RANGE{RangeType: D3D12_DESCRIPTOR_RANGE_TYPE_SRV, NumDescriptors: 1}
    sampler_range := D3D12_DESCRIPTOR_RANGE{RangeType: D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER, NumDescriptors: 1}
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE
    params[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL
    params[1].u_DescriptorTable().NumDescriptorRanges = 1
    params[1].u_DescriptorTable().pDescriptorRanges = &srv_range
    params[2].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE
    params[2].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL
    params[2].u_DescriptorTable().NumDescriptorRanges = 1
    params[2].u_DescriptorTable().pDescriptorRanges = &sampler_range
    root_desc := D3D12_ROOT_SIGNATURE_DESC{NumParameters: 3, pParameters: ptr(params),
        Flags: D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT}
    blob: *ID3DBlob
    errors: *ID3DBlob
    hr = D3D12SerializeRootSignature(&root_desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors)
    if FAILED(hr) {
        text := if errors != nil { clone(trim_right(blob_bytes(errors), "\0\r\n")) } else { hresult_text("D3D12SerializeRootSignature", hr) }
        com_release(&errors)
        return text
    }
    hr = d.device.CreateRootSignature(0, blob.GetBufferPointer(), blob.GetBufferSize(), &IID_ID3D12RootSignature, &d.root)
    com_release(&blob)
    com_release(&errors)
    if FAILED(hr) { return hresult_text("CreateRootSignature", hr) }

    layout := [3]D3D12_INPUT_ELEMENT_DESC{
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("POSITION"), Format: DXGI_FORMAT_R32G32_FLOAT, AlignedByteOffset: POS_AT},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("TEXCOORD"), Format: DXGI_FORMAT_R32G32_FLOAT, AlignedByteOffset: UV_AT},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("COLOR"), Format: DXGI_FORMAT_R8G8B8A8_UNORM, AlignedByteOffset: COLOR_AT},
    }
    for b in 0..2 {
        p: D3D12_GRAPHICS_PIPELINE_STATE_DESC
        p.pRootSignature = d.root
        p.VS = D3D12_SHADER_BYTECODE{ptr(__GFX_VS_DXBC), u64(len(__GFX_VS_DXBC))}
        p.PS = D3D12_SHADER_BYTECODE{ptr(__GFX_PS_DXBC), u64(len(__GFX_PS_DXBC))}
        p.InputLayout = D3D12_INPUT_LAYOUT_DESC{ptr(layout), 3}
        p.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID
        p.RasterizerState.CullMode = D3D12_CULL_MODE_NONE
        p.RasterizerState.DepthClipEnable = 1
        rt := &p.BlendState.RenderTarget[0]
        rt.BlendEnable = 1
        rt.SrcBlend = D3D12_BLEND_SRC_ALPHA
        rt.BlendOp = D3D12_BLEND_OP_ADD
        rt.BlendOpAlpha = D3D12_BLEND_OP_ADD
        rt.LogicOp = D3D12_LOGIC_OP_NOOP
        rt.RenderTargetWriteMask = u8(D3D12_COLOR_WRITE_ENABLE_ALL)
        if b == 0 {
            rt.DestBlend = D3D12_BLEND_INV_SRC_ALPHA
            rt.SrcBlendAlpha = D3D12_BLEND_ONE
            rt.DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA
        } else {
            rt.DestBlend = D3D12_BLEND_ONE
            rt.SrcBlendAlpha = D3D12_BLEND_ZERO
            rt.DestBlendAlpha = D3D12_BLEND_ONE
        }
        p.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS
        p.SampleMask = 0xffffffff
        p.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE
        p.NumRenderTargets = 1
        p.RTVFormats[0] = FORMAT
        p.SampleDesc.Count = 1
        hr = d.device.CreateGraphicsPipelineState(&p, &IID_ID3D12PipelineState, &d.pipelines[b])
        if FAILED(hr) { return hresult_text("CreateGraphicsPipelineState", hr) }
    }

    for i in 0..FRAMES {
        check(d, d.device.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, &d.allocators[i]), "CreateCommandAllocator")
    }
    check(d, d.device.CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, d.allocators[0], nil, &IID_ID3D12GraphicsCommandList, &d.list), "CreateCommandList")
    check(d, d.list.Close(), "ID3D12GraphicsCommandList::Close")
    check(d, d.device.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, &d.upload_allocator), "CreateCommandAllocator")
    check(d, d.device.CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, d.upload_allocator, nil, &IID_ID3D12GraphicsCommandList, &d.upload_list), "CreateCommandList")
    check(d, d.upload_list.Close(), "ID3D12GraphicsCommandList::Close")

    d.max_vertices = __gfx_max_vertices(desc)
    d.vbuf = buffer(d, D3D12_HEAP_TYPE_UPLOAD, FRAMES * d.max_vertices * sizeof[GfxVertex](), D3D12_RESOURCE_STATE_GENERIC_READ)
    mapped: *u8
    none := D3D12_RANGE{0, 0}
    check(d, d.vbuf.Map(0, &none, &mapped), "ID3D12Resource::Map (vertices)")
    d.mapped = mkslice[GfxVertex](cast[*GfxVertex](mapped), FRAMES * d.max_vertices)

    // texture 1: the white pixel that shapes are drawn with when no texture is at hand
    white := [4]u8{255, 255, 255, 255}
    make_texture(g, d, 1, 1, 1, 4, false, white[..])
    ""
}

priv fn swap_targets(g: *Gfx, d: *Dx) {
    for i in 0..FRAMES {
        check(d, d.swap.GetBuffer(u32(i), &IID_ID3D12Resource, &d.backs[i]), "IDXGISwapChain::GetBuffer")
        d.device.CreateRenderTargetView(d.backs[i], nil, cpu(d.rtv_heap, d.rtv_inc, i))
    }
}

// Opens a renderer on the window: the first hardware Direct3D 12 device (feature level 11.0),
// else WARP, and a swap chain. (g, "") or (nil, why it cannot draw here).
fn gfx_open(w: *Window, desc: GfxDesc) -> (*Gfx, str) {
    width, height := w.size()
    g := __gfx_new(max(width, 1), max(height, 1), desc)
    d := new[Dx]()
    d.win = w
    g.os = cast[*u8](d)
    err := open_device(g, d, desc)
    if err != "" {
        gfx_close(g)
        return (nil, concat("no Direct3D 12 device: ", err))
    }
    sdesc := DXGI_SWAP_CHAIN_DESC1{
        Width: u32(g.width), Height: u32(g.height), Format: FORMAT, SampleDesc: DXGI_SAMPLE_DESC{Count: 1},
        BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT, BufferCount: FRAMES, SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
    }
    swap1: *IDXGISwapChain1
    hr := d.factory.CreateSwapChainForHwnd(cast[*IUnknown](d.queue), win32_hwnd(w), &sdesc, nil, nil, &swap1)
    if FAILED(hr) {
        gfx_close(g)
        return (nil, hresult_text("CreateSwapChainForHwnd", hr))
    }
    check(d, swap1.QueryInterface(&IID_IDXGISwapChain3, &d.swap), "QueryInterface IDXGISwapChain3")
    com_release(&swap1)
    // fullscreen is std.window's borderless window (set_fullscreen), not DXGI's Alt+Enter
    d.factory.MakeWindowAssociation(win32_hwnd(w), DXGI_MWA_NO_ALT_ENTER)
    swap_targets(g, d)
    (g, "")
}

// A renderer without a window: the screen is a width x height image that read_pixels returns
// after end_frame. For tests, screenshots and tools.
fn gfx_offscreen(width: i64, height: i64, desc: GfxDesc) -> (*Gfx, str) {
    g := __gfx_new(width, height, desc)
    g.offscreen = true
    d := new[Dx]()
    g.os = cast[*u8](d)
    err := open_device(g, d, desc)
    if err != "" {
        gfx_close(g)
        return (nil, concat("no Direct3D 12 device: ", err))
    }
    d.screen_tex = render_texture(g, width, height, FilterNearest).id
    (g, "")
}

// Waits for the GPU and releases everything (not the window).
fn gfx_close(g: *Gfx) {
    d := dx(g)
    if d.queue != nil && d.fence != nil && d.fence_event != nil { flush(d) }
    if d.vbuf != nil && len(d.mapped) > 0 { d.vbuf.Unmap(0, nil) }
    for i in 0..len(d.texs) { com_release(&d.texs[i]) }
    for i in 0..FRAMES {
        com_release(&d.backs[i])
        com_release(&d.allocators[i])
    }
    com_release(&d.vbuf)
    com_release(&d.staging)
    com_release(&d.list)
    com_release(&d.upload_list)
    com_release(&d.upload_allocator)
    com_release(&d.pipelines[0])
    com_release(&d.pipelines[1])
    com_release(&d.root)
    com_release(&d.rtv_heap)
    com_release(&d.srv_heap)
    com_release(&d.sampler_heap)
    com_release(&d.swap)
    if d.fence_event != nil {
        CloseHandle(d.fence_event)
        d.fence_event = nil
    }
    com_release(&d.fence)
    com_release(&d.queue)
    com_release(&d.device)
    com_release(&d.adapter)
    com_release(&d.factory)
}

// ---- frames ----------------------------------------------------------------------------------

// Starts a frame cleared to `clear` (RGBA8, red in the lowest byte). Follows the window's size
// (g.width, g.height), waits until the GPU is done with the frame two frames back. Returns
// false when there is nothing to draw into (the window is minimized: it then sleeps 10 ms, so
// a loop that skips the frame does not spin; or the device is lost): skip drawing and end_frame.
fn begin_frame(g: *Gfx, clear: u32) -> bool {
    if g.lost != "" { return false }
    d := dx(g)
    if d.swap != nil {
        ww, wh := d.win.size()
        if d.win.minimized || ww <= 0 || wh <= 0 {
            sleep_ms(10)
            return false
        }
        if ww != g.width || wh != g.height {
            flush(d)
            for i in 0..FRAMES { com_release(&d.backs[i]) }
            hr := d.swap.ResizeBuffers(FRAMES, u32(ww), u32(wh), DXGI_FORMAT_UNKNOWN, 0)
            if FAILED(hr) {
                r := removed(d)
                g.lost = if r == "" { hresult_text("IDXGISwapChain::ResizeBuffers", hr) } else { r }
                return false
            }
            g.width = ww
            g.height = wh
            swap_targets(g, d)
        }
        d.frame = i64(d.swap.GetCurrentBackBufferIndex())
    } else {
        d.frame = (d.frame + 1) % FRAMES
    }
    wait(d, d.done[d.frame])
    base := d.frame * d.max_vertices
    __gfx_begin(g, d.mapped[base..base + d.max_vertices], clear)
    true
}

// The render-target view and resource of target `id` (0: the screen).
priv fn target_of(d: *Dx, id: i64) -> (D3D12_CPU_DESCRIPTOR_HANDLE, *ID3D12Resource) {
    if id == 0 && d.swap != nil {
        return (cpu(d.rtv_heap, d.rtv_inc, d.frame), d.backs[d.frame])
    }
    t := if id == 0 { d.screen_tex } else { id }
    (cpu(d.rtv_heap, d.rtv_inc, FRAMES + t), d.texs[t])
}

priv fn rgba(c: u32) -> [4]f32 {
    v := color_vec4(c)
    [4]f32{v.x, v.y, v.z, v.w}
}

// Draws the frame and presents it (with vsync unless g.vsync is false). "" or what failed;
// a removed device sets g.lost (begin_frame then returns false).
fn end_frame(g: *Gfx) -> str {
    __gfx_end(g)
    d := dx(g)
    list := d.list
    check(d, d.allocators[d.frame].Reset(), "ID3D12CommandAllocator::Reset")
    check(d, list.Reset(d.allocators[d.frame], nil), "ID3D12GraphicsCommandList::Reset")
    heaps := [2]*ID3D12DescriptorHeap{d.srv_heap, d.sampler_heap}
    list.SetDescriptorHeaps(2, ptr(heaps))
    list.SetGraphicsRootSignature(d.root)
    list.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST)
    stride := sizeof[GfxVertex]()
    vview := D3D12_VERTEX_BUFFER_VIEW{d.vbuf.GetGPUVirtualAddress() + u64(d.frame * d.max_vertices * stride),
        u32(d.max_vertices * stride), u32(stride)}
    list.IASetVertexBuffers(0, 1, &vview)
    screen_state := if d.swap != nil { D3D12_RESOURCE_STATE_PRESENT } else { D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE }

    fn start(list: *ID3D12GraphicsCommandList, rtv: D3D12_CPU_DESCRIPTOR_HANDLE, w: i64, h: i64) {
        list.OMSetRenderTargets(1, &rtv, 0, nil)
        viewport := D3D12_VIEWPORT{0.0, 0.0, f32(w), f32(h), 0.0, 1.0}
        list.RSSetViewports(1, &viewport)
        view := [4]f32{2.0 / f32(w), -2.0 / f32(h), -1.0, 1.0}
        list.SetGraphicsRoot32BitConstants(0, 4, cast[*u8](ptr(view)), 0)
    }
    target := 0
    tw := g.width
    th := g.height
    rtv, res := target_of(d, 0)
    barrier(list, res, screen_state, D3D12_RESOURCE_STATE_RENDER_TARGET)
    start(list, rtv, tw, th)
    color := rgba(g.clear_color)
    list.ClearRenderTargetView(rtv, ptr(color), 0, nil)
    pipeline := -1
    for c in g.cmds[..g.ncmds] {
        if c.kind == __GFX_TARGET {
            id := i64(c.tex)
            if id == target { continue }
            if target != 0 { barrier(list, res, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE) }
            target = id
            rtv, res = target_of(d, id)
            if id != 0 {
                barrier(list, res, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_RENDER_TARGET)
                tw = g.texs[id].w
                th = g.texs[id].h
            } else {
                tw = g.width
                th = g.height
            }
            start(list, rtv, tw, th)
        } else if c.kind == __GFX_CLEAR {
            color = rgba(c.color)
            list.ClearRenderTargetView(rtv, ptr(color), 0, nil)
        } else if c.count > 0 {
            assert g.texs[c.tex].live, "end_frame: a texture drawn in this frame was freed"
            if i64(c.blend) != pipeline {
                pipeline = i64(c.blend)
                list.SetPipelineState(d.pipelines[pipeline])
            }
            list.SetGraphicsRootDescriptorTable(1, gpu(d.srv_heap, d.srv_inc, i64(c.tex)))
            list.SetGraphicsRootDescriptorTable(2, gpu(d.sampler_heap, d.sampler_inc, i64(g.texs[c.tex].filter)))
            scissor := if c.clip[2] < 0 { D3D12_RECT{0, 0, i32(tw), i32(th)} } else {
                D3D12_RECT{c.clip[0], c.clip[1], c.clip[0] + c.clip[2], c.clip[1] + c.clip[3]} }
            list.RSSetScissorRects(1, &scissor)
            list.DrawInstanced(u32(c.count), 1, u32(c.first), 0)
        }
    }
    if target != 0 {
        barrier(list, res, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
        rtv, res = target_of(d, 0)
    } else {
        _, res = target_of(d, 0)
    }
    barrier(list, res, D3D12_RESOURCE_STATE_RENDER_TARGET, screen_state)
    hr := list.Close()
    if SUCCEEDED(hr) {
        lists := [1]*ID3D12CommandList{cast[*ID3D12CommandList](list)}
        d.queue.ExecuteCommandLists(1, ptr(lists))
        if d.swap != nil { hr = d.swap.Present(if g.vsync { 1 } else { 0 }, 0) }
    }
    if FAILED(hr) {
        r := removed(d)
        g.lost = if r == "" { hresult_text(if d.swap != nil { "IDXGISwapChain::Present" } else { "ID3D12GraphicsCommandList::Close" }, hr) } else { r }
        return g.lost
    }
    d.done[d.frame] = signal(d)
    if hr == DXGI_STATUS_OCCLUDED { sleep_ms(10) }     // a hidden window presents at once: no vsync paces the loop
    ""
}

// ---- textures --------------------------------------------------------------------------------

priv fn begin_upload(d: *Dx) -> *ID3D12GraphicsCommandList {
    check(d, d.upload_allocator.Reset(), "ID3D12CommandAllocator::Reset")
    check(d, d.upload_list.Reset(d.upload_allocator, nil), "ID3D12GraphicsCommandList::Reset")
    d.upload_list
}

priv fn end_upload(d: *Dx) {
    check(d, d.upload_list.Close(), "ID3D12GraphicsCommandList::Close")
    lists := [1]*ID3D12CommandList{cast[*ID3D12CommandList](d.upload_list)}
    d.queue.ExecuteCommandLists(1, ptr(lists))
    flush(d)
}

// Records a copy of w x h pixels of `bpp` bytes (rows packed) to (x, y) of texture id.
priv fn copy_in(d: *Dx, list: *ID3D12GraphicsCommandList, id: i64, x: i64, y: i64, w: i64, h: i64, bpp: i64, pix: []u8) {
    pitch := align_up(w * bpp, 256)
    if pitch * h > d.staging_size {
        com_release(&d.staging)
        d.staging_size = max(pitch * h, 65536)
        d.staging = buffer(d, D3D12_HEAP_TYPE_UPLOAD, d.staging_size, D3D12_RESOURCE_STATE_GENERIC_READ)
    }
    mapped: *u8
    none := D3D12_RANGE{0, 0}
    check(d, d.staging.Map(0, &none, &mapped), "ID3D12Resource::Map (staging)")
    mem := mkslice[u8](mapped, pitch * h)
    for row in 0..h {
        copy(mem[row * pitch..row * pitch + w * bpp], pix[row * w * bpp..(row + 1) * w * bpp])
    }
    d.staging.Unmap(0, nil)
    dst := D3D12_TEXTURE_COPY_LOCATION{pResource: d.texs[id], Type: D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}
    src := D3D12_TEXTURE_COPY_LOCATION{pResource: d.staging, Type: D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT}
    *src.u_PlacedFootprint() = D3D12_PLACED_SUBRESOURCE_FOOTPRINT{0,
        D3D12_SUBRESOURCE_FOOTPRINT{if bpp == 1 { DXGI_FORMAT_R8_UNORM } else { FORMAT }, u32(w), u32(h), 1, u32(pitch)}}
    list.CopyTextureRegion(&dst, u32(x), u32(y), 0, &src, nil)
}

// Creates texture `id` (bpp 1: coverage, 4: RGBA) holding `pix` (nil: a render texture, cleared
// to transparent) and its views.
priv fn make_texture(g: *Gfx, d: *Dx, id: i64, w: i64, h: i64, bpp: i64, target: bool, pix: []u8) {
    format := if bpp == 1 { DXGI_FORMAT_R8_UNORM } else { FORMAT }
    props := D3D12_HEAP_PROPERTIES{Type: D3D12_HEAP_TYPE_DEFAULT, CreationNodeMask: 1, VisibleNodeMask: 1}
    desc := D3D12_RESOURCE_DESC{
        Dimension: D3D12_RESOURCE_DIMENSION_TEXTURE2D, Width: u64(w), Height: u32(h), DepthOrArraySize: 1,
        MipLevels: 1, Format: format, SampleDesc: DXGI_SAMPLE_DESC{Count: 1},
        Flags: if target { D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET } else { D3D12_RESOURCE_FLAG_NONE },
    }
    clear := D3D12_CLEAR_VALUE{Format: format}
    state := if target { D3D12_RESOURCE_STATE_RENDER_TARGET } else { D3D12_RESOURCE_STATE_COPY_DEST }
    check(d, d.device.CreateCommittedResource(&props, D3D12_HEAP_FLAG_NONE, &desc, state, if target { &clear } else { nil },
        &IID_ID3D12Resource, &d.texs[id]), "CreateCommittedResource (texture)")
    view := D3D12_SHADER_RESOURCE_VIEW_DESC{Format: format, ViewDimension: D3D12_SRV_DIMENSION_TEXTURE2D,
        Shader4ComponentMapping: if bpp == 1 { COVERAGE_MAPPING } else { D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING }}
    view.u_Texture2D().MipLevels = 1
    d.device.CreateShaderResourceView(d.texs[id], &view, cpu(d.srv_heap, d.srv_inc, id))
    list := begin_upload(d)
    if target {
        rtv := cpu(d.rtv_heap, d.rtv_inc, FRAMES + id)
        d.device.CreateRenderTargetView(d.texs[id], nil, rtv)
        transparent := [4]f32{0.0, 0.0, 0.0, 0.0}
        list.ClearRenderTargetView(rtv, ptr(transparent), 0, nil)
    } else {
        copy_in(d, list, id, 0, 0, w, h, bpp, pix)
    }
    barrier(list, d.texs[id], state, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
    end_upload(d)
}

priv fn new_id(g: *Gfx, w: i64, h: i64, filter: Filter, coverage: bool, target: bool) -> i64 {
    id := g.__gfx_tex_new(w, h, filter, coverage, target)
    if id == 0 { panic(fmt("gfx: more than ", len(g.texs) - 2, " textures (GfxDesc.max_textures)")) }
    id
}

// A texture holding the image (copied to the GPU before it returns): one channel is a
// coverage texture, drawn as the tint's colour with that coverage as alpha (font atlases);
// two, three or four channels are converted to RGBA.
fn texture(g: *Gfx, img: Image, filter: Filter) -> Texture {
    bpp, pix := __gfx_pixels(img)
    id := new_id(g, img.w, img.h, filter, bpp == 1, false)
    make_texture(g, dx(g), id, img.w, img.h, bpp, false, pix)
    Texture{id, img.w, img.h}
}

// A w x h RGBA texture to draw into (set_target) and to draw with; transparent at first.
fn render_texture(g: *Gfx, w: i64, h: i64, filter: Filter) -> Texture {
    id := new_id(g, w, h, filter, false, true)
    make_texture(g, dx(g), id, w, h, 4, true, nil)
    Texture{id, w, h}
}

// Replaces the pixels of t from (x, y) with the image (its channels as for `texture`; one for
// a coverage texture, else at least three). Waits for the GPU; within a frame the new pixels
// are what every draw of that frame shows (they are drawn at end_frame).
fn update_texture(g: *Gfx, t: Texture, x: i64, y: i64, img: Image) {
    assert t.id > 1 && t.id < len(g.texs) && g.texs[t.id].live && !g.texs[t.id].target, "update_texture: not a texture made by `texture`"
    bpp, pix := __gfx_pixels(img)
    assert (bpp == 1) == g.texs[t.id].coverage, "update_texture: a coverage texture takes one channel, an RGBA texture three or four"
    assert x >= 0 && y >= 0 && x + img.w <= t.w && y + img.h <= t.h, "update_texture: outside the texture"
    d := dx(g)
    list := begin_upload(d)
    barrier(list, d.texs[t.id], D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_DEST)
    copy_in(d, list, t.id, x, y, img.w, img.h, bpp, pix)
    barrier(list, d.texs[t.id], D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
    end_upload(d)
}

// Releases the texture (waits for the GPU). Not between begin_frame and end_frame.
fn free_texture(g: *Gfx, t: Texture) {
    assert !g.in_frame, "free_texture: between begin_frame and end_frame"
    assert t.id > 1 && t.id < len(g.texs) && g.texs[t.id].live, "free_texture: not a live texture"
    d := dx(g)
    flush(d)
    com_release(&d.texs[t.id])
    g.texs[t.id].live = false
}

// The pixels of a texture as an image (4 channels, or 1 for a coverage texture); waits for the GPU.
fn read_texture(g: *Gfx, t: Texture) -> Image {
    assert t.id > 0 && t.id < len(g.texs) && g.texs[t.id].live, "read_texture: not a live texture"
    assert !g.in_frame, "read_texture: between begin_frame and end_frame"
    d := dx(g)
    bpp := if g.texs[t.id].coverage { 1 } else { 4 }
    pitch := align_up(t.w * bpp, 256)
    rb := buffer(d, D3D12_HEAP_TYPE_READBACK, pitch * t.h, D3D12_RESOURCE_STATE_COPY_DEST)
    list := begin_upload(d)
    dst := D3D12_TEXTURE_COPY_LOCATION{pResource: rb, Type: D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT}
    *dst.u_PlacedFootprint() = D3D12_PLACED_SUBRESOURCE_FOOTPRINT{0,
        D3D12_SUBRESOURCE_FOOTPRINT{if bpp == 1 { DXGI_FORMAT_R8_UNORM } else { FORMAT }, u32(t.w), u32(t.h), 1, u32(pitch)}}
    src := D3D12_TEXTURE_COPY_LOCATION{pResource: d.texs[t.id], Type: D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX}
    barrier(list, d.texs[t.id], D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_SOURCE)
    list.CopyTextureRegion(&dst, 0, 0, 0, &src, nil)
    barrier(list, d.texs[t.id], D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
    end_upload(d)
    img := image_new(t.w, t.h, bpp)
    mapped: *u8
    whole := D3D12_RANGE{0, u64(pitch * t.h)}
    check(d, rb.Map(0, &whole, &mapped), "ID3D12Resource::Map (readback)")
    mem := mkslice[u8](mapped, pitch * t.h)
    for row in 0..t.h {
        copy(img.pix[row * t.w * bpp..(row + 1) * t.w * bpp], mem[row * pitch..row * pitch + t.w * bpp])
    }
    none := D3D12_RANGE{0, 0}
    rb.Unmap(0, &none)
    com_release(&rb)
    img
}

// The screen of a gfx_offscreen renderer after end_frame, as an RGBA image.
fn read_pixels(g: *Gfx) -> Image {
    assert g.offscreen, "read_pixels: only for gfx_offscreen (draw into a render_texture and read_texture it)"
    read_texture(g, Texture{dx(g).screen_tex, g.width, g.height})
}

// where the input layout finds the fields of a vertex
priv const POS_AT: u32 = offsetof[GfxVertex](pos)
priv const UV_AT: u32 = offsetof[GfxVertex](uv)
priv const COLOR_AT: u32 = offsetof[GfxVertex](color)
