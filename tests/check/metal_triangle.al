// A triangle with Metal: window, CAMetalLayer, pipeline from Metal Shading Language source,
// vertex buffer, render loop, clean-up. Written against std.metal.
//
// AL has no macOS backend yet, so this program is only type-checked (`alc check`); building it
// reports that its libraries are not Linux libraries. See docs/std/metal.md.
use std.metal

WIDTH :: 800.0
HEIGHT :: 600.0

Vertex :: struct { pos: vec2, color: vec3 }

SHADERS :: `
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float3 color    [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 color;
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}
`

App :: struct {
    app: *NSApplication
    window: *NSWindow
    layer: *CAMetalLayer
    device: *MTLDevice
    queue: *MTLCommandQueue
    pipeline: *MTLRenderPipelineState
    vertices: *MTLBuffer
    frames: i64
}

fail :: (what: str, err: *NSError) -> never {
    panic(fmt(what, ": ", ns_error_text(err)))
}

open_window :: (a: *App) {
    a.app = ns_app()
    a.app.ns_set_activation_policy(NSApplicationActivationPolicyRegular)
    style := NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
    a.window = ns_window_new(WIDTH, HEIGHT, style, "AL + Metal")
    scale := a.window.ns_backing_scale_factor()
    a.layer = ca_metal_layer_new()
    a.layer.ca_set_device(a.device)
    a.layer.ca_set_pixel_format(MTLPixelFormatBGRA8Unorm)
    a.layer.ca_set_framebuffer_only(true)
    a.layer.ca_set_contents_scale(scale)
    a.layer.ca_set_drawable_size(WIDTH * scale, HEIGHT * scale)
    a.layer.ca_set_display_sync_enabled(true)
    a.window.ns_content_view().ns_set_layer(a.layer)
    a.window.ns_make_key_and_order_front()
    a.app.ns_finish_launching()
    a.app.ns_activate()
}

make_pipeline :: (a: *App) {
    err: *NSError
    library := a.device.mtl_new_library_with_source(SHADERS, &err)
    if library == nil {
        fail("shader compilation", err)
    }
    vertex_fn := library.mtl_new_function_with_name("vertex_main")
    fragment_fn := library.mtl_new_function_with_name("fragment_main")

    layout := mtl_vertex_descriptor()
    layout.mtl_set_attribute(0, MTLVertexFormatFloat2, 0, 0)
    layout.mtl_set_attribute(1, MTLVertexFormatFloat3, 8, 0)
    layout.mtl_set_layout(0, u64(sizeof[Vertex]()), MTLVertexStepFunctionPerVertex, 1)

    desc := mtl_render_pipeline_descriptor_new()
    desc.mtl_set_label("triangle pipeline")
    desc.mtl_set_vertex_function(vertex_fn)
    desc.mtl_set_fragment_function(fragment_fn)
    desc.mtl_set_vertex_descriptor(layout)
    desc.mtl_color_attachment(0).mtl_set_pixel_format(MTLPixelFormatBGRA8Unorm)
    a.pipeline = a.device.mtl_new_render_pipeline_state_with_descriptor(desc, &err)
    if a.pipeline == nil {
        fail("pipeline", err)
    }
    objc_release(desc)
    objc_release(vertex_fn)
    objc_release(fragment_fn)
    objc_release(library)
}

make_vertices :: (a: *App) {
    tri := [3]Vertex{
        Vertex{pos: vec2(0.0, 0.6), color: vec3(1.0, 0.0, 0.0)},
        Vertex{pos: vec2(-0.6, -0.6), color: vec3(0.0, 1.0, 0.0)},
        Vertex{pos: vec2(0.6, -0.6), color: vec3(0.0, 0.0, 1.0)},
    }
    a.vertices = a.device.mtl_new_buffer_with_bytes(cast[*u8](ptr(tri)), u64(sizeof[Vertex]() * 3), MTLResourceStorageModeShared)
    a.vertices.mtl_set_label("triangle vertices")
}

// Handles pending events; false when the window was closed or Escape was pressed.
pump_events :: (a: *App) -> bool {
    loop {
        e := a.app.ns_next_event(false)
        if e == nil {
            break
        }
        if e.ns_type() == NSEventTypeKeyDown && e.ns_key_code() == NS_KEY_ESCAPE {
            return false
        }
        a.app.ns_send_event(e)
    }
    return a.window.ns_is_visible()
}

draw :: (a: *App) {
    drawable := a.layer.ca_next_drawable()
    if drawable == nil {
        return
    }
    target := drawable.ca_texture()
    pass := mtl_render_pass_descriptor()
    color := pass.mtl_color_attachment(0)
    color.mtl_set_texture(target)
    color.mtl_set_load_action(MTLLoadActionClear)
    color.mtl_set_store_action(MTLStoreActionStore)
    color.mtl_set_clear_color(MTLClearColor{0.05, 0.05, 0.08, 1.0})

    commands := a.queue.mtl_command_buffer()
    enc := commands.mtl_render_command_encoder_with_descriptor(pass)
    enc.mtl_set_render_pipeline_state(a.pipeline)
    enc.mtl_set_viewport(MTLViewport{0.0, 0.0, f64(target.mtl_width()), f64(target.mtl_height()), 0.0, 1.0})
    enc.mtl_set_cull_mode(MTLCullModeNone)
    enc.mtl_set_vertex_buffer(a.vertices, 0, 0)
    enc.mtl_draw_primitives(MTLPrimitiveTypeTriangle, 0, 3)
    enc.mtl_end_encoding()
    commands.mtl_present_drawable(drawable)
    commands.mtl_commit()
    a.frames += 1
}

main :: () {
    NSApplicationLoad()
    a: App
    a.device = mtl_create_system_default_device()
    if a.device == nil {
        panic("this machine has no Metal device")
    }
    print("device:", a.device.mtl_name())
    a.queue = a.device.mtl_new_command_queue()
    open_window(&a)
    make_pipeline(&a)
    make_vertices(&a)
    start := CACurrentMediaTime()
    running := true
    while running {
        // objects created during a frame are autoreleased: one pool per frame frees them
        pool := objc_autoreleasePoolPush()
        running = pump_events(&a)
        if running {
            draw(&a)
        }
        objc_autoreleasePoolPop(pool)
    }
    print(a.frames, "frames in", CACurrentMediaTime() - start, "seconds")
    objc_release(a.vertices)
    objc_release(a.pipeline)
    objc_release(a.queue)
    objc_release(a.layer)
    a.window.ns_close()
    objc_release(a.device)
}
