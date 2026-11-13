// Direct3D 12 without a window: on the first hardware adapter (else WARP), and again on WARP,
// clear a 64 x 64 render target and a depth buffer, draw two triangles with HLSL compiled at
// run time by D3DCompile (one in front of the cleared depth, one behind it), draw sprites with
// std.dx12_util's batcher (an atlas texture, one-colour and half-transparent rectangles), copy
// the target to a readback buffer and check pixels at known positions.
//
// Windows only. Without a Direct3D 12 device (Wine without a display: CreateDXGIFactory2 fails
// with DXGI_ERROR_UNSUPPORTED) it says why and ends with status 77, which tests/run.sh reports
// as SKIP.
use std.dx12_util

const SIZE = 64
const CLEAR = [4]f32{0.2, 0.4, 0.6, 1.0}

struct Vertex { position: vec3, color: vec4 }

const TRIANGLE = `
struct V { float4 pos : SV_POSITION; float4 color : COLOR; };
V vs_main(float3 pos : POSITION, float4 color : COLOR) {
    V o;
    o.pos = float4(pos, 1.0);
    o.color = color;
    return o;
}
float4 ps_main(V i) : SV_TARGET { return i.color; }
`

// A pixel to check: where, what is expected there (R, G, B, A), and what should be drawn there.
struct Probe { x: i64, y: i64, want: [4]i64, what: str }

const PROBES = [_]Probe{
    Probe{60, 2, [4]i64{51, 102, 153, 255}, "clear colour"},
    Probe{2, 30, [4]i64{51, 102, 153, 255}, "clear colour"},
    Probe{32, 36, [4]i64{255, 0, 0, 255}, "triangle"},
    Probe{20, 44, [4]i64{255, 0, 0, 255}, "triangle"},
    Probe{14, 44, [4]i64{51, 102, 153, 255}, "clear colour beside the triangle"},
    Probe{54, 10, [4]i64{51, 102, 153, 255}, "clear colour: a triangle behind the cleared depth"},
    Probe{4, 4, [4]i64{255, 0, 0, 255}, "sprite: atlas texel (0, 0)"},
    Probe{12, 4, [4]i64{0, 255, 0, 255}, "sprite: atlas texel (1, 0)"},
    Probe{4, 12, [4]i64{0, 0, 255, 255}, "sprite: atlas texel (0, 1)"},
    Probe{12, 12, [4]i64{255, 255, 255, 255}, "sprite: atlas texel (1, 1)"},
    Probe{18, 4, [4]i64{51, 102, 153, 255}, "clear colour beside the sprite"},
    Probe{56, 56, [4]i64{0, 255, 0, 255}, "rectangle"},
    Probe{4, 52, [4]i64{153, 179, 204, 255}, "half-transparent white over the clear colour"},
    Probe{28, 4, [4]i64{0, 255, 0, 255}, "mirrored sprite: atlas texel (1, 0) on the left"},
    Probe{36, 4, [4]i64{255, 0, 0, 255}, "mirrored sprite: atlas texel (0, 0) on the right"},
}

// Renders the scene on `g` and returns the pixels of the render target (rows packed, RGBA8).
fn render(g: *Gpu) -> []u8 {
    // the render target (with CLEAR as its optimized clear value) and its view
    clear := CLEAR
    target := gpu_texture(g, SIZE, SIZE, DXGI_FORMAT_R8G8B8A8_UNORM, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
        D3D12_RESOURCE_STATE_RENDER_TARGET, &clear)
    rtv_heap := gpu_descriptor_heap(g, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1, false)
    rtv := gpu_cpu_handle(g, rtv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 0)
    g.device.CreateRenderTargetView(target, nil, rtv)

    // a depth buffer, cleared to 0.5 below (ClearDepthStencilView: a float in the fourth
    // register, a byte on the stack)
    depth_clear := D3D12_CLEAR_VALUE{Format: DXGI_FORMAT_D32_FLOAT}
    depth_clear.u_DepthStencil().Depth = 0.5
    props := D3D12_HEAP_PROPERTIES{Type: D3D12_HEAP_TYPE_DEFAULT, CreationNodeMask: 1, VisibleNodeMask: 1}
    depth_desc := D3D12_RESOURCE_DESC{Dimension: D3D12_RESOURCE_DIMENSION_TEXTURE2D, Width: SIZE, Height: SIZE, DepthOrArraySize: 1,
        MipLevels: 1, Format: DXGI_FORMAT_D32_FLOAT, SampleDesc: DXGI_SAMPLE_DESC{Count: 1}, Flags: D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL}
    depth: *ID3D12Resource
    gpu_check(g, g.device.CreateCommittedResource(&props, D3D12_HEAP_FLAG_NONE, &depth_desc, D3D12_RESOURCE_STATE_DEPTH_WRITE,
        &depth_clear, &IID_ID3D12Resource, &depth), "CreateCommittedResource (depth)")
    dsv_heap := gpu_descriptor_heap(g, D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 1, false)
    dsv := gpu_cpu_handle(g, dsv_heap, D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 0)
    g.device.CreateDepthStencilView(depth, nil, dsv)

    // the triangle's pipeline: no root parameters, vertices from an upload buffer
    root_desc := D3D12_ROOT_SIGNATURE_DESC{Flags: D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT}
    root, err := dx_root_signature(g, &root_desc)
    assert err == "", err
    vs, verr := dx_compile(TRIANGLE, "vs_main", "vs_5_0")
    assert verr == "", verr
    ps, perr := dx_compile(TRIANGLE, "ps_main", "ps_5_0")
    assert perr == "", perr
    layout := [2]D3D12_INPUT_ELEMENT_DESC{
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("POSITION"), Format: DXGI_FORMAT_R32G32B32_FLOAT, AlignedByteOffset: 0},
        D3D12_INPUT_ELEMENT_DESC{SemanticName: ptr("COLOR"), Format: DXGI_FORMAT_R32G32B32A32_FLOAT, AlignedByteOffset: 12},
    }
    desc := dx_pipeline_desc(root, vs, ps, DXGI_FORMAT_R8G8B8A8_UNORM)
    desc.InputLayout = D3D12_INPUT_LAYOUT_DESC{ptr(layout), 2}
    desc.DepthStencilState.DepthEnable = 1
    desc.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL
    desc.DSVFormat = DXGI_FORMAT_D32_FLOAT
    pipeline: *ID3D12PipelineState
    dx_check(g.device.CreateGraphicsPipelineState(&desc, &IID_ID3D12PipelineState, &pipeline), "CreateGraphicsPipelineState")
    com_release(&vs)
    com_release(&ps)
    red := vec4(1.0, 0.0, 0.0, 1.0)
    vertices := [6]Vertex{
        Vertex{vec3(-0.5, -0.5, 0.25), red}, Vertex{vec3(0.0, 0.5, 0.25), red}, Vertex{vec3(0.5, -0.5, 0.25), red},
        Vertex{vec3(0.5, 0.9, 0.75), red}, Vertex{vec3(0.9, 0.9, 0.75), red}, Vertex{vec3(0.7, 0.5, 0.75), red},
    }
    vbuf := gpu_upload(g, as_bytes(vertices[..]))
    vview := D3D12_VERTEX_BUFFER_VIEW{vbuf.GetGPUVirtualAddress(), u32(sizeof[[6]Vertex]()), u32(sizeof[Vertex]())}

    // the sprite batcher with a 2 x 2 atlas: red, green / blue, white
    atlas := []u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255}
    sprites, serr := sprites_new(g, DXGI_FORMAT_R8G8B8A8_UNORM, 16, 1, 2, 2, atlas)
    assert serr == "", serr

    allocator, list := gpu_command_list(g)
    gpu_reset(allocator, list)
    list.ClearRenderTargetView(rtv, ptr(clear), 0, nil)
    list.ClearDepthStencilView(dsv, D3D12_CLEAR_FLAG_DEPTH, 0.5, 0, 0, nil)
    list.OMSetRenderTargets(1, &rtv, 0, &dsv)
    viewport := D3D12_VIEWPORT{0.0, 0.0, f32(SIZE), f32(SIZE), 0.0, 1.0}
    scissor := D3D12_RECT{0, 0, SIZE, SIZE}
    list.RSSetViewports(1, &viewport)
    list.RSSetScissorRects(1, &scissor)
    list.SetPipelineState(pipeline)
    list.SetGraphicsRootSignature(root)
    list.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST)
    list.IASetVertexBuffers(0, 1, &vview)
    list.DrawInstanced(6, 1, 0, 0)
    list.OMSetRenderTargets(1, &rtv, 0, nil)    // the sprite pipeline has no depth buffer

    sprites.sprites_begin(0, SIZE, SIZE)
    sprites.sprite(0.0, 0.0, 16.0, 16.0, 0.0, 0.0, 2.0, 2.0, 0xffffffff)
    sprites.sprite(24.0, 0.0, 16.0, 8.0, 2.0, 0.0, -2.0, 1.0, 0xffffffff)     // the top row, mirrored
    sprites.sprite_rect(48.0, 48.0, 16.0, 16.0, color_u32(vec4(0.0, 1.0, 0.0, 1.0)))
    sprites.sprite_rect(0.0, 48.0, 8.0, 8.0, color_u32(vec4(1.0, 1.0, 1.0, 0.5)))
    sprites.sprites_draw(list)

    back := gpu_readback(g, list, target, D3D12_RESOURCE_STATE_RENDER_TARGET)
    gpu_execute(g, list)
    gpu_flush(g)
    removed := gpu_removed(g)
    assert removed == "", removed
    pixels := readback_pixels(&back)

    readback_free(&back)
    sprites_free(&sprites)
    com_release(&list)
    com_release(&allocator)
    com_release(&vbuf)
    com_release(&pipeline)
    com_release(&root)
    com_release(&rtv_heap)
    com_release(&dsv_heap)
    com_release(&depth)
    com_release(&target)
    pixels
}

// Checks the probes; prints one line per probe. Returns the number of wrong pixels.
fn check(pixels: []u8) -> i64 {
    wrong := 0
    for p in PROBES {
        i := (p.y * SIZE + p.x) * 4
        good := true
        for c in 0..4 {
            if abs(i64(pixels[i + c]) - p.want[c]) > 1 { good = false }
        }
        if good {
            print("  ok", p.x, p.y, p.what)
        } else {
            print("  WRONG", p.x, p.y, p.what, "want", p.want, "got", pixels[i..i + 4])
            wrong += 1
        }
    }
    wrong
}

fn main() -> i64 {
    wrong := 0
    for warp in []bool{false, true} {
        g, err := gpu_open(false, warp)
        if err != "" {
            if !warp {
                print("no Direct3D 12 device:", err)    // the first line: tests/run.sh shows it with SKIP
                return 77
            }
            print("WARP:", err)
            return 1
        }
        if !warp {
            // the shader compiler reports errors as text
            _, cerr := dx_compile("float4 main() : SV_TARGET { return undefined_name; }", "main", "ps_5_0")
            print("compile error reported:", cerr != "" && find(cerr, "undefined_name") >= 0)
        }
        eprint(fmt("device: ", g.adapter_name, if g.warp { " (WARP)" } else { "" }))
        print(if warp { "WARP device" } else { "first device" })
        wrong += check(render(&g))
        gpu_close(&g)
    }
    if wrong == 0 { 0 } else { 1 }
}
