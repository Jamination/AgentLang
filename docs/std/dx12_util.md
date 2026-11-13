# std.dx12_util

`use std.dx12_util` (it loads `std.dx12`). Windows only (`alc build --target windows`). The
set-up code every Direct3D 12 program repeats, written once: opening a device with a WARP
fallback, fence waits, device-removal text, HLSL compilation with the compiler's messages,
buffers, textures, barriers, reading a render target back, and a sprite batcher for 2D games.
Everything else is the plain bindings of [std.dx12](dx12.md); the helpers hand out the same
interface pointers.

Errors: functions that can fail because of the machine (no device, a shader that does not
compile) return `(value, str)` with `""` for success; the rest stop the program with the HRESULT
(`gpu_check`), naming the removal reason if the device is gone.

## Device

```
struct Gpu { factory, adapter, device, queue, fence, fence_event, fence_value: u64, warp: bool, adapter_name: str }

gpu_open(debug: bool, warp_only: bool) -> (Gpu, str)
gpu_close(g: *Gpu)                          // waits for the GPU, releases everything; safe on a half-opened Gpu
gpu_signal(g: *Gpu) -> u64                  // signals the next fence value after the work submitted so far
gpu_wait(g: *Gpu, value: u64)               // blocks until the GPU passed it
gpu_flush(g: *Gpu)                          // gpu_wait(g, gpu_signal(g)): everything submitted is done
gpu_execute(g: *Gpu, list: *ID3D12GraphicsCommandList)   // Close + ExecuteCommandLists
gpu_command_list(g: *Gpu) -> (*ID3D12CommandAllocator, *ID3D12GraphicsCommandList)   // the list is closed
gpu_reset(allocator, list)                  // ready to record again (the GPU must be done with them)
gpu_removed(g: *Gpu) -> str                 // "" while the device works, else the reason (GetDeviceRemovedReason)
gpu_check(g: *Gpu, hr: i32, what: str)      // dx_check that also names the removal reason
hresult_name(hr) -> str    hresult_code(hr) -> str    hresult_text(what, hr) -> str
                                            // "DXGI_ERROR_DEVICE_REMOVED"; "0x887a0005 (DXGI_ERROR_DEVICE_REMOVED)"; "Present failed: HRESULT 0x..."
```

`gpu_open` takes the first hardware adapter (by `EnumAdapters1` order, skipping software
adapters) on which `D3D12CreateDevice` succeeds at feature level 11.0; if there is none, or with
`warp_only`, it takes WARP (`IDXGIFactory4::EnumWarpAdapter`), the software rasterizer every
Windows 10 has (`g.warp` tells which). `debug` enables the debug layer if the Graphics Tools are
installed (its messages go to the debugger output), and asks for a debug DXGI factory, falling
back to a normal one. The device gets one direct command queue and a fence with its event.

A removed device (driver update or crash, GPU hang, TDR) makes `Present` and other calls return
`DXGI_ERROR_DEVICE_REMOVED` / `DXGI_ERROR_DEVICE_RESET` and its fence read as all ones, so
`gpu_wait` returns at once; `gpu_removed` gives the reason. Recovering means closing everything
and calling `gpu_open` again.

## Shaders, root signatures, pipelines

```
dx_compile(source: str, entry: str, target: str) -> (*ID3DBlob, str)   // D3DCompile; on failure the compiler's messages
dx_bytecode(blob: *ID3DBlob) -> D3D12_SHADER_BYTECODE
dx_root_signature(g: *Gpu, desc: *D3D12_ROOT_SIGNATURE_DESC) -> (*ID3D12RootSignature, str)
dx_pipeline_desc(root, vs, ps: *ID3DBlob, format: i32) -> D3D12_GRAPHICS_PIPELINE_STATE_DESC
```

HLSL is compiled at run time by `d3dcompiler_47.dll` (shader model 5.x targets: `vs_5_0`,
`ps_5_0`, ...) with strictness and optimization level 3. `dx_pipeline_desc` fills the usual
defaults: solid fill, no culling, depth test off, blending off (all channels written),
triangles, one render target of `format`, sample count 1; set `InputLayout` and change what
differs (depth: `DepthStencilState`, `DSVFormat`).

## Resources

```
gpu_buffer(g: *Gpu, heap: i32, size: i64, state: u32) -> *ID3D12Resource      // D3D12_HEAP_TYPE_UPLOAD / READBACK / DEFAULT
gpu_upload(g: *Gpu, data: []u8) -> *ID3D12Resource                             // an upload buffer holding data: gpu_upload(g, as_bytes(vertices[..]))
gpu_texture(g, width, height, format: i32, flags: u32, state: u32, clear: *[4]f32) -> *ID3D12Resource   // 2D, default heap
gpu_descriptor_heap(g, kind: i32, count: i64, shader_visible: bool) -> *ID3D12DescriptorHeap
gpu_cpu_handle(g, heap, kind: i32, index: i64) -> D3D12_CPU_DESCRIPTOR_HANDLE
dx_barrier(list, resource, before: u32, after: u32)                            // one transition barrier, all subresources

struct Readback { buffer: *ID3D12Resource, width: i64, height: i64, row_pitch: i64 }
gpu_readback(g, list, texture, state: u32) -> Readback   // records a copy of a 4-byte-per-pixel texture (in `state` before and after)
readback_pixels(r: *Readback) -> []u8                    // after the GPU ran the list: rows packed, width * 4 bytes each
readback_free(r: *Readback)
```

An upload buffer is fine for vertices that change every frame or for small static data; large
static meshes belong in a default-heap buffer filled by `CopyBufferRegion` from an upload buffer.

## Sprites

A batcher for 2D games: textured, tinted, alpha-blended rectangles from one atlas texture, in
pixel coordinates with the origin at the top left, point sampling (pixel art stays sharp), one
draw call per `sprites_draw`. Vertices are written into a persistently mapped upload buffer that
has one region per frame in flight.

```
sprites_new(g: *Gpu, format: i32, capacity: i64, frames: i64, width: i64, height: i64, rgba: []u8) -> (Sprites, str)
sprites_begin(s: *Sprites, frame: i64, width: i64, height: i64)   // frame 0..frames-1; target size in pixels
sprite(s, x, y, w, h: f32, sx, sy, sw, sh: f32, color: u32)       // atlas rectangle (atlas pixels) -> target rectangle; negative sw / sh mirror
sprite_rect(s, x, y, w, h: f32, color: u32)                       // one colour
sprites_draw(s, list)                                             // draws what was added since the last sprites_draw of this frame
sprites_dropped(s) -> i64                                         // sprites beyond the capacity in this frame (not drawn)
sprites_free(s: *Sprites)
```

- `format` is the render target format the pipeline is built for (`DXGI_FORMAT_R8G8B8A8_UNORM`).
- The atlas is `width` x `height` RGBA8 pixels, rows packed, red first (an `Image` of
  [std.image](image.md) with 4 channels: `img.pix`); it is uploaded before `sprites_new` returns.
- Colours are RGBA8 with red in the lowest byte: `color_u32(vec4(r, g, b, a))` of
  [std.math](math.md); `0xffffffff` draws the texels unchanged. Blending is
  `src * a + dst * (1 - a)`.
- `frame` must name a region the GPU is done with: with one back buffer per frame in flight, the
  back buffer index after waiting for its fence (see `examples/dx12_triangle.al`).
- `sprites_draw` sets the pipeline, root signature, descriptor heap, topology and vertex buffer
  of the list; the render target, viewport and scissor rectangle are the caller's. Draw in
  layers by calling it between other drawing.

```
s, err := sprites_new(&g, DXGI_FORMAT_R8G8B8A8_UNORM, 4096, FRAMES, atlas.w, atlas.h, atlas.pix)
...
s.sprites_begin(frame, width, height)
s.sprite(px, py, 32.0, 32.0, 0.0, 0.0, 16.0, 16.0, 0xffffffff)   // a 16 x 16 tile, drawn at twice its size
s.sprite_rect(0.0, 0.0, f32(width), 24.0, color_u32(vec4(0.0, 0.0, 0.0, 0.5)))
s.sprites_draw(list)
```

## Examples and tests

- `examples/dx12_triangle.al`: a std.window window with a flip-model swap chain, two frames in
  flight, resizing, fullscreen, vsync, a sprite overlay, device-removal reporting and a clean shutdown.
- `examples/dx12_starter`, `examples/dx12_breakout`: games on the sprite batcher, through
  `examples/gamekit/screen.al` (swap chain, letterboxed virtual resolution, bitmap-font text).
- `tests/sys/dx12_offscreen.al`: device (and WARP) creation, shader compilation and its error
  text, a depth buffer, triangles, sprites from an atlas, readback; pixels checked at known
  positions.

Under Wine without a display no DXGI factory can be created (`CreateDXGIFactory2` fails with
`DXGI_ERROR_UNSUPPORTED`, because wined3d needs a display driver), so `tests/run.sh --target
windows` reports the offscreen test as SKIP there; on a desktop under Wine and on Windows it runs.
