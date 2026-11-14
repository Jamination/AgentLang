// The parts of std.vk that run without a Vulkan driver: the union constructors the generator
// writes (AL has no unions), the version macros of vulkan_core.h, the sType constructors and
// vk_result_name. No Vulkan command is reached, so the program stays static.
use std.vk

fn words(p: *u8, n: i64) -> []u32 { mkslice[u32](cast[*u32](p), n) }

fn main() {
    // unions: the member's bytes at offset 0, the rest zero
    c := vk_clear_color_value_float32([4]f32{0.25, 0.5, 1.0, -2.0})
    print(sizeof[VkClearColorValue](), words(cast[*u8](&c), 4)[0] == cast[u32](f32(0.25)),
        words(cast[*u8](&c), 4)[3] == cast[u32](f32(-2.0)))
    ci := vk_clear_color_value_int32([4]i32{-1, 2, -3, 4})
    print(cast[*[4]i32](&ci)[0], cast[*[4]i32](&ci)[2])
    cu := vk_clear_color_value_uint32([4]u32{7, 8, 9, 0xFFFFFFFF})
    print(words(cast[*u8](&cu), 4))
    v := vk_clear_value_color(cu)
    print(sizeof[VkClearValue](), words(cast[*u8](&v), 4))
    d := vk_clear_value_depth_stencil(VkClearDepthStencilValue{1.0, 3})
    dw := words(cast[*u8](&d), 4)
    print(dw[0] == cast[u32](f32(1.0)), dw[1], dw[2], dw[3])

    // VK_MAKE_API_VERSION and its parts
    ver := vk_make_api_version(0, 1, 3, 280)
    print(ver == VK_API_VERSION_1_3 + 280, vk_api_version_variant(ver), vk_api_version_major(ver),
        vk_api_version_minor(ver), vk_api_version_patch(ver))
    print(vk_api_version_variant(vk_make_api_version(7, 0, 0, 0)), hex(u64(vk_make_api_version(0, 1, 0, 0))))

    // sType constructors and result names
    print(vk_instance_create_info().sType == VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        vk_physical_device_vulkan13_features().sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES)
    print(vk_result_name(VK_SUCCESS), vk_result_name(VK_ERROR_OUT_OF_DATE_KHR), vk_result_name(12345))
}
