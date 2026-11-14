// The scene of renderer.al in a window, presented through a swapchain: run_windowed, used by
// windowed.al and by the test tests/sys/vk_present.al.
//
// X11: a std.window window and VK_KHR_xlib_surface. Wayland: a raw std.wayland surface
// (xdg-shell toplevel, no std.window) and VK_KHR_wayland_surface. The present mode is the
// vsync choice: FIFO (vsync, always available), MAILBOX (vsync without blocking, the newest
// frame wins), IMMEDIATE (no vsync, may tear); an unsupported one falls back to FIFO. The
// swapchain is recreated when the window is resized or the present mode changes; rendering
// pauses while the window is minimised.
use "renderer.al"
use std.window
use std.wayland

// ---- the swapchain -----------------------------------------------------------------------------

struct Swapchain {
    handle: u64
    format: VkSurfaceFormatKHR
    extent: VkExtent2D
    present_mode: i32
    images: []u64
    views: []u64
    acquired: [FRAMES_IN_FLIGHT]u64     // per frame slot: signalled when the acquired image is free
    rendered: []u64                     // per image: signalled when its frame is drawn, waited for by present
    recreated: i64
}

fn mode_name(mode: i32) -> str {
    match mode {
        VK_PRESENT_MODE_FIFO_KHR => "fifo"
        VK_PRESENT_MODE_MAILBOX_KHR => "mailbox"
        VK_PRESENT_MODE_IMMEDIATE_KHR => "immediate"
        VK_PRESENT_MODE_FIFO_RELAXED_KHR => "fifo_relaxed"
        _ => fmt("mode ", mode)
    }
}

// A surface format for the swapchain: B8G8R8A8 or R8G8B8A8 UNORM (the offscreen colours), else the first.
fn choose_format(g: *Gpu, surface: u64) -> VkSurfaceFormatKHR {
    n: u32
    vkGetPhysicalDeviceSurfaceFormatsKHR(g.physical, surface, &n, nil)
    formats := alloc[VkSurfaceFormatKHR](i64(n))
    vkGetPhysicalDeviceSurfaceFormatsKHR(g.physical, surface, &n, ptr(formats))
    for f in formats {
        if (f.format == VK_FORMAT_B8G8R8A8_UNORM || f.format == VK_FORMAT_R8G8B8A8_UNORM) &&
                f.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR {
            return f
        }
    }
    formats[0]
}

fn supports_mode(g: *Gpu, surface: u64, mode: i32) -> bool {
    n: u32
    vkGetPhysicalDeviceSurfacePresentModesKHR(g.physical, surface, &n, nil)
    modes := alloc[i32](i64(n))
    vkGetPhysicalDeviceSurfacePresentModesKHR(g.physical, surface, &n, ptr(modes))
    contains(modes, mode)
}

// (Re)creates the swapchain for the window size `want` (used when the surface leaves the size
// to the application, as Wayland does). The old one is handed to the driver and then destroyed.
// Returns false while the surface has no area (minimised).
fn swapchain_build(g: *Gpu, sc: *Swapchain, surface: u64, want: VkExtent2D, mode: i32, verbose: bool) -> bool {
    caps: VkSurfaceCapabilitiesKHR
    check(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(g.physical, surface, &caps), "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")
    extent := caps.currentExtent
    if extent.width == 0xFFFFFFFF {
        extent.width = max(caps.minImageExtent.width, min(caps.maxImageExtent.width, want.width))
        extent.height = max(caps.minImageExtent.height, min(caps.maxImageExtent.height, want.height))
    }
    if extent.width == 0 || extent.height == 0 { return false }
    count := caps.minImageCount + 1
    if caps.maxImageCount != 0 { count = min(count, caps.maxImageCount) }
    if !supports_mode(g, surface, mode) {
        if verbose { print("present mode", mode_name(mode), "is not supported here: using fifo") }
        mode = VK_PRESENT_MODE_FIFO_KHR
    }

    vkDeviceWaitIdle(g.device)
    for v in sc.views { vkDestroyImageView(g.device, v, nil) }
    for s in sc.rendered { vkDestroySemaphore(g.device, s, nil) }
    info := vk_swapchain_create_info_khr()
    info.surface = surface
    info.minImageCount = count
    info.imageFormat = sc.format.format
    info.imageColorSpace = sc.format.colorSpace
    info.imageExtent = extent
    info.imageArrayLayers = 1
    info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
    info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE
    info.preTransform = caps.currentTransform
    info.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
    info.presentMode = mode
    info.clipped = VK_TRUE
    info.oldSwapchain = sc.handle
    handle: u64
    check(vkCreateSwapchainKHR(g.device, &info, nil, &handle), "vkCreateSwapchainKHR")
    if sc.handle != 0 {
        vkDestroySwapchainKHR(g.device, sc.handle, nil)
        sc.recreated += 1
    }
    sc.handle = handle
    sc.extent = extent
    sc.present_mode = mode

    n: u32
    vkGetSwapchainImagesKHR(g.device, handle, &n, nil)
    sc.images = alloc[u64](i64(n))
    vkGetSwapchainImagesKHR(g.device, handle, &n, ptr(sc.images))
    sc.views = alloc[u64](i64(n))
    sc.rendered = alloc[u64](i64(n))
    sem_info := vk_semaphore_create_info()
    for i in 0..i64(n) {
        sc.views[i] = view_create(g, sc.images[i], sc.format.format, VK_IMAGE_ASPECT_COLOR_BIT)
        check(vkCreateSemaphore(g.device, &sem_info, nil, &sc.rendered[i]), "vkCreateSemaphore")
    }
    true
}

fn swapchain_destroy(g: *Gpu, sc: *Swapchain) {
    vkDeviceWaitIdle(g.device)
    for v in sc.views { vkDestroyImageView(g.device, v, nil) }
    for s in sc.rendered { vkDestroySemaphore(g.device, s, nil) }
    for s in sc.acquired { vkDestroySemaphore(g.device, s, nil) }
    if sc.handle != 0 { vkDestroySwapchainKHR(g.device, sc.handle, nil) }
}

// ---- Wayland: a toplevel surface without std.window ---------------------------------------------

struct Wl {
    display: *WlDisplay
    compositor: *WlCompositor
    wm_base: *XdgWmBase
    surface: *WlSurface
    xdg_surface: *XdgSurface
    toplevel: *XdgToplevel
    width: u32
    height: u32
    resized: bool
    configured: bool
    pending: bool           // a configure to acknowledge once the swapchain has its size
    pending_serial: u32
    draining: bool          // waiting for the frame callback that follows the old frames
    drained: bool
    closing: bool
}

wl: Wl

fn on_global(data: *u8, registry: *WlRegistry, name: u32, interface: *u8, version: u32) {
    match from_cstr(interface) {
        "wl_compositor" => wl.compositor = cast[*WlCompositor](wl_registry_bind(registry, name, &wl_compositor_interface, min(version, 4)))
        "xdg_wm_base" => wl.wm_base = cast[*XdgWmBase](wl_registry_bind(registry, name, xdg_wm_base_interface(), min(version, 2)))
        _ => {}
    }
}
fn on_ping(data: *u8, wm_base: *XdgWmBase, serial: u32) { xdg_wm_base_pong(wm_base, serial) }
fn on_toplevel_configure(data: *u8, toplevel: *XdgToplevel, width: i32, height: i32, states: *WlArray) {
    if width > 0 && height > 0 && (u32(width) != wl.width || u32(height) != wl.height) {
        wl.width = u32(width)
        wl.height = u32(height)
        wl.resized = true
    }
}
// The first configure is acknowledged at once (nothing is shown yet); later ones only when the
// swapchain has been rebuilt for them and the old frames are out of the way: after the ack, the
// next commit applied must have the new size.
fn on_surface_configure(data: *u8, xdg_surface: *XdgSurface, serial: u32) {
    if !wl.configured {
        xdg_surface_ack_configure(xdg_surface, serial)
        wl.configured = true
        return
    }
    wl.pending = true
    wl.pending_serial = serial
}
fn on_close(data: *u8, toplevel: *XdgToplevel) { wl.closing = true }
fn on_drained(data: *u8, callback: *WlCallback, time: u32) {
    wl_callback_destroy(callback)
    wl.drained = true
}

registry_listener := WlRegistryListener{global: on_global}
wm_base_listener := XdgWmBaseListener{ping: on_ping}
xdg_surface_listener := XdgSurfaceListener{configure: on_surface_configure}
toplevel_listener := XdgToplevelListener{configure: on_toplevel_configure, close: on_close}
drain_listener := WlCallbackListener{done: on_drained}

// `socket`: the compositor's socket name, "" for $WAYLAND_DISPLAY.
fn wayland_open(socket: str, width: u32, height: u32) -> str {
    wl.display = wl_display_connect(if socket == "" { nil } else { cstr(socket) })
    if wl.display == nil { return "cannot connect to a Wayland compositor ($WAYLAND_DISPLAY)" }
    registry := wl_display_get_registry(wl.display)
    wl_registry_add_listener(registry, &registry_listener, nil)
    wl_display_roundtrip(wl.display)
    if wl.compositor == nil || wl.wm_base == nil { return "the compositor offers no wl_compositor or xdg_wm_base" }
    xdg_wm_base_add_listener(wl.wm_base, &wm_base_listener, nil)
    wl.width = width
    wl.height = height
    wl.surface = wl_compositor_create_surface(wl.compositor)
    wl.xdg_surface = xdg_wm_base_get_xdg_surface(wl.wm_base, wl.surface)
    xdg_surface_add_listener(wl.xdg_surface, &xdg_surface_listener, nil)
    wl.toplevel = xdg_surface_get_toplevel(wl.xdg_surface)
    xdg_toplevel_add_listener(wl.toplevel, &toplevel_listener, nil)
    xdg_toplevel_set_title(wl.toplevel, "vk_renderer (Wayland)")
    xdg_toplevel_set_app_id(wl.toplevel, "al.example.vk_renderer")
    wl_surface_commit(wl.surface)               // no buffer: asks for the first configure
    while !wl.configured {
        if wl_display_dispatch(wl.display) < 0 { return "the Wayland connection broke" }
    }
    ""
}

fn wayland_close() {
    if wl.toplevel != nil { xdg_toplevel_destroy(wl.toplevel) }
    if wl.xdg_surface != nil { xdg_surface_destroy(wl.xdg_surface) }
    if wl.surface != nil { wl_surface_destroy(wl.surface) }
    if wl.wm_base != nil { xdg_wm_base_destroy(wl.wm_base) }
    if wl.display != nil { wl_display_disconnect(wl.display) }
}

// ---- the frame loop ----------------------------------------------------------------------------

struct Run {
    wayland: bool
    mode: i32
    seconds: f64            // stop after this time (0: when the window is closed)
    scripted: bool          // go fullscreen halfway, to exercise swapchain recreation without a user
    wayland_socket: str     // Wayland: the compositor's socket; "" for $WAYLAND_DISPLAY
    verbose: bool           // print the swapchain changes and the frame rate once a second
}

struct Summary {
    device: str
    validation: bool
    frames: i64
    recreated: i64          // swapchain recreations
    present_mode: i32       // the mode in use at the end
    first: VkExtent2D       // swapchain size at the start and at the end
    last: VkExtent2D
}

// Opens the window, renders until it is closed (or `run.seconds` have passed), tears down.
// "" or why it cannot run here (no display, no Vulkan).
fn run_windowed(run: Run) -> (Summary, str) {
    s: Summary
    mode := run.mode
    // the window first: the instance needs to know which surface extension to enable
    win: *Window
    if run.wayland {
        wl = Wl{}
        problem := wayland_open(run.wayland_socket, 800, 600)
        if problem != "" {
            wayland_close()
            return (s, problem)
        }
    } else {
        w, ok := window_open(WindowDesc{title: "vk_renderer (X11)", width: 800, height: 600, resizable: true})
        if !ok { return (s, "cannot open an X11 window") }
        win = w
    }

    g: Gpu
    platform := if run.wayland { VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME } else { VK_KHR_XLIB_SURFACE_EXTENSION_NAME }
    problem := gpu_create_instance(&g, "vk_renderer windowed", []str{VK_KHR_SURFACE_EXTENSION_NAME, platform}, true)
    surface: u64
    if problem == "" && run.wayland {
        info := vk_wayland_surface_create_info_khr()
        info.display = cast[*u8](wl.display)
        info.surface = cast[*u8](wl.surface)
        check(vkCreateWaylandSurfaceKHR(g.instance, &info, nil, &surface), "vkCreateWaylandSurfaceKHR")
    } else if problem == "" {
        info := vk_xlib_surface_create_info_khr()
        info.dpy = x11_display(win)
        info.window = x11_window(win)
        check(vkCreateXlibSurfaceKHR(g.instance, &info, nil, &surface), "vkCreateXlibSurfaceKHR")
    }
    if problem == "" { problem = gpu_pick_device(&g, surface) }
    if problem == "" { problem = gpu_create_device(&g, true) }
    if problem != "" {
        if surface != 0 { vkDestroySurfaceKHR(g.instance, surface, nil) }
        gpu_destroy(&g)
        if run.wayland { wayland_close() } else { win.close() }
        return (s, fmt("cannot use Vulkan: ", problem))
    }
    s.device = clone(from_cstr(ptr(g.props.deviceName)))
    s.validation = g.validation
    if run.verbose {
        print("device:", s.device, "| surface:", platform, "| validation layer:", if g.validation { "enabled" } else { "not installed" })
    }

    sc: Swapchain
    sc.format = choose_format(&g, surface)
    sem_info := vk_semaphore_create_info()
    for i in 0..FRAMES_IN_FLIGHT { check(vkCreateSemaphore(g.device, &sem_info, nil, &sc.acquired[i]), "vkCreateSemaphore") }
    fn window_extent(win: *Window) -> VkExtent2D {
        if win == nil { return VkExtent2D{wl.width, wl.height} }
        ww, wh := size(win)
        VkExtent2D{u32(ww), u32(wh)}
    }
    have_swapchain := swapchain_build(&g, &sc, surface, window_extent(win), mode, run.verbose)
    s.first = sc.extent
    if run.verbose {
        print("swapchain:", sc.images.len, "images", sc.extent.width, "x", sc.extent.height, "present mode", mode_name(sc.present_mode))
    }
    r, rproblem := renderer_create(&g, sc.format.format, sc.extent)
    if rproblem != "" { panic(rproblem) }
    r.animate = true

    start := clock_ns()
    second_start := start
    second_frames := 0
    dirty := false
    paused := false
    went_fullscreen := false
    loop {
        elapsed := f64(clock_ns() - start) / 1e9
        if run.seconds > 0.0 && elapsed >= run.seconds { break }
        if run.scripted && !went_fullscreen && elapsed >= run.seconds / 2.0 {
            went_fullscreen = true
            if run.wayland { xdg_toplevel_set_fullscreen(wl.toplevel, nil) } else { win.set_fullscreen(true) }
        }
        // window events
        if run.wayland {
            if wl_display_poll(wl.display, 0) < 0 || wl.closing { break }
            if wl.resized {
                wl.resized = false
                dirty = true
            }
        } else {
            win.poll()
            if win.should_close() { break }
            loop {
                e, more := win.next_event()
                if !more { break }
                match e.kind {
                    EventResize => dirty = true
                    EventMinimize => paused = true
                    EventRestore => {
                        paused = false
                        dirty = true
                    }
                    EventKeyDown => match e.key {
                        KEY_ESCAPE => win.closing = true
                        KEY_F11 => win.set_fullscreen(!win.fullscreen)
                        KEY_1 => { mode = VK_PRESENT_MODE_FIFO_KHR; dirty = true }
                        KEY_2 => { mode = VK_PRESENT_MODE_MAILBOX_KHR; dirty = true }
                        KEY_3 => { mode = VK_PRESENT_MODE_IMMEDIATE_KHR; dirty = true }
                        _ => {}
                    }
                    _ => {}
                }
            }
        }
        if paused {
            sleep_ns(10_000_000)
            continue
        }
        if dirty || !have_swapchain {
            dirty = false
            have_swapchain = swapchain_build(&g, &sc, surface, window_extent(win), mode, run.verbose)
            if !have_swapchain {
                sleep_ns(10_000_000)          // no area (minimised): try again later
                continue
            }
            r.renderer_resize(&g, sc.extent)
            if run.verbose {
                print("swapchain recreated:", sc.extent.width, "x", sc.extent.height, "present mode", mode_name(sc.present_mode))
            }
        }

        if run.wayland && wl.pending {
            // With FIFO the driver presents through wp_fifo_v1: the commits of the old frames
            // can still be queued in the compositor, and an ack sent now would apply to them
            // (an 800 x 600 frame in a 640 x 480 fullscreen state is a protocol error). A frame
            // callback on a commit of our own fires once everything before it has been applied.
            if !wl.draining {
                wl.draining = true
                wl.drained = false
                wl_callback_add_listener(wl_surface_frame(wl.surface), &drain_listener, nil)
                wl_surface_commit(wl.surface)
                wl_display_flush(wl.display)
            }
            if !wl.drained {
                sleep_ns(1_000_000)
                continue
            }
            wl.pending = false
            wl.draining = false
            xdg_surface_ack_configure(wl.xdg_surface, wl.pending_serial)
        }
        slot := r.frame_begin(&g)
        index: u32
        res := vkAcquireNextImageKHR(g.device, sc.handle, FOREVER, sc.acquired[slot], 0, &index)
        if res == VK_ERROR_OUT_OF_DATE_KHR {
            dirty = true
            continue
        }
        if res != VK_SUCCESS && res != VK_SUBOPTIMAL_KHR { check(res, "vkAcquireNextImageKHR") }
        r.frame_render(&g, slot, Target{sc.images[index], sc.views[index], sc.extent, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            sc.acquired[slot], sc.rendered[index]})
        present := vk_present_info_khr()
        present.waitSemaphoreCount = 1
        present.pWaitSemaphores = &sc.rendered[index]
        present.swapchainCount = 1
        present.pSwapchains = &sc.handle
        present.pImageIndices = &index
        res = vkQueuePresentKHR(g.queue, &present)
        if res == VK_ERROR_OUT_OF_DATE_KHR || res == VK_SUBOPTIMAL_KHR {
            dirty = true
        } else {
            check(res, "vkQueuePresentKHR")
        }

        second_frames += 1
        now := clock_ns()
        if now - second_start >= 1_000_000_000 {
            if run.verbose {
                gpu := if r.gpu_ms.is_empty() { 0.0 } else { r.gpu_ms.last() }
                print(second_frames, "frames/s, GPU", fmtf(gpu, 3), "ms/frame, present mode", mode_name(sc.present_mode))
            }
            second_frames = 0
            second_start = now
        }
    }

    s.frames = r.frame
    s.recreated = sc.recreated
    s.present_mode = sc.present_mode
    s.last = sc.extent
    r.renderer_destroy(&g)
    swapchain_destroy(&g, &sc)
    vkDestroySurfaceKHR(g.instance, surface, nil)
    gpu_destroy(&g)
    if run.wayland { wayland_close() } else { win.close() }
    (s, "")
}
