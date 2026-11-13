// A spinning triangle in a window with Direct3D 12 (Windows only):
//
//     alc build --target windows examples/dx12_triangle.al     then run dx12_triangle.exe
//
// Options: --no-vsync (present as fast as possible), --warp (the software rasterizer),
// --debug (the debug layer, if the Graphics Tools are installed), --frames N (quit after N
// frames), --remove-device N (remove the device after N frames, to see how a lost device is
// reported). Escape or closing the window quits, F11 or Alt+Enter toggles fullscreen.
//
// It shows the parts of a real-time program: a std.window window whose HWND (win32_hwnd) gets
// a flip-model swap chain, two frames in flight (one command allocator and fence value per back
// buffer), root constants, a sprite overlay from std.dx12_util, resizing the swap chain with the
// window (ResizeBuffers; std.window keeps the loop running while the user drags the window's
// edge), vsync, reporting a removed device, and a clean shutdown that waits for the GPU and
// releases everything.
use std.window
use std.dx12_util

const FRAMES = 2
const FORMAT = DXGI_FORMAT_R8G8B8A8_UNORM

struct Vertex { position: vec2, color: vec4 }

// angle and aspect ratio arrive as root constants
const SHADER = `
cbuffer Params : register(b0) { float angle; float aspect; };
struct V { float4 pos : SV_POSITION; float4 color : COLOR; };
V vs_main(float2 pos : POSITION, float4 color : COLOR) {
    V o;
    float s = sin(angle), c = cos(angle);
    o.pos = float4((pos.x * c - pos.y * s) / aspect, pos.x * s + pos.y * c, 0.0, 1.0);
    o.color = color;
    return o;
}
float4 ps_main(V i) : SV_TARGET { return i.color; }
`

// ---- Direct3D 12 -----------------------------------------------------------------------------

struct App {
    g: Gpu
    swap: *IDXGISwapChain3
    rtv_heap: *ID3D12DescriptorHeap
    targets: [FRAMES]*ID3D12Resource
    allocators: [FRAMES]*ID3D12CommandAllocator
    done: [FRAMES]u64               // the fence value that ends the last frame drawn into each back buffer
    list: *ID3D12GraphicsCommandList
    root: *ID3D12RootSignature
    pipeline: *ID3D12PipelineState
    vertices: *ID3D12Resource
    vertex_view: D3D12_VERTEX_BUFFER_VIEW
    sprites: Sprites
    width: i64                      // of the back buffers
    height: i64
}

// Stops with the HRESULT and, if the device is gone, the reason Direct3D gives for it.
fn fail(app: *App, what: str, hr: i32) -> never {
    eprint(hresult_text(what, hr))
    removed := gpu_removed(&app.g)
    if removed != "" { eprint(removed) }
    exit(2)
}

fn check(app: *App, hr: i32, what: str) {
    if FAILED(hr) { fail(app, what, hr) }
}

fn create_swap_chain(app: *App, hwnd: *u8) {
    desc := DXGI_SWAP_CHAIN_DESC1{
        Width: u32(app.width), Height: u32(app.height), Format: FORMAT, SampleDesc: DXGI_SAMPLE_DESC{Count: 1},
        BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT, BufferCount: FRAMES, SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
    }
    // a Direct3D 12 swap chain presents through the command queue
    swap1: *IDXGISwapChain1
    hr := app.g.factory.CreateSwapChainForHwnd(cast[*IUnknown](app.g.queue), hwnd, &desc, nil, nil, &swap1)
    if FAILED(hr) { fail(app, "CreateSwapChainForHwnd", hr) }
    check(app, swap1.QueryInterface(&IID_IDXGISwapChain3, &app.swap), "QueryInterface IDXGISwapChain3")
    com_release(&swap1)
    app.g.factory.MakeWindowAssociation(hwnd, DXGI_MWA_NO_ALT_ENTER)
    app.rtv_heap = gpu_descriptor_heap(&app.g, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, FRAMES, false)
    create_targets(app)
}

// One render-target view per back buffer.
fn create_targets(app: *App) {
    for i in 0..FRAMES {
        check(app, app.swap.GetBuffer(u32(i), &IID_ID3D12Resource, &app.targets[i]), "IDXGISwapChain::GetBuffer")
        app.g.device.CreateRenderTargetView(app.targets[i], nil, gpu_cpu_handle(&app.g, app.rtv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, i))
    }
}

// Gives the swap chain the window's new size: the GPU must be done with the old back buffers.
fn resize(app: *App, width: i64, height: i64) {
    gpu_flush(&app.g)
    for i in 0..FRAMES {
        com_release(&app.targets[i])
    }
    hr := app.swap.ResizeBuffers(FRAMES, u32(width), u32(height), DXGI_FORMAT_UNKNOWN, 0)
    if FAILED(hr) { fail(app, "IDXGISwapChain::ResizeBuffers", hr) }
    app.width = width
    app.height = height
    create_targets(app)
}

fn create_pipeline(app: *App) {
    param: D3D12_ROOT_PARAMETER
    param.ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS
    param.ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX
    param.u_Constants().Num32BitValues = 2
    root_desc := D3D12_ROOT_SIGNATURE_DESC{NumParameters: 1, pParameters: &param,
        Flags: D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT}
    root, err := dx_root_signature(&app.g, &root_desc)
    if err != "" { panic(err) }
    app.root = root
    vs, verr := dx_compile(SHADER, "vs_main", "vs_5_0")
    if verr != "" { panic(verr) }
    ps, perr := dx_compile(SHADER, "ps_main", "ps_5_0")
    if perr != "" { panic(perr) }
    layout := [2]D3D12_INPUT_ELEMENT_DESC{
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("POSITION"), Format: DXGI_FORMAT_R32G32_FLOAT, AlignedByteOffset: 0},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("COLOR"), Format: DXGI_FORMAT_R32G32B32A32_FLOAT, AlignedByteOffset: 8},
    }
    desc := dx_pipeline_desc(app.root, vs, ps, FORMAT)
    desc.InputLayout = D3D12_INPUT_LAYOUT_DESC{ptr(layout), 2}
    hr := app.g.device.CreateGraphicsPipelineState(&desc, &IID_ID3D12PipelineState, &app.pipeline)
    if FAILED(hr) { fail(app, "CreateGraphicsPipelineState", hr) }
    com_release(&vs)
    com_release(&ps)

    vertices := [3]Vertex{
        Vertex{vec2(0.0, 0.6), vec4(1.0, 0.2, 0.2, 1.0)},
        Vertex{vec2(0.52, -0.3), vec4(0.2, 1.0, 0.2, 1.0)},
        Vertex{vec2(-0.52, -0.3), vec4(0.2, 0.4, 1.0, 1.0)},
    }
    size := sizeof[[3]Vertex]()
    app.vertices = gpu_upload(&app.g, as_bytes(vertices[..]))
    app.vertex_view = D3D12_VERTEX_BUFFER_VIEW{app.vertices.GetGPUVirtualAddress(), u32(size), u32(sizeof[Vertex]())}

    for i in 0..FRAMES {
        check(app, app.g.device.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator,
            &app.allocators[i]), "CreateCommandAllocator")
    }
    check(app, app.g.device.CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, app.allocators[0], nil,
        &IID_ID3D12GraphicsCommandList, &app.list), "CreateCommandList")
    check(app, app.list.Close(), "ID3D12GraphicsCommandList::Close")

    // the overlay: plain rectangles, so the atlas is one white pixel
    white := []u8{255, 255, 255, 255}
    sprites, serr := sprites_new(&app.g, FORMAT, 64, FRAMES, 1, 1, white)
    if serr != "" { panic(serr) }
    app.sprites = sprites
}

// Draws one frame into the current back buffer and presents it; returns Present's HRESULT.
fn render(app: *App, seconds: f32, sync: u32) -> i32 {
    i := i64(app.swap.GetCurrentBackBufferIndex())
    gpu_wait(&app.g, app.done[i])           // the GPU is done with this back buffer's last frame
    list := app.list
    check(app, app.allocators[i].Reset(), "ID3D12CommandAllocator::Reset")
    check(app, list.Reset(app.allocators[i], app.pipeline), "ID3D12GraphicsCommandList::Reset")
    target := app.targets[i]
    dx_barrier(list, target, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET)
    rtv := gpu_cpu_handle(&app.g, app.rtv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, i)
    list.OMSetRenderTargets(1, &rtv, 0, nil)
    background := [4]f32{0.05, 0.07, 0.12, 1.0}
    list.ClearRenderTargetView(rtv, ptr(background), 0, nil)
    viewport := D3D12_VIEWPORT{0.0, 0.0, f32(app.width), f32(app.height), 0.0, 1.0}
    scissor := D3D12_RECT{0, 0, i32(app.width), i32(app.height)}
    list.RSSetViewports(1, &viewport)
    list.RSSetScissorRects(1, &scissor)

    list.SetGraphicsRootSignature(app.root)
    params := [2]f32{seconds, f32(app.width) / f32(app.height)}
    list.SetGraphicsRoot32BitConstants(0, 2, cast[*u8](ptr(params)), 0)
    list.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST)
    list.IASetVertexBuffers(0, 1, &app.vertex_view)
    list.DrawInstanced(3, 1, 0, 0)

    // overlay: a frame around the window and a bar that fills every two seconds
    s := &app.sprites
    w := f32(app.width)
    h := f32(app.height)
    edge := color_u32(vec4(0.9, 0.8, 0.3, 1.0))
    s.sprites_begin(i, app.width, app.height)
    s.sprite_rect(0.0, 0.0, w, 4.0, edge)
    s.sprite_rect(0.0, h - 4.0, w, 4.0, edge)
    s.sprite_rect(0.0, 0.0, 4.0, h, edge)
    s.sprite_rect(w - 4.0, 0.0, 4.0, h, edge)
    s.sprite_rect(16.0, h - 28.0, w - 32.0, 12.0, color_u32(vec4(1.0, 1.0, 1.0, 0.25)))
    s.sprite_rect(16.0, h - 28.0, (w - 32.0) * fmod(seconds, 2.0) / 2.0, 12.0, color_u32(vec4(0.3, 0.9, 0.5, 0.9)))
    s.sprites_draw(list)

    dx_barrier(list, target, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT)
    gpu_execute(&app.g, list)
    hr := app.swap.Present(sync, 0)
    if SUCCEEDED(hr) { app.done[i] = gpu_signal(&app.g) }
    hr
}

fn destroy(app: *App) {
    gpu_flush(&app.g)
    sprites_free(&app.sprites)
    com_release(&app.vertices)
    com_release(&app.pipeline)
    com_release(&app.root)
    com_release(&app.list)
    for i in 0..FRAMES {
        com_release(&app.allocators[i])
        com_release(&app.targets[i])
    }
    com_release(&app.rtv_heap)
    com_release(&app.swap)
    gpu_close(&app.g)
}

fn main() -> i64 {
    vsync := true
    warp := false
    debug := false
    max_frames := -1
    remove_at := -1
    a := args()
    k := 1
    while k < len(a) {
        if a[k] == "--no-vsync" {
            vsync = false
        } else if a[k] == "--warp" {
            warp = true
        } else if a[k] == "--debug" {
            debug = true
        } else if (a[k] == "--frames" || a[k] == "--remove-device") && k + 1 < len(a) {
            n, ok := parse_i64(a[k + 1])
            if !ok { panic(fmt("not a number: ", a[k + 1])) }
            if a[k] == "--frames" { max_frames = n } else { remove_at = n }
            k += 1
        } else {
            eprint(fmt("unknown option ", a[k], " (options: --no-vsync --warp --debug --frames N --remove-device N)"))
            return 1
        }
        k += 1
    }

    app: App
    g, err := gpu_open(debug, warp)
    if err != "" {
        eprint(fmt("no Direct3D 12 device: ", err))
        return 1
    }
    app.g = g
    print(fmt("device: ", g.adapter_name, if g.warp { " (WARP)" } else { "" }))
    w, opened := window_open(WindowDesc{title: "AL Direct3D 12 triangle", width: 1280, height: 720, resizable: true})
    if !opened {
        eprint("cannot open a window")
        gpu_close(&app.g)
        return 1
    }
    width, height := w.size()
    app.width = max(width, 1)
    app.height = max(height, 1)
    create_swap_chain(&app, win32_hwnd(w))
    create_pipeline(&app)

    start := clock_ns()
    frames := 0
    resizes := 0
    while !w.should_close() && frames != max_frames {
        // events: during a drag of the window's edge poll returns every 10-16 ms with the new size
        w.poll()
        inp := &w.input
        if inp.key_pressed(KEY_ESCAPE) {
            w.closing = true
        }
        if inp.key_pressed(KEY_F11) || (inp.key_pressed(KEY_ENTER) && inp.alt_down()) {
            w.set_fullscreen(!w.fullscreen)
        }
        if w.should_close() {
            break
        }
        width, height = w.size()
        if width == 0 || height == 0 {              // nothing to draw into
            sleep_ms(16)
            continue
        }
        if width != app.width || height != app.height {
            resize(&app, width, height)
            resizes += 1
        }
        if frames == remove_at {
            device5: *ID3D12Device5
            if SUCCEEDED(app.g.device.QueryInterface(&IID_ID3D12Device5, &device5)) {
                device5.RemoveDevice()
                com_release(&device5)
            } else {
                eprint("--remove-device: ID3D12Device5 is not available")
            }
        }
        seconds := f32(f64(clock_ns() - start) / 1e9)
        hr := render(&app, seconds, if vsync { 1 } else { 0 })
        if hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET {
            eprint("the GPU device was lost (driver update or crash, GPU reset, or --remove-device)")
        }
        check(&app, hr, "IDXGISwapChain::Present")
        frames += 1
    }
    elapsed := f64(clock_ns() - start) / 1e9
    print(fmt("frames: ", frames, ", resizes: ", resizes, ", ", fmtf(f64(frames) / fmax(elapsed, 1e-9), 1), " frames per second"))
    destroy(&app)
    w.close()
    0
}
