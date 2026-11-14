# std.vk: Vulkan bindings

The bindings import `libvulkan.so.1`: Linux only, with `--target windows` `use std.vk` is a
compile error.

`use std.vk` gives an AL program the Vulkan API: core 1.0 to 1.3 plus `VK_KHR_surface`,
`VK_KHR_swapchain`, `VK_KHR_xlib_surface`, `VK_KHR_xcb_surface`, `VK_KHR_wayland_surface`,
`VK_EXT_debug_utils`, `VK_EXT_layer_settings`, `VK_EXT_memory_budget` and
`VK_EXT_memory_priority`. It is a binding and nothing else: the names, structs and call
sequences are those of the C API, so the Vulkan specification and any C tutorial apply
directly. What the module adds is only what the C headers themselves provide or what AL needs
to express a C construct (see [Glue](#glue)). Device set-up, memory allocation, error policy,
shader loading and rendering are the program's code: [examples/vk_renderer](#example-walk-through-examplesvk_renderer)
shows all of it written on the bindings alone.

The module is generated: `std/vk.al` is written by `tools/gen_vk.al` from the Khronos registry
(`vk.xml`), followed by the version macros of `tools/vk_helpers.al`. It contains 305 structs,
about 1200 constants and 235 functions. Using it costs about 10 ms of compile time.

A program that calls a Vulkan function is dynamically linked against `libvulkan.so.1` (the
Vulkan loader), which must be installed together with a driver.

## Mapping rules

| C | AL |
|---|----|
| dispatchable handle: `VkInstance`, `VkPhysicalDevice`, `VkDevice`, `VkQueue`, `VkCommandBuffer` | `*u8` (`nil` = no handle) |
| non-dispatchable handle: `VkBuffer`, `VkImage`, `VkPipeline`, `VkSurfaceKHR`, ... | `u64` (`0` or `VK_NULL_HANDLE` = no handle) |
| enum (`VkFormat`, `VkResult`, `VkStructureType`, ...) | `i32`; values are constants with the C names: `const VK_FORMAT_R8G8B8A8_UNORM: i32 = 37` |
| flags (`VkImageUsageFlags`) and flag bits (`VK_IMAGE_USAGE_SAMPLED_BIT`) | `u32`; combine with `\|` |
| 64-bit flags (`VkAccessFlags2`, `VkPipelineStageFlags2`, `VkFormatFeatureFlags2`) | `u64` |
| `VkBool32` | `u32` (`VK_TRUE`, `VK_FALSE`) |
| `uint32_t`, `int32_t`, `float`, `uint8_t`, ... | `u32`, `i32`, `f32`, `u8`, ... |
| `size_t`, `VkDeviceSize`, `VkDeviceAddress`, `uint64_t` | `u64` |
| struct | struct with the same name, field names, field order and C layout |
| pointer to struct, `const VkFoo*` | `*VkFoo` |
| `void*` (also `pNext`), `char*`, function pointers (`PFN_vk...`) | `*u8` |
| `const char* const*` | `**u8` |
| pointer to handle | `**u8` (dispatchable), `*u64` (non-dispatchable) |
| fixed array member `float blendConstants[4]`, `char deviceName[VK_MAX_PHYSICAL_DEVICE_NAME_SIZE]` | `[4]f32`, `[VK_MAX_PHYSICAL_DEVICE_NAME_SIZE]u8` |
| array parameter `const float blendConstants[4]` | `*f32` |
| union (`VkClearValue`, `VkClearColorValue`) | `struct { data: [N]u32 }` of the union's size and alignment, plus one constructor per member (below) |
| struct with bit-fields | not bound (a comment in `std/vk.al` names it; none in the current selection) |
| command | `extern "libvulkan.so.1" fn vkXxx(...)` with the C parameter names |
| `VK_API_VERSION_1_x`, `VK_NULL_HANDLE`, `VK_WHOLE_SIZE`, `VK_KHR_SWAPCHAIN_EXTENSION_NAME`, ... | constants (`u32`, `u64`, `str`) |
| window-system types | `Display*`, `xcb_connection_t*`, `wl_display*`, `wl_surface*` are `*u8`; `Window`, `VisualID` are `u64`; `xcb_window_t`, `xcb_visualid_t` are `u32` |

AL types have one name each, so the C type of a field or parameter that became `i32`/`u32`/`u64`/`*u8`
is kept as a comment: every struct field carries `// VkFormat`-style notes and every `extern` is
preceded by its C prototype. `std/vk.al` is meant to be searched (`grep -n 'struct VkImageCreateInfo' -A 16 std/vk.al`).

A field or parameter whose name is an AL keyword would get a trailing underscore (none of the
current names needs it). Struct names that C defines as a second name of another struct
(`VkPhysicalDeviceVariablePointerFeatures`) are listed as comments only; use the name they point to.

## Passing things to Vulkan

- **Handles** are plain values. Output handles are written through a pointer to a variable:
  `device: *u8; vkCreateDevice(physical, &info, nil, &device)`,
  `image: u64; vkCreateImage(device, &info, nil, &image)`.
- **Structs** are passed by pointer (`&info`). `s: VkFoo` is zeroed, like `VkFoo s = {0}`.
  Struct literals work as usual: `VkExtent3D{256, 256, 1}`, `VkAttachmentDescription{format: f, ...}`.
- **Arrays**: use a local array and `ptr(array)` (or `&array[0]`), or a slice from `alloc`
  and `ptr(slice)`; the count goes into the matching `...Count` field as `u32`.
  A single element is passed as `&element`. Two-call enumerations: call once with `nil` for
  the count, `alloc` that many, call again.
- **Strings**: string literals are NUL-terminated in memory, so `ptr("main")` is a valid
  `const char*`; use `cstr(s)` for computed strings and `from_cstr(ptr(props.deviceName))` to
  read a `char` array. Lists of names are `*u8` arrays:
  `names := [2]*u8{ptr(VK_KHR_SURFACE_EXTENSION_NAME), ptr(VK_KHR_XLIB_SURFACE_EXTENSION_NAME)}`,
  then `info.ppEnabledExtensionNames = ptr(names)`.
- **Unions**: build them with their member constructors:
  `vk_clear_value_color(vk_clear_color_value_float32([4]f32{0.1, 0.1, 0.15, 1.0}))`,
  `vk_clear_value_depth_stencil(VkClearDepthStencilValue{1.0, 0})` (C:
  `{.color = {.float32 = {...}}}`). To read one, cast: `cast[*[4]f32](&value)[0]`.
- **pNext chains**: `pNext` is `*u8`; link structs with `cast[*u8](&next)`, see
  [pNext chains](#pnext-chains).
- **Mapped memory**: `p: *u8; vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &p)`, then
  `memcopy(p, ptr(data), nbytes)` or `mkslice[u8](p, nbytes)`. The layouts of AL's
  `vec2`/`vec4`/`mat4` (column-major, 16-byte `vec4`) match GLSL's `std140`/`std430` for
  `vec4` and `mat4` members; a `vec3` is 12 bytes in AL and 16-byte aligned in `std140`.
- **Callbacks** (`pfnUserCallback`, allocation callbacks): an AL function with scalar/pointer
  parameters, stored with `cast[*u8](my_callback)` (see the debug messenger below).

Vulkan commands return `i32` `VkResult` values; nothing in the module checks them, panics or
allocates. A program decides what a failure means: the examples stop on results that only
occur in a broken program (`check(r, "vkCreateBuffer")`, three lines of their own) and report
the ones that depend on the machine (no device, no surface support).

## Glue

| Function | Purpose |
|----------|---------|
| `vk_instance_create_info()`, `vk_device_create_info()`, `vk_buffer_create_info()`, ... | one per struct that has an `sType`: the zeroed struct with `sType` set (what `VkFoo s = {VK_STRUCTURE_TYPE_FOO}` does in C). The name is the struct name in snake case: `VkPipelineShaderStageCreateInfo` → `vk_pipeline_shader_stage_create_info()`, `VkPhysicalDeviceVulkan13Features` → `vk_physical_device_vulkan13_features()`, `VkXlibSurfaceCreateInfoKHR` → `vk_xlib_surface_create_info_khr()` |
| `vk_clear_color_value_float32(v: [4]f32)`, `vk_clear_color_value_int32(v: [4]i32)`, `vk_clear_color_value_uint32(v: [4]u32) -> VkClearColorValue` | the union `VkClearColorValue` holding that member |
| `vk_clear_value_color(v: VkClearColorValue)`, `vk_clear_value_depth_stencil(v: VkClearDepthStencilValue) -> VkClearValue` | the union `VkClearValue` holding that member |
| `vk_make_api_version(variant, major, minor, patch: u32) -> u32` | `VK_MAKE_API_VERSION` |
| `vk_api_version_variant(v)`, `vk_api_version_major(v)`, `vk_api_version_minor(v)`, `vk_api_version_patch(v)` | `VK_API_VERSION_VARIANT` / `_MAJOR` / `_MINOR` / `_PATCH` |
| `vk_result_name(result: i32) -> str` | `"VK_SUCCESS"`, `"VK_ERROR_DEVICE_LOST"`, ... (`string_VkResult` of the Khronos utility headers); no allocation |

The union constructors are generated for every union of the selection, `vk_<union>_<member>`.
Constant groups: `VK_API_VERSION_1_0` .. `VK_API_VERSION_1_3`, `VK_NULL_HANDLE`, the API
constants (`VK_WHOLE_SIZE`, `VK_QUEUE_FAMILY_IGNORED`, `VK_SUBPASS_EXTERNAL`, `VK_MAX_...`),
every enum and flag-bit value of the selected API (including `VK_STRUCTURE_TYPE_...` for every
struct), and per extension `VK_..._EXTENSION_NAME` (`str`) and `VK_..._SPEC_VERSION`.

## SPIR-V shaders

Vulkan takes shaders as SPIR-V. The usual route compiles them when building and puts the bytes
into the executable, so running needs no shader compiler:

```
glslc --target-env=vulkan1.3 scene.vert -o scene.vert.spv     # once per change (shaderc's glslc;
glslc --target-env=vulkan1.3 scene.frag -o scene.frag.spv     #  glslangValidator -V works too)
```

```
const SCENE_VERT = embed("shaders/scene.vert.spv")            // path relative to the source file

// A shader module from SPIR-V bytes. The words are copied: an embedded file need not be 4-byte aligned.
fn shader_module(device: *u8, spirv: []u8) -> u64 {
    words := alloc[u32](spirv.len / 4)
    memcopy(ptr(words), ptr(spirv), words.len * 4)
    info := vk_shader_module_create_info()
    info.codeSize = u64(words.len * 4)                         // bytes, not words
    info.pCode = ptr(words)
    module: u64
    r := vkCreateShaderModule(device, &info, nil, &module)
    if r != VK_SUCCESS { panic(fmt("vkCreateShaderModule: ", vk_result_name(r))) }
    module
}
```

Commit the `.spv` files next to their sources (the examples do), or regenerate them in the
script that builds the game. To compile at run time instead, for example to reload shaders
while the game runs, use [std.shaderc](shaderc.md): the same compiler as a library, giving the
SPIR-V words in memory.

## Extension commands

The loader exports every command of core Vulkan and of the surface and swapchain extensions,
and those are `extern` functions. It exports none of `VK_EXT_debug_utils`: these are listed
with their AL function types in a comment at the end of the commands section of `std/vk.al`
and are fetched at run time, as in C, then called through an AL function value:

```
create := cast[fn(*u8, *VkDebugUtilsMessengerCreateInfoEXT, *VkAllocationCallbacks, *u64) -> i32](
    vkGetInstanceProcAddr(instance, ptr("vkCreateDebugUtilsMessengerEXT")))
messenger: u64
r := create(instance, &info, nil, &messenger)
// at shutdown, before vkDestroyInstance:
destroy := cast[fn(*u8, u64, *VkAllocationCallbacks)](
    vkGetInstanceProcAddr(instance, ptr("vkDestroyDebugUtilsMessengerEXT")))
destroy(instance, messenger, nil)
```

- A `nil` result means the command is not available (extension not enabled); calling a
  function value made from `nil` crashes, so check first.
- Commands whose first parameter is a `VkDevice`, `VkQueue` or `VkCommandBuffer` can be
  fetched with `vkGetDeviceProcAddr(device, name)` once the device exists: this skips the
  loader's dispatch (the renderer does it for `vkSetDebugUtilsObjectNameEXT` and
  `vkCmdBeginDebugUtilsLabelEXT`). The same works for core commands, for hot paths.
- Keep the function values in a struct (`examples/vk_renderer/renderer.al`: `struct Ext`);
  a field of type `fn(...) -> R` holds them.
- An extension that is not in the generator's list has no structs or constants in `std/vk.al`;
  add it to `EXTENSIONS` in `tools/gen_vk.al` and regenerate (see [Regenerating](#regenerating)).

## pNext chains

Extension structs hang off `pNext` (`*u8`). Build each struct with its constructor, link them
with `cast[*u8](&next)`, and keep every struct of the chain alive (locals of the function
that makes the call). Querying and enabling the Vulkan 1.3 features dynamic rendering and
synchronization2:

```
f13 := vk_physical_device_vulkan13_features()
f2 := vk_physical_device_features2()
f2.pNext = cast[*u8](&f13)                       // VkPhysicalDeviceFeatures2 -> Vulkan13Features
vkGetPhysicalDeviceFeatures2(physical, &f2)
if f13.dynamicRendering != VK_TRUE || f13.synchronization2 != VK_TRUE { ... pick another device ... }

want := vk_physical_device_vulkan13_features()
want.dynamicRendering = VK_TRUE
want.synchronization2 = VK_TRUE
features := vk_physical_device_features2()
features.pNext = cast[*u8](&want)
info := vk_device_create_info()
info.pNext = cast[*u8](&features)               // pEnabledFeatures stays nil
```

The same pattern gives dynamic rendering its attachment formats
(`VkPipelineRenderingCreateInfo` in the `pNext` of `VkGraphicsPipelineCreateInfo`), a debug
messenger for instance creation (`VkDebugUtilsMessengerCreateInfoEXT` in the `pNext` of
`VkInstanceCreateInfo`), layer settings, memory priorities and so on.

## Validation layers and the debug messenger

With the Khronos validation layer installed (package `vulkan-validation-layers`; it appears
in `/usr/share/vulkan/explicit_layer.d/`), enable `VK_LAYER_KHRONOS_validation` on the instance
(check with `vkEnumerateInstanceLayerProperties` first) and receive its messages through a
`VK_EXT_debug_utils` messenger whose callback is an AL function:

```
fn on_message(severity: u32, kind: u32, data: *VkDebugUtilsMessengerCallbackDataEXT, user: *u8) -> u32 {
    eprint(from_cstr(data.pMessage))
    VK_FALSE
}

m := vk_debug_utils_messenger_create_info_ext()
m.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
m.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
m.pfnUserCallback = cast[*u8](on_message)
```

The callback runs on the thread that made the Vulkan call and gets no AL context: keep what it
records in a global. Put the same create info into the `pNext` of `VkInstanceCreateInfo` to
also see messages from `vkCreateInstance` / `vkDestroyInstance`.

Synchronization validation (missing barriers, hazards between commands and submissions) is
off by default. Switch it on from the program with the layer's `VK_EXT_layer_settings`
(enable that extension, listed by `vkEnumerateInstanceExtensionProperties(cstr("VK_LAYER_KHRONOS_validation"), ...)`):

```
on: u32 = VK_TRUE
layer := cstr("VK_LAYER_KHRONOS_validation")
setting := [2]VkLayerSettingEXT{
    VkLayerSettingEXT{layer, ptr("validate_sync"), VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, cast[*u8](&on)},
    // without this, accesses that shaders make through descriptors (storage buffers and
    // images) are not tracked, so compute/graphics hazards go unreported
    VkLayerSettingEXT{layer, ptr("syncval_shader_accesses_heuristic"), VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, cast[*u8](&on)},
}
settings := vk_layer_settings_create_info_ext()
settings.settingCount = 2
settings.pSettings = ptr(setting)
instance_info.pNext = cast[*u8](&settings)
```

To be sure it checks, build once with a barrier deliberately removed: the layer must report a
hazard. (The shader-access heuristic is based on static analysis of the SPIR-V and can rarely
give false positives; it is off by default in the layer.)

or from the environment without changing the program: `VK_LAYER_VALIDATE_SYNC=true`,
`VK_LAYER_VALIDATE_BEST_PRACTICES=true` (performance advice; `_NVIDIA`, `_AMD` variants).

## Example: list the GPUs

```
use std.vk

fn main() -> i64 {
    version: u32
    vkEnumerateInstanceVersion(&version)
    print("loader:", vk_api_version_major(version), vk_api_version_minor(version))

    app := vk_application_info()
    app.pApplicationName = ptr("devices")
    app.apiVersion = VK_API_VERSION_1_0
    info := vk_instance_create_info()
    info.pApplicationInfo = &app
    instance: *u8
    r := vkCreateInstance(&info, nil, &instance)
    if r != VK_SUCCESS {
        print("no Vulkan:", vk_result_name(r))
        return 77
    }

    count: u32
    vkEnumeratePhysicalDevices(instance, &count, nil)
    devices := alloc[*u8](i64(count))
    vkEnumeratePhysicalDevices(instance, &count, ptr(devices))
    for d in devices {
        props: VkPhysicalDeviceProperties
        vkGetPhysicalDeviceProperties(d, &props)
        print(from_cstr(ptr(props.deviceName)), "api", vk_api_version_major(props.apiVersion),
            vk_api_version_minor(props.apiVersion), "max texture", props.limits.maxImageDimension2D)
    }
    vkDestroyInstance(instance, nil)
    0
}
```

prints, for example:

```
loader: 1 4
NVIDIA GeForce RTX 2060 api 1 4 max texture 32768
```

## Example walk-through: `examples/vk_renderer`

An engine-style renderer written from scratch on the bindings, proving that they cover what an
engine needs. It draws two textured quads (one occluding the other through the depth buffer)
whose placement a compute shader writes every frame.

| File | Contents |
|------|----------|
| `renderer.al` | everything shared: instance, messenger, device, memory, uploads, pipelines, frames in flight, offscreen rendering |
| `offscreen.al` | `alc run examples/vk_renderer/offscreen.al`: 8 frames without a window, read back, saved as `vk_renderer.png`, GPU time per frame |
| `present.al`, `windowed.al` | `alc run examples/vk_renderer/windowed.al -- [x11\|wayland] [fifo\|mailbox\|immediate] [seconds]`: the same in a window |
| `shaders/` | `scene.vert`, `scene.frag`, `instances.comp` and their `.spv` (glslc, `--target-env=vulkan1.3`) |
| `texture.png` | a 64 x 64 texture of four coloured quadrants |

The steps in `renderer.al`, in the order an engine sets them up:

1. **Instance** (`gpu_create_instance`): checks the instance extensions and the validation
   layer, chains `VkLayerSettingsCreateInfoEXT` (synchronization validation) and a messenger
   create info into `VkInstanceCreateInfo.pNext`, then creates the messenger through
   `vkGetInstanceProcAddr` and sends it a test message with `vkSubmitDebugUtilsMessageEXT`. The
   callback `on_debug_message` counts warnings and errors in a global.
2. **Physical device** (`gpu_pick_device`): every device with API 1.3, dynamic rendering and
   synchronization2 (queried through a `pNext` chain), a queue family with graphics, compute and
   timestamps (and, with a surface, presentation and `VK_KHR_swapchain`); discrete GPUs first.
3. **Device** (`gpu_create_device`): the 1.3 features enabled through
   `VkDeviceCreateInfo -> VkPhysicalDeviceFeatures2 -> VkPhysicalDeviceVulkan13Features`, then
   device-level debug-utils commands from `vkGetDeviceProcAddr`; objects get debug names.
4. **Memory**: `memory_type` searches `VkPhysicalDeviceMemoryProperties`; `buffer_create`
   allocates one block per buffer (an engine would sub-allocate: the best-practices layer
   says so) and keeps host-visible buffers mapped.
5. **Staging uploads**: `buffer_upload` copies vertex and index data into device-local buffers
   through a host-visible staging buffer and a one-shot command buffer.
6. **Texture**: `texture_load` decodes `texture.png` with `image_decode` and `convert(img, 4)`
   of [std.image](image.md), uploads it and moves it to `SHADER_READ_ONLY_OPTIMAL` with
   synchronization2 barriers (`vkCmdPipelineBarrier2`, 64-bit stage and access flags).
7. **Descriptors and push constants**: per frame a uniform buffer (a `mat4` camera: a
   translation, so a wrong matrix layout would show), the texture with a nearest sampler, and a
   storage buffer of instances; a `vec4` tint as a push constant; the compute pipeline gets a
   push-constant block with the frame number.
8. **Pipelines**: a graphics pipeline for dynamic rendering (`VkPipelineRenderingCreateInfo` with
   the colour and `D32_SFLOAT` depth formats, dynamic viewport and scissor) and a compute
   pipeline, both from embedded SPIR-V.
9. **Frames in flight** (`frame_begin`, `frame_render`): two slots, each with a fence, two
   command buffers, a binary semaphore, a uniform buffer, an instance buffer and descriptor sets.
   A frame waits for its slot's fence, reads the slot's two timestamps from the previous use
   (`vkGetQueryPoolResults`, times `timestampPeriod`), submits the compute pass
   (`vkQueueSubmit2`, signalling the semaphore), then the graphics pass waiting for it at the
   vertex shader stage (and for the swapchain's acquire semaphore at colour output):
   `vkCmdBeginRendering` with cleared colour and depth, an indexed instanced draw, a barrier to
   `TRANSFER_SRC_OPTIMAL` or `PRESENT_SRC_KHR`, timestamps around it, a debug label.
10. **Readback** (`render_offscreen`): after the last frame, the image is copied into a
    host-visible buffer and returned as RGBA bytes.

`tests/sys/vk_renderer.al` renders 256 x 256 offscreen and checks pixels that each depend on
one step (texture quadrants, depth test, push constant, compute output of frame 7, camera
translation), the timestamps, the messenger's test message, and that the validation layer
(with synchronization validation) reported no error or warning; without the layer it runs
unvalidated and says so on standard error. `tests/sys/vk_present.al` runs the windowed path on
its own headless weston (below).

`examples/vk_triangle.al` is the minimal program: one triangle with a render pass into an
offscreen image written as `triangle.bmp`; `tests/sys/vk_triangle.al` compares it with
`tests/sys/data/vk_triangle.ref` (computed by `python3 tests/gen/vk_triangle_ref.py`; its
shaders `tests/sys/data/tri.vert` / `tri.frag` were compiled with `glslangValidator -V`).

## Windows, swapchains and vsync

This module creates no window. Create one first, enable `VK_KHR_SURFACE_EXTENSION_NAME` plus the
platform extension on the instance and `VK_KHR_SWAPCHAIN_EXTENSION_NAME` on the device, then:

- **X11** (`std.window`): `VkXlibSurfaceCreateInfoKHR` with `dpy = x11_display(w)` and
  `window = x11_window(w)`, `vkCreateXlibSurfaceKHR`. Recreate the swapchain on `EventResize`,
  stop rendering between `EventMinimize` and `EventRestore` (see [window.md](window.md)).
- **Wayland** (`std.wayland`, no std.window): `VkWaylandSurfaceCreateInfoKHR` with
  `display = cast[*u8](display)`, `surface = cast[*u8](surface)` of an xdg-shell toplevel,
  `vkCreateWaylandSurfaceKHR` ([wayland.md](wayland.md#a-window-step-by-step)). The surface
  has no size of its own (`currentExtent` is `0xFFFFFFFF`): the swapchain takes the size of
  `xdg_toplevel.configure`. Acknowledge a configure only after the swapchain has been
  recreated for it, and with FIFO only after the old frames have reached the compositor: the
  driver presents through `wp_fifo_v1`, so their commits can still be queued there, and the
  ack would apply to them (weston: "xdg_surface geometry (800 x 600) is larger than the
  configured fullscreen state", then `VK_ERROR_SURFACE_LOST_KHR`). `present.al` requests a
  frame callback with a commit of its own and acknowledges when it fires.

**Vsync is the present mode** of the swapchain:

| `VkSwapchainCreateInfoKHR.presentMode` | |
|---|---|
| `VK_PRESENT_MODE_FIFO_KHR` | vsync; the only mode every driver has; `vkAcquireNextImageKHR` / present block when the queue is full |
| `VK_PRESENT_MODE_MAILBOX_KHR` | vsync without blocking: the newest frame replaces a waiting one (low latency, renders faster than the display) |
| `VK_PRESENT_MODE_IMMEDIATE_KHR` | no vsync: may tear |
| `VK_PRESENT_MODE_FIFO_RELAXED_KHR` | vsync, but a late frame is shown at once |

Query the supported ones with `vkGetPhysicalDeviceSurfacePresentModesKHR` and fall back to
FIFO; changing the mode means recreating the swapchain. Recreate also when
`vkAcquireNextImageKHR` or `vkQueuePresentKHR` return `VK_ERROR_OUT_OF_DATE_KHR` or
`VK_SUBOPTIMAL_KHR`, passing the old swapchain as `oldSwapchain` and destroying it afterwards.
Use one "render finished" semaphore per swapchain image and one "image acquired" semaphore per
frame in flight (`present.al`).

Measured on Linux with an NVIDIA RTX 2060 (driver 620.70): in a nested X server (an Xvfb-like
private desktop) FIFO and IMMEDIATE present at about 100 frames per second at 800 x 600 and
25 at 1920 x 1056 (the X server copies each frame), MAILBOX is not offered; on a headless weston
with the GL renderer FIFO paces at 60, MAILBOX and IMMEDIATE run at about 3000. The validation
layer reported nothing in any of these runs. A weston nested inside that X server (x11 backend)
showed nothing: it has no DRI3 device there and cannot import the driver's buffers.

## Regenerating

```
./build/alc run tools/gen_vk.al                # rewrites std/vk.al (byte-identical if nothing changed)
./build/alc run tools/gen_vk.al -- --verify    # also checks the layout against the C headers: builds and runs two programs
```

- The generator is an AL program, run from the root of the repository. The lists `VERSIONS`
  and `EXTENSIONS` at its top select what is bound; the registry is read from
  `/usr/share/vulkan/registry/vk.xml`. Types and enum values are included when a selected
  version/extension requires them, directly or through a struct member or command parameter.
- Only commands that the loader `/usr/lib/libvulkan.so.1` exports (the generator reads its
  dynamic symbol table: what `nm -D --defined-only` lists) become `extern` declarations (an
  `extern` for a missing symbol would stop the program from starting); the others are listed
  with their AL function types for `vkGetInstanceProcAddr`.
- `--verify` writes `tmp/VulkanBindings/layout.c` (using `<vulkan/vulkan.h>`) and `layout.al`
  (using `sizeof[T]()` and field addresses), builds them (clang, gcc or cc; `./build/alc`
  with `ALC_STD_DIR=std`), runs them and compares their output (`layout: no mismatches in 1495
  lines`, or the differing lines and exit status 1). Both programs print the
  size and every field offset of every struct and the value of every numeric constant, and the
  outputs must be identical. The generator's own layout computation, which sizes the unions,
  is checked against the same numbers: `layout.c` asserts them at compile time. It needs a C
  compiler and the Vulkan, X11, xcb and Wayland headers. `tests/std/vk_glue.al` checks the
  union constructors, the version macros, the `sType` constructors and `vk_result_name`.
- The hand-written part is the version macros in `tools/vk_helpers.al`; edit it there, not in
  `std/vk.al`. It holds only what `vulkan_core.h` defines as macros: no policy.
