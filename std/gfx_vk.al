// std.gfx on Vulkan 1.3: the backend `use std.gfx` picks on Linux (an X11 window of std.window,
// VK_KHR_xlib_surface); on Windows a program gets it with `use std.gfx_vk` instead of
// `use std.gfx` (VK_KHR_win32_surface). Derived from examples/vk_renderer: dynamic rendering
// and synchronization2, two frames in flight, a swapchain recreated when the window's size or
// g.vsync changes (FIFO with vsync; MAILBOX, else IMMEDIATE without), one descriptor set per
// texture (a combined image sampler), push constants for the view, one pipeline per blend mode
// and colour format. The shaders are SPIR-V compiled ahead of time (std/gfx_shaders.al).
use std.gfx_core
use std.gfx_shaders
use std.window
use std.image
use std.vk

priv const FRAMES = 2
priv const MAX_IMAGES = 8
priv const FOREVER: u64 = 0xFFFF_FFFF_FFFF_FFFF
priv const TEX_FORMAT: i32 = VK_FORMAT_R8G8B8A8_UNORM
priv const VALIDATION_LAYER = "VK_LAYER_KHRONOS_validation"

// Validation errors and warnings the debug messenger has seen (GfxDesc.debug), all renderers
// of the program together; each is also written to standard error. The tests check it is 0.
__gfx_vk_messages: i64

priv fn on_message(severity: u32, types: u32, data: *VkDebugUtilsMessengerCallbackDataEXT, user: *u8) -> u32 {
    if severity & (VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) != 0 {
        __gfx_vk_messages += 1
        eprint(concat("gfx: vulkan: ", from_cstr(data.pMessage)))
    }
    VK_FALSE
}

priv struct Buf {
    buffer: u64
    memory: u64
    size: u64
    mapped: *u8
}

priv struct Tex {
    image: u64
    memory: u64
    view: u64
}

priv struct Vk {
    instance: *u8
    messenger: u64
    destroy_messenger: fn(*u8, u64, *VkAllocationCallbacks)
    physical: *u8
    device: *u8
    queue: *u8
    family: u32
    memory: VkPhysicalDeviceMemoryProperties
    win: *Window
    surface: u64
    swapchain: u64
    sc_format: i32
    sc_extent: VkExtent2D
    sc_vsync: bool
    nimages: i64                    // swapchain images (fixed arrays: rebuilding allocates nothing)
    images: [MAX_IMAGES]u64
    views: [MAX_IMAGES]u64
    rendered: [MAX_IMAGES]u64       // per swapchain image: signalled when its frame is drawn
    acquired: [FRAMES]u64           // per frame slot: signalled when the acquired image is free
    rebuild: bool
    image_index: u32
    pool: u64
    cmds: [FRAMES]*u8
    fences: [FRAMES]u64
    frame: i64
    set_layout: u64
    layout: u64
    pipelines: [2][2]u64            // [format: textures, swapchain][Blend]
    pipeline_format: i32            // the swapchain format of pipelines[1]
    samplers: [2]u64                // by Filter
    desc_pool: u64
    sets: []u64                     // by texture id
    texs: []Tex
    vbuf: Buf
    mapped: []GfxVertex
    max_vertices: i64
    staging: Buf
    screen_tex: i64
}

priv fn vk(g: *Gfx) -> *Vk { cast[*Vk](g.os) }

priv fn check(r: i32, what: str) {
    if r != VK_SUCCESS { panic(fmt("gfx: ", what, ": ", vk_result_name(r))) }
}

priv fn c_names(names: []str) -> []*u8 {
    out := alloc[*u8](names.len)
    for i, n in names { out[i] = cstr(n) }
    out
}

priv fn has_layer(name: str) -> bool {
    count: u32
    vkEnumerateInstanceLayerProperties(&count, nil)
    layers := alloc[VkLayerProperties](i64(count))
    vkEnumerateInstanceLayerProperties(&count, ptr(layers))
    for i in 0..i64(count) {
        if from_cstr(ptr(layers[i].layerName)) == name { return true }
    }
    false
}

priv fn has_instance_extension(name: str) -> bool { has_instance_extension("", name) }

// `layer`: "" for the extensions of the loader and the drivers, else those a layer adds.
priv fn has_instance_extension(layer: str, name: str) -> bool {
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

priv fn has_device_extension(physical: *u8, name: str) -> bool {
    count: u32
    vkEnumerateDeviceExtensionProperties(physical, nil, &count, nil)
    exts := alloc[VkExtensionProperties](i64(count))
    vkEnumerateDeviceExtensionProperties(physical, nil, &count, ptr(exts))
    for i in 0..i64(count) {
        if from_cstr(ptr(exts[i].extensionName)) == name { return true }
    }
    false
}

when TARGET_OS == Windows {
    priv const SURFACE_EXTENSION = VK_KHR_WIN32_SURFACE_EXTENSION_NAME
    priv fn create_surface(v: *Vk, w: *Window) -> i32 {
        info := vk_win32_surface_create_info_khr()
        info.hinstance = win32_hinstance(w)
        info.hwnd = win32_hwnd(w)
        vkCreateWin32SurfaceKHR(v.instance, &info, nil, &v.surface)
    }
} else {
    priv const SURFACE_EXTENSION = VK_KHR_XLIB_SURFACE_EXTENSION_NAME
    priv fn create_surface(v: *Vk, w: *Window) -> i32 {
        info := vk_xlib_surface_create_info_khr()
        info.dpy = x11_display(w)
        info.window = x11_window(w)
        vkCreateXlibSurfaceKHR(v.instance, &info, nil, &v.surface)
    }
}

// ---- memory ----------------------------------------------------------------------------------

priv fn allocate(v: *Vk, req: *VkMemoryRequirements, flags: u32) -> u64 {
    index := -1
    for i in 0..i64(v.memory.memoryTypeCount) {
        if req.memoryTypeBits >> u32(i) & 1 == 1 && v.memory.memoryTypes[i].propertyFlags & flags == flags {
            index = i
            break
        }
    }
    if index < 0 { panic(fmt("gfx: no Vulkan memory type with flags ", hex(u64(flags)))) }
    info := vk_memory_allocate_info()
    info.allocationSize = req.size
    info.memoryTypeIndex = u32(index)
    memory: u64
    check(vkAllocateMemory(v.device, &info, nil, &memory), "vkAllocateMemory")
    memory
}

// A host-visible, coherent, mapped buffer.
priv fn host_buffer(v: *Vk, size: u64, usage: u32) -> Buf {
    b := Buf{size: size}
    info := vk_buffer_create_info()
    info.size = size
    info.usage = usage
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
    check(vkCreateBuffer(v.device, &info, nil, &b.buffer), "vkCreateBuffer")
    req: VkMemoryRequirements
    vkGetBufferMemoryRequirements(v.device, b.buffer, &req)
    b.memory = allocate(v, &req, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)
    check(vkBindBufferMemory(v.device, b.buffer, b.memory, 0), "vkBindBufferMemory")
    check(vkMapMemory(v.device, b.memory, 0, VK_WHOLE_SIZE, 0, &b.mapped), "vkMapMemory")
    b
}

priv fn free_buffer(v: *Vk, b: *Buf) {
    if b.buffer == 0 { return }
    vkDestroyBuffer(v.device, b.buffer, nil)
    vkFreeMemory(v.device, b.memory, nil)
    *b = Buf{}
}

priv fn view_of(v: *Vk, image: u64, format: i32, coverage: bool) -> u64 {
    info := vk_image_view_create_info()
    info.image = image
    info.viewType = VK_IMAGE_VIEW_TYPE_2D
    info.format = format
    if coverage {
        info.components = VkComponentMapping{VK_COMPONENT_SWIZZLE_ONE, VK_COMPONENT_SWIZZLE_ONE, VK_COMPONENT_SWIZZLE_ONE, VK_COMPONENT_SWIZZLE_R}
    }
    info.subresourceRange = VkImageSubresourceRange{VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}
    view: u64
    check(vkCreateImageView(v.device, &info, nil, &view), "vkCreateImageView")
    view
}

priv fn barrier(cmd: *u8, image: u64, src_stage: u64, src_access: u64, dst_stage: u64, dst_access: u64, old_layout: i32, new_layout: i32) {
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
    b.subresourceRange = VkImageSubresourceRange{VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}
    dep := vk_dependency_info()
    dep.imageMemoryBarrierCount = 1
    dep.pImageMemoryBarriers = &b
    vkCmdPipelineBarrier2(cmd, &dep)
}

// a texture being sampled -> drawn into, and back
priv const SAMPLED_STAGE = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT
priv const SAMPLED_ACCESS = VK_ACCESS_2_SHADER_SAMPLED_READ_BIT
priv const DRAWN_STAGE = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT
priv const DRAWN_ACCESS = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT

priv fn one_shot_begin(v: *Vk) -> *u8 {
    info := vk_command_buffer_allocate_info()
    info.commandPool = v.pool
    info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
    info.commandBufferCount = 1
    cmd: *u8
    check(vkAllocateCommandBuffers(v.device, &info, &cmd), "vkAllocateCommandBuffers")
    begin := vk_command_buffer_begin_info()
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
    check(vkBeginCommandBuffer(cmd, &begin), "vkBeginCommandBuffer")
    cmd
}

// Submits, waits for the queue to be idle (also for the frames in flight), frees the buffer.
priv fn one_shot_end(v: *Vk, cmd: *u8) {
    check(vkEndCommandBuffer(cmd), "vkEndCommandBuffer")
    info := vk_command_buffer_submit_info()
    info.commandBuffer = cmd
    submit := vk_submit_info2()
    submit.commandBufferInfoCount = 1
    submit.pCommandBufferInfos = &info
    check(vkQueueSubmit2(v.queue, 1, &submit, 0), "vkQueueSubmit2")
    check(vkQueueWaitIdle(v.queue), "vkQueueWaitIdle")
    c := cmd
    vkFreeCommandBuffers(v.device, v.pool, 1, &c)
}

priv fn shader(v: *Vk, spirv: str) -> u64 {
    words := alloc[u32](spirv.len / 4)
    memcopy(ptr(words), ptr(spirv), words.len * 4)
    info := vk_shader_module_create_info()
    info.codeSize = u64(words.len * 4)
    info.pCode = ptr(words)
    m: u64
    check(vkCreateShaderModule(v.device, &info, nil, &m), "vkCreateShaderModule")
    m
}

// The two pipelines (alpha, additive) for colour attachments of `format`.
priv fn make_pipelines(v: *Vk, format: i32) -> [2]u64 {
    vert := shader(v, __GFX_VERT_SPV)
    frag := shader(v, __GFX_FRAG_SPV)
    stages: [2]VkPipelineShaderStageCreateInfo
    stages[0] = vk_pipeline_shader_stage_create_info()
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT
    stages[0].module = vert
    stages[0].pName = ptr("main")
    stages[1] = vk_pipeline_shader_stage_create_info()
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT
    stages[1].module = frag
    stages[1].pName = ptr("main")
    binding := VkVertexInputBindingDescription{0, u32(sizeof[GfxVertex]()), VK_VERTEX_INPUT_RATE_VERTEX}
    attributes := [3]VkVertexInputAttributeDescription{
        VkVertexInputAttributeDescription{0, 0, VK_FORMAT_R32G32_SFLOAT, 0},
        VkVertexInputAttributeDescription{1, 0, VK_FORMAT_R32G32_SFLOAT, 8},
        VkVertexInputAttributeDescription{2, 0, VK_FORMAT_R8G8B8A8_UNORM, 16},
    }
    vertex_input := vk_pipeline_vertex_input_state_create_info()
    vertex_input.vertexBindingDescriptionCount = 1
    vertex_input.pVertexBindingDescriptions = &binding
    vertex_input.vertexAttributeDescriptionCount = 3
    vertex_input.pVertexAttributeDescriptions = ptr(attributes)
    assembly := vk_pipeline_input_assembly_state_create_info()
    assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
    viewport := vk_pipeline_viewport_state_create_info()
    viewport.viewportCount = 1
    viewport.scissorCount = 1
    raster := vk_pipeline_rasterization_state_create_info()
    raster.polygonMode = VK_POLYGON_MODE_FILL
    raster.cullMode = VK_CULL_MODE_NONE
    raster.frontFace = VK_FRONT_FACE_CLOCKWISE
    raster.lineWidth = 1.0
    multisample := vk_pipeline_multisample_state_create_info()
    multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT
    depth := vk_pipeline_depth_stencil_state_create_info()
    dynamic_states := [2]i32{VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR}
    dynamic := vk_pipeline_dynamic_state_create_info()
    dynamic.dynamicStateCount = 2
    dynamic.pDynamicStates = ptr(dynamic_states)
    rendering := vk_pipeline_rendering_create_info()
    rendering.colorAttachmentCount = 1
    rendering.pColorAttachmentFormats = &format
    out: [2]u64
    for b in 0..2 {
        attachment := VkPipelineColorBlendAttachmentState{
            blendEnable: VK_TRUE, srcColorBlendFactor: VK_BLEND_FACTOR_SRC_ALPHA, colorBlendOp: VK_BLEND_OP_ADD,
            alphaBlendOp: VK_BLEND_OP_ADD,
            colorWriteMask: VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
        }
        if b == 0 {
            attachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
            attachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE
            attachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
        } else {
            attachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE
            attachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ZERO
            attachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE
        }
        blend := vk_pipeline_color_blend_state_create_info()
        blend.attachmentCount = 1
        blend.pAttachments = &attachment
        info := vk_graphics_pipeline_create_info()
        info.pNext = cast[*u8](&rendering)
        info.stageCount = 2
        info.pStages = ptr(stages)
        info.pVertexInputState = &vertex_input
        info.pInputAssemblyState = &assembly
        info.pViewportState = &viewport
        info.pRasterizationState = &raster
        info.pMultisampleState = &multisample
        info.pDepthStencilState = &depth
        info.pColorBlendState = &blend
        info.pDynamicState = &dynamic
        info.layout = v.layout
        check(vkCreateGraphicsPipelines(v.device, 0, 1, &info, nil, &out[b]), "vkCreateGraphicsPipelines")
    }
    vkDestroyShaderModule(v.device, vert, nil)
    vkDestroyShaderModule(v.device, frag, nil)
    out
}

// ---- instance and device ---------------------------------------------------------------------

// Instance, surface (if w is not nil), device, queue, layouts, pipelines, buffers. "" or why
// Vulkan cannot be used here.
priv fn open_device(g: *Gfx, v: *Vk, w: *Window, desc: GfxDesc) -> str {
    exts := vec[str]()
    if w != nil {
        for e in []str{VK_KHR_SURFACE_EXTENSION_NAME, SURFACE_EXTENSION} {
            if !has_instance_extension(e) { return fmt("the Vulkan instance extension ", e, " is not available") }
            exts.push(e)
        }
    }
    validate := desc.debug && has_layer(VALIDATION_LAYER) && has_instance_extension(VK_EXT_DEBUG_UTILS_EXTENSION_NAME)
    if desc.debug {
        eprint(if validate { "gfx: Vulkan validation layer on" } else { "gfx: the Vulkan validation layer is not installed: running without it" })
    }
    if validate { exts.push(VK_EXT_DEBUG_UTILS_EXTENSION_NAME) }
    layers := if validate { []str{VALIDATION_LAYER} } else { []str{} }
    app := vk_application_info()
    app.pApplicationName = ptr("std.gfx")
    app.pEngineName = ptr("std.gfx")
    app.apiVersion = VK_API_VERSION_1_3
    info := vk_instance_create_info()
    info.pApplicationInfo = &app
    // with the layer: synchronization validation too (missing barriers), off by default
    on: u32 = VK_TRUE
    layer := cstr(VALIDATION_LAYER)
    setting := VkLayerSettingEXT{layer, ptr("validate_sync"), VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, cast[*u8](&on)}
    settings := vk_layer_settings_create_info_ext()
    settings.settingCount = 1
    settings.pSettings = &setting
    if validate && has_instance_extension(VALIDATION_LAYER, VK_EXT_LAYER_SETTINGS_EXTENSION_NAME) {
        exts.push(VK_EXT_LAYER_SETTINGS_EXTENSION_NAME)
        info.pNext = cast[*u8](&settings)
    }
    info.enabledLayerCount = u32(layers.len)
    info.ppEnabledLayerNames = ptr(c_names(layers))
    info.enabledExtensionCount = u32(exts.len)
    info.ppEnabledExtensionNames = ptr(c_names(exts.items()))
    r := vkCreateInstance(&info, nil, &v.instance)
    if r != VK_SUCCESS { return fmt("vkCreateInstance: ", vk_result_name(r)) }
    if validate {
        m := vk_debug_utils_messenger_create_info_ext()
        m.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
        m.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
            VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT
        m.pfnUserCallback = cast[*u8](on_message)
        create := cast[fn(*u8, *VkDebugUtilsMessengerCreateInfoEXT, *VkAllocationCallbacks, *u64) -> i32](
            vkGetInstanceProcAddr(v.instance, ptr("vkCreateDebugUtilsMessengerEXT")))
        v.destroy_messenger = cast[fn(*u8, u64, *VkAllocationCallbacks)](vkGetInstanceProcAddr(v.instance, ptr("vkDestroyDebugUtilsMessengerEXT")))
        check(create(v.instance, &m, nil, &v.messenger), "vkCreateDebugUtilsMessengerEXT")
    }
    if w != nil {
        r = create_surface(v, w)
        if r != VK_SUCCESS { return fmt("creating the window surface: ", vk_result_name(r)) }
    }

    // a Vulkan 1.3 device with dynamic rendering and synchronization2 and a graphics queue
    // (that presents to the surface); discrete before integrated GPUs, a CPU device first if asked
    count: u32
    vkEnumeratePhysicalDevices(v.instance, &count, nil)
    devices := alloc[*u8](i64(count))
    vkEnumeratePhysicalDevices(v.instance, &count, ptr(devices))
    best := -1
    name := ""
    for d in devices[..i64(count)] {
        props: VkPhysicalDeviceProperties
        vkGetPhysicalDeviceProperties(d, &props)
        if props.apiVersion < VK_API_VERSION_1_3 { continue }
        f13 := vk_physical_device_vulkan13_features()
        f2 := vk_physical_device_features2()
        f2.pNext = cast[*u8](&f13)
        vkGetPhysicalDeviceFeatures2(d, &f2)
        if f13.dynamicRendering != VK_TRUE || f13.synchronization2 != VK_TRUE { continue }
        if w != nil && !has_device_extension(d, VK_KHR_SWAPCHAIN_EXTENSION_NAME) { continue }
        n: u32
        vkGetPhysicalDeviceQueueFamilyProperties(d, &n, nil)
        families := alloc[VkQueueFamilyProperties](i64(n))
        vkGetPhysicalDeviceQueueFamilyProperties(d, &n, ptr(families))
        family := -1
        for i in 0..i64(n) {
            if families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT == 0 { continue }
            if w != nil {
                present: u32
                vkGetPhysicalDeviceSurfaceSupportKHR(d, u32(i), v.surface, &present)
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
            VK_PHYSICAL_DEVICE_TYPE_CPU => if desc.software { 4 } else { 0 }
            _ => 0
        }
        if score > best {
            best = score
            v.physical = d
            v.family = u32(family)
            name = clone(from_cstr(ptr(props.deviceName)))
        }
    }
    if v.physical == nil { return "no Vulkan 1.3 device with dynamic rendering and synchronization2" }
    g.device = name
    vkGetPhysicalDeviceMemoryProperties(v.physical, &v.memory)
    priority: f32 = 1.0
    queue_info := vk_device_queue_create_info()
    queue_info.queueFamilyIndex = v.family
    queue_info.queueCount = 1
    queue_info.pQueuePriorities = &priority
    f13 := vk_physical_device_vulkan13_features()
    f13.dynamicRendering = VK_TRUE
    f13.synchronization2 = VK_TRUE
    f2 := vk_physical_device_features2()
    f2.pNext = cast[*u8](&f13)
    dexts := if w != nil { []str{VK_KHR_SWAPCHAIN_EXTENSION_NAME} } else { []str{} }
    dinfo := vk_device_create_info()
    dinfo.pNext = cast[*u8](&f2)
    dinfo.queueCreateInfoCount = 1
    dinfo.pQueueCreateInfos = &queue_info
    dinfo.enabledExtensionCount = u32(dexts.len)
    dinfo.ppEnabledExtensionNames = ptr(c_names(dexts))
    r = vkCreateDevice(v.physical, &dinfo, nil, &v.device)
    if r != VK_SUCCESS { return fmt("vkCreateDevice: ", vk_result_name(r)) }
    vkGetDeviceQueue(v.device, v.family, 0, &v.queue)

    pool_info := vk_command_pool_create_info()
    pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
    pool_info.queueFamilyIndex = v.family
    check(vkCreateCommandPool(v.device, &pool_info, nil, &v.pool), "vkCreateCommandPool")
    for i in 0..FRAMES {
        cinfo := vk_command_buffer_allocate_info()
        cinfo.commandPool = v.pool
        cinfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        cinfo.commandBufferCount = 1
        check(vkAllocateCommandBuffers(v.device, &cinfo, &v.cmds[i]), "vkAllocateCommandBuffers")
        fence_info := vk_fence_create_info()
        fence_info.flags = VK_FENCE_CREATE_SIGNALED_BIT
        check(vkCreateFence(v.device, &fence_info, nil, &v.fences[i]), "vkCreateFence")
        sem_info := vk_semaphore_create_info()
        check(vkCreateSemaphore(v.device, &sem_info, nil, &v.acquired[i]), "vkCreateSemaphore")
    }
    for i in 0..2 {
        s := vk_sampler_create_info()
        s.magFilter = if i == 0 { VK_FILTER_NEAREST } else { VK_FILTER_LINEAR }
        s.minFilter = s.magFilter
        s.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST
        s.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        s.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        s.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        check(vkCreateSampler(v.device, &s, nil, &v.samplers[i]), "vkCreateSampler")
    }
    binding := VkDescriptorSetLayoutBinding{0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, nil}
    linfo := vk_descriptor_set_layout_create_info()
    linfo.bindingCount = 1
    linfo.pBindings = &binding
    check(vkCreateDescriptorSetLayout(v.device, &linfo, nil, &v.set_layout), "vkCreateDescriptorSetLayout")
    push := VkPushConstantRange{VK_SHADER_STAGE_VERTEX_BIT, 0, 16}
    playout := vk_pipeline_layout_create_info()
    playout.setLayoutCount = 1
    playout.pSetLayouts = &v.set_layout
    playout.pushConstantRangeCount = 1
    playout.pPushConstantRanges = &push
    check(vkCreatePipelineLayout(v.device, &playout, nil, &v.layout), "vkCreatePipelineLayout")
    ntex := len(g.texs)
    size := VkDescriptorPoolSize{VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, u32(ntex)}
    dpool := vk_descriptor_pool_create_info()
    dpool.maxSets = u32(ntex)
    dpool.poolSizeCount = 1
    dpool.pPoolSizes = &size
    check(vkCreateDescriptorPool(v.device, &dpool, nil, &v.desc_pool), "vkCreateDescriptorPool")
    v.sets = alloc[u64](ntex)
    set_layouts := alloc[u64](ntex)
    fill(set_layouts, v.set_layout)
    sinfo := vk_descriptor_set_allocate_info()
    sinfo.descriptorPool = v.desc_pool
    sinfo.descriptorSetCount = u32(ntex)
    sinfo.pSetLayouts = ptr(set_layouts)
    check(vkAllocateDescriptorSets(v.device, &sinfo, ptr(v.sets)), "vkAllocateDescriptorSets")
    v.texs = alloc[Tex](ntex)
    v.pipelines[0] = make_pipelines(v, TEX_FORMAT)

    v.max_vertices = __gfx_max_vertices(desc)
    v.vbuf = host_buffer(v, u64(FRAMES * v.max_vertices * sizeof[GfxVertex]()), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT)
    v.mapped = mkslice[GfxVertex](cast[*GfxVertex](v.vbuf.mapped), FRAMES * v.max_vertices)
    white := [4]u8{255, 255, 255, 255}
    make_texture(g, v, 1, 1, 1, 4, false, white[..])
    ""
}

// (Re)creates the swapchain for the window's size and g.vsync. false while the window has no area.
priv fn build_swapchain(g: *Gfx, v: *Vk) -> bool {
    caps: VkSurfaceCapabilitiesKHR
    r := vkGetPhysicalDeviceSurfaceCapabilitiesKHR(v.physical, v.surface, &caps)
    if r == VK_ERROR_SURFACE_LOST_KHR || r == VK_ERROR_DEVICE_LOST {
        g.lost = fmt("vkGetPhysicalDeviceSurfaceCapabilitiesKHR: ", vk_result_name(r))
        return false
    }
    check(r, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")
    ww, wh := v.win.size()
    extent := caps.currentExtent
    if extent.width == 0xFFFFFFFF {
        extent.width = u32(clamp(ww, i64(caps.minImageExtent.width), i64(caps.maxImageExtent.width)))
        extent.height = u32(clamp(wh, i64(caps.minImageExtent.height), i64(caps.maxImageExtent.height)))
    }
    if extent.width == 0 || extent.height == 0 { return false }
    if v.sc_format == 0 {
        n: u32
        vkGetPhysicalDeviceSurfaceFormatsKHR(v.physical, v.surface, &n, nil)
        formats := alloc[VkSurfaceFormatKHR](i64(n))
        vkGetPhysicalDeviceSurfaceFormatsKHR(v.physical, v.surface, &n, ptr(formats))
        v.sc_format = formats[0].format
        for f in formats {
            if (f.format == VK_FORMAT_B8G8R8A8_UNORM || f.format == VK_FORMAT_R8G8B8A8_UNORM) && f.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR {
                v.sc_format = f.format
                break
            }
        }
    }
    mode := VK_PRESENT_MODE_FIFO_KHR
    if !g.vsync {
        n: u32
        vkGetPhysicalDeviceSurfacePresentModesKHR(v.physical, v.surface, &n, nil)
        modes := alloc[i32](i64(n))
        vkGetPhysicalDeviceSurfacePresentModesKHR(v.physical, v.surface, &n, ptr(modes))
        if contains(modes, VK_PRESENT_MODE_MAILBOX_KHR) {
            mode = VK_PRESENT_MODE_MAILBOX_KHR
        } else if contains(modes, VK_PRESENT_MODE_IMMEDIATE_KHR) {
            mode = VK_PRESENT_MODE_IMMEDIATE_KHR
        }
    }
    count := caps.minImageCount + 1
    if caps.maxImageCount != 0 { count = min(count, caps.maxImageCount) }
    vkDeviceWaitIdle(v.device)
    for x in v.views[..v.nimages] { vkDestroyImageView(v.device, x, nil) }
    for s in v.rendered[..v.nimages] { vkDestroySemaphore(v.device, s, nil) }
    info := vk_swapchain_create_info_khr()
    info.surface = v.surface
    info.minImageCount = count
    info.imageFormat = v.sc_format
    info.imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR
    info.imageExtent = extent
    info.imageArrayLayers = 1
    info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
    info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE
    info.preTransform = caps.currentTransform
    info.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
    info.presentMode = mode
    info.clipped = VK_TRUE
    info.oldSwapchain = v.swapchain
    handle: u64
    r = vkCreateSwapchainKHR(v.device, &info, nil, &handle)
    if r != VK_SUCCESS {
        g.lost = fmt("vkCreateSwapchainKHR: ", vk_result_name(r))
        return false
    }
    if v.swapchain != 0 { vkDestroySwapchainKHR(v.device, v.swapchain, nil) }
    v.swapchain = handle
    v.sc_extent = extent
    v.sc_vsync = g.vsync
    n: u32
    vkGetSwapchainImagesKHR(v.device, handle, &n, nil)
    assert n <= MAX_IMAGES, "gfx: more swapchain images than expected"
    vkGetSwapchainImagesKHR(v.device, handle, &n, ptr(v.images))
    v.nimages = i64(n)
    sem_info := vk_semaphore_create_info()
    for i in 0..i64(n) {
        v.views[i] = view_of(v, v.images[i], v.sc_format, false)
        check(vkCreateSemaphore(v.device, &sem_info, nil, &v.rendered[i]), "vkCreateSemaphore")
    }
    if v.pipeline_format != v.sc_format {
        if v.pipeline_format != 0 && v.pipeline_format != TEX_FORMAT {
            for b in 0..2 { vkDestroyPipeline(v.device, v.pipelines[1][b], nil) }
        }
        v.pipelines[1] = if v.sc_format == TEX_FORMAT { v.pipelines[0] } else { make_pipelines(v, v.sc_format) }
        v.pipeline_format = v.sc_format
    }
    g.width = i64(extent.width)
    g.height = i64(extent.height)
    v.rebuild = false
    true
}

// Opens a renderer on the window: a Vulkan 1.3 device (discrete GPUs first) and a swapchain.
// (g, "") or (nil, why it cannot draw here).
fn gfx_open(w: *Window, desc: GfxDesc) -> (*Gfx, str) {
    width, height := w.size()
    g := __gfx_new(max(width, 1), max(height, 1), desc)
    v := new[Vk]()
    v.win = w
    g.os = cast[*u8](v)
    err := open_device(g, v, w, desc)
    if err != "" {
        gfx_close(g)
        return (nil, concat("cannot use Vulkan: ", err))
    }
    v.rebuild = true
    (g, "")
}

// A renderer without a window: the screen is a width x height image that read_pixels returns
// after end_frame. For tests, screenshots and tools.
fn gfx_offscreen(width: i64, height: i64, desc: GfxDesc) -> (*Gfx, str) {
    g := __gfx_new(width, height, desc)
    g.offscreen = true
    v := new[Vk]()
    g.os = cast[*u8](v)
    err := open_device(g, v, nil, desc)
    if err != "" {
        gfx_close(g)
        return (nil, concat("cannot use Vulkan: ", err))
    }
    v.screen_tex = render_texture(g, width, height, FilterNearest).id
    (g, "")
}

// Waits for the GPU and releases everything (not the window).
fn gfx_close(g: *Gfx) {
    v := vk(g)
    if v.device != nil {
        vkDeviceWaitIdle(v.device)
        for i in 0..len(v.texs) { free_tex(v, i) }
        free_buffer(v, &v.vbuf)
        free_buffer(v, &v.staging)
        for x in v.views[..v.nimages] { vkDestroyImageView(v.device, x, nil) }
        for s in v.rendered[..v.nimages] { vkDestroySemaphore(v.device, s, nil) }
        if v.swapchain != 0 { vkDestroySwapchainKHR(v.device, v.swapchain, nil) }
        for b in 0..2 {
            if v.pipeline_format != 0 && v.pipeline_format != TEX_FORMAT { vkDestroyPipeline(v.device, v.pipelines[1][b], nil) }
            vkDestroyPipeline(v.device, v.pipelines[0][b], nil)
        }
        for i in 0..FRAMES {
            vkDestroyFence(v.device, v.fences[i], nil)
            vkDestroySemaphore(v.device, v.acquired[i], nil)
        }
        for i in 0..2 { vkDestroySampler(v.device, v.samplers[i], nil) }
        vkDestroyDescriptorPool(v.device, v.desc_pool, nil)
        vkDestroyPipelineLayout(v.device, v.layout, nil)
        vkDestroyDescriptorSetLayout(v.device, v.set_layout, nil)
        vkDestroyCommandPool(v.device, v.pool, nil)
        vkDestroyDevice(v.device, nil)
    }
    if v.surface != 0 { vkDestroySurfaceKHR(v.instance, v.surface, nil) }
    if v.messenger != 0 { v.destroy_messenger(v.instance, v.messenger, nil) }
    if v.instance != nil { vkDestroyInstance(v.instance, nil) }
    *v = Vk{}
}

// ---- frames ----------------------------------------------------------------------------------

// Starts a frame cleared to `clear` (RGBA8, red in the lowest byte). Follows the window's size
// (g.width, g.height) and g.vsync, waits until the GPU is done with the frame two frames back.
// Returns false when there is nothing to draw into (the window is minimized: it then sleeps
// 10 ms, so a loop that skips the frame does not spin; or the device is lost): skip drawing
// and end_frame.
fn begin_frame(g: *Gfx, clear: u32) -> bool {
    if g.lost != "" { return false }
    v := vk(g)
    slot := (v.frame + 1) % FRAMES
    if v.win != nil {
        ww, wh := v.win.size()
        if v.win.minimized || ww <= 0 || wh <= 0 {
            sleep_ms(10)
            return false
        }
        if v.rebuild || ww != g.width || wh != g.height || g.vsync != v.sc_vsync {
            if !build_swapchain(g, v) {
                if g.lost == "" { sleep_ms(10) }
                return false
            }
        }
    }
    r := vkWaitForFences(v.device, 1, &v.fences[slot], VK_TRUE, FOREVER)
    if r == VK_ERROR_DEVICE_LOST {
        g.lost = "the Vulkan device was lost (VK_ERROR_DEVICE_LOST)"
        return false
    }
    check(r, "vkWaitForFences")
    if v.win != nil {
        r = vkAcquireNextImageKHR(v.device, v.swapchain, FOREVER, v.acquired[slot], 0, &v.image_index)
        if r == VK_ERROR_OUT_OF_DATE_KHR {
            v.rebuild = true
            return false
        }
        if r == VK_SUBOPTIMAL_KHR {
            v.rebuild = true
        } else if r == VK_ERROR_DEVICE_LOST || r == VK_ERROR_SURFACE_LOST_KHR {
            g.lost = fmt("vkAcquireNextImageKHR: ", vk_result_name(r))
            return false
        } else {
            check(r, "vkAcquireNextImageKHR")
        }
    }
    v.frame = slot
    base := slot * v.max_vertices
    __gfx_begin(g, v.mapped[base..base + v.max_vertices], clear)
    true
}

priv fn clear_value(c: u32) -> VkClearValue {
    x := color_vec4(c)
    vk_clear_value_color(vk_clear_color_value_float32([4]f32{x.x, x.y, x.z, x.w}))
}

priv fn start(cmd: *u8, view: u64, w: i64, h: i64, clear: bool, color: u32, layout: u64) {
    att := vk_rendering_attachment_info()
    att.imageView = view
    att.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
    att.loadOp = if clear { VK_ATTACHMENT_LOAD_OP_CLEAR } else { VK_ATTACHMENT_LOAD_OP_LOAD }
    att.storeOp = VK_ATTACHMENT_STORE_OP_STORE
    att.clearValue = clear_value(color)
    extent := VkExtent2D{u32(w), u32(h)}
    info := vk_rendering_info()
    info.renderArea = VkRect2D{VkOffset2D{0, 0}, extent}
    info.layerCount = 1
    info.colorAttachmentCount = 1
    info.pColorAttachments = &att
    vkCmdBeginRendering(cmd, &info)
    viewport := VkViewport{0.0, 0.0, f32(w), f32(h), 0.0, 1.0}
    vkCmdSetViewport(cmd, 0, 1, &viewport)
    view_constants := [4]f32{2.0 / f32(w), 2.0 / f32(h), -1.0, -1.0}
    vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_VERTEX_BIT, 0, 16, cast[*u8](ptr(view_constants)))
}

// Draws the frame and presents it. "" or what failed; a lost device sets g.lost (begin_frame
// then returns false).
fn end_frame(g: *Gfx) -> str {
    __gfx_end(g)
    v := vk(g)
    cmd := v.cmds[v.frame]
    check(vkResetCommandBuffer(cmd, 0), "vkResetCommandBuffer")
    begin := vk_command_buffer_begin_info()
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
    check(vkBeginCommandBuffer(cmd, &begin), "vkBeginCommandBuffer")
    // the screen: this frame's swapchain image (its old content is not needed), or the offscreen texture
    screen_image: u64
    screen_view: u64
    screen_fmt := 0
    if v.win != nil {
        screen_image = v.images[v.image_index]
        screen_view = v.views[v.image_index]
        screen_fmt = 1
        barrier(cmd, screen_image, DRAWN_STAGE, 0, DRAWN_STAGE, DRAWN_ACCESS, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
    } else {
        screen_image = v.texs[v.screen_tex].image
        screen_view = v.texs[v.screen_tex].view
        barrier(cmd, screen_image, SAMPLED_STAGE | VK_PIPELINE_STAGE_2_COPY_BIT, 0, DRAWN_STAGE, DRAWN_ACCESS,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
    }
    start(cmd, screen_view, g.width, g.height, true, g.clear_color, v.layout)
    offset := u64(v.frame * v.max_vertices * sizeof[GfxVertex]())
    vkCmdBindVertexBuffers(cmd, 0, 1, &v.vbuf.buffer, &offset)
    target := 0
    fmt_slot := screen_fmt
    tw := g.width
    th := g.height
    pipeline := -1
    for c in g.cmds[..g.ncmds] {
        if c.kind == __GFX_TARGET {
            id := i64(c.tex)
            if id == target { continue }
            vkCmdEndRendering(cmd)
            if target != 0 {
                barrier(cmd, v.texs[target].image, DRAWN_STAGE, DRAWN_ACCESS, SAMPLED_STAGE, SAMPLED_ACCESS,
                    VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
            }
            target = id
            pipeline = -1
            if id != 0 {
                barrier(cmd, v.texs[id].image, SAMPLED_STAGE, 0, DRAWN_STAGE, DRAWN_ACCESS,
                    VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
                tw = g.texs[id].w
                th = g.texs[id].h
                fmt_slot = 0
                start(cmd, v.texs[id].view, tw, th, false, 0, v.layout)
            } else {
                tw = g.width
                th = g.height
                fmt_slot = screen_fmt
                start(cmd, screen_view, tw, th, false, 0, v.layout)
            }
        } else if c.kind == __GFX_CLEAR {
            att := VkClearAttachment{VK_IMAGE_ASPECT_COLOR_BIT, 0, clear_value(c.color)}
            rect := VkClearRect{VkRect2D{VkOffset2D{0, 0}, VkExtent2D{u32(tw), u32(th)}}, 0, 1}
            vkCmdClearAttachments(cmd, 1, &att, 1, &rect)
        } else if c.count > 0 {
            assert g.texs[c.tex].live, "end_frame: a texture drawn in this frame was freed"
            if i64(c.blend) != pipeline {
                pipeline = i64(c.blend)
                vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, v.pipelines[fmt_slot][pipeline])
            }
            vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, v.layout, 0, 1, &v.sets[c.tex], 0, nil)
            scissor := if c.clip[2] < 0 { VkRect2D{VkOffset2D{0, 0}, VkExtent2D{u32(tw), u32(th)}} } else {
                VkRect2D{VkOffset2D{c.clip[0], c.clip[1]}, VkExtent2D{u32(c.clip[2]), u32(c.clip[3])}} }
            vkCmdSetScissor(cmd, 0, 1, &scissor)
            vkCmdDraw(cmd, u32(c.count), 1, u32(c.first), 0)
        }
    }
    vkCmdEndRendering(cmd)
    if target != 0 {
        barrier(cmd, v.texs[target].image, DRAWN_STAGE, DRAWN_ACCESS, SAMPLED_STAGE, SAMPLED_ACCESS,
            VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    }
    if v.win != nil {
        barrier(cmd, screen_image, DRAWN_STAGE, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT, VK_PIPELINE_STAGE_2_NONE, 0,
            VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR)
    } else {
        barrier(cmd, screen_image, DRAWN_STAGE, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT, SAMPLED_STAGE | VK_PIPELINE_STAGE_2_COPY_BIT,
            SAMPLED_ACCESS | VK_ACCESS_2_TRANSFER_READ_BIT, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    }
    check(vkEndCommandBuffer(cmd), "vkEndCommandBuffer")

    wait := vk_semaphore_submit_info()
    wait.semaphore = v.acquired[v.frame]
    wait.stageMask = DRAWN_STAGE
    signal := vk_semaphore_submit_info()
    cmd_info := vk_command_buffer_submit_info()
    cmd_info.commandBuffer = cmd
    submit := vk_submit_info2()
    submit.commandBufferInfoCount = 1
    submit.pCommandBufferInfos = &cmd_info
    if v.win != nil {
        signal.semaphore = v.rendered[v.image_index]
        signal.stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT
        submit.waitSemaphoreInfoCount = 1
        submit.pWaitSemaphoreInfos = &wait
        submit.signalSemaphoreInfoCount = 1
        submit.pSignalSemaphoreInfos = &signal
    }
    check(vkResetFences(v.device, 1, &v.fences[v.frame]), "vkResetFences")
    r := vkQueueSubmit2(v.queue, 1, &submit, v.fences[v.frame])
    if r == VK_ERROR_DEVICE_LOST {
        g.lost = "the Vulkan device was lost (VK_ERROR_DEVICE_LOST)"
        return g.lost
    }
    check(r, "vkQueueSubmit2")
    if v.win != nil {
        present := vk_present_info_khr()
        present.waitSemaphoreCount = 1
        present.pWaitSemaphores = &v.rendered[v.image_index]
        present.swapchainCount = 1
        present.pSwapchains = &v.swapchain
        present.pImageIndices = &v.image_index
        r = vkQueuePresentKHR(v.queue, &present)
        if r == VK_ERROR_OUT_OF_DATE_KHR || r == VK_SUBOPTIMAL_KHR {
            v.rebuild = true
        } else if r == VK_ERROR_DEVICE_LOST || r == VK_ERROR_SURFACE_LOST_KHR {
            g.lost = fmt("vkQueuePresentKHR: ", vk_result_name(r))
            return g.lost
        } else {
            check(r, "vkQueuePresentKHR")
        }
    }
    ""
}

// ---- textures --------------------------------------------------------------------------------

priv fn free_tex(v: *Vk, id: i64) {
    t := &v.texs[id]
    if t.image == 0 { return }
    vkDestroyImageView(v.device, t.view, nil)
    vkDestroyImage(v.device, t.image, nil)
    vkFreeMemory(v.device, t.memory, nil)
    *t = Tex{}
}

// Records a copy of w x h pixels of `bpp` bytes (rows packed) to (x, y) of texture id, which is
// in TRANSFER_DST_OPTIMAL.
priv fn copy_in(v: *Vk, cmd: *u8, id: i64, x: i64, y: i64, w: i64, h: i64, bpp: i64, pix: []u8) {
    size := u64(w * h * bpp)
    if size > v.staging.size {
        free_buffer(v, &v.staging)
        v.staging = host_buffer(v, max(size, 65536), VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT)
    }
    memcopy(v.staging.mapped, ptr(pix), i64(size))
    region := VkBufferImageCopy{
        imageSubresource: VkImageSubresourceLayers{VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        imageOffset: VkOffset3D{i32(x), i32(y), 0},
        imageExtent: VkExtent3D{u32(w), u32(h), 1},
    }
    vkCmdCopyBufferToImage(cmd, v.staging.buffer, v.texs[id].image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region)
}

// Creates texture `id` (bpp 1: coverage, 4: RGBA) holding `pix` (a render texture: cleared to
// transparent), its view and descriptor; leaves it in SHADER_READ_ONLY_OPTIMAL.
priv fn make_texture(g: *Gfx, v: *Vk, id: i64, w: i64, h: i64, bpp: i64, target: bool, pix: []u8) {
    format := if bpp == 1 { VK_FORMAT_R8_UNORM } else { TEX_FORMAT }
    info := vk_image_create_info()
    info.imageType = VK_IMAGE_TYPE_2D
    info.format = format
    info.extent = VkExtent3D{u32(w), u32(h), 1}
    info.mipLevels = 1
    info.arrayLayers = 1
    info.samples = VK_SAMPLE_COUNT_1_BIT
    info.tiling = VK_IMAGE_TILING_OPTIMAL
    info.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
        (if target { VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT } else { 0 })
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
    info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
    t := &v.texs[id]
    check(vkCreateImage(v.device, &info, nil, &t.image), "vkCreateImage")
    req: VkMemoryRequirements
    vkGetImageMemoryRequirements(v.device, t.image, &req)
    t.memory = allocate(v, &req, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)
    check(vkBindImageMemory(v.device, t.image, t.memory, 0), "vkBindImageMemory")
    t.view = view_of(v, t.image, format, bpp == 1)
    cmd := one_shot_begin(v)
    barrier(cmd, t.image, VK_PIPELINE_STAGE_2_NONE, 0, VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT,
        VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
    if target {
        transparent := vk_clear_color_value_float32([4]f32{0.0, 0.0, 0.0, 0.0})
        range := VkImageSubresourceRange{VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}
        vkCmdClearColorImage(cmd, t.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &transparent, 1, &range)
    } else {
        copy_in(v, cmd, id, 0, 0, w, h, bpp, pix)
    }
    barrier(cmd, t.image, VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT, SAMPLED_STAGE, SAMPLED_ACCESS,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    one_shot_end(v, cmd)
    image := VkDescriptorImageInfo{v.samplers[i64(g.texs[id].filter)], t.view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL}
    write := vk_write_descriptor_set()
    write.dstSet = v.sets[id]
    write.descriptorCount = 1
    write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
    write.pImageInfo = &image
    vkUpdateDescriptorSets(v.device, 1, &write, 0, nil)
}

priv fn new_id(g: *Gfx, w: i64, h: i64, filter: Filter, coverage: bool, target: bool) -> i64 {
    id := g.__gfx_tex_new(w, h, filter, coverage, target)
    if id == 0 { panic(fmt("gfx: more than ", len(g.texs) - 2, " textures (GfxDesc.max_textures)")) }
    id
}

// A texture holding the image (copied to the GPU before it returns): one channel is a
// coverage texture, drawn as the tint's colour with that coverage as alpha (font atlases);
// two, three or four channels are converted to RGBA.
fn texture(g: *Gfx, img: Image, filter: Filter) -> Texture {
    bpp, pix := __gfx_pixels(img)
    id := new_id(g, img.w, img.h, filter, bpp == 1, false)
    make_texture(g, vk(g), id, img.w, img.h, bpp, false, pix)
    Texture{id, img.w, img.h}
}

// A w x h RGBA texture to draw into (set_target) and to draw with; transparent at first.
fn render_texture(g: *Gfx, w: i64, h: i64, filter: Filter) -> Texture {
    id := new_id(g, w, h, filter, false, true)
    make_texture(g, vk(g), id, w, h, 4, true, nil)
    Texture{id, w, h}
}

// Replaces the pixels of t from (x, y) with the image (its channels as for `texture`; one for
// a coverage texture, else at least three). Waits for the GPU; within a frame the new pixels
// are what every draw of that frame shows (they are drawn at end_frame).
fn update_texture(g: *Gfx, t: Texture, x: i64, y: i64, img: Image) {
    assert t.id > 1 && t.id < len(g.texs) && g.texs[t.id].live && !g.texs[t.id].target, "update_texture: not a texture made by `texture`"
    bpp, pix := __gfx_pixels(img)
    assert (bpp == 1) == g.texs[t.id].coverage, "update_texture: a coverage texture takes one channel, an RGBA texture three or four"
    assert x >= 0 && y >= 0 && x + img.w <= t.w && y + img.h <= t.h, "update_texture: outside the texture"
    v := vk(g)
    image := v.texs[t.id].image
    cmd := one_shot_begin(v)
    barrier(cmd, image, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, 0, VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT,
        VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
    copy_in(v, cmd, t.id, x, y, img.w, img.h, bpp, pix)
    barrier(cmd, image, VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT, SAMPLED_STAGE, SAMPLED_ACCESS,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    one_shot_end(v, cmd)
}

// Releases the texture (waits for the GPU). Not between begin_frame and end_frame.
fn free_texture(g: *Gfx, t: Texture) {
    assert !g.in_frame, "free_texture: between begin_frame and end_frame"
    assert t.id > 1 && t.id < len(g.texs) && g.texs[t.id].live, "free_texture: not a live texture"
    v := vk(g)
    vkDeviceWaitIdle(v.device)
    free_tex(v, t.id)
    g.texs[t.id].live = false
}

// The pixels of a texture as an image (4 channels, or 1 for a coverage texture); waits for the GPU.
fn read_texture(g: *Gfx, t: Texture) -> Image {
    assert t.id > 0 && t.id < len(g.texs) && g.texs[t.id].live, "read_texture: not a live texture"
    assert !g.in_frame, "read_texture: between begin_frame and end_frame"
    v := vk(g)
    bpp := if g.texs[t.id].coverage { 1 } else { 4 }
    size := u64(t.w * t.h * bpp)
    if size > v.staging.size {
        free_buffer(v, &v.staging)
        v.staging = host_buffer(v, max(size, 65536), VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT)
    }
    image := v.texs[t.id].image
    cmd := one_shot_begin(v)
    barrier(cmd, image, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_MEMORY_WRITE_BIT, VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
        VK_ACCESS_2_TRANSFER_READ_BIT, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)
    region := VkBufferImageCopy{
        imageSubresource: VkImageSubresourceLayers{VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        imageExtent: VkExtent3D{u32(t.w), u32(t.h), 1},
    }
    vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, v.staging.buffer, 1, &region)
    barrier(cmd, image, VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT, 0, SAMPLED_STAGE, SAMPLED_ACCESS,
        VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    one_shot_end(v, cmd)
    img := image_new(t.w, t.h, bpp)
    memcopy(ptr(img.pix), v.staging.mapped, i64(size))
    img
}

// The screen of a gfx_offscreen renderer after end_frame, as an RGBA image.
fn read_pixels(g: *Gfx) -> Image {
    assert g.offscreen, "read_pixels: only for gfx_offscreen (draw into a render_texture and read_texture it)"
    read_texture(g, Texture{vk(g).screen_tex, g.width, g.height})
}
