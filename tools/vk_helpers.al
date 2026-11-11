// ---- convenience layer (hand-written: tools/vk_helpers.al) ----

// Packs a version number the way VK_MAKE_API_VERSION does (variant 0).
fn vk_make_version(major: u32, minor: u32, patch: u32) -> u32 { major << 22 | minor << 12 | patch }

// Major part of a packed version.
fn vk_version_major(v: u32) -> u32 { v >> 22 & 0x7F }

// Minor part of a packed version.
fn vk_version_minor(v: u32) -> u32 { v >> 12 & 0x3FF }

// Patch part of a packed version.
fn vk_version_patch(v: u32) -> u32 { v & 0xFFF }

// Panics with `what` and the VkResult name unless `result` is VK_SUCCESS. Allocates only when failing.
fn vk_check(result: i32, what: str) {
    if result != VK_SUCCESS {
        panic(fmt(what, ": ", vk_result_name(result), " (", result, ")"))
    }
}

// Clear colour from four floats, for vkCmdClearColorImage and float/normalised attachments.
fn vk_clear_color_value(r: f32, g: f32, b: f32, a: f32) -> VkClearColorValue {
    VkClearColorValue{data: [4]u32{cast[u32](r), cast[u32](g), cast[u32](b), cast[u32](a)}}
}

// Clear value for a float/normalised colour attachment.
fn vk_clear_color(r: f32, g: f32, b: f32, a: f32) -> VkClearValue {
    VkClearValue{data: [4]u32{cast[u32](r), cast[u32](g), cast[u32](b), cast[u32](a)}}
}

// Clear value for a signed-integer colour attachment.
fn vk_clear_color_int(r: i32, g: i32, b: i32, a: i32) -> VkClearValue {
    VkClearValue{data: [4]u32{u32(r), u32(g), u32(b), u32(a)}}
}

// Clear value for an unsigned-integer colour attachment.
fn vk_clear_color_uint(r: u32, g: u32, b: u32, a: u32) -> VkClearValue {
    VkClearValue{data: [4]u32{r, g, b, a}}
}

// Clear value for a depth/stencil attachment.
fn vk_clear_depth(depth: f32, stencil: u32) -> VkClearValue {
    VkClearValue{data: [4]u32{cast[u32](depth), stencil, 0, 0}}
}

// Index of the first memory type allowed by `type_bits` (VkMemoryRequirements.memoryTypeBits)
// that has all property `flags` (VK_MEMORY_PROPERTY_...); false if there is none.
fn vk_find_memory_type(props: *VkPhysicalDeviceMemoryProperties, type_bits: u32, flags: u32) -> (u32, bool) {
    for i in 0..i64(props.memoryTypeCount) {
        if type_bits >> u32(i) & 1 == 1 && props.memoryTypes[i].propertyFlags & flags == flags {
            return (u32(i), true)
        }
    }
    (0, false)
}

// Creates a shader module from SPIR-V bytes (for example `embed("shader.spv")`); false on failure.
// Copies the code into temporary arena memory when it is not 4-byte aligned.
fn vk_create_shader_module(device: *u8, code: []u8) -> (u64, bool) {
    if code.len == 0 || code.len % 4 != 0 {
        return (0, false)
    }
    m := mark()
    info := vk_shader_module_create_info()
    info.codeSize = u64(code.len)
    info.pCode = cast[*u32](ptr(code))
    if cast[i64](ptr(code)) & 3 != 0 {
        words := alloc[u32](code.len / 4)
        memcopy(ptr(words), ptr(code), code.len)
        info.pCode = ptr(words)
    }
    module: u64
    r := vkCreateShaderModule(device, &info, nil, &module)
    release(m)
    (module, r == VK_SUCCESS)
}
