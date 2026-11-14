// The renderer of examples/vk_renderer, written from scratch on the Vulkan bindings (std.vk):
// what a small engine needs, in the order an engine sets it up.
//
//   - instance with the validation layer (when installed) and extensions, a VK_EXT_debug_utils
//     messenger whose callback is an AL function;
//   - extension commands fetched with vkGetInstanceProcAddr / vkGetDeviceProcAddr;
//   - physical device selection (Vulkan 1.3, queue family, features, presentation);
//   - a logical device with Vulkan 1.3 features (dynamic rendering, synchronization2) enabled
//     through a pNext chain;
//   - buffers and memory, staging uploads, a texture from a PNG decoded by std.image, a depth
//     buffer, descriptor sets, push constants;
//   - a graphics pipeline and a compute pipeline from SPIR-V compiled with glslc and embedded;
//   - timestamp queries, frames in flight with fences and semaphores, readback.
//
// Used by offscreen.al (no window), windowed.al (X11 or Wayland swapchain) and the test
// tests/sys/vk_renderer.al. Error policy: a call that only fails in a broken program or on a
// lost device stops the program (`check`); what depends on the machine is returned as text.
use std.vk
use std.image

const FRAMES_IN_FLIGHT = 2
const INSTANCE_COUNT: u32 = 2
const DEPTH_FORMAT: i32 = VK_FORMAT_D32_SFLOAT
const VALIDATION_LAYER = "VK_LAYER_KHRONOS_validation"
const FOREVER: u64 = 0xFFFF_FFFF_FFFF_FFFF

// ---- results -----------------------------------------------------------------------------------

// Stops the program unless `result` is VK_SUCCESS.
fn check(result: i32, what: str) {
    if result != VK_SUCCESS { panic(fmt(what, ": ", vk_result_name(result))) }
}

// ---- debug messenger ---------------------------------------------------------------------------

// What the messenger callback has seen. A global: the callback gets no AL context, only the
// `user` pointer (unused here).
struct DebugStats {
    messages: i64
    warnings: i64
    errors: i64
    test_seen: bool
}

debug_stats: DebugStats

const TEST_MESSAGE = "vk_renderer: debug messenger test"

// PFN_vkDebugUtilsMessengerCallbackEXT, as an AL function. Called on the thread that made the
// Vulkan call. Warnings and errors go to standard error and are counted.
fn on_debug_message(severity: u32, types: u32, data: *VkDebugUtilsMessengerCallbackDataEXT, user: *u8) -> u32 {
    debug_stats.messages += 1
    text := from_cstr(data.pMessage)
    if text == TEST_MESSAGE {
        debug_stats.test_seen = true
        return VK_FALSE
    }
    if severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT != 0 {
        debug_stats.errors += 1
        eprint(concat("vulkan error: ", text))
    } else if severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT != 0 {
        debug_stats.warnings += 1
        eprint(concat("vulkan warning: ", text))
    }
    VK_FALSE
}

// Extension commands: the loader does not export them, so they are fetched at run time and
// called through function values of their C signatures.
struct Ext {
    create_messenger: fn(*u8, *VkDebugUtilsMessengerCreateInfoEXT, *VkAllocationCallbacks, *u64) -> i32
    destroy_messenger: fn(*u8, u64, *VkAllocationCallbacks)
    submit_message: fn(*u8, u32, u32, *VkDebugUtilsMessengerCallbackDataEXT)
    // device-level: from vkGetDeviceProcAddr (no loader trampoline)
    set_object_name: fn(*u8, *VkDebugUtilsObjectNameInfoEXT) -> i32
    cmd_begin_label: fn(*u8, *VkDebugUtilsLabelEXT)
    cmd_end_label: fn(*u8)
}

fn messenger_info() -> VkDebugUtilsMessengerCreateInfoEXT {
    m := vk_debug_utils_messenger_create_info_ext()
    m.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
        VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT
    m.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
        VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT
    m.pfnUserCallback = cast[*u8](on_debug_message)
    m
}

// ---- instance and device -----------------------------------------------------------------------

struct Gpu {
    instance: *u8
    messenger: u64
    validation: bool        // VK_LAYER_KHRONOS_validation is enabled
    physical: *u8
    device: *u8
    queue: *u8
    family: u32             // graphics + compute (+ present) queue family
    props: VkPhysicalDeviceProperties
    memory: VkPhysicalDeviceMemoryProperties
    ext: Ext
}

fn has_layer(name: str) -> bool {
    count: u32
    vkEnumerateInstanceLayerProperties(&count, nil)
    layers := alloc[VkLayerProperties](i64(count))
    vkEnumerateInstanceLayerProperties(&count, ptr(layers))
    for i in 0..i64(count) {
        if from_cstr(ptr(layers[i].layerName)) == name { return true }
    }
    false
}

// `layer`: "" for the extensions of the loader and the drivers, else those a layer adds.
fn has_instance_extension(layer: str, name: str) -> bool {
    layer_name: *u8 = if layer == "" { nil } else { cstr(layer) }
    count: u32
    vkEnumerateInstanceExtensionProperties(layer_name, &count, nil)
    exts := alloc[VkExtensionProperties](i64(count))
    vkEnumerateInstanceExtensionProperties(layer_name, &count, ptr(exts))
    for i in 0..i64(count) {
        if from_cstr(ptr(exts[i].extensionName)) == name { return true }
    }
    false
}

fn has_device_extension(physical: *u8, name: str) -> bool {
    count: u32
    vkEnumerateDeviceExtensionProperties(physical, nil, &count, nil)
    exts := alloc[VkExtensionProperties](i64(count))
    vkEnumerateDeviceExtensionProperties(physical, nil, &count, ptr(exts))
    for i in 0..i64(count) {
        if from_cstr(ptr(exts[i].extensionName)) == name { return true }
    }
    false
}

// NUL-terminated copies of names, as a `const char* const*` array.
fn c_names(names: []str) -> []*u8 {
    out := alloc[*u8](names.len)
    for i, n in names { out[i] = cstr(n) }
    out
}

// Creates the instance (with `extensions` and VK_EXT_debug_utils; with the validation layer if
// `validate` and it is installed) and the debug messenger. "" on success.
fn gpu_create_instance(g: *Gpu, app_name: str, extensions: []str, validate: bool) -> str {
    if !has_instance_extension("", VK_EXT_DEBUG_UTILS_EXTENSION_NAME) { return "VK_EXT_debug_utils is not available" }
    exts := vec_of(extensions)
    exts.push(VK_EXT_DEBUG_UTILS_EXTENSION_NAME)
    for e in extensions {
        if !has_instance_extension("", e) { return fmt("instance extension ", e, " is not available") }
    }
    g.validation = validate && has_layer(VALIDATION_LAYER)
    layers := if g.validation { []str{VALIDATION_LAYER} } else { []str{} }

    app := vk_application_info()
    app.pApplicationName = cstr(app_name)
    app.applicationVersion = vk_make_api_version(0, 0, 1, 0)
    app.pEngineName = ptr("none")
    app.apiVersion = VK_API_VERSION_1_3
    // a messenger in the pNext chain also reports what happens inside vkCreateInstance and
    // vkDestroyInstance
    during_create := messenger_info()
    info := vk_instance_create_info()
    info.pNext = cast[*u8](&during_create)
    // the layer's own extension VK_EXT_layer_settings switches on synchronization validation
    // (hazards between commands, missing barriers), which is off by default:
    // instance -> layer settings -> messenger
    on: u32 = VK_TRUE
    setting := VkLayerSettingEXT{cstr(VALIDATION_LAYER), ptr("validate_sync"), VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, cast[*u8](&on)}
    settings := vk_layer_settings_create_info_ext()
    settings.settingCount = 1
    settings.pSettings = &setting
    if g.validation && has_instance_extension(VALIDATION_LAYER, VK_EXT_LAYER_SETTINGS_EXTENSION_NAME) {
        exts.push(VK_EXT_LAYER_SETTINGS_EXTENSION_NAME)
        settings.pNext = cast[*u8](&during_create)
        info.pNext = cast[*u8](&settings)
    }
    info.pApplicationInfo = &app
    info.enabledLayerCount = u32(layers.len)
    info.ppEnabledLayerNames = ptr(c_names(layers))
    info.enabledExtensionCount = u32(exts.len)
    info.ppEnabledExtensionNames = ptr(c_names(exts.items()))
    r := vkCreateInstance(&info, nil, &g.instance)
    if r != VK_SUCCESS { return fmt("vkCreateInstance: ", vk_result_name(r)) }

    fn proc(instance: *u8, name: str) -> *u8 {
        p := vkGetInstanceProcAddr(instance, cstr(name))
        if p == nil { panic(fmt("vkGetInstanceProcAddr: no ", name)) }
        p
    }
    g.ext.create_messenger = cast[fn(*u8, *VkDebugUtilsMessengerCreateInfoEXT, *VkAllocationCallbacks, *u64) -> i32](
        proc(g.instance, "vkCreateDebugUtilsMessengerEXT"))
    g.ext.destroy_messenger = cast[fn(*u8, u64, *VkAllocationCallbacks)](proc(g.instance, "vkDestroyDebugUtilsMessengerEXT"))
    g.ext.submit_message = cast[fn(*u8, u32, u32, *VkDebugUtilsMessengerCallbackDataEXT)](
        proc(g.instance, "vkSubmitDebugUtilsMessageEXT"))
    m := messenger_info()
    check(g.ext.create_messenger(g.instance, &m, nil, &g.messenger), "vkCreateDebugUtilsMessengerEXT")

    // a message of our own proves the callback works, layers or not
    data := vk_debug_utils_messenger_callback_data_ext()
    data.pMessage = ptr(TEST_MESSAGE)
    g.ext.submit_message(g.instance, VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT, VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT, &data)
    ""
}

// A device that can run the renderer: Vulkan 1.3 with dynamic rendering and synchronization2,
// a queue family with graphics, compute and timestamps (and presentation to `surface` if it is
// not 0, with VK_KHR_swapchain). Discrete GPUs are preferred over integrated ones.
fn gpu_pick_device(g: *Gpu, surface: u64) -> str {
    count: u32
    vkEnumeratePhysicalDevices(g.instance, &count, nil)
    devices := alloc[*u8](i64(count))
    vkEnumeratePhysicalDevices(g.instance, &count, ptr(devices))
    best_score := -1
    for d in devices[..i64(count)] {
        props: VkPhysicalDeviceProperties
        vkGetPhysicalDeviceProperties(d, &props)
        if props.apiVersion < VK_API_VERSION_1_3 { continue }
        f13 := vk_physical_device_vulkan13_features()
        f2 := vk_physical_device_features2()
        f2.pNext = cast[*u8](&f13)
        vkGetPhysicalDeviceFeatures2(d, &f2)
        if f13.dynamicRendering != VK_TRUE || f13.synchronization2 != VK_TRUE { continue }
        if surface != 0 && !has_device_extension(d, VK_KHR_SWAPCHAIN_EXTENSION_NAME) { continue }
        n: u32
        vkGetPhysicalDeviceQueueFamilyProperties(d, &n, nil)
        families := alloc[VkQueueFamilyProperties](i64(n))
        vkGetPhysicalDeviceQueueFamilyProperties(d, &n, ptr(families))
        family := -1
        for i in 0..i64(n) {
            want := VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT
            if families[i].queueFlags & want != want || families[i].timestampValidBits == 0 { continue }
            if surface != 0 {
                present: u32
                vkGetPhysicalDeviceSurfaceSupportKHR(d, u32(i), surface, &present)
                if present != VK_TRUE { continue }
            }
            family = i
            break
        }
        if family < 0 { continue }
        score := match props.deviceType {
            VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 3
            VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 2
            VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 1
            _ => 0
        }
        if score > best_score {
            best_score = score
            g.physical = d
            g.family = u32(family)
            g.props = props
        }
    }
    if g.physical == nil { return "no Vulkan 1.3 device with dynamic rendering, synchronization2 and timestamps" }
    vkGetPhysicalDeviceMemoryProperties(g.physical, &g.memory)
    ""
}

// Creates the device with the Vulkan 1.3 features enabled through the pNext chain
// VkDeviceCreateInfo -> VkPhysicalDeviceFeatures2 -> VkPhysicalDeviceVulkan13Features.
fn gpu_create_device(g: *Gpu, swapchain: bool) -> str {
    priority: f32 = 1.0
    queue_info := vk_device_queue_create_info()
    queue_info.queueFamilyIndex = g.family
    queue_info.queueCount = 1
    queue_info.pQueuePriorities = &priority

    f13 := vk_physical_device_vulkan13_features()
    f13.dynamicRendering = VK_TRUE
    f13.synchronization2 = VK_TRUE
    f2 := vk_physical_device_features2()
    f2.pNext = cast[*u8](&f13)

    exts := if swapchain { []str{VK_KHR_SWAPCHAIN_EXTENSION_NAME} } else { []str{} }
    info := vk_device_create_info()
    info.pNext = cast[*u8](&f2)        // pEnabledFeatures stays nil: the features are in the chain
    info.queueCreateInfoCount = 1
    info.pQueueCreateInfos = &queue_info
    info.enabledExtensionCount = u32(exts.len)
    info.ppEnabledExtensionNames = ptr(c_names(exts))
    r := vkCreateDevice(g.physical, &info, nil, &g.device)
    if r != VK_SUCCESS { return fmt("vkCreateDevice: ", vk_result_name(r)) }
    vkGetDeviceQueue(g.device, g.family, 0, &g.queue)

    fn proc(device: *u8, name: str) -> *u8 {
        p := vkGetDeviceProcAddr(device, cstr(name))
        if p == nil { panic(fmt("vkGetDeviceProcAddr: no ", name)) }
        p
    }
    g.ext.set_object_name = cast[fn(*u8, *VkDebugUtilsObjectNameInfoEXT) -> i32](proc(g.device, "vkSetDebugUtilsObjectNameEXT"))
    g.ext.cmd_begin_label = cast[fn(*u8, *VkDebugUtilsLabelEXT)](proc(g.device, "vkCmdBeginDebugUtilsLabelEXT"))
    g.ext.cmd_end_label = cast[fn(*u8)](proc(g.device, "vkCmdEndDebugUtilsLabelEXT"))
    ""
}

// Names an object for validation messages and debuggers (RenderDoc).
fn name_object(g: *Gpu, kind: i32, handle: u64, name: str) {
    info := vk_debug_utils_object_name_info_ext()
    info.objectType = kind
    info.objectHandle = handle
    info.pObjectName = cstr(name)
    check(g.ext.set_object_name(g.device, &info), "vkSetDebugUtilsObjectNameEXT")
}

fn gpu_destroy(g: *Gpu) {
    if g.device != nil { vkDestroyDevice(g.device, nil) }
    if g.messenger != 0 { g.ext.destroy_messenger(g.instance, g.messenger, nil) }
    if g.instance != nil { vkDestroyInstance(g.instance, nil) }
}

// ---- memory, buffers, images -------------------------------------------------------------------

// The first memory type allowed by `bits` (VkMemoryRequirements.memoryTypeBits) with all `flags`.
fn memory_type(g: *Gpu, bits: u32, flags: u32) -> u32 {
    for i in 0..i64(g.memory.memoryTypeCount) {
        if bits >> u32(i) & 1 == 1 && g.memory.memoryTypes[i].propertyFlags & flags == flags { return u32(i) }
    }
    panic(fmt("no memory type with flags ", hex(u64(flags)), " in ", hex(u64(bits))))
}

fn allocate(g: *Gpu, req: *VkMemoryRequirements, flags: u32) -> u64 {
    info := vk_memory_allocate_info()
    info.allocationSize = req.size
    info.memoryTypeIndex = memory_type(g, req.memoryTypeBits, flags)
    memory: u64
    check(vkAllocateMemory(g.device, &info, nil, &memory), "vkAllocateMemory")
    memory
}

struct Buffer {
    buffer: u64
    memory: u64
    size: u64
    mapped: *u8         // host-visible buffers stay mapped
}

fn buffer_create(g: *Gpu, size: u64, usage: u32, flags: u32) -> Buffer {
    b := Buffer{size: size}
    info := vk_buffer_create_info()
    info.size = size
    info.usage = usage
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
    check(vkCreateBuffer(g.device, &info, nil, &b.buffer), "vkCreateBuffer")
    req: VkMemoryRequirements
    vkGetBufferMemoryRequirements(g.device, b.buffer, &req)
    b.memory = allocate(g, &req, flags)
    check(vkBindBufferMemory(g.device, b.buffer, b.memory, 0), "vkBindBufferMemory")
    if flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT != 0 {
        check(vkMapMemory(g.device, b.memory, 0, VK_WHOLE_SIZE, 0, &b.mapped), "vkMapMemory")
    }
    b
}

fn buffer_destroy(g: *Gpu, b: *Buffer) {
    vkDestroyBuffer(g.device, b.buffer, nil)
    vkFreeMemory(g.device, b.memory, nil)
    *b = Buffer{}
}

struct Image2D {
    image: u64
    memory: u64
    view: u64
    format: i32
    aspect: u32
    extent: VkExtent2D
}

fn image_create(g: *Gpu, w: u32, h: u32, format: i32, usage: u32, aspect: u32) -> Image2D {
    img := Image2D{format: format, aspect: aspect, extent: VkExtent2D{w, h}}
    info := vk_image_create_info()
    info.imageType = VK_IMAGE_TYPE_2D
    info.format = format
    info.extent = VkExtent3D{w, h, 1}
    info.mipLevels = 1
    info.arrayLayers = 1
    info.samples = VK_SAMPLE_COUNT_1_BIT
    info.tiling = VK_IMAGE_TILING_OPTIMAL
    info.usage = usage
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
    info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
    check(vkCreateImage(g.device, &info, nil, &img.image), "vkCreateImage")
    req: VkMemoryRequirements
    vkGetImageMemoryRequirements(g.device, img.image, &req)
    img.memory = allocate(g, &req, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)
    check(vkBindImageMemory(g.device, img.image, img.memory, 0), "vkBindImageMemory")
    img.view = view_create(g, img.image, format, aspect)
    img
}

fn view_create(g: *Gpu, image: u64, format: i32, aspect: u32) -> u64 {
    info := vk_image_view_create_info()
    info.image = image
    info.viewType = VK_IMAGE_VIEW_TYPE_2D
    info.format = format
    info.subresourceRange = VkImageSubresourceRange{aspect, 0, 1, 0, 1}
    view: u64
    check(vkCreateImageView(g.device, &info, nil, &view), "vkCreateImageView")
    view
}

fn image_destroy(g: *Gpu, img: *Image2D) {
    if img.image == 0 { return }
    vkDestroyImageView(g.device, img.view, nil)
    vkDestroyImage(g.device, img.image, nil)
    vkFreeMemory(g.device, img.memory, nil)
    *img = Image2D{}
}

// A layout transition and execution/memory dependency for a whole single-level image
// (synchronization2: stages and accesses are 64-bit flags).
fn image_barrier(cmd: *u8, image: u64, aspect: u32, src_stage: u64, src_access: u64, dst_stage: u64, dst_access: u64,
        old_layout: i32, new_layout: i32) {
    b := vk_image_memory_barrier2()
    b.srcStageMask = src_stage
    b.srcAccessMask = src_access
    b.dstStageMask = dst_stage
    b.dstAccessMask = dst_access
    b.oldLayout = old_layout
    b.newLayout = new_layout
    b.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
    b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
    b.image = image
    b.subresourceRange = VkImageSubresourceRange{aspect, 0, 1, 0, 1}
    dep := vk_dependency_info()
    dep.imageMemoryBarrierCount = 1
    dep.pImageMemoryBarriers = &b
    vkCmdPipelineBarrier2(cmd, &dep)
}

// ---- one-shot commands and staging uploads -----------------------------------------------------

fn one_shot_begin(g: *Gpu, pool: u64) -> *u8 {
    info := vk_command_buffer_allocate_info()
    info.commandPool = pool
    info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
    info.commandBufferCount = 1
    cmd: *u8
    check(vkAllocateCommandBuffers(g.device, &info, &cmd), "vkAllocateCommandBuffers")
    begin := vk_command_buffer_begin_info()
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
    check(vkBeginCommandBuffer(cmd, &begin), "vkBeginCommandBuffer")
    cmd
}

// Ends, submits and waits for a command buffer of one_shot_begin, then frees it.
fn one_shot_end(g: *Gpu, pool: u64, cmd: *u8) {
    check(vkEndCommandBuffer(cmd), "vkEndCommandBuffer")
    fence_info := vk_fence_create_info()
    fence: u64
    check(vkCreateFence(g.device, &fence_info, nil, &fence), "vkCreateFence")
    cmd_info := vk_command_buffer_submit_info()
    cmd_info.commandBuffer = cmd
    submit := vk_submit_info2()
    submit.commandBufferInfoCount = 1
    submit.pCommandBufferInfos = &cmd_info
    check(vkQueueSubmit2(g.queue, 1, &submit, fence), "vkQueueSubmit2")
    check(vkWaitForFences(g.device, 1, &fence, VK_TRUE, FOREVER), "vkWaitForFences")
    vkDestroyFence(g.device, fence, nil)
    c := cmd
    vkFreeCommandBuffers(g.device, pool, 1, &c)
}

// A device-local buffer filled with `data` through a host-visible staging buffer.
fn buffer_upload(g: *Gpu, pool: u64, data: []u8, usage: u32) -> Buffer {
    size := u64(data.len)
    staging := buffer_create(g, size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)
    memcopy(staging.mapped, ptr(data), data.len)
    b := buffer_create(g, size, usage | VK_BUFFER_USAGE_TRANSFER_DST_BIT, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)
    cmd := one_shot_begin(g, pool)
    region := VkBufferCopy{0, 0, size}
    vkCmdCopyBuffer(cmd, staging.buffer, b.buffer, 1, &region)
    one_shot_end(g, pool, cmd)        // the fence wait makes the copy visible to later submissions
    buffer_destroy(g, &staging)
    b
}

// A sampled RGBA8 texture from PNG (or BMP) bytes, uploaded through a staging buffer and left
// in SHADER_READ_ONLY_OPTIMAL. "" or what went wrong.
fn texture_load(g: *Gpu, pool: u64, file: []u8) -> (Image2D, str) {
    decoded, ok := image_decode(file)
    if !ok { return (Image2D{}, "cannot decode the texture") }
    rgba := convert(decoded, 4)
    staging := buffer_create(g, u64(rgba.pix.len), VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)
    memcopy(staging.mapped, ptr(rgba.pix), rgba.pix.len)
    tex := image_create(g, u32(rgba.w), u32(rgba.h), VK_FORMAT_R8G8B8A8_UNORM,
        VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, VK_IMAGE_ASPECT_COLOR_BIT)
    cmd := one_shot_begin(g, pool)
    image_barrier(cmd, tex.image, VK_IMAGE_ASPECT_COLOR_BIT, VK_PIPELINE_STAGE_2_NONE, 0,
        VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT,
        VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
    region := VkBufferImageCopy{
        imageSubresource: VkImageSubresourceLayers{VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        imageExtent: VkExtent3D{u32(rgba.w), u32(rgba.h), 1},
    }
    vkCmdCopyBufferToImage(cmd, staging.buffer, tex.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region)
    image_barrier(cmd, tex.image, VK_IMAGE_ASPECT_COLOR_BIT, VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT,
        VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT, VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    one_shot_end(g, pool, cmd)
    buffer_destroy(g, &staging)
    (tex, "")
}

// A shader module from SPIR-V bytes (copied into words: an embedded file need not be aligned).
fn shader_module(g: *Gpu, spirv: []u8) -> u64 {
    words := alloc[u32](spirv.len / 4)
    memcopy(ptr(words), ptr(spirv), words.len * 4)
    info := vk_shader_module_create_info()
    info.codeSize = u64(words.len * 4)
    info.pCode = ptr(words)
    module: u64
    check(vkCreateShaderModule(g.device, &info, nil, &module), "vkCreateShaderModule")
    module
}

// ---- the renderer ------------------------------------------------------------------------------

// The layouts the shaders declare (std140 uniform block, std430 storage buffer, push constants).
struct FrameUniforms {
    view_proj: mat4
    params: vec4            // x: seconds
}

struct InstanceData {
    offset_scale: vec4
    tint: vec4
}

struct ComputePush {
    frame: u32
    count: u32
    animate: u32
    seconds: f32
}

struct Vertex { pos: vec2, uv: vec2 }

// What one frame in flight owns. The slot is reused once its fence has signalled.
struct Frame {
    compute_cmd: *u8
    graphics_cmd: *u8
    fence: u64              // signalled when the graphics submission (and so the compute one) is done
    compute_done: u64       // binary semaphore: compute submission -> graphics submission
    uniforms: Buffer        // host-visible, mapped
    instances: Buffer       // device-local storage buffer, written by the compute shader
    set: u64                // graphics descriptor set
    compute_set: u64
    submitted: bool         // a submission is pending or done: the timestamps can be read
}

struct Renderer {
    color_format: i32
    pool: u64
    set_layout: u64
    compute_set_layout: u64
    pipeline_layout: u64
    compute_layout: u64
    pipeline: u64
    compute_pipeline: u64
    descriptor_pool: u64
    sampler: u64
    texture: Image2D
    vertices: Buffer
    indices: Buffer
    depth: Image2D
    query_pool: u64
    frames: [FRAMES_IN_FLIGHT]Frame
    frame: i64              // frames submitted so far
    animate: bool
    view_proj: mat4
    start_ns: i64
    gpu_ms: Vec[f64]        // GPU time of each frame whose timestamps have been read
}

const SCENE_VERT = embed("shaders/scene.vert.spv")
const SCENE_FRAG = embed("shaders/scene.frag.spv")
const INSTANCES_COMP = embed("shaders/instances.comp.spv")
const TEXTURE_PNG = embed("texture.png")

fn renderer_create(g: *Gpu, color_format: i32, extent: VkExtent2D) -> (Renderer, str) {
    r := Renderer{color_format: color_format, start_ns: clock_ns()}
    // the camera: a translation, so that a wrong mat4 layout in the uniform buffer shows
    r.view_proj = translate(vec3(0.1, 0.0, 0.0))

    pool_info := vk_command_pool_create_info()
    pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
    pool_info.queueFamilyIndex = g.family
    check(vkCreateCommandPool(g.device, &pool_info, nil, &r.pool), "vkCreateCommandPool")

    tex, problem := texture_load(g, r.pool, TEXTURE_PNG)
    if problem != "" { return (r, problem) }
    r.texture = tex
    name_object(g, VK_OBJECT_TYPE_IMAGE, r.texture.image, "texture.png")

    // a quad: position in -1..1, texture coordinates with (0, 0) at the top left
    quad := [4]Vertex{
        Vertex{vec2(-1.0, -1.0), vec2(0.0, 0.0)}, Vertex{vec2(1.0, -1.0), vec2(1.0, 0.0)},
        Vertex{vec2(1.0, 1.0), vec2(1.0, 1.0)}, Vertex{vec2(-1.0, 1.0), vec2(0.0, 1.0)},
    }
    indices := [6]u16{0, 1, 2, 2, 3, 0}
    r.vertices = buffer_upload(g, r.pool, mkslice[u8](cast[*u8](&quad), sizeof[[4]Vertex]()), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT)
    r.indices = buffer_upload(g, r.pool, mkslice[u8](cast[*u8](&indices), sizeof[[6]u16]()), VK_BUFFER_USAGE_INDEX_BUFFER_BIT)

    sampler_info := vk_sampler_create_info()
    sampler_info.magFilter = VK_FILTER_NEAREST
    sampler_info.minFilter = VK_FILTER_NEAREST
    sampler_info.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST
    sampler_info.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    sampler_info.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    sampler_info.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    sampler_info.maxLod = 0.0
    check(vkCreateSampler(g.device, &sampler_info, nil, &r.sampler), "vkCreateSampler")

    r.create_layouts(g)
    r.create_pipelines(g)
    r.create_frames(g)
    r.depth = image_create(g, extent.width, extent.height, DEPTH_FORMAT, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
        VK_IMAGE_ASPECT_DEPTH_BIT)
    name_object(g, VK_OBJECT_TYPE_IMAGE, r.depth.image, "depth")

    query_info := vk_query_pool_create_info()
    query_info.queryType = VK_QUERY_TYPE_TIMESTAMP
    query_info.queryCount = 2 * FRAMES_IN_FLIGHT
    check(vkCreateQueryPool(g.device, &query_info, nil, &r.query_pool), "vkCreateQueryPool")
    (r, "")
}

fn create_layouts(r: *Renderer, g: *Gpu) {
    bindings := [3]VkDescriptorSetLayoutBinding{
        VkDescriptorSetLayoutBinding{0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_VERTEX_BIT, nil},
        VkDescriptorSetLayoutBinding{1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, nil},
        VkDescriptorSetLayoutBinding{2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_VERTEX_BIT, nil},
    }
    info := vk_descriptor_set_layout_create_info()
    info.bindingCount = 3
    info.pBindings = ptr(bindings)
    check(vkCreateDescriptorSetLayout(g.device, &info, nil, &r.set_layout), "vkCreateDescriptorSetLayout")
    compute_binding := VkDescriptorSetLayoutBinding{0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nil}
    info.bindingCount = 1
    info.pBindings = &compute_binding
    check(vkCreateDescriptorSetLayout(g.device, &info, nil, &r.compute_set_layout), "vkCreateDescriptorSetLayout")

    push := VkPushConstantRange{VK_SHADER_STAGE_VERTEX_BIT, 0, u32(sizeof[vec4]())}
    layout_info := vk_pipeline_layout_create_info()
    layout_info.setLayoutCount = 1
    layout_info.pSetLayouts = &r.set_layout
    layout_info.pushConstantRangeCount = 1
    layout_info.pPushConstantRanges = &push
    check(vkCreatePipelineLayout(g.device, &layout_info, nil, &r.pipeline_layout), "vkCreatePipelineLayout")
    compute_push := VkPushConstantRange{VK_SHADER_STAGE_COMPUTE_BIT, 0, u32(sizeof[ComputePush]())}
    layout_info.pSetLayouts = &r.compute_set_layout
    layout_info.pPushConstantRanges = &compute_push
    check(vkCreatePipelineLayout(g.device, &layout_info, nil, &r.compute_layout), "vkCreatePipelineLayout")

    sizes := [3]VkDescriptorPoolSize{
        VkDescriptorPoolSize{VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, FRAMES_IN_FLIGHT},
        VkDescriptorPoolSize{VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, FRAMES_IN_FLIGHT},
        VkDescriptorPoolSize{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2 * FRAMES_IN_FLIGHT},
    }
    pool_info := vk_descriptor_pool_create_info()
    pool_info.maxSets = 2 * FRAMES_IN_FLIGHT
    pool_info.poolSizeCount = 3
    pool_info.pPoolSizes = ptr(sizes)
    check(vkCreateDescriptorPool(g.device, &pool_info, nil, &r.descriptor_pool), "vkCreateDescriptorPool")
}

// The graphics pipeline renders with dynamic rendering: no render pass, the attachment formats
// come in a VkPipelineRenderingCreateInfo chained to the create info.
fn create_pipelines(r: *Renderer, g: *Gpu) {
    vert := shader_module(g, SCENE_VERT)
    frag := shader_module(g, SCENE_FRAG)
    comp := shader_module(g, INSTANCES_COMP)

    stages: [2]VkPipelineShaderStageCreateInfo
    stages[0] = vk_pipeline_shader_stage_create_info()
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT
    stages[0].module = vert
    stages[0].pName = ptr("main")
    stages[1] = vk_pipeline_shader_stage_create_info()
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT
    stages[1].module = frag
    stages[1].pName = ptr("main")

    binding := VkVertexInputBindingDescription{0, u32(sizeof[Vertex]()), VK_VERTEX_INPUT_RATE_VERTEX}
    attributes := [2]VkVertexInputAttributeDescription{
        VkVertexInputAttributeDescription{0, 0, VK_FORMAT_R32G32_SFLOAT, 0},
        VkVertexInputAttributeDescription{1, 0, VK_FORMAT_R32G32_SFLOAT, 8},
    }
    vertex_input := vk_pipeline_vertex_input_state_create_info()
    vertex_input.vertexBindingDescriptionCount = 1
    vertex_input.pVertexBindingDescriptions = &binding
    vertex_input.vertexAttributeDescriptionCount = 2
    vertex_input.pVertexAttributeDescriptions = ptr(attributes)
    input_assembly := vk_pipeline_input_assembly_state_create_info()
    input_assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
    viewport_state := vk_pipeline_viewport_state_create_info()
    viewport_state.viewportCount = 1           // viewport and scissor are dynamic state
    viewport_state.scissorCount = 1
    raster := vk_pipeline_rasterization_state_create_info()
    raster.polygonMode = VK_POLYGON_MODE_FILL
    raster.cullMode = VK_CULL_MODE_NONE
    raster.frontFace = VK_FRONT_FACE_CLOCKWISE
    raster.lineWidth = 1.0
    multisample := vk_pipeline_multisample_state_create_info()
    multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT
    depth := vk_pipeline_depth_stencil_state_create_info()
    depth.depthTestEnable = VK_TRUE
    depth.depthWriteEnable = VK_TRUE
    depth.depthCompareOp = VK_COMPARE_OP_LESS
    blend_attachment := VkPipelineColorBlendAttachmentState{
        colorWriteMask: VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
    }
    blend := vk_pipeline_color_blend_state_create_info()
    blend.attachmentCount = 1
    blend.pAttachments = &blend_attachment
    dynamic_states := [2]i32{VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR}
    dynamic := vk_pipeline_dynamic_state_create_info()
    dynamic.dynamicStateCount = 2
    dynamic.pDynamicStates = ptr(dynamic_states)

    rendering := vk_pipeline_rendering_create_info()
    rendering.colorAttachmentCount = 1
    rendering.pColorAttachmentFormats = &r.color_format
    rendering.depthAttachmentFormat = DEPTH_FORMAT

    info := vk_graphics_pipeline_create_info()
    info.pNext = cast[*u8](&rendering)
    info.stageCount = 2
    info.pStages = ptr(stages)
    info.pVertexInputState = &vertex_input
    info.pInputAssemblyState = &input_assembly
    info.pViewportState = &viewport_state
    info.pRasterizationState = &raster
    info.pMultisampleState = &multisample
    info.pDepthStencilState = &depth
    info.pColorBlendState = &blend
    info.pDynamicState = &dynamic
    info.layout = r.pipeline_layout
    check(vkCreateGraphicsPipelines(g.device, 0, 1, &info, nil, &r.pipeline), "vkCreateGraphicsPipelines")

    compute := vk_compute_pipeline_create_info()
    compute.stage = vk_pipeline_shader_stage_create_info()
    compute.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT
    compute.stage.module = comp
    compute.stage.pName = ptr("main")
    compute.layout = r.compute_layout
    check(vkCreateComputePipelines(g.device, 0, 1, &compute, nil, &r.compute_pipeline), "vkCreateComputePipelines")

    vkDestroyShaderModule(g.device, vert, nil)
    vkDestroyShaderModule(g.device, frag, nil)
    vkDestroyShaderModule(g.device, comp, nil)
}

fn create_frames(r: *Renderer, g: *Gpu) {
    for i in 0..FRAMES_IN_FLIGHT {
        f := &r.frames[i]
        alloc_info := vk_command_buffer_allocate_info()
        alloc_info.commandPool = r.pool
        alloc_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        alloc_info.commandBufferCount = 1
        check(vkAllocateCommandBuffers(g.device, &alloc_info, &f.compute_cmd), "vkAllocateCommandBuffers")
        check(vkAllocateCommandBuffers(g.device, &alloc_info, &f.graphics_cmd), "vkAllocateCommandBuffers")
        fence_info := vk_fence_create_info()
        fence_info.flags = VK_FENCE_CREATE_SIGNALED_BIT       // the first wait returns at once
        check(vkCreateFence(g.device, &fence_info, nil, &f.fence), "vkCreateFence")
        sem_info := vk_semaphore_create_info()
        check(vkCreateSemaphore(g.device, &sem_info, nil, &f.compute_done), "vkCreateSemaphore")

        f.uniforms = buffer_create(g, u64(sizeof[FrameUniforms]()), VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)
        f.instances = buffer_create(g, u64(sizeof[InstanceData]()) * u64(INSTANCE_COUNT), VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)

        layouts := [2]u64{r.set_layout, r.compute_set_layout}
        sets: [2]u64
        set_info := vk_descriptor_set_allocate_info()
        set_info.descriptorPool = r.descriptor_pool
        set_info.descriptorSetCount = 2
        set_info.pSetLayouts = ptr(layouts)
        check(vkAllocateDescriptorSets(g.device, &set_info, ptr(sets)), "vkAllocateDescriptorSets")
        f.set = sets[0]
        f.compute_set = sets[1]

        ubo := VkDescriptorBufferInfo{f.uniforms.buffer, 0, VK_WHOLE_SIZE}
        storage := VkDescriptorBufferInfo{f.instances.buffer, 0, VK_WHOLE_SIZE}
        image := VkDescriptorImageInfo{r.sampler, r.texture.view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL}
        writes: [4]VkWriteDescriptorSet
        for w in 0..4 {
            writes[w] = vk_write_descriptor_set()
            writes[w].descriptorCount = 1
        }
        writes[0].dstSet = f.set
        writes[0].dstBinding = 0
        writes[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
        writes[0].pBufferInfo = &ubo
        writes[1].dstSet = f.set
        writes[1].dstBinding = 1
        writes[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
        writes[1].pImageInfo = &image
        writes[2].dstSet = f.set
        writes[2].dstBinding = 2
        writes[2].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
        writes[2].pBufferInfo = &storage
        writes[3].dstSet = f.compute_set
        writes[3].dstBinding = 0
        writes[3].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
        writes[3].pBufferInfo = &storage
        vkUpdateDescriptorSets(g.device, 4, ptr(writes), 0, nil)
    }
}

// A new depth buffer for a new size (the caller has waited for the device to be idle).
fn renderer_resize(r: *Renderer, g: *Gpu, extent: VkExtent2D) {
    image_destroy(g, &r.depth)
    r.depth = image_create(g, extent.width, extent.height, DEPTH_FORMAT, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
        VK_IMAGE_ASPECT_DEPTH_BIT)
}

// Waits until the next frame slot is free and collects its timestamps. Returns the slot.
fn frame_begin(r: *Renderer, g: *Gpu) -> i64 {
    slot := r.frame % FRAMES_IN_FLIGHT
    f := &r.frames[slot]
    check(vkWaitForFences(g.device, 1, &f.fence, VK_TRUE, FOREVER), "vkWaitForFences")
    if f.submitted {
        stamps: [2]u64
        check(vkGetQueryPoolResults(g.device, r.query_pool, u32(slot * 2), 2, 16, cast[*u8](&stamps), 8,
            VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT), "vkGetQueryPoolResults")
        ticks := if stamps[1] >= stamps[0] { stamps[1] - stamps[0] } else { 0 }
        r.gpu_ms.push(f64(ticks) * f64(g.props.limits.timestampPeriod) / 1e6)
        f.submitted = false
    }
    slot
}

// Where a frame is drawn: an image the caller owns (offscreen target or swapchain image), the
// layout it must be left in, and the semaphores of a swapchain (0 offscreen).
struct Target {
    image: u64
    view: u64
    extent: VkExtent2D
    final_layout: i32       // TRANSFER_SRC_OPTIMAL (read back) or PRESENT_SRC_KHR
    wait: u64               // semaphore to wait for before writing colour (image acquired)
    signal: u64             // semaphore to signal when done (present may start)
}

// Records and submits the frame of `slot` (from frame_begin): the compute pass that writes the
// instances, then the graphics pass that waits for it through a semaphore.
fn frame_render(r: *Renderer, g: *Gpu, slot: i64, t: Target) {
    f := &r.frames[slot]
    seconds := f32(f64(clock_ns() - r.start_ns) / 1e9)
    u := FrameUniforms{r.view_proj, vec4(seconds, 0.0, 0.0, 0.0)}
    memcopy(f.uniforms.mapped, cast[*u8](&u), sizeof[FrameUniforms]())

    // compute: the instances of this frame
    begin := vk_command_buffer_begin_info()
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
    c := f.compute_cmd
    check(vkResetCommandBuffer(c, 0), "vkResetCommandBuffer")
    check(vkBeginCommandBuffer(c, &begin), "vkBeginCommandBuffer")
    vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_COMPUTE, r.compute_pipeline)
    vkCmdBindDescriptorSets(c, VK_PIPELINE_BIND_POINT_COMPUTE, r.compute_layout, 0, 1, &f.compute_set, 0, nil)
    push := ComputePush{u32(r.frame), INSTANCE_COUNT, if r.animate { 1 } else { 0 }, seconds}
    vkCmdPushConstants(c, r.compute_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, u32(sizeof[ComputePush]()), cast[*u8](&push))
    vkCmdDispatch(c, (INSTANCE_COUNT + 63) / 64, 1, 1)
    check(vkEndCommandBuffer(c), "vkEndCommandBuffer")
    compute_cmd := vk_command_buffer_submit_info()
    compute_cmd.commandBuffer = c
    compute_signal := vk_semaphore_submit_info()
    compute_signal.semaphore = f.compute_done
    compute_signal.stageMask = VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT
    submit := vk_submit_info2()
    submit.commandBufferInfoCount = 1
    submit.pCommandBufferInfos = &compute_cmd
    submit.signalSemaphoreInfoCount = 1
    submit.pSignalSemaphoreInfos = &compute_signal
    check(vkQueueSubmit2(g.queue, 1, &submit, 0), "vkQueueSubmit2")

    // graphics
    cmd := f.graphics_cmd
    check(vkResetCommandBuffer(cmd, 0), "vkResetCommandBuffer")
    check(vkBeginCommandBuffer(cmd, &begin), "vkBeginCommandBuffer")
    vkCmdResetQueryPool(cmd, r.query_pool, u32(slot * 2), 2)
    vkCmdWriteTimestamp2(cmd, VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT, r.query_pool, u32(slot * 2))
    label := vk_debug_utils_label_ext()
    label.pLabelName = ptr("scene")
    label.color = [4]f32{0.2, 0.6, 1.0, 1.0}
    g.ext.cmd_begin_label(cmd, &label)

    // the colour image's old content is not needed; the stage matches the acquire semaphore's
    image_barrier(cmd, t.image, VK_IMAGE_ASPECT_COLOR_BIT, VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, 0,
        VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
    // the depth buffer is shared by the frames in flight: wait for the previous frame's tests
    depth_stages := VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT
    image_barrier(cmd, r.depth.image, VK_IMAGE_ASPECT_DEPTH_BIT, depth_stages, VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        depth_stages, VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT | VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL)

    color := vk_rendering_attachment_info()
    color.imageView = t.view
    color.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
    color.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
    color.storeOp = VK_ATTACHMENT_STORE_OP_STORE
    color.clearValue = vk_clear_value_color(vk_clear_color_value_float32([4]f32{0.1, 0.1, 0.15, 1.0}))
    depth := vk_rendering_attachment_info()
    depth.imageView = r.depth.view
    depth.imageLayout = VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL
    depth.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
    depth.storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE
    depth.clearValue = vk_clear_value_depth_stencil(VkClearDepthStencilValue{1.0, 0})
    rendering := vk_rendering_info()
    rendering.renderArea = VkRect2D{VkOffset2D{0, 0}, t.extent}
    rendering.layerCount = 1
    rendering.colorAttachmentCount = 1
    rendering.pColorAttachments = &color
    rendering.pDepthAttachment = &depth
    vkCmdBeginRendering(cmd, &rendering)
    viewport := VkViewport{0.0, 0.0, f32(t.extent.width), f32(t.extent.height), 0.0, 1.0}
    vkCmdSetViewport(cmd, 0, 1, &viewport)
    scissor := VkRect2D{VkOffset2D{0, 0}, t.extent}
    vkCmdSetScissor(cmd, 0, 1, &scissor)
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, r.pipeline)
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, r.pipeline_layout, 0, 1, &f.set, 0, nil)
    offset: u64 = 0
    vkCmdBindVertexBuffers(cmd, 0, 1, &r.vertices.buffer, &offset)
    vkCmdBindIndexBuffer(cmd, r.indices.buffer, 0, VK_INDEX_TYPE_UINT16)
    tint := vec4(1.0, 0.5, 1.0, 1.0)
    vkCmdPushConstants(cmd, r.pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, u32(sizeof[vec4]()), cast[*u8](&tint))
    vkCmdDrawIndexed(cmd, 6, INSTANCE_COUNT, 0, 0, 0)
    vkCmdEndRendering(cmd)

    if t.final_layout == VK_IMAGE_LAYOUT_PRESENT_SRC_KHR {
        image_barrier(cmd, t.image, VK_IMAGE_ASPECT_COLOR_BIT, VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT, VK_PIPELINE_STAGE_2_NONE, 0,
            VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR)
    } else {
        image_barrier(cmd, t.image, VK_IMAGE_ASPECT_COLOR_BIT, VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT, VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_READ_BIT,
            VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, t.final_layout)
    }
    g.ext.cmd_end_label(cmd)
    vkCmdWriteTimestamp2(cmd, VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT, r.query_pool, u32(slot * 2 + 1))
    check(vkEndCommandBuffer(cmd), "vkEndCommandBuffer")

    waits: [2]VkSemaphoreSubmitInfo
    waits[0] = vk_semaphore_submit_info()
    waits[0].semaphore = f.compute_done
    waits[0].stageMask = VK_PIPELINE_STAGE_2_VERTEX_SHADER_BIT
    nwaits: u32 = 1
    if t.wait != 0 {
        waits[1] = vk_semaphore_submit_info()
        waits[1].semaphore = t.wait
        waits[1].stageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT
        nwaits = 2
    }
    signal := vk_semaphore_submit_info()
    signal.semaphore = t.signal
    signal.stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT
    graphics_cmd := vk_command_buffer_submit_info()
    graphics_cmd.commandBuffer = cmd
    submit = vk_submit_info2()
    submit.waitSemaphoreInfoCount = nwaits
    submit.pWaitSemaphoreInfos = ptr(waits)
    submit.commandBufferInfoCount = 1
    submit.pCommandBufferInfos = &graphics_cmd
    if t.signal != 0 {
        submit.signalSemaphoreInfoCount = 1
        submit.pSignalSemaphoreInfos = &signal
    }
    check(vkResetFences(g.device, 1, &f.fence), "vkResetFences")
    check(vkQueueSubmit2(g.queue, 1, &submit, f.fence), "vkQueueSubmit2")
    f.submitted = true
    r.frame += 1
}

fn renderer_destroy(r: *Renderer, g: *Gpu) {
    vkDeviceWaitIdle(g.device)
    for i in 0..FRAMES_IN_FLIGHT {
        f := &r.frames[i]
        vkDestroyFence(g.device, f.fence, nil)
        vkDestroySemaphore(g.device, f.compute_done, nil)
        buffer_destroy(g, &f.uniforms)
        buffer_destroy(g, &f.instances)
    }
    vkDestroyQueryPool(g.device, r.query_pool, nil)
    image_destroy(g, &r.depth)
    vkDestroyPipeline(g.device, r.pipeline, nil)
    vkDestroyPipeline(g.device, r.compute_pipeline, nil)
    vkDestroyPipelineLayout(g.device, r.pipeline_layout, nil)
    vkDestroyPipelineLayout(g.device, r.compute_layout, nil)
    vkDestroyDescriptorPool(g.device, r.descriptor_pool, nil)
    vkDestroyDescriptorSetLayout(g.device, r.set_layout, nil)
    vkDestroyDescriptorSetLayout(g.device, r.compute_set_layout, nil)
    vkDestroySampler(g.device, r.sampler, nil)
    image_destroy(g, &r.texture)
    buffer_destroy(g, &r.vertices)
    buffer_destroy(g, &r.indices)
    vkDestroyCommandPool(g.device, r.pool, nil)
}

// ---- offscreen rendering -----------------------------------------------------------------------

struct Offscreen {
    pixels: []u8            // RGBA8, rows top to bottom, of the last frame
    frames: i64
    gpu_ms: []f64           // GPU time per frame (timestamps)
    device: str
    validation: bool
}

// Renders `frames` frames into per-slot offscreen colour images with FRAMES_IN_FLIGHT frames in
// flight and reads the last one back. "" or why Vulkan cannot be used here.
fn render_offscreen(width: u32, height: u32, frames: i64) -> (Offscreen, str) {
    out: Offscreen
    g: Gpu
    defer { gpu_destroy(&g) }
    problem := gpu_create_instance(&g, "vk_renderer", []str{}, true)
    if problem == "" { problem = gpu_pick_device(&g, 0) }
    if problem == "" { problem = gpu_create_device(&g, false) }
    if problem != "" { return (out, problem) }
    out.device = clone(from_cstr(ptr(g.props.deviceName)))
    out.validation = g.validation

    extent := VkExtent2D{width, height}
    r, rproblem := renderer_create(&g, VK_FORMAT_R8G8B8A8_UNORM, extent)
    if rproblem != "" { return (out, rproblem) }
    targets: [FRAMES_IN_FLIGHT]Image2D
    for i in 0..FRAMES_IN_FLIGHT {
        targets[i] = image_create(&g, width, height, VK_FORMAT_R8G8B8A8_UNORM,
            VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, VK_IMAGE_ASPECT_COLOR_BIT)
        name_object(&g, VK_OBJECT_TYPE_IMAGE, targets[i].image, fmt("offscreen target ", i))
    }
    last := 0
    for n in 0..frames {
        slot := r.frame_begin(&g)
        last = slot
        r.frame_render(&g, slot, Target{targets[slot].image, targets[slot].view, extent, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, 0, 0})
    }
    // collect the timestamps of the frames still in flight
    for n in 0..FRAMES_IN_FLIGHT {
        r.frame_begin(&g)
        r.frame += 1
    }

    // read back the last frame (it was left in TRANSFER_SRC_OPTIMAL)
    nbytes := u64(width) * u64(height) * 4
    readback := buffer_create(&g, nbytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)
    cmd := one_shot_begin(&g, r.pool)
    region := VkBufferImageCopy{
        imageSubresource: VkImageSubresourceLayers{VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        imageExtent: VkExtent3D{width, height, 1},
    }
    vkCmdCopyImageToBuffer(cmd, targets[last].image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.buffer, 1, &region)
    one_shot_end(&g, r.pool, cmd)
    out.pixels = alloc[u8](i64(nbytes))
    memcopy(ptr(out.pixels), readback.mapped, i64(nbytes))
    out.frames = frames
    out.gpu_ms = r.gpu_ms.items()

    buffer_destroy(&g, &readback)
    r.renderer_destroy(&g)
    for i in 0..FRAMES_IN_FLIGHT { image_destroy(&g, &targets[i]) }
    (out, "")
}
