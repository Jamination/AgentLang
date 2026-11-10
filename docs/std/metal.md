# std.metal

`use std.metal`. Apple's Metal through the Objective-C runtime, hand-written: the core Metal
API (`mtl_`), `CAMetalLayer` (`ca_`), the AppKit pieces needed to open a window and pump
events (`ns_`), and the runtime itself (`objc_`, `sel`, the `msg_*` family).

**Status: type-check only.** `alc` emits x86-64 Linux executables. A program that uses this
module passes `alc check` (which also checks every function of the module), but
`alc build` stops with

```
error: `NSApplicationLoad` is imported from `/System/Library/Frameworks/AppKit.framework/AppKit`, which is not a Linux library; ...
```

A macOS backend needs a Mach-O writer and an arm64 code generator (or x86-64 with the macOS
conventions below). The module has never been executed; it has been written against Apple's
documented selectors and enum values and is checked only by the type checker.

## How it maps

- **Objects** are typed pointers to empty structs (`*MTLDevice`, `*MTLTexture`, `*NSWindow`),
  so passing a texture where a buffer is expected is a compile error. nil is a valid receiver:
  a message to nil does nothing, as in Objective-C.
- **Methods** are functions named after the selector in snake_case with a prefix, taking the
  receiver first: `[device newCommandQueue]` is `device.mtl_new_command_queue()`,
  `[encoder setVertexBuffer:offset:atIndex:]` is `enc.mtl_set_vertex_buffer(buf, 0, 0)`.
  Property setters are `mtl_set_<property>`. Overloading on the receiver type keeps names
  short (`mtl_set_pixel_format` exists for texture descriptors and for pipeline attachments).
- **Selectors** are registered on first use and cached in a global per selector.
- **Messages** go through `objc_msgSend` cast to the C signature of the message; the `msg_*`
  functions name the signature (`msg_void_puu`: returns nothing, takes pointer, u64, u64). Use
  them to send messages the module does not wrap.
- **Enums** (`NSUInteger`) are `u64` constants with Apple's names and values:
  `MTLPixelFormatBGRA8Unorm`, `MTLLoadActionClear`, `MTLPrimitiveTypeTriangle`, ...
- **Strings**: AL `str` parameters are converted to `NSString` inside the wrappers;
  `ns_string(s)` / `ns_string_text(ns)` convert explicitly; `ns_error_text(err)` is the
  description of an `NSError`.
- **Ownership**: functions named `mtl_new_...` or `..._new` return an object the caller owns
  and must `objc_release`; everything else is autoreleased. Wrap each frame in
  `objc_autoreleasePoolPush()` / `objc_autoreleasePoolPop(pool)`.

## Structs passed by value

`MTLOrigin`, `MTLSize`, `MTLRegion`, `MTLClearColor`, `MTLViewport`, `MTLScissorRect` are C
structs that Objective-C passes by value. The wrappers take them by value and lower the call
the way the arm64 ABI does: a struct of up to four doubles (`MTLClearColor`) travels as that
many floating-point arguments, any other struct larger than 16 bytes as a pointer to a copy.
On x86-64 macOS such structs are copied onto the stack instead, so a backend for that target
has to lower these calls itself: `mtl_set_clear_color`, `mtl_set_viewport`,
`mtl_set_scissor_rect`, `mtl_replace_region`, `mtl_get_bytes`, `mtl_copy_from_texture`,
`mtl_dispatch_threadgroups`.

## Contents

| Area | Functions |
|------|-----------|
| runtime | `objc_getClass`, `sel_registerName`, `objc_class`, `sel`, `objc_new`, `objc_retain`, `objc_release`, autorelease pools, `objc_allocateClassPair` / `class_addMethod` / `objc_registerClassPair` (delegates written in AL) |
| AppKit | `ns_app`, activation policy, `ns_window_new`, `ns_content_view`, `ns_set_layer`, `ns_next_event`, `ns_send_event`, `ns_type`, `ns_key_code`, `ns_is_visible`, `ns_close` |
| CAMetalLayer | `ca_metal_layer_new`, device / pixel format / drawable size / contents scale / display sync, `ca_next_drawable`, `ca_texture` |
| device | command queue, buffers (`with_length`, `with_bytes`), textures, sampler states, depth-stencil states, libraries from source, functions, render and compute pipeline states |
| descriptors | texture, sampler, depth-stencil and stencil, vertex descriptor (`mtl_set_attribute`, `mtl_set_layout`), render pipeline and its colour attachments (format, blending), render pass and its attachments (texture, load / store actions, clear values) |
| command buffer | `mtl_command_buffer`, render / blit / compute encoders, `mtl_present_drawable`, `mtl_commit`, `mtl_wait_until_completed`, `mtl_status`, `mtl_error` |
| render encoder | pipeline and depth-stencil state, viewport, scissor, winding, culling, fill mode, depth bias, blend colour, stencil reference, vertex / fragment buffers, bytes, textures and samplers, `mtl_draw_primitives`, `mtl_draw_indexed_primitives` (plain and instanced) |
| blit / compute | buffer and texture copies, mipmap generation; compute pipeline, buffers, textures, `mtl_dispatch_threadgroups` |

## Sample

`tests/check/metal_triangle.al` is a complete triangle program:

1. `mtl_create_system_default_device`, command queue.
2. `open_window`: `NSApplication`, a titled window, a `CAMetalLayer` attached to its content view.
3. `make_pipeline`: Metal Shading Language in a raw string compiled with
   `mtl_new_library_with_source`, vertex descriptor matching the AL `Vertex` struct
   (`vec2` + `vec3`), render pipeline state.
4. `make_vertices`: a shared-storage buffer filled from an AL array.
5. Loop: one autorelease pool per frame, `pump_events`, `draw` (next drawable, render pass
   with a clear colour, encoder, draw, present, commit).
6. Releases what it owns.
