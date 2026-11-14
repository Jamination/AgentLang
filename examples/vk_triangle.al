// Renders one colour-interpolated triangle with Vulkan into an offscreen image (no window) and
// saves it as triangle.bmp.
//
//     ALC_STD_DIR=std alc run examples/vk_triangle.al
//
// The steps: instance -> physical device -> device + queue -> colour image + view -> render pass
// -> framebuffer -> pipeline -> vertex buffer -> command buffer (draw, copy image to a buffer)
// -> submit -> map the buffer and write the pixels. The shaders are tests/sys/data/tri.vert and
// tri.frag, compiled to SPIR-V ahead of time and embedded into the executable.
use std.vk

const SIZE: u32 = 256
const FORMAT: i32 = VK_FORMAT_R8G8B8A8_UNORM

// The device and what is needed to allocate from it and submit to it.
struct Gpu {
    instance: *u8
    physical: *u8
    device: *u8
    queue: *u8
    family: u32
    memory: VkPhysicalDeviceMemoryProperties
}

// The offscreen colour attachment.
struct Target {
    image: u64
    memory: u64
    view: u64
    render_pass: u64
    framebuffer: u64
}

// Creates an instance and a device on the first GPU that has a graphics queue. The text result
// is empty on success and says what is missing otherwise.
fn open_gpu() -> (Gpu, str) {
    g: Gpu
    app := vk_application_info()
    app.pApplicationName = ptr("vk_triangle")
    app.apiVersion = VK_API_VERSION_1_0
    instance_info := vk_instance_create_info()
    instance_info.pApplicationInfo = &app
    r := vkCreateInstance(&instance_info, nil, &g.instance)
    if r != VK_SUCCESS {
        return (g, fmt("vkCreateInstance: ", vk_result_name(r)))
    }

    devices: [8]*u8
    count: u32 = 8
    vkEnumeratePhysicalDevices(g.instance, &count, ptr(devices))
    for d in 0..i64(count) {
        families: [16]VkQueueFamilyProperties
        n: u32 = 16
        vkGetPhysicalDeviceQueueFamilyProperties(devices[d], &n, ptr(families))
        for f in 0..i64(n) {
            if g.physical == nil && families[f].queueFlags & VK_QUEUE_GRAPHICS_BIT != 0 {
                g.physical = devices[d]
                g.family = u32(f)
            }
        }
    }
    if g.physical == nil {
        vkDestroyInstance(g.instance, nil)
        return (g, "no physical device with a graphics queue")
    }

    priority: f32 = 1.0
    queue_info := vk_device_queue_create_info()
    queue_info.queueFamilyIndex = g.family
    queue_info.queueCount = 1
    queue_info.pQueuePriorities = &priority
    device_info := vk_device_create_info()
    device_info.queueCreateInfoCount = 1
    device_info.pQueueCreateInfos = &queue_info
    r = vkCreateDevice(g.physical, &device_info, nil, &g.device)
    if r != VK_SUCCESS {
        vkDestroyInstance(g.instance, nil)
        return (g, fmt("vkCreateDevice: ", vk_result_name(r)))
    }
    vkGetDeviceQueue(g.device, g.family, 0, &g.queue)
    vkGetPhysicalDeviceMemoryProperties(g.physical, &g.memory)
    (g, "")
}

// Stops the program unless `result` is VK_SUCCESS: for calls that cannot fail in a correct program.
fn check(result: i32, what: str) {
    if result != VK_SUCCESS { panic(fmt(what, ": ", vk_result_name(result))) }
}

// Allocates device memory that satisfies `req` and has the property `flags`: the first memory
// type that `req.memoryTypeBits` allows and that has all the flags.
fn allocate(g: *Gpu, req: *VkMemoryRequirements, flags: u32) -> u64 {
    index := -1
    for i in 0..i64(g.memory.memoryTypeCount) {
        if index < 0 && req.memoryTypeBits >> u32(i) & 1 == 1 && g.memory.memoryTypes[i].propertyFlags & flags == flags {
            index = i
        }
    }
    assert index >= 0, "no suitable memory type"
    info := vk_memory_allocate_info()
    info.allocationSize = req.size
    info.memoryTypeIndex = u32(index)
    memory: u64
    check(vkAllocateMemory(g.device, &info, nil, &memory), "vkAllocateMemory")
    memory
}

// A shader module from SPIR-V bytes. The words are copied: an embedded file need not be 4-byte aligned.
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

// Creates a buffer backed by host-visible memory; returns (buffer, memory).
fn create_buffer(g: *Gpu, size: u64, usage: u32) -> (u64, u64) {
    info := vk_buffer_create_info()
    info.size = size
    info.usage = usage
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
    buffer: u64
    check(vkCreateBuffer(g.device, &info, nil, &buffer), "vkCreateBuffer")
    req: VkMemoryRequirements
    vkGetBufferMemoryRequirements(g.device, buffer, &req)
    memory := allocate(g, &req, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)
    check(vkBindBufferMemory(g.device, buffer, memory, 0), "vkBindBufferMemory")
    (buffer, memory)
}

// Creates the colour image, its view, a render pass that clears it and leaves it ready to be
// copied from, and the framebuffer.
fn create_target(g: *Gpu) -> Target {
    t: Target
    image_info := vk_image_create_info()
    image_info.imageType = VK_IMAGE_TYPE_2D
    image_info.format = FORMAT
    image_info.extent = VkExtent3D{SIZE, SIZE, 1}
    image_info.mipLevels = 1
    image_info.arrayLayers = 1
    image_info.samples = VK_SAMPLE_COUNT_1_BIT
    image_info.tiling = VK_IMAGE_TILING_OPTIMAL
    image_info.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT
    image_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
    check(vkCreateImage(g.device, &image_info, nil, &t.image), "vkCreateImage")
    req: VkMemoryRequirements
    vkGetImageMemoryRequirements(g.device, t.image, &req)
    t.memory = allocate(g, &req, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)
    check(vkBindImageMemory(g.device, t.image, t.memory, 0), "vkBindImageMemory")

    view_info := vk_image_view_create_info()
    view_info.image = t.image
    view_info.viewType = VK_IMAGE_VIEW_TYPE_2D
    view_info.format = FORMAT
    view_info.subresourceRange = VkImageSubresourceRange{VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}
    check(vkCreateImageView(g.device, &view_info, nil, &t.view), "vkCreateImageView")

    attachment := VkAttachmentDescription{
        format: FORMAT,
        samples: VK_SAMPLE_COUNT_1_BIT,
        loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
        storeOp: VK_ATTACHMENT_STORE_OP_STORE,
        stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
        initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
        finalLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    }
    color_ref := VkAttachmentReference{0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL}
    subpass := VkSubpassDescription{
        pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
        colorAttachmentCount: 1,
        pColorAttachments: &color_ref,
    }
    // the copy after the render pass must wait for the colour writes
    dependency := VkSubpassDependency{
        srcSubpass: 0,
        dstSubpass: VK_SUBPASS_EXTERNAL,
        srcStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        dstStageMask: VK_PIPELINE_STAGE_TRANSFER_BIT,
        srcAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        dstAccessMask: VK_ACCESS_TRANSFER_READ_BIT,
    }
    pass_info := vk_render_pass_create_info()
    pass_info.attachmentCount = 1
    pass_info.pAttachments = &attachment
    pass_info.subpassCount = 1
    pass_info.pSubpasses = &subpass
    pass_info.dependencyCount = 1
    pass_info.pDependencies = &dependency
    check(vkCreateRenderPass(g.device, &pass_info, nil, &t.render_pass), "vkCreateRenderPass")

    fb_info := vk_framebuffer_create_info()
    fb_info.renderPass = t.render_pass
    fb_info.attachmentCount = 1
    fb_info.pAttachments = &t.view
    fb_info.width = SIZE
    fb_info.height = SIZE
    fb_info.layers = 1
    check(vkCreateFramebuffer(g.device, &fb_info, nil, &t.framebuffer), "vkCreateFramebuffer")
    t
}

// Creates the graphics pipeline: two shader stages, vertices of (vec2 position, vec3 colour),
// a fixed viewport covering the image, no culling, no blending. Returns (pipeline, layout).
fn create_pipeline(g: *Gpu, render_pass: u64) -> (u64, u64) {
    vert := shader_module(g, embed("../tests/sys/data/tri.vert.spv"))
    frag := shader_module(g, embed("../tests/sys/data/tri.frag.spv"))

    stages: [2]VkPipelineShaderStageCreateInfo
    stages[0] = vk_pipeline_shader_stage_create_info()
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT
    stages[0].module = vert
    stages[0].pName = ptr("main")
    stages[1] = vk_pipeline_shader_stage_create_info()
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT
    stages[1].module = frag
    stages[1].pName = ptr("main")

    binding := VkVertexInputBindingDescription{0, 20, VK_VERTEX_INPUT_RATE_VERTEX}
    attributes: [2]VkVertexInputAttributeDescription
    attributes[0] = VkVertexInputAttributeDescription{0, 0, VK_FORMAT_R32G32_SFLOAT, 0}
    attributes[1] = VkVertexInputAttributeDescription{1, 0, VK_FORMAT_R32G32B32_SFLOAT, 8}
    vertex_input := vk_pipeline_vertex_input_state_create_info()
    vertex_input.vertexBindingDescriptionCount = 1
    vertex_input.pVertexBindingDescriptions = &binding
    vertex_input.vertexAttributeDescriptionCount = 2
    vertex_input.pVertexAttributeDescriptions = ptr(attributes)

    input_assembly := vk_pipeline_input_assembly_state_create_info()
    input_assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST

    viewport := VkViewport{0.0, 0.0, f32(SIZE), f32(SIZE), 0.0, 1.0}
    scissor := VkRect2D{VkOffset2D{0, 0}, VkExtent2D{SIZE, SIZE}}
    viewport_state := vk_pipeline_viewport_state_create_info()
    viewport_state.viewportCount = 1
    viewport_state.pViewports = &viewport
    viewport_state.scissorCount = 1
    viewport_state.pScissors = &scissor

    raster := vk_pipeline_rasterization_state_create_info()
    raster.polygonMode = VK_POLYGON_MODE_FILL
    raster.cullMode = VK_CULL_MODE_NONE
    raster.frontFace = VK_FRONT_FACE_CLOCKWISE
    raster.lineWidth = 1.0

    multisample := vk_pipeline_multisample_state_create_info()
    multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT

    blend_attachment := VkPipelineColorBlendAttachmentState{
        colorWriteMask: VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
            VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
    }
    blend := vk_pipeline_color_blend_state_create_info()
    blend.attachmentCount = 1
    blend.pAttachments = &blend_attachment

    layout_info := vk_pipeline_layout_create_info()
    layout: u64
    check(vkCreatePipelineLayout(g.device, &layout_info, nil, &layout), "vkCreatePipelineLayout")

    info := vk_graphics_pipeline_create_info()
    info.stageCount = 2
    info.pStages = ptr(stages)
    info.pVertexInputState = &vertex_input
    info.pInputAssemblyState = &input_assembly
    info.pViewportState = &viewport_state
    info.pRasterizationState = &raster
    info.pMultisampleState = &multisample
    info.pColorBlendState = &blend
    info.layout = layout
    info.renderPass = render_pass
    pipeline: u64
    check(vkCreateGraphicsPipelines(g.device, 0, 1, &info, nil, &pipeline), "vkCreateGraphicsPipelines")
    vkDestroyShaderModule(g.device, vert, nil)
    vkDestroyShaderModule(g.device, frag, nil)
    (pipeline, layout)
}

// Writes tightly packed RGBA pixels (row 0 = top) as a 24-bit BMP file.
fn write_bmp(path: str, rgba: []u8, width: i64, height: i64) -> bool {
    row := (width * 3 + 3) / 4 * 4
    data := alloc[u8](54 + row * height)
    header := [6]i64{54 + row * height, 0, 54, 40, width, height}
    data[0] = 'B'
    data[1] = 'M'
    for i, v in header {
        for b in 0..4 { data[2 + i * 4 + b] = u8(v >> u64(b * 8)) }
    }
    data[26] = 1                                   // planes
    data[28] = 24                                  // bits per pixel
    for y in 0..height {
        src := (height - 1 - y) * width * 4        // BMP rows run bottom-up, pixels are BGR
        dst := 54 + y * row
        for x in 0..width {
            data[dst + x * 3] = rgba[src + x * 4 + 2]
            data[dst + x * 3 + 1] = rgba[src + x * 4 + 1]
            data[dst + x * 3 + 2] = rgba[src + x * 4]
        }
    }
    write_file(path, data)
}

fn main() -> i64 {
    g, problem := open_gpu()
    if problem.len != 0 {
        print("cannot use Vulkan:", problem)
        return 77
    }
    target := create_target(&g)
    pipeline, layout := create_pipeline(&g, target.render_pass)

    // x, y in normalised device coordinates (y points down), then r, g, b
    vertices := [15]f32{
        0.0, -0.75, 1.0, 0.0, 0.0,
        0.75, 0.75, 0.0, 1.0, 0.0,
        -0.75, 0.75, 0.0, 0.0, 1.0,
    }
    vertex_bytes := u64(sizeof[[15]f32]())
    vertex_buffer, vertex_memory := create_buffer(&g, vertex_bytes, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT)
    mapped: *u8
    check(vkMapMemory(g.device, vertex_memory, 0, VK_WHOLE_SIZE, 0, &mapped), "vkMapMemory")
    memcopy(mapped, ptr(vertices), i64(vertex_bytes))
    vkUnmapMemory(g.device, vertex_memory)

    pixel_bytes := i64(SIZE) * i64(SIZE) * 4
    readback, readback_memory := create_buffer(&g, u64(pixel_bytes), VK_BUFFER_USAGE_TRANSFER_DST_BIT)

    pool_info := vk_command_pool_create_info()
    pool_info.queueFamilyIndex = g.family
    pool: u64
    check(vkCreateCommandPool(g.device, &pool_info, nil, &pool), "vkCreateCommandPool")
    alloc_info := vk_command_buffer_allocate_info()
    alloc_info.commandPool = pool
    alloc_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
    alloc_info.commandBufferCount = 1
    cmd: *u8
    check(vkAllocateCommandBuffers(g.device, &alloc_info, &cmd), "vkAllocateCommandBuffers")

    // record: clear, draw the triangle, copy the image into the read-back buffer
    begin_info := vk_command_buffer_begin_info()
    begin_info.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
    check(vkBeginCommandBuffer(cmd, &begin_info), "vkBeginCommandBuffer")
    clear := vk_clear_value_color(vk_clear_color_value_float32([4]f32{0.2, 0.2, 0.4, 1.0}))
    pass_begin := vk_render_pass_begin_info()
    pass_begin.renderPass = target.render_pass
    pass_begin.framebuffer = target.framebuffer
    pass_begin.renderArea = VkRect2D{VkOffset2D{0, 0}, VkExtent2D{SIZE, SIZE}}
    pass_begin.clearValueCount = 1
    pass_begin.pClearValues = &clear
    vkCmdBeginRenderPass(cmd, &pass_begin, VK_SUBPASS_CONTENTS_INLINE)
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
    offset: u64 = 0
    vkCmdBindVertexBuffers(cmd, 0, 1, &vertex_buffer, &offset)
    vkCmdDraw(cmd, 3, 1, 0, 0)
    vkCmdEndRenderPass(cmd)
    region := VkBufferImageCopy{
        imageSubresource: VkImageSubresourceLayers{VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        imageExtent: VkExtent3D{SIZE, SIZE, 1},
    }
    vkCmdCopyImageToBuffer(cmd, target.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback, 1, &region)
    check(vkEndCommandBuffer(cmd), "vkEndCommandBuffer")

    submit := vk_submit_info()
    submit.commandBufferCount = 1
    submit.pCommandBuffers = &cmd
    check(vkQueueSubmit(g.queue, 1, &submit, 0), "vkQueueSubmit")
    check(vkQueueWaitIdle(g.queue), "vkQueueWaitIdle")

    check(vkMapMemory(g.device, readback_memory, 0, VK_WHOLE_SIZE, 0, &mapped), "vkMapMemory")
    saved := write_bmp("triangle.bmp", mkslice[u8](mapped, pixel_bytes), i64(SIZE), i64(SIZE))
    vkUnmapMemory(g.device, readback_memory)

    // destroy everything in reverse order of creation
    vkDestroyCommandPool(g.device, pool, nil)
    vkDestroyBuffer(g.device, readback, nil)
    vkFreeMemory(g.device, readback_memory, nil)
    vkDestroyBuffer(g.device, vertex_buffer, nil)
    vkFreeMemory(g.device, vertex_memory, nil)
    vkDestroyPipeline(g.device, pipeline, nil)
    vkDestroyPipelineLayout(g.device, layout, nil)
    vkDestroyFramebuffer(g.device, target.framebuffer, nil)
    vkDestroyRenderPass(g.device, target.render_pass, nil)
    vkDestroyImageView(g.device, target.view, nil)
    vkDestroyImage(g.device, target.image, nil)
    vkFreeMemory(g.device, target.memory, nil)
    vkDestroyDevice(g.device, nil)
    vkDestroyInstance(g.instance, nil)

    if !saved {
        print("cannot write triangle.bmp")
        return 1
    }
    print("wrote triangle.bmp")
    0
}
