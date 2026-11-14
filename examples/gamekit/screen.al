// A std.window window drawn with Direct3D 12 (Windows only): a flip-model swap chain on the
// window's HWND, two frames in flight, and the sprite batcher of dx12_gpu.al drawing at a fixed
// virtual resolution that is scaled to the window with its aspect ratio kept (black bars).
// It resizes the swap chain when the window's size changes (also during a drag of its edge,
// while std.window keeps the loop running), and reports a removed device.
//
//   sc, err := screen_open(w, 320, 180, atlas, 4096, false)
//   loop {
//       w.poll()
//       s := sc.screen_begin(0xff000000)           // waits for a free back buffer
//       s.sprite(...)  draw_text(s, font, ...)      // virtual pixels, origin top left
//       err = sc.screen_end()                       // draws, presents; "" or why it failed
//   }
//   screen_close(sc)
use std.window
use std.image
use "dx12_gpu.al"
use "font.al"

const SCREEN_FRAMES = 2
const SCREEN_FORMAT = DXGI_FORMAT_R8G8B8A8_UNORM

struct Screen {
    w: *Window
    g: Gpu
    swap: *IDXGISwapChain3
    rtv_heap: *ID3D12DescriptorHeap
    targets: [SCREEN_FRAMES]*ID3D12Resource
    allocators: [SCREEN_FRAMES]*ID3D12CommandAllocator
    done: [SCREEN_FRAMES]u64     // the fence value that ends the last frame drawn into each back buffer
    list: *ID3D12GraphicsCommandList
    sprites: Sprites
    width: i64                   // of the back buffers (the window's client area)
    height: i64
    view_w: i64                  // the virtual resolution the game draws in
    view_h: i64
    view: (i64, i64, i64, i64)   // where it lands in the window: x, y, width, height
    frame: i64                   // the back buffer of the frame between screen_begin and screen_end
    vsync: bool
    resizes: i64
    occluded: bool               // the last Present found the window invisible (minimized)
}

// Opens the GPU (`warp`: the software rasterizer) and a swap chain on the window. `atlas` is
// the sprite atlas (4 channels), `capacity` the most sprites per frame. Returns (screen, "")
// or (nil, why it failed).
fn screen_open(w: *Window, view_w: i64, view_h: i64, atlas: Image, capacity: i64, warp: bool) -> (*Screen, str) {
    assert atlas.channels == 4, "screen_open: the atlas needs 4 channels"
    g, err := gpu_open(false, warp)
    if err != "" {
        return (nil, fmt("no Direct3D 12 device: ", err))
    }
    sc := new[Screen]()
    sc.w = w
    sc.g = g
    sc.view_w = view_w
    sc.view_h = view_h
    sc.vsync = true
    width, height := w.size()
    sc.width = max(width, 1)
    sc.height = max(height, 1)
    desc := DXGI_SWAP_CHAIN_DESC1{
        Width: u32(sc.width), Height: u32(sc.height), Format: SCREEN_FORMAT, SampleDesc: DXGI_SAMPLE_DESC{Count: 1},
        BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT, BufferCount: SCREEN_FRAMES, SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
    }
    // a Direct3D 12 swap chain presents through the command queue
    swap1: *IDXGISwapChain1
    hr := sc.g.factory.CreateSwapChainForHwnd(cast[*IUnknown](sc.g.queue), win32_hwnd(w), &desc, nil, nil, &swap1)
    if FAILED(hr) {
        gpu_close(&sc.g)
        return (nil, hresult_text("CreateSwapChainForHwnd", hr))
    }
    sc.g.gpu_check(swap1.QueryInterface(&IID_IDXGISwapChain3, &sc.swap), "QueryInterface IDXGISwapChain3")
    com_release(&swap1)
    // fullscreen is std.window's borderless window (set_fullscreen), not DXGI's Alt+Enter
    sc.g.factory.MakeWindowAssociation(win32_hwnd(w), DXGI_MWA_NO_ALT_ENTER)
    sc.rtv_heap = gpu_descriptor_heap(&sc.g, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, SCREEN_FRAMES, false)
    create_targets(sc)
    for i in 0..SCREEN_FRAMES {
        sc.g.gpu_check(sc.g.device.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator,
            &sc.allocators[i]), "CreateCommandAllocator")
    }
    sc.g.gpu_check(sc.g.device.CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, sc.allocators[0], nil,
        &IID_ID3D12GraphicsCommandList, &sc.list), "CreateCommandList")
    sc.g.gpu_check(sc.list.Close(), "ID3D12GraphicsCommandList::Close")
    sprites, serr := sprites_new(&sc.g, SCREEN_FORMAT, capacity, SCREEN_FRAMES, atlas.w, atlas.h, atlas.pix)
    if serr != "" {
        screen_close(sc)
        return (nil, serr)
    }
    sc.sprites = sprites
    sc.view = fit_rect(sc.width, sc.height, view_w, view_h)
    (sc, "")
}

// One render-target view per back buffer.
priv fn create_targets(sc: *Screen) {
    for i in 0..SCREEN_FRAMES {
        sc.g.gpu_check(sc.swap.GetBuffer(u32(i), &IID_ID3D12Resource, &sc.targets[i]), "IDXGISwapChain::GetBuffer")
        sc.g.device.CreateRenderTargetView(sc.targets[i], nil, gpu_cpu_handle(&sc.g, sc.rtv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, i))
    }
}

// Gives the swap chain the window's size: the GPU must be done with the old back buffers.
priv fn resize(sc: *Screen, width: i64, height: i64) {
    gpu_flush(&sc.g)
    for i in 0..SCREEN_FRAMES {
        com_release(&sc.targets[i])
    }
    sc.g.gpu_check(sc.swap.ResizeBuffers(SCREEN_FRAMES, u32(width), u32(height), DXGI_FORMAT_UNKNOWN, 0), "IDXGISwapChain::ResizeBuffers")
    sc.width = width
    sc.height = height
    sc.view = fit_rect(width, height, sc.view_w, sc.view_h)
    sc.resizes += 1
    create_targets(sc)
}

// Starts a frame: follows the window's size, waits until the GPU is done with the next back
// buffer, clears it to black and the game's area to `background` (RGBA8, red in the lowest
// byte). Returns the sprite batcher, set up for the virtual resolution.
fn screen_begin(sc: *Screen, background: u32) -> *Sprites {
    width, height := sc.w.size()
    if width > 0 && height > 0 && (width != sc.width || height != sc.height) {
        resize(sc, width, height)
    }
    i := i64(sc.swap.GetCurrentBackBufferIndex())
    sc.frame = i
    gpu_wait(&sc.g, sc.done[i])
    list := sc.list
    sc.g.gpu_check(sc.allocators[i].Reset(), "ID3D12CommandAllocator::Reset")
    sc.g.gpu_check(list.Reset(sc.allocators[i], nil), "ID3D12GraphicsCommandList::Reset")
    dx_barrier(list, sc.targets[i], D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET)
    rtv := gpu_cpu_handle(&sc.g, sc.rtv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, i)
    list.OMSetRenderTargets(1, &rtv, 0, nil)
    black := [4]f32{0.0, 0.0, 0.0, 1.0}
    list.ClearRenderTargetView(rtv, ptr(black), 0, nil)
    // the viewport maps the virtual resolution onto the letterboxed rectangle
    vx, vy, vw, vh := sc.view
    viewport := D3D12_VIEWPORT{f32(vx), f32(vy), f32(vw), f32(vh), 0.0, 1.0}
    scissor := D3D12_RECT{i32(vx), i32(vy), i32(vx + vw), i32(vy + vh)}
    list.RSSetViewports(1, &viewport)
    list.RSSetScissorRects(1, &scissor)
    s := &sc.sprites
    s.sprites_begin(i, sc.view_w, sc.view_h)
    s.sprite_rect(0.0, 0.0, f32(sc.view_w), f32(sc.view_h), background)
    s
}

// Draws the sprites of the frame and presents it (with vsync unless sc.vsync is false).
// "" or what failed (the device was removed: the reason).
fn screen_end(sc: *Screen) -> str {
    i := sc.frame
    list := sc.list
    sc.sprites.sprites_draw(list)
    dx_barrier(list, sc.targets[i], D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT)
    gpu_execute(&sc.g, list)
    hr := sc.swap.Present(if sc.vsync { 1 } else { 0 }, 0)
    if FAILED(hr) {
        removed := gpu_removed(&sc.g)
        return if removed == "" { hresult_text("IDXGISwapChain::Present", hr) } else { removed }
    }
    sc.done[i] = gpu_signal(&sc.g)
    // a minimized window presents at once: no vsync paces the loop then
    sc.occluded = hr == DXGI_STATUS_OCCLUDED
    if sc.occluded {
        sleep_ms(16)
    }
    ""
}

// A window position (mouse) in virtual pixels.
fn screen_to_view(sc: *Screen, p: vec2) -> vec2 {
    vx, vy, vw, vh := sc.view
    (p - vec2(f32(vx), f32(vy))) * vec2(f32(sc.view_w) / f32(max(vw, 1)), f32(sc.view_h) / f32(max(vh, 1)))
}

// Waits for the GPU and releases everything (not the window).
fn screen_close(sc: *Screen) {
    if sc.g.queue != nil {
        gpu_flush(&sc.g)
    }
    sprites_free(&sc.sprites)
    com_release(&sc.list)
    for i in 0..SCREEN_FRAMES {
        com_release(&sc.allocators[i])
        com_release(&sc.targets[i])
    }
    com_release(&sc.rtv_heap)
    com_release(&sc.swap)
    gpu_close(&sc.g)
}

// Draws a line of text with its top left corner at (x, y), each font pixel `scale` virtual
// pixels large; '\n' starts a new line.
fn draw_text(s: *Sprites, f: Font, x: f32, y: f32, scale: f32, text: str, color: u32) {
    cx := x
    for c in text {
        if c == '\n' {
            cx = x
            y += f32(LINE_ADVANCE) * scale
            continue
        }
        if c != ' ' {
            gx, gy := cell(f, c)
            s.sprite(cx, y, f32(GLYPH_W) * scale, f32(GLYPH_H) * scale, f32(gx), f32(gy), f32(GLYPH_W), f32(GLYPH_H), color)
        }
        cx += f32(GLYPH_ADVANCE) * scale
    }
}

// The same, centered on x.
fn draw_text_centered(s: *Sprites, f: Font, x: f32, y: f32, scale: f32, text: str, color: u32) {
    draw_text(s, f, floor(x - text_width(text, scale) / 2.0), y, scale, text, color)
}
