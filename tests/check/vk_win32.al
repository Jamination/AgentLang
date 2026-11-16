// std.vk for both systems: the platform surface is chosen with `when`, everything else is the
// same code (type-checked here for Linux and Windows: tests/run.al checks it for every target)
use std.vk
use std.window

fn surface(instance: *u8, w: *Window) -> (u64, i32) {
    s: u64 = 0
    when TARGET_OS == Windows {
        info := vk_win32_surface_create_info_khr()
        info.hinstance = win32_hinstance(w)
        info.hwnd = win32_hwnd(w)
        r := vkCreateWin32SurfaceKHR(instance, &info, nil, &s)
    } else {
        info := vk_xlib_surface_create_info_khr()
        info.dpy = x11_display(w)
        info.window = x11_window(w)
        r := vkCreateXlibSurfaceKHR(instance, &info, nil, &s)
    }
    (s, r)
}

fn main() {
    ext := if TARGET_OS == Windows { VK_KHR_WIN32_SURFACE_EXTENSION_NAME } else { VK_KHR_XLIB_SURFACE_EXTENSION_NAME }
    names := [2]*u8{ptr(VK_KHR_SURFACE_EXTENSION_NAME), ptr(ext)}
    ci := vk_instance_create_info()
    ci.enabledExtensionCount = 2
    ci.ppEnabledExtensionNames = &names[0]
    instance: *u8 = nil
    if vkCreateInstance(&ci, nil, &instance) != VK_SUCCESS {
        return
    }
    w, ok := window_open(WindowDesc{title: "vk", width: 320, height: 240})
    if ok {
        s, r := surface(instance, w)
        print(s != 0, vk_result_name(r))
    }
    vkDestroyInstance(instance, nil)
}
