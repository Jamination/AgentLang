// std.gfx: a small 2D renderer on a std.window window: textures from std.image images (also
// one-channel coverage, for font atlases), batched sprites, rectangles, lines and triangles,
// alpha and additive blending, a 2D transform, scissor and render textures. docs/std/gfx.md.
//
// The API is std/gfx_core.al; the backend is chosen by the target and never named by the
// program: Direct3D 12 on Windows (std/gfx_dx12.al), Vulkan 1.3 on Linux (std/gfx_vk.al).
// The shaders are compiled ahead of time (std/gfx_shaders.al). A program that wants the
// Vulkan backend on Windows writes `use std.gfx_vk` instead of `use std.gfx`.
when TARGET_OS == Windows {
    use std.gfx_dx12
} else {
    use std.gfx_vk
}
