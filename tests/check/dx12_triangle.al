// A spinning triangle with Direct3D 12, written against std.dx12.
//
// AL has no Windows backend yet, so this program is only type-checked (`alc check`); it is the
// reference for how the bindings are meant to be used. Structure: one explicit state struct,
// set-up split by concern, a render loop that records one command list per frame and waits
// for the GPU with a fence, and a clean-up that releases every COM object.
use std.dx12

WIDTH :: 1280
HEIGHT :: 720
FRAME_COUNT :: 2

Vertex :: struct {
    position: vec3
    color: vec4
}

App :: struct {
    hwnd: *u8
    factory: *IDXGIFactory4
    device: *ID3D12Device
    queue: *ID3D12CommandQueue
    swap_chain: *IDXGISwapChain3
    rtv_heap: *ID3D12DescriptorHeap
    rtv_size: u32
    render_targets: [FRAME_COUNT]*ID3D12Resource
    allocator: *ID3D12CommandAllocator
    list: *ID3D12GraphicsCommandList
    root_signature: *ID3D12RootSignature
    pipeline: *ID3D12PipelineState
    vertex_buffer: *ID3D12Resource
    vertex_view: D3D12_VERTEX_BUFFER_VIEW
    fence: *ID3D12Fence
    fence_event: *u8
    fence_value: u64
    frame_index: u32
    ticks_per_second: i64
    start_ticks: i64
}

// HLSL for both stages; the angle and the aspect ratio arrive as root constants.
SHADER :: `
cbuffer Params : register(b0) { float angle; float aspect; };
struct PSInput { float4 position : SV_POSITION; float4 color : COLOR; };

PSInput VSMain(float3 position : POSITION, float4 color : COLOR) {
    PSInput o;
    float s = sin(angle), c = cos(angle);
    o.position = float4((position.x * c - position.y * s) / aspect, position.x * s + position.y * c, position.z, 1.0);
    o.color = color;
    return o;
}

float4 PSMain(PSInput input) : SV_TARGET { return input.color; }
`

window_proc :: (hwnd: *u8, msg: u32, wparam: u64, lparam: i64) -> i64 {
    if msg == WM_DESTROY {
        PostQuitMessage(0)
        return 0
    }
    if msg == WM_KEYDOWN && wparam == VK_ESCAPE {
        DestroyWindow(hwnd)
        return 0
    }
    DefWindowProcW(hwnd, msg, wparam, lparam)
}

create_window :: (title: str) -> *u8 {
    instance := GetModuleHandleW(nil)
    class_name := utf16("ALTriangleWindow")
    class := WNDCLASSEXW{
        cbSize: u32(sizeof[WNDCLASSEXW]()),
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: window_proc,
        hInstance: instance,
        hCursor: LoadCursorW(nil, cast[*u16](IDC_ARROW)),
        lpszClassName: class_name,
    }
    assert RegisterClassExW(&class) != 0, "RegisterClassExW"
    rect := RECT{0, 0, WIDTH, HEIGHT}
    AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, 0)
    hwnd := CreateWindowExW(0, class_name, utf16(title), WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
        rect.right - rect.left, rect.bottom - rect.top, nil, nil, instance, nil)
    assert hwnd != nil, "CreateWindowExW"
    ShowWindow(hwnd, SW_SHOW)
    hwnd
}

// The first hardware adapter that supports Direct3D 12 (nil: let D3D12CreateDevice choose).
pick_adapter :: (factory: *IDXGIFactory4) -> *IDXGIAdapter1 {
    index: u32
    loop {
        adapter: *IDXGIAdapter1
        if factory.EnumAdapters1(index, &adapter) == DXGI_ERROR_NOT_FOUND {
            return nil
        }
        desc: DXGI_ADAPTER_DESC1
        adapter.GetDesc1(&desc)
        software := desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE != 0
        if !software && SUCCEEDED(D3D12CreateDevice(cast[*IUnknown](adapter), D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, nil)) {
            return adapter
        }
        com_release(&adapter)
        index += 1
    }
}

create_device :: (app: *App, debug: bool) {
    factory_flags: u32
    if debug {
        layer: *ID3D12Debug
        if SUCCEEDED(D3D12GetDebugInterface(&IID_ID3D12Debug, ppv(&layer))) {
            layer.EnableDebugLayer()
            factory_flags |= DXGI_CREATE_FACTORY_DEBUG
            com_release(&layer)
        }
    }
    dx_check(CreateDXGIFactory2(factory_flags, &IID_IDXGIFactory4, ppv(&app.factory)), "CreateDXGIFactory2")
    adapter := pick_adapter(app.factory)
    dx_check(D3D12CreateDevice(cast[*IUnknown](adapter), D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, ppv(&app.device)), "D3D12CreateDevice")
    com_release(&adapter)
    app.device.SetName(utf16("triangle device"))

    queue_desc := D3D12_COMMAND_QUEUE_DESC{Type: D3D12_COMMAND_LIST_TYPE_DIRECT, Flags: D3D12_COMMAND_QUEUE_FLAG_NONE}
    dx_check(app.device.CreateCommandQueue(&queue_desc, &IID_ID3D12CommandQueue, &app.queue), "CreateCommandQueue")
    dx_check(app.device.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, &app.allocator), "CreateCommandAllocator")
}

create_swap_chain :: (app: *App) {
    desc := DXGI_SWAP_CHAIN_DESC1{
        Width: WIDTH,
        Height: HEIGHT,
        Format: DXGI_FORMAT_R8G8B8A8_UNORM,
        SampleDesc: DXGI_SAMPLE_DESC{Count: 1},
        BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
        BufferCount: FRAME_COUNT,
        SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
    }
    // the swap chain presents through the command queue, not the device
    swap_chain: *IDXGISwapChain1
    dx_check(app.factory.CreateSwapChainForHwnd(cast[*IUnknown](app.queue), app.hwnd, &desc, nil, nil, &swap_chain), "CreateSwapChainForHwnd")
    dx_check(swap_chain.QueryInterface(&IID_IDXGISwapChain3, &app.swap_chain), "IDXGISwapChain3")
    com_release(&swap_chain)
    app.factory.MakeWindowAssociation(app.hwnd, DXGI_MWA_NO_ALT_ENTER)
    app.frame_index = app.swap_chain.GetCurrentBackBufferIndex()

    // one render-target view per back buffer
    heap_desc := D3D12_DESCRIPTOR_HEAP_DESC{Type: D3D12_DESCRIPTOR_HEAP_TYPE_RTV, NumDescriptors: FRAME_COUNT}
    dx_check(app.device.CreateDescriptorHeap(&heap_desc, &IID_ID3D12DescriptorHeap, &app.rtv_heap), "CreateDescriptorHeap")
    app.rtv_size = app.device.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV)
    handle := app.rtv_heap.GetCPUDescriptorHandleForHeapStart()
    for i in 0..FRAME_COUNT {
        dx_check(app.swap_chain.GetBuffer(u32(i), &IID_ID3D12Resource, &app.render_targets[i]), "GetBuffer")
        app.device.CreateRenderTargetView(app.render_targets[i], nil, handle)
        handle.ptr += u64(app.rtv_size)
    }
}

// Compiles one entry point of the HLSL source; the compiler's messages are printed on failure.
compile_shader :: (source: str, entry: str, target: str) -> *ID3DBlob {
    code: *ID3DBlob
    errors: *ID3DBlob
    hr := D3DCompile(ptr(source), u64(len(source)), ptr("triangle.hlsl"), nil, nil, cstr(entry), cstr(target),
        D3DCOMPILE_ENABLE_STRICTNESS, 0, &code, &errors)
    if FAILED(hr) {
        if errors != nil {
            print(blob_bytes(errors))
        }
        dx_check(hr, entry)
    }
    com_release(&errors)
    code
}

create_pipeline :: (app: *App) {
    // root signature: two 32-bit constants (angle, aspect) for the vertex shader
    param: D3D12_ROOT_PARAMETER
    param.ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS
    param.ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX
    constants := param.u_Constants()
    constants.ShaderRegister = 0
    constants.Num32BitValues = 2
    root_desc := D3D12_ROOT_SIGNATURE_DESC{
        NumParameters: 1,
        pParameters: &param,
        Flags: D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
    }
    signature: *ID3DBlob
    errors: *ID3DBlob
    dx_check(D3D12SerializeRootSignature(&root_desc, D3D_ROOT_SIGNATURE_VERSION_1, &signature, &errors), "D3D12SerializeRootSignature")
    dx_check(app.device.CreateRootSignature(0, signature.GetBufferPointer(), signature.GetBufferSize(), &IID_ID3D12RootSignature, &app.root_signature), "CreateRootSignature")
    com_release(&signature)
    com_release(&errors)

    vs := compile_shader(SHADER, "VSMain", "vs_5_0")
    ps := compile_shader(SHADER, "PSMain", "ps_5_0")

    layout := [2]D3D12_INPUT_ELEMENT_DESC{
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("POSITION"), Format: DXGI_FORMAT_R32G32B32_FLOAT, AlignedByteOffset: 0,
            InputSlotClass: D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("COLOR"), Format: DXGI_FORMAT_R32G32B32A32_FLOAT, AlignedByteOffset: 12,
            InputSlotClass: D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA},
    }
    desc: D3D12_GRAPHICS_PIPELINE_STATE_DESC
    desc.pRootSignature = app.root_signature
    desc.VS = D3D12_SHADER_BYTECODE{vs.GetBufferPointer(), vs.GetBufferSize()}
    desc.PS = D3D12_SHADER_BYTECODE{ps.GetBufferPointer(), ps.GetBufferSize()}
    desc.InputLayout = D3D12_INPUT_LAYOUT_DESC{ptr(layout), 2}
    desc.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID
    desc.RasterizerState.CullMode = D3D12_CULL_MODE_NONE
    desc.RasterizerState.DepthClipEnable = 1
    desc.BlendState.RenderTarget[0].RenderTargetWriteMask = u8(D3D12_COLOR_WRITE_ENABLE_ALL)
    desc.SampleMask = 0xffffffff
    desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE
    desc.NumRenderTargets = 1
    desc.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM
    desc.SampleDesc.Count = 1
    dx_check(app.device.CreateGraphicsPipelineState(&desc, &IID_ID3D12PipelineState, &app.pipeline), "CreateGraphicsPipelineState")
    com_release(&vs)
    com_release(&ps)

    // the list is created in the recording state; the render loop expects it closed
    dx_check(app.device.CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, app.allocator, app.pipeline, &IID_ID3D12GraphicsCommandList, &app.list), "CreateCommandList")
    dx_check(app.list.Close(), "Close")
}

create_vertex_buffer :: (app: *App) {
    vertices := [3]Vertex{
        Vertex{vec3(0.0, 0.5, 0.0), vec4(1.0, 0.0, 0.0, 1.0)},
        Vertex{vec3(0.45, -0.5, 0.0), vec4(0.0, 1.0, 0.0, 1.0)},
        Vertex{vec3(-0.45, -0.5, 0.0), vec4(0.0, 0.0, 1.0, 1.0)},
    }
    size := u64(sizeof[[3]Vertex]())
    // an upload heap is CPU-writable; fine for a buffer this small
    heap := D3D12_HEAP_PROPERTIES{Type: D3D12_HEAP_TYPE_UPLOAD, CreationNodeMask: 1, VisibleNodeMask: 1}
    desc := D3D12_RESOURCE_DESC{
        Dimension: D3D12_RESOURCE_DIMENSION_BUFFER,
        Width: size,
        Height: 1,
        DepthOrArraySize: 1,
        MipLevels: 1,
        SampleDesc: DXGI_SAMPLE_DESC{Count: 1},
        Layout: D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
    }
    dx_check(app.device.CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_GENERIC_READ, nil,
        &IID_ID3D12Resource, &app.vertex_buffer), "CreateCommittedResource")
    mapped: *u8
    no_read := D3D12_RANGE{0, 0}
    dx_check(app.vertex_buffer.Map(0, &no_read, &mapped), "Map")
    memcopy(mapped, ptr(vertices), i64(size))
    app.vertex_buffer.Unmap(0, nil)
    app.vertex_view = D3D12_VERTEX_BUFFER_VIEW{app.vertex_buffer.GetGPUVirtualAddress(), u32(size), u32(sizeof[Vertex]())}
}

// Blocks until the GPU has finished everything submitted so far.
wait_for_gpu :: (app: *App) {
    app.fence_value += 1
    dx_check(app.queue.Signal(app.fence, app.fence_value), "Signal")
    if app.fence.GetCompletedValue() < app.fence_value {
        dx_check(app.fence.SetEventOnCompletion(app.fence_value, app.fence_event), "SetEventOnCompletion")
        WaitForSingleObject(app.fence_event, INFINITE)
    }
}

transition :: (resource: *ID3D12Resource, before: u32, after: u32) -> D3D12_RESOURCE_BARRIER {
    barrier: D3D12_RESOURCE_BARRIER
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION
    t := barrier.u_Transition()
    t.pResource = resource
    t.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES
    t.StateBefore = before
    t.StateAfter = after
    barrier
}

seconds :: (app: *App) -> f32 {
    now: i64
    QueryPerformanceCounter(&now)
    f32(f64(now - app.start_ticks) / f64(app.ticks_per_second))
}

render :: (app: *App) {
    dx_check(app.allocator.Reset(), "allocator Reset")
    dx_check(app.list.Reset(app.allocator, app.pipeline), "list Reset")
    list := app.list
    target := app.render_targets[app.frame_index]

    params := [2]f32{seconds(app), f32(WIDTH) / f32(HEIGHT)}
    viewport := D3D12_VIEWPORT{0.0, 0.0, f32(WIDTH), f32(HEIGHT), 0.0, 1.0}
    scissor := D3D12_RECT{0, 0, WIDTH, HEIGHT}
    list.SetGraphicsRootSignature(app.root_signature)
    list.SetGraphicsRoot32BitConstants(0, 2, cast[*u8](ptr(params)), 0)
    list.RSSetViewports(1, &viewport)
    list.RSSetScissorRects(1, &scissor)

    to_target := transition(target, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET)
    list.ResourceBarrier(1, &to_target)
    rtv := app.rtv_heap.GetCPUDescriptorHandleForHeapStart()
    rtv.ptr += u64(app.frame_index) * u64(app.rtv_size)
    list.OMSetRenderTargets(1, &rtv, 0, nil)
    clear_color := [4]f32{0.05, 0.07, 0.12, 1.0}
    list.ClearRenderTargetView(rtv, ptr(clear_color), 0, nil)
    list.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST)
    list.IASetVertexBuffers(0, 1, &app.vertex_view)
    list.DrawInstanced(3, 1, 0, 0)
    to_present := transition(target, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT)
    list.ResourceBarrier(1, &to_present)
    dx_check(list.Close(), "Close")

    lists := [1]*ID3D12CommandList{cast[*ID3D12CommandList](list)}
    app.queue.ExecuteCommandLists(1, ptr(lists))
    dx_check(app.swap_chain.Present(1, 0), "Present")
    wait_for_gpu(app)
    app.frame_index = app.swap_chain.GetCurrentBackBufferIndex()
}

destroy :: (app: *App) {
    wait_for_gpu(app)
    CloseHandle(app.fence_event)
    com_release(&app.fence)
    com_release(&app.vertex_buffer)
    com_release(&app.pipeline)
    com_release(&app.root_signature)
    com_release(&app.list)
    com_release(&app.allocator)
    for i in 0..FRAME_COUNT {
        com_release(&app.render_targets[i])
    }
    com_release(&app.rtv_heap)
    com_release(&app.swap_chain)
    com_release(&app.queue)
    com_release(&app.device)
    com_release(&app.factory)
}

main :: () {
    app: App
    app.hwnd = create_window("AL Direct3D 12 triangle")
    create_device(&app, true)
    create_swap_chain(&app)
    create_pipeline(&app)
    create_vertex_buffer(&app)
    dx_check(app.device.CreateFence(0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, &app.fence), "CreateFence")
    app.fence_event = CreateEventW(nil, 0, 0, nil)
    assert app.fence_event != nil, "CreateEventW"
    wait_for_gpu(&app)   // the vertex upload
    QueryPerformanceFrequency(&app.ticks_per_second)
    QueryPerformanceCounter(&app.start_ticks)

    msg: MSG
    while msg.message != WM_QUIT {
        if PeekMessageW(&msg, nil, 0, 0, PM_REMOVE) != 0 {
            TranslateMessage(&msg)
            DispatchMessageW(&msg)
        } else {
            render(&app)
        }
    }
    destroy(&app)
}
