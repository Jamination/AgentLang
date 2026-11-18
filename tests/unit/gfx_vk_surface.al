// The GPU-free decisions of std.gfx's Vulkan backend about the window's surface (std/gfx_vk.al):
// which instance extension makes it, and the swapchain extent. On Linux a Wayland surface has
// no size of its own (currentExtent 0xFFFFFFFF): the extent is the window's pixel size (its
// surface size times the buffer scale), a whole multiple of the scale. The Wayland path itself
// has never run on a real compositor (docs/std/gfx.md, "Wayland").
use std.gfx_vk

fn ext(w: u32, h: u32) -> VkExtent2D { VkExtent2D{w, h} }

fn same(a: VkExtent2D, w: u32, h: u32) -> bool { a.width == w && a.height == h }

priv const NONE: u32 = 0xFFFFFFFF

test "the surface extension" {
    assert __gfx_vk_surface_extension(true, false) == "VK_KHR_win32_surface"
    assert __gfx_vk_surface_extension(true, true) == "VK_KHR_win32_surface"
    assert __gfx_vk_surface_extension(false, false) == "VK_KHR_xlib_surface"
    assert __gfx_vk_surface_extension(false, true) == "VK_KHR_wayland_surface"
}

test "a surface with a size of its own keeps it (X11, Win32)" {
    // the window's size and the scale do not matter: the swapchain must match the surface
    assert same(__gfx_vk_extent(ext(240, 160), ext(240, 160), ext(240, 160), 999, 999, 1), 240, 160)
    assert same(__gfx_vk_extent(ext(0, 0), ext(0, 0), ext(16384, 16384), 640, 480, 1), 0, 0)
    assert same(__gfx_vk_extent(ext(641, 481), ext(1, 1), ext(16384, 16384), 640, 480, 2), 641, 481)
}

test "a surface without a size: the window's pixels" {
    lo := ext(1, 1)
    hi := ext(16384, 16384)
    // scale 1: exactly what the code before the Wayland path did (clamp to the limits)
    assert same(__gfx_vk_extent(ext(NONE, NONE), lo, hi, 960, 540, 1), 960, 540)
    assert same(__gfx_vk_extent(ext(NONE, NONE), lo, hi, 20000, 3, 1), 16384, 3)
    assert same(__gfx_vk_extent(ext(NONE, NONE), ext(64, 64), hi, 7, 9, 1), 64, 64)
    // scale 2: window_open made the surface 640 x 360 for 1280 x 720 pixels (and 641 x 361 for
    // 1281 x 721 asked: 1282 x 722 pixels); the window's pixels are already a multiple
    assert same(__gfx_vk_extent(ext(NONE, NONE), lo, hi, 1280, 720, 2), 1280, 720)
    assert same(__gfx_vk_extent(ext(NONE, NONE), lo, hi, 1282, 722, 2), 1282, 722)
    // scale 3, a maximized window of 1000 x 700 surface units
    assert same(__gfx_vk_extent(ext(NONE, NONE), lo, hi, 3000, 2100, 3), 3000, 2100)
}

test "the limits never give a buffer that is not a multiple of the scale, unless nothing else fits" {
    lo := ext(1, 1)
    // clamped to an odd maximum: rounded down to the scale
    assert same(__gfx_vk_extent(ext(NONE, NONE), lo, ext(1001, 777), 4000, 4000, 2), 1000, 776)
    assert same(__gfx_vk_extent(ext(NONE, NONE), lo, ext(1001, 777), 4000, 4000, 3), 999, 777)
    // a minimum above the rounded size: the limits win (Vulkan requires them)
    assert same(__gfx_vk_extent(ext(NONE, NONE), ext(5, 5), ext(5, 5), 4, 4, 2), 5, 5)
    // fewer pixels than the scale (the limits allow it): kept, never 0
    assert same(__gfx_vk_extent(ext(NONE, NONE), lo, ext(100, 100), 1, 1, 2), 1, 1)
    // a bad scale is ignored
    assert same(__gfx_vk_extent(ext(NONE, NONE), lo, ext(100, 100), 51, 51, 0), 51, 51)
}
