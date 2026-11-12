# std.vk: Vulkan bindings

`use std.vk` gives an AL program the Vulkan API: core 1.0 to 1.3 plus `VK_KHR_surface`,
`VK_KHR_swapchain`, `VK_KHR_xlib_surface`, `VK_KHR_xcb_surface`, `VK_KHR_wayland_surface` and
`VK_EXT_debug_utils`. It is a binding, not an engine: the names, structs and call sequences are
those of the C API, so the Vulkan specification and any C tutorial apply directly. A small
convenience layer (result checking, `sType` constructors, clear values, memory type search,
shader modules) removes the most repetitive boilerplate.

The module is generated: `std/vk.al` is written by `tools/gen_vk.al` from the Khronos registry
(`vk.xml`), followed by the hand-written `tools/vk_helpers.al`. It contains 300 structs, about
1200 constants and 235 functions. Using it costs about 10 ms of compile time.

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
| `void*`, `char*`, function pointers (`PFN_vk...`) | `*u8` |
| `const char* const*` | `**u8` |
| pointer to handle | `**u8` (dispatchable), `*u64` (non-dispatchable) |
| fixed array member `float blendConstants[4]`, `char deviceName[VK_MAX_PHYSICAL_DEVICE_NAME_SIZE]` | `[4]f32`, `[VK_MAX_PHYSICAL_DEVICE_NAME_SIZE]u8` |
| array parameter `const float blendConstants[4]` | `*f32` |
| union (`VkClearValue`, `VkClearColorValue`) | `struct { data: [N]u32 }` of the union's size and alignment; build values with the helpers below |
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
  A single element is passed as `&element`.
- **Strings**: string literals are NUL-terminated in memory, so `ptr("main")` is a valid
  `const char*`; use `cstr(s)` for computed strings and `from_cstr(ptr(props.deviceName))` to
  read a `char` array. Lists of names are `[N]*u8` arrays:
  `names := [2]*u8{ptr(VK_KHR_SURFACE_EXTENSION_NAME), ptr(VK_KHR_XLIB_SURFACE_EXTENSION_NAME)}`,
  then `info.ppEnabledExtensionNames = ptr(names)`.
- **Unions**: `VkClearValue` and `VkClearColorValue` are opaque word arrays; create them with
  `vk_clear_color`, `vk_clear_depth`, ... (`pass_begin.pClearValues = &clear`).
- **Mapped memory**: `p: *u8; vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &p)`, then
  `memcopy(p, ptr(data), nbytes)` or `mkslice[u8](p, nbytes)`.
- **Callbacks** (`pfnUserCallback`, allocation callbacks): an AL function with scalar/pointer
  parameters, stored with `cast[*u8](my_callback)` (see the debug messenger below).
- **Commands the loader does not export**: the loader exports everything of core and of the
  surface/swapchain extensions, but none of the `VK_EXT_debug_utils` commands. They are listed
  with their AL function types in a comment at the end of the commands section of `std/vk.al`
  and are reached the C way, through `vkGetInstanceProcAddr` and a cast to a function type:

  ```
  fn on_message(severity: u32, kind: u32, data: *VkDebugUtilsMessengerCallbackDataEXT, user: *u8) -> u32 {
      print(from_cstr(data.pMessage))
      VK_FALSE
  }

  m := vk_debug_utils_messenger_create_info_ext()
  m.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
  m.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
  m.pfnUserCallback = cast[*u8](on_message)
  create := cast[fn(*u8, *VkDebugUtilsMessengerCreateInfoEXT, *VkAllocationCallbacks, *u64) -> i32](
      vkGetInstanceProcAddr(instance, ptr("vkCreateDebugUtilsMessengerEXT")))
  messenger: u64
  vk_check(create(instance, &m, nil, &messenger), "vkCreateDebugUtilsMessengerEXT")
  ```

  (the instance must have been created with `VK_EXT_DEBUG_UTILS_EXTENSION_NAME` enabled).

None of the bindings allocates. Vulkan commands return `i32` `VkResult` values and never panic.

## Convenience layer

| Function | Purpose |
|----------|---------|
| `vk_check(result: i32, what: str)` | panics with `what: VK_ERROR_...` unless `result == VK_SUCCESS`. For calls that cannot fail in a correct program; test `result` yourself where failure is a run-time condition (instance/device creation, swapchain acquisition) |
| `vk_result_name(result: i32) -> str` | `"VK_SUCCESS"`, `"VK_ERROR_DEVICE_LOST"`, ...; no allocation |
| `vk_make_version(major, minor, patch: u32) -> u32` | packed version number, as `VK_MAKE_API_VERSION(0, ...)` |
| `vk_version_major(v)`, `vk_version_minor(v)`, `vk_version_patch(v)` | unpack a version |
| `vk_instance_create_info()`, `vk_device_create_info()`, `vk_buffer_create_info()`, ... | one constructor per struct that has an `sType`: returns the zeroed struct with `sType` set. The name is the struct name in snake case: `VkPipelineShaderStageCreateInfo` → `vk_pipeline_shader_stage_create_info()`, `VkXlibSurfaceCreateInfoKHR` → `vk_xlib_surface_create_info_khr()` |
| `vk_clear_color(r, g, b, a: f32) -> VkClearValue` | clear value of a float/normalised colour attachment |
| `vk_clear_color_int(r, g, b, a: i32)`, `vk_clear_color_uint(r, g, b, a: u32)` | the same for integer formats |
| `vk_clear_depth(depth: f32, stencil: u32) -> VkClearValue` | clear value of a depth/stencil attachment |
| `vk_clear_color_value(r, g, b, a: f32) -> VkClearColorValue` | for `vkCmdClearColorImage` |
| `vk_find_memory_type(props: *VkPhysicalDeviceMemoryProperties, type_bits: u32, flags: u32) -> (u32, bool)` | first memory type allowed by `memoryTypeBits` that has all the `VK_MEMORY_PROPERTY_...` flags |
| `vk_create_shader_module(device: *u8, code: []u8) -> (u64, bool)` | shader module from SPIR-V bytes, typically `embed("x.spv")`. Uses temporary arena memory (released before returning) if the bytes are not 4-byte aligned |

Constant groups: `VK_API_VERSION_1_0` .. `VK_API_VERSION_1_3`, `VK_NULL_HANDLE`, the API constants
(`VK_WHOLE_SIZE`, `VK_QUEUE_FAMILY_IGNORED`, `VK_SUBPASS_EXTERNAL`, `VK_MAX_...`), every enum and
flag-bit value of the selected API (including `VK_STRUCTURE_TYPE_...` for every struct), and per
extension `VK_..._EXTENSION_NAME` (`str`) and `VK_..._SPEC_VERSION`.

## Example: list the GPUs

```
use std.vk

fn main() -> i64 {
    version: u32
    vk_check(vkEnumerateInstanceVersion(&version), "vkEnumerateInstanceVersion")
    print("loader:", vk_version_major(version), vk_version_minor(version))

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

    devices: [8]*u8
    count: u32 = 8
    vkEnumeratePhysicalDevices(instance, &count, ptr(devices))
    for i in 0..i64(count) {
        props: VkPhysicalDeviceProperties
        vkGetPhysicalDeviceProperties(devices[i], &props)
        print(from_cstr(ptr(props.deviceName)), "api", vk_version_major(props.apiVersion),
            vk_version_minor(props.apiVersion), "max texture", props.limits.maxImageDimension2D)
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

## Example walk-through: `examples/vk_triangle.al`

`ALC_STD_DIR=std alc run examples/vk_triangle.al` renders a red/green/blue triangle into a
256x256 offscreen image and writes `triangle.bmp`; no window is involved. The program keeps its
state in two explicit structs (`Gpu`: instance, physical device, device, queue, memory
properties; `Target`: image, memory, view, render pass, framebuffer) and is split into the usual
Vulkan stages:

1. `open_gpu()` creates the instance (`vk_application_info()`, `vk_instance_create_info()`), picks
   the first physical device with a `VK_QUEUE_GRAPHICS_BIT` queue family, creates the device with
   one queue and fetches the memory properties. Failure is a run-time condition here, so the
   `VkResult` is tested and reported (`vk_result_name`) instead of `vk_check`ed.
2. `allocate()` / `create_buffer()` show the memory pattern: query `VkMemoryRequirements`, pick a
   type with `vk_find_memory_type`, `vkAllocateMemory`, bind.
3. `create_target()` creates the `VK_FORMAT_R8G8B8A8_UNORM` image (colour attachment + transfer
   source), its view, a render pass with one attachment that is cleared and ends in
   `VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL` (with a subpass dependency so that the later copy waits
   for the colour writes), and the framebuffer.
4. `create_pipeline()` builds shader modules from embedded SPIR-V
   (`vk_create_shader_module(device, embed("...tri.vert.spv"))`), describes the vertex layout
   (`vec2` position at offset 0, `vec3` colour at offset 8, stride 20) and fills the fixed-function
   state structs. Arrays of structs are local arrays passed with `ptr(stages)`.
5. `main` uploads the three vertices through `vkMapMemory` + `memcopy`, records one command
   buffer (begin render pass with `vk_clear_color(0.2, 0.2, 0.4, 1.0)`, bind, draw, end,
   `vkCmdCopyImageToBuffer`), submits it, waits with `vkQueueWaitIdle`, maps the read-back buffer
   as a `[]u8` with `mkslice` and writes the BMP. Everything is destroyed in reverse order.

The GLSL sources are `tests/sys/data/tri.vert` and `tri.frag`; they were compiled once with
`glslangValidator -V tri.vert -o tri.vert.spv` (same for `tri.frag`) and the `.spv` files are
checked in, so neither building nor running needs a shader compiler.

`tests/sys/vk_triangle.al` is the same rendering as a test: it compares the pixels with
`tests/sys/data/vk_triangle.ref`, an image computed without a GPU by
`python3 tests/gen/vk_triangle_ref.py` (barycentric rasterisation of the same vertices), allowing
0.5% of the pixels to differ by more than 8 in a channel. The script can also check the example's
output: `python3 tests/gen/vk_triangle_ref.py --compare triangle.bmp`.

## Windows and swapchains

The surface extensions are bound but this module creates no window. Create one with the
window-system module, then enable `VK_KHR_SURFACE_EXTENSION_NAME` plus the platform extension on
the instance and `VK_KHR_SWAPCHAIN_EXTENSION_NAME` on the device, and call
`vkCreateXlibSurfaceKHR` / `vkCreateXcbSurfaceKHR` / `vkCreateWaylandSurfaceKHR` with the native
display and window handles.

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
  `extern` for a missing symbol would stop the program from starting).
- `--verify` writes `tmp/VulkanBindings/layout.c` (using `<vulkan/vulkan.h>`) and `layout.al`
  (using `sizeof[T]()` and field addresses), builds them (clang, gcc or cc; `./build/alc`
  with `ALC_STD_DIR=std`), runs them and compares their output (`layout: no mismatches in 1475
  lines`, or the differing lines and exit status 1). Both programs print the
  size and every field offset of every struct and the value of every numeric constant, and the
  outputs must be identical. The generator's own layout computation, which sizes the unions,
  is checked against the same numbers: `layout.c` asserts them at compile time. Current
  result: 300 structs, 1928 fields, 1175 constants, 0 mismatches. It needs a C compiler and
  the Vulkan, X11, xcb and Wayland headers.
- The convenience layer lives in `tools/vk_helpers.al`; edit it there, not in `std/vk.al`.
