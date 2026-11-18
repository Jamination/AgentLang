// Crypt's renderer, Direct3D 12 (Windows only): the maze as one static mesh, gems, wraiths and
// the exit as small meshes with a model matrix each, per-pixel lighting from the player's
// lantern with distance fog, a depth buffer, and the HUD with the sprite batcher and bitmap
// font of ../gamekit. It draws either into a window's swap chain (two frames in flight) or
// into a texture of its own (offscreen: the scripted test), and can read the finished picture
// back into memory for a screenshot.
//
// render_frame reads the game and never changes it.
use std.window
use std.image
use "logic.al"
use "../gamekit/dx12_gpu.al"
use "../gamekit/font.al"

const RENDER_FORMAT = DXGI_FORMAT_R8G8B8A8_UNORM
const DEPTH_FORMAT = DXGI_FORMAT_D32_FLOAT
const MAX_FRAMES = 2
const HUD_H = 270                  // the HUD is drawn in a virtual space 270 pixels high
const FOG = vec4(0.015, 0.012, 0.03, 1.0)

// One corner of a triangle: position, normal and colour (RGBA8, red in the lowest byte).
struct MeshVertex { pos: vec3, normal: vec3, color: u32 }

// The root constants of one draw call: 44 values (the shader's cbuffer, register b0).
struct DrawConsts {
    view_proj: mat4
    model: mat4
    tint: vec4
    eye: vec4             // xyz: the camera, w: the time (flicker)
    fx: vec4              // x: emission, y: fog distance, z: lantern flash, w: unused
}

// A range of vertices of the mesh buffer.
struct Mesh { first: i64, count: i64 }

struct Renderer {
    w: *Window                       // nil: offscreen
    g: Gpu
    swap: *IDXGISwapChain3           // nil: offscreen
    frames: i64
    targets: [MAX_FRAMES]*ID3D12Resource
    allocators: [MAX_FRAMES]*ID3D12CommandAllocator
    done: [MAX_FRAMES]u64            // the fence value of the last frame drawn into each target
    list: *ID3D12GraphicsCommandList
    rtv_heap: *ID3D12DescriptorHeap
    dsv_heap: *ID3D12DescriptorHeap
    depth: *ID3D12Resource
    root: *ID3D12RootSignature
    pipeline: *ID3D12PipelineState
    vertices: *ID3D12Resource
    vertex_view: D3D12_VERTEX_BUFFER_VIEW
    maze: Mesh
    cube: Mesh
    gem: Mesh
    ghost: Mesh
    sprites: Sprites
    font: Font
    width: i64
    height: i64
    frame: i64
    vsync: bool
    resizes: i64
}

priv const MESH_SHADER = `
cbuffer Draw : register(b0) { float4x4 view_proj; float4x4 model; float4 tint; float4 eye; float4 fx; };
struct V { float4 pos : SV_POSITION; float3 world : WORLD; float3 normal : NORMAL; float4 color : COLOR; };
V vs_main(float3 pos : POSITION, float3 normal : NORMAL, float4 color : COLOR) {
    V o;
    float4 w = mul(model, float4(pos, 1.0));
    o.pos = mul(view_proj, w);
    o.world = w.xyz;
    o.normal = mul((float3x3)model, normal);
    o.color = color * tint;
    return o;
}
float4 ps_main(V i) : SV_TARGET {
    float3 n = normalize(i.normal);
    float3 to_eye = eye.xyz - i.world;
    float d = length(to_eye);
    float flicker = 0.93 + 0.07 * sin(eye.w * 13.0) * sin(eye.w * 7.3);
    float lantern = (0.25 + 0.75 * saturate(dot(n, to_eye / d))) * flicker / (1.0 + 0.07 * d * d);
    float sky = 0.10 + 0.06 * saturate(dot(n, normalize(float3(0.3, 1.0, 0.2))));
    float3 c = i.color.rgb * (sky + 1.5 * lantern + fx.z * 2.0 / (1.0 + 0.02 * d * d) + fx.x);
    float fog = saturate(d / fx.y);
    c = lerp(c, float3(0.015, 0.012, 0.03), fog * fog);
    return float4(c, 1.0);
}
`

// ---- meshes ----------------------------------------------------------------------------------

priv fn quad(v: *Vec[MeshVertex], a: vec3, b: vec3, c: vec3, d: vec3, n: vec3, top: u32, bottom: u32) {
    // a b on top, c d below: two triangles
    v.push(MeshVertex{a, n, top})
    v.push(MeshVertex{b, n, top})
    v.push(MeshVertex{c, n, bottom})
    v.push(MeshVertex{c, n, bottom})
    v.push(MeshVertex{b, n, top})
    v.push(MeshVertex{d, n, bottom})
}

priv fn rgb(r: f32, g: f32, b: f32) -> u32 { color_u32(vec4(r, g, b, 1.0)) }

// Floor, ceiling and the wall faces that look into a floor cell; the bottom of each wall is
// darker (a cheap contact shadow), and the stones vary a little from cell to cell.
priv fn build_maze(v: *Vec[MeshVertex]) {
    for r in 0..MAP_H {
        for c in 0..MAP_W {
            if is_wall(c, r) {
                continue
            }
            x0 := f32(c) * CELL
            z0 := f32(r) * CELL
            x1 := x0 + CELL
            z1 := z0 + CELL
            k := f32((c * 7 + r * 13) % 5) * 0.03
            floor_c := if (c + r) % 2 == 0 { rgb(0.34 + k, 0.30 + k, 0.26) } else { rgb(0.28 + k, 0.25 + k, 0.22) }
            quad(v, vec3(x0, 0.0, z0), vec3(x1, 0.0, z0), vec3(x0, 0.0, z1), vec3(x1, 0.0, z1), vec3(0.0, 1.0, 0.0), floor_c, floor_c)
            ceil_c := rgb(0.16, 0.15, 0.17)
            quad(v, vec3(x0, WALL_H, z0), vec3(x1, WALL_H, z0), vec3(x0, WALL_H, z1), vec3(x1, WALL_H, z1), vec3(0.0, -1.0, 0.0), ceil_c, ceil_c)
            top := rgb(0.52 + k, 0.47 + k, 0.40)
            bottom := rgb(0.20, 0.18, 0.16)
            h := WALL_H
            if is_wall(c, r - 1) {
                quad(v, vec3(x0, h, z0), vec3(x1, h, z0), vec3(x0, 0.0, z0), vec3(x1, 0.0, z0), vec3(0.0, 0.0, 1.0), top, bottom)
            }
            if is_wall(c, r + 1) {
                quad(v, vec3(x1, h, z1), vec3(x0, h, z1), vec3(x1, 0.0, z1), vec3(x0, 0.0, z1), vec3(0.0, 0.0, -1.0), top, bottom)
            }
            if is_wall(c - 1, r) {
                quad(v, vec3(x0, h, z1), vec3(x0, h, z0), vec3(x0, 0.0, z1), vec3(x0, 0.0, z0), vec3(1.0, 0.0, 0.0), top, bottom)
            }
            if is_wall(c + 1, r) {
                quad(v, vec3(x1, h, z0), vec3(x1, h, z1), vec3(x1, 0.0, z0), vec3(x1, 0.0, z1), vec3(-1.0, 0.0, 0.0), top, bottom)
            }
        }
    }
}

// A unit cube around the origin (-0.5 .. 0.5), white.
priv fn build_cube(v: *Vec[MeshVertex]) {
    white: u32 = 0xFFFFFFFF
    for axis in 0..3 {
        for side in [_]f32{-1.0, 1.0} {
            n := vec3(0.0)
            n[axis] = side
            u := vec3(0.0)
            u[(axis + 1) % 3] = 0.5
            w := vec3(0.0)
            w[(axis + 2) % 3] = 0.5
            o := n * 0.5
            quad(v, o - u + w, o + u + w, o - u - w, o + u - w, n, white, white)
        }
    }
}

// An octahedron with its points at distance 1 on the axes, white, flat-shaded.
priv fn build_octahedron(v: *Vec[MeshVertex]) {
    white: u32 = 0xFFFFFFFF
    for sy in [_]f32{-1.0, 1.0} {
        for k in 0..4 {
            a := f32(k) * HALF_PI
            p0 := vec3(cos(a), 0.0, sin(a))
            p1 := vec3(cos(a + HALF_PI), 0.0, sin(a + HALF_PI))
            tip := vec3(0.0, sy, 0.0)
            n := normalize(p0 + p1 + tip)
            v.push(MeshVertex{p0, n, white})
            v.push(MeshVertex{p1, n, white})
            v.push(MeshVertex{tip, n, white})
        }
    }
}

priv fn mesh_of(v: *Vec[MeshVertex], first: i64) -> Mesh { Mesh{first, v.len - first} }

// ---- set-up ----------------------------------------------------------------------------------

// The parts shared by both kinds of renderer: pipeline, meshes, sprites. "" or what failed.
priv fn renderer_setup(r: *Renderer) -> str {
    g := &r.g
    assert sizeof[MeshVertex]() == 28 && sizeof[DrawConsts]() == 176, "unexpected layout of the GPU structs"
    params: [1]D3D12_ROOT_PARAMETER
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS
    params[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL
    params[0].u_Constants().Num32BitValues = u32(sizeof[DrawConsts]() / 4)
    root_desc := D3D12_ROOT_SIGNATURE_DESC{NumParameters: 1, pParameters: ptr(params),
        Flags: D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT}
    root, err := dx_root_signature(g, &root_desc)
    if err != "" { return err }
    r.root = root
    vs, verr := dx_compile(MESH_SHADER, "vs_main", "vs_5_0")
    if verr != "" { return verr }
    ps, perr := dx_compile(MESH_SHADER, "ps_main", "ps_5_0")
    if perr != "" { return perr }
    layout := [3]D3D12_INPUT_ELEMENT_DESC{
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("POSITION"), Format: DXGI_FORMAT_R32G32B32_FLOAT, AlignedByteOffset: 0},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("NORMAL"), Format: DXGI_FORMAT_R32G32B32_FLOAT, AlignedByteOffset: 12},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("COLOR"), Format: DXGI_FORMAT_R8G8B8A8_UNORM, AlignedByteOffset: 24},
    }
    desc := dx_pipeline_desc(r.root, vs, ps, RENDER_FORMAT)
    desc.InputLayout = D3D12_INPUT_LAYOUT_DESC{ptr(layout), 3}
    desc.DepthStencilState.DepthEnable = 1
    desc.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL
    desc.DSVFormat = DEPTH_FORMAT
    hr := g.device.CreateGraphicsPipelineState(&desc, &IID_ID3D12PipelineState, &r.pipeline)
    com_release(&vs)
    com_release(&ps)
    if FAILED(hr) { return hresult_text("CreateGraphicsPipelineState (meshes)", hr) }

    v := vec[MeshVertex]()
    build_maze(&v)
    r.maze = mesh_of(&v, 0)
    first := v.len
    build_cube(&v)
    r.cube = mesh_of(&v, first)
    first = v.len
    build_octahedron(&v)
    r.gem = mesh_of(&v, first)
    r.ghost = r.gem
    r.vertices = gpu_upload(g, as_bytes(v.items()))
    r.vertex_view = D3D12_VERTEX_BUFFER_VIEW{r.vertices.GetGPUVirtualAddress(), u32(v.len * sizeof[MeshVertex]()), u32(sizeof[MeshVertex]())}

    for i in 0..r.frames {
        gpu_check(g, g.device.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator,
            &r.allocators[i]), "CreateCommandAllocator")
    }
    gpu_check(g, g.device.CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, r.allocators[0], nil,
        &IID_ID3D12GraphicsCommandList, &r.list), "CreateCommandList")
    gpu_check(g, r.list.Close(), "ID3D12GraphicsCommandList::Close")
    r.rtv_heap = gpu_descriptor_heap(g, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, MAX_FRAMES, false)
    r.dsv_heap = gpu_descriptor_heap(g, D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 1, false)

    atlas := image_new(FONT_ATLAS_W, FONT_ATLAS_H, 4)
    r.font = font_bake(&atlas, 0, 0)
    sprites, serr := sprites_new(g, RENDER_FORMAT, 4096, r.frames, atlas.w, atlas.h, atlas.pix)
    if serr != "" { return serr }
    r.sprites = sprites
    ""
}

// The depth buffer and the render-target views for the current size.
priv fn create_views(r: *Renderer) {
    g := &r.g
    for i in 0..r.frames {
        if r.swap != nil {
            gpu_check(g, r.swap.GetBuffer(u32(i), &IID_ID3D12Resource, &r.targets[i]), "IDXGISwapChain::GetBuffer")
        }
        g.device.CreateRenderTargetView(r.targets[i], nil, gpu_cpu_handle(g, r.rtv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, i))
    }
    clear := D3D12_CLEAR_VALUE{Format: DEPTH_FORMAT}
    clear.u_DepthStencil().Depth = 1.0
    props := D3D12_HEAP_PROPERTIES{Type: D3D12_HEAP_TYPE_DEFAULT, CreationNodeMask: 1, VisibleNodeMask: 1}
    desc := D3D12_RESOURCE_DESC{Dimension: D3D12_RESOURCE_DIMENSION_TEXTURE2D, Width: u64(r.width), Height: u32(r.height),
        DepthOrArraySize: 1, MipLevels: 1, Format: DEPTH_FORMAT, SampleDesc: DXGI_SAMPLE_DESC{Count: 1},
        Flags: D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL}
    gpu_check(g, g.device.CreateCommittedResource(&props, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_DEPTH_WRITE,
        &clear, &IID_ID3D12Resource, &r.depth), "CreateCommittedResource (depth)")
    g.device.CreateDepthStencilView(r.depth, nil, gpu_cpu_handle(g, r.dsv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 0))
}

// A renderer on a window: a flip-model swap chain on its HWND. (renderer, "") or (nil, why).
fn renderer_window(w: *Window, warp: bool) -> (*Renderer, str) {
    gpu, err := gpu_open(false, warp)
    if err != "" {
        return (nil, fmt("no Direct3D 12 device: ", err))
    }
    r := new[Renderer]()
    r.w = w
    r.g = gpu
    r.frames = MAX_FRAMES
    r.vsync = true
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
        gpu_close(&r.g)
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
    (r, "")
}

// A renderer that draws into a texture of `width` x `height` (one frame in flight).
fn renderer_offscreen(width: i64, height: i64, warp: bool) -> (*Renderer, str) {
    gpu, err := gpu_open(false, warp)
    if err != "" {
        return (nil, fmt("no Direct3D 12 device: ", err))
    }
    r := new[Renderer]()
    r.g = gpu
    r.frames = 1
    r.width = width
    r.height = height
    serr := renderer_setup(r)
    if serr != "" {
        renderer_close(r)
        return (nil, serr)
    }
    clear := [4]f32{FOG.x, FOG.y, FOG.z, 1.0}
    r.targets[0] = gpu_texture(&r.g, width, height, RENDER_FORMAT, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
        D3D12_RESOURCE_STATE_PRESENT, &clear)
    create_views(r)
    (r, "")
}

priv fn resize(r: *Renderer, width: i64, height: i64) {
    gpu_flush(&r.g)
    for i in 0..r.frames {
        com_release(&r.targets[i])
    }
    com_release(&r.depth)
    gpu_check(&r.g, r.swap.ResizeBuffers(u32(r.frames), u32(width), u32(height), DXGI_FORMAT_UNKNOWN, 0), "IDXGISwapChain::ResizeBuffers")
    r.width = width
    r.height = height
    r.resizes += 1
    create_views(r)
}

fn renderer_close(r: *Renderer) {
    if r.g.queue != nil {
        gpu_flush(&r.g)
    }
    sprites_free(&r.sprites)
    com_release(&r.list)
    for i in 0..MAX_FRAMES {
        com_release(&r.allocators[i])
        com_release(&r.targets[i])
    }
    com_release(&r.depth)
    com_release(&r.rtv_heap)
    com_release(&r.dsv_heap)
    com_release(&r.vertices)
    com_release(&r.pipeline)
    com_release(&r.root)
    com_release(&r.swap)
    gpu_close(&r.g)
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

// ---- the frame -------------------------------------------------------------------------------

// The camera of the frame: where the eye is and the view-projection matrix.
fn camera(g: *Game, alpha: f32, aspect: f32) -> (vec3, mat4) {
    p := lerp(g.prev_pos, g.pos, alpha)
    yaw := g.yaw
    pitch := g.pitch
    bob: f32 = 0.0
    if g.mode == Title {
        // the title screen looks around the start
        p = g.start
        yaw = f32(g.time) * 0.25
        pitch = -0.1
    } else {
        bob = sin(length(p - g.start) * 4.0) * 0.03
    }
    eye := vec3(p.x, EYE_H + bob, p.y)
    f := forward_of(yaw)
    dir := vec3(f.x * cos(pitch), sin(pitch), f.y * cos(pitch))
    view := look_at(eye, eye + dir, vec3(0.0, 1.0, 0.0))
    proj := perspective(radians(70.0), aspect, 0.05, 80.0)
    (eye, proj * view)
}

priv fn draw(list: *ID3D12GraphicsCommandList, c: *DrawConsts, m: Mesh) {
    list.SetGraphicsRoot32BitConstants(0, u32(sizeof[DrawConsts]() / 4), cast[*u8](c), 0)
    list.DrawInstanced(u32(m.count), 1, u32(m.first), 0)
}

priv fn draw_world(r: *Renderer, g: *Game, alpha: f32) {
    list := r.list
    eye, view_proj := camera(g, alpha, f32(r.width) / f32(max(r.height, 1)))
    t := f32(g.time)
    flash := if g.flash > 0.0 { g.flash / FLASH_TIME } else { 0.0 }
    c := DrawConsts{view_proj: view_proj, model: mat4(1.0), tint: vec4(1.0), eye: vec4(eye, t), fx: vec4(0.0, 22.0, flash, 0.0)}
    list.SetPipelineState(r.pipeline)
    list.SetGraphicsRootSignature(r.root)
    list.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST)
    list.IASetVertexBuffers(0, 1, &r.vertex_view)
    draw(list, &c, r.maze)

    // the exit: a pillar of light once every gem is taken, a dark stone before
    open := exit_open(g) && g.mode != Title
    c.model = translate(vec3(g.exit.x, WALL_H / 2.0, g.exit.y)) * scale(vec3(0.7, WALL_H, 0.7))
    c.tint = if open { vec4(0.3, 1.0, 0.5, 1.0) } else { vec4(0.35, 0.12, 0.12, 1.0) }
    c.fx.x = if open { 0.9 + 0.3 * sin(t * 3.0) } else { 0.05 }
    draw(list, &c, r.cube)

    // gems: spinning, bobbing, glowing
    for i in 0..g.n_gems {
        gem := g.gems[i]
        if gem.taken && g.mode != Title {
            continue
        }
        y := 0.9 + 0.12 * sin(t * 2.0 + f32(i))
        c.model = translate(vec3(gem.pos.x, y, gem.pos.y)) * rotate_y(t * 1.5 + f32(i)) * scale(vec3(0.22, 0.32, 0.22))
        c.tint = if i % 2 == 0 { vec4(1.0, 0.85, 0.2, 1.0) } else { vec4(0.3, 0.9, 1.0, 1.0) }
        c.fx.x = 0.3
        draw(list, &c, r.gem)
    }

    // wraiths: a dark tall body that turns to the player, and two red eyes
    for i in 0..g.n_enemies {
        e := g.enemies[i]
        p := lerp(e.prev, e.pos, alpha)
        to := g.pos - p
        face := atan2(-to.x, -to.y)
        hover := 0.15 * sin(t * 3.0 + f32(i) * 2.0)
        body := translate(vec3(p.x, 1.0 + hover, p.y)) * rotate_y(face)
        stunned := e.stun > 0.0
        c.model = body * scale(vec3(0.38, 0.9, 0.38))
        c.tint = if stunned { vec4(0.5, 0.5, 0.8, 1.0) } else { vec4(0.35, 0.1, 0.45, 1.0) }
        c.fx.x = 0.08
        draw(list, &c, r.ghost)
        c.tint = if stunned { vec4(0.3, 0.3, 0.5, 1.0) } else { vec4(1.0, 0.15, 0.1, 1.0) }
        c.fx.x = if stunned { 0.0 } else { 1.5 }
        for side in [_]f32{-1.0, 1.0} {
            c.model = body * translate(vec3(0.12 * side, 0.35, -0.3)) * scale(vec3(0.08))
            draw(list, &c, r.cube)
        }
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
    target := r.targets[i]
    dx_barrier(list, target, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET)
    rtv := gpu_cpu_handle(&r.g, r.rtv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, i)
    dsv := gpu_cpu_handle(&r.g, r.dsv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 0)
    list.OMSetRenderTargets(1, &rtv, 0, &dsv)
    fog := [4]f32{FOG.x, FOG.y, FOG.z, 1.0}
    list.ClearRenderTargetView(rtv, ptr(fog), 0, nil)
    list.ClearDepthStencilView(dsv, D3D12_CLEAR_FLAG_DEPTH, 1.0, 0, 0, nil)
    viewport := D3D12_VIEWPORT{0.0, 0.0, f32(r.width), f32(r.height), 0.0, 1.0}
    scissor := D3D12_RECT{0, 0, i32(r.width), i32(r.height)}
    list.RSSetViewports(1, &viewport)
    list.RSSetScissorRects(1, &scissor)
    draw_world(r, g, alpha)

    // the HUD over it, without the depth buffer
    list.OMSetRenderTargets(1, &rtv, 0, nil)
    hud_w := HUD_H * r.width / max(r.height, 1)
    s := &r.sprites
    s.sprites_begin(i, hud_w, HUD_H)
    draw_hud(s, r.font, g, f32(hud_w), note)
    s.sprites_draw(list)

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
        shot = readback_image(&rb)
    }
    (shot, "")
}

// ---- the HUD -----------------------------------------------------------------------------------

const WHITE: u32 = 0xFFFFFFFF
const GREY: u32 = 0xFFA0A0A0
const YELLOW: u32 = 0xFF40E0FF
const RED: u32 = 0xFF3030E0
const GREEN: u32 = 0xFF60E060

// A line of text with its top left corner at (x, y), `scale` HUD pixels per font pixel.
fn draw_text(s: *Sprites, f: Font, x: f32, y: f32, scale: f32, text: str, color: u32) {
    cx := x
    for c in text {
        if c != ' ' {
            gx, gy := cell(f, c)
            s.sprite(cx, y, f32(GLYPH_W) * scale, f32(GLYPH_H) * scale, f32(gx), f32(gy), f32(GLYPH_W), f32(GLYPH_H), color)
        }
        cx += f32(GLYPH_ADVANCE) * scale
    }
}

fn draw_text_centered(s: *Sprites, f: Font, x: f32, y: f32, scale: f32, text: str, color: u32) {
    draw_text(s, f, floor(x - text_width(text, scale) / 2.0), y, scale, text, color)
}

priv fn clock_text(seconds: f32) -> str {
    t := i64(seconds)
    fmt(t / 60, ":", fmti(t % 60, 2, '0'))
}

fn draw_hud(s: *Sprites, f: Font, g: *Game, w: f32, note: str) {
    h := f32(HUD_H)
    cx := w / 2.0
    blink := fmod(g.time, 1.0) < 0.6
    match g.mode {
        Title => {
            s.sprite_rect(0.0, 0.0, w, h, 0x88000000)
            draw_text_centered(s, f, cx, 50.0, 6.0, "CRYPT", YELLOW)
            draw_text_centered(s, f, cx, 106.0, 1.0, "TAKE EVERY GEM, THEN FIND THE EXIT. THE WRAITHS HUNT BY SIGHT.", GREY)
            if blink {
                draw_text_centered(s, f, cx, 140.0, 2.0, "PRESS ENTER OR A", WHITE)
            }
            if g.best > 0 {
                draw_text_centered(s, f, cx, 170.0, 1.0, fmt("BEST ", g.best), GREY)
            }
            draw_text_centered(s, f, cx, 200.0, 1.0, "WASD / STICK MOVE    MOUSE / RIGHT STICK LOOK", GREY)
            draw_text_centered(s, f, cx, 212.0, 1.0, "F / RIGHT CLICK / X  LANTERN FLASH STUNS WRAITHS", GREY)
            draw_text_centered(s, f, cx, 224.0, 1.0, "ESC / START PAUSE    F11 FULLSCREEN    ESC QUIT", GREY)
        }
        Playing, Paused => {
            draw_status(s, f, g, w)
            if g.mode == Paused {
                draw_menu(s, f, g, w)
            }
        }
        Won, Lost => {
            draw_status(s, f, g, w)
            s.sprite_rect(0.0, 0.0, w, h, 0x99000000)
            if g.mode == Won {
                draw_text_centered(s, f, cx, 70.0, 4.0, "YOU ESCAPED", GREEN)
            } else {
                draw_text_centered(s, f, cx, 70.0, 4.0, "CAUGHT", RED)
            }
            draw_text_centered(s, f, cx, 120.0, 2.0, fmt("SCORE ", g.score), WHITE)
            draw_text_centered(s, f, cx, 145.0, 1.0, if g.score >= g.best && g.score > 0 { "NEW BEST!" } else { fmt("BEST ", g.best) }, YELLOW)
            if g.end_time > 1.0 && blink {
                draw_text_centered(s, f, cx, 180.0, 1.0, "PRESS ENTER OR A", WHITE)
            }
        }
    }
    if note != "" {
        draw_text(s, f, 4.0, h - 10.0, 1.0, note, 0xFF60C0FF)
    }
}

// The play HUD: gems, life, time, the lantern's charge, a crosshair, a map, a red flash when hurt.
priv fn draw_status(s: *Sprites, f: Font, g: *Game, w: f32) {
    h := f32(HUD_H)
    if g.hurt > 0.0 {
        a := u32(clamp(g.hurt / 1.5, 0.0, 1.0) * 110.0)
        s.sprite_rect(0.0, 0.0, w, h, (a << 24) | 0x000020C0)
    }
    s.sprite_rect(w / 2.0 - 4.0, h / 2.0, 9.0, 1.0, 0xAAFFFFFF)
    s.sprite_rect(w / 2.0, h / 2.0 - 4.0, 1.0, 9.0, 0xAAFFFFFF)
    draw_text(s, f, 8.0, 8.0, 2.0, fmt("GEMS ", g.got, "/", g.n_gems), YELLOW)
    for k in 0..MAX_HP {
        s.sprite_rect(8.0 + f32(k) * 14.0, 28.0, 10.0, 10.0, if k < g.hp { RED } else { 0x66404040 })
    }
    draw_text(s, f, w - 8.0 - text_width("0:00", 2.0), 8.0, 2.0, clock_text(g.run_time), WHITE)
    // the lantern: full when it can flash again
    charge := 1.0 - g.flash_wait / FLASH_WAIT
    s.sprite_rect(8.0, 44.0, 40.0, 4.0, 0x66404040)
    s.sprite_rect(8.0, 44.0, 40.0 * charge, 4.0, if charge >= 1.0 { YELLOW } else { GREY })
    if exit_open(g) && g.mode == Playing {
        draw_text_centered(s, f, w / 2.0, 30.0, 1.0, "THE EXIT IS OPEN", GREEN)
    }
    // the map, bottom right, 3 pixels a cell
    k: f32 = 3.0
    x0 := w - 8.0 - k * f32(MAP_W)
    y0 := h - 8.0 - k * f32(MAP_H)
    s.sprite_rect(x0 - 2.0, y0 - 2.0, k * f32(MAP_W) + 4.0, k * f32(MAP_H) + 4.0, 0x88000000)
    for r in 0..MAP_H {
        for c in 0..MAP_W {
            if is_wall(c, r) {
                s.sprite_rect(x0 + f32(c) * k, y0 + f32(r) * k, k, k, 0xCC786860)
            }
        }
    }
    for i in 0..g.n_gems {
        if !g.gems[i].taken {
            p := g.gems[i].pos / CELL * k
            s.sprite_rect(x0 + p.x - 1.0, y0 + p.y - 1.0, 2.0, 2.0, YELLOW)
        }
    }
    e := g.exit / CELL * k
    s.sprite_rect(x0 + e.x - 1.5, y0 + e.y - 1.5, 3.0, 3.0, if exit_open(g) { GREEN } else { 0xFF303070 })
    p := g.pos / CELL * k
    s.sprite_rect(x0 + p.x - 1.0, y0 + p.y - 1.0, 2.0, 2.0, WHITE)
    d := forward_of(g.yaw) * 3.0
    s.sprite_rect(x0 + p.x + d.x - 0.5, y0 + p.y + d.y - 0.5, 1.0, 1.0, WHITE)
}

priv fn draw_menu(s: *Sprites, f: Font, g: *Game, w: f32) {
    s.sprite_rect(0.0, 0.0, w, f32(HUD_H), 0xAA000000)
    cx := w / 2.0
    draw_text_centered(s, f, cx, 40.0, 3.0, "PAUSED", WHITE)
    labels := [MENU_ITEMS]str{"RESUME", "MUSIC", "SOUND", "MOUSE SPEED", "INVERT LOOK", "FULLSCREEN", "QUIT TO TITLE"}
    left := cx - 90.0
    for i, label in labels {
        y := 84.0 + f32(i) * 16.0
        color := if i == g.menu { YELLOW } else { WHITE }
        if i == g.menu {
            draw_text(s, f, left - 10.0, y, 1.0, ">", YELLOW)
        }
        draw_text(s, f, left, y, 1.0, label, color)
        level := match i { MENU_MUSIC => g.settings.music; MENU_SOUND => g.settings.sound; MENU_MOUSE => g.settings.mouse; _ => -1 }
        if level >= 0 {
            for k in 0..VOLUME_STEPS {
                s.sprite_rect(left + 100.0 + f32(k) * 7.0, y, 5.0, 7.0, if k < level { color } else { 0xFF404040 })
            }
        }
        if i == MENU_INVERT {
            draw_text(s, f, left + 100.0, y, 1.0, if g.settings.invert { "ON" } else { "OFF" }, color)
        }
    }
    draw_text_centered(s, f, cx, 210.0, 1.0, "UP / DOWN CHOOSE    LEFT / RIGHT CHANGE    ESC / B BACK", GREY)
}
