// std.gfx (Vulkan, VK_KHR_wayland_surface) on a window of std.window's experimental Wayland
// backend, against a real compositor: the program starts its own `weston --backend=headless`
// on a private socket (as tests/sys/window_wayland.al does) and opens its window there by
// naming that socket in WindowDesc.display. The frames of data/gfx_window.al: with vsync and
// without, fullscreen and back (the swapchain follows the window's configure), then the
// renderer is closed before the window. The validation layer is on where it is installed.
// Weston is started with its GL renderer, which offers linux-dmabuf, the buffer path a GPU
// driver presents through (NVIDIA has no other); where that compositor does not come up (no
// GPU render node), weston composites in software (pixman, no linux-dmabuf). In either the
// first device is tried, then the software one (lavapipe, which presents through wl_shm).
// First passed on NVIDIA (driver Vulkan 1.4, weston 15, GL renderer) with no validation
// message; see docs/std/gfx.md, "Wayland".
use std.gfx
use std.os
use "data/gfx_window.al"

// Ends the compositor (SIGTERM to `timeout`, which passes it on) and waits at most 10 s.
fn stop(weston: Process) {
    kill(weston, 15)
    for attempt in 0..500 {
        _, ended := try_wait(weston)
        if ended { return }
        sleep_ns(20_000_000)
    }
    kill(weston, 9)
    wait(weston)
}

// One renderer on a new window of the compositor `wl_name`: "" if every step worked, else
// what failed. `skip` is set when Vulkan itself is missing here (not a failure of the path).
fn attempt(wl_name: str, desc: GfxDesc, skip: *bool) -> str {
    w, ok := window_open(WindowDesc{title: "std.gfx on Wayland", width: 240, height: 160, resizable: true, display: wl_name})
    if !ok { return "no window" }
    if wayland_display(w) == nil || wayland_surface(w) == nil {
        w.close()
        return "not a Wayland window"
    }
    g, err := gfx_open(w, desc)
    if err != "" {
        *skip = find(err, "vkCreateInstance") >= 0 || find(err, "VK_KHR_surface ") >= 0
        w.close()
        return err
    }
    t := g.texture(Image{2, 2, 4, []u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255}}, FilterNearest)
    good := frames(g, w, t, 10)
    if g.lost != "" || g.stats.frames == 0 {
        why := if g.lost != "" { g.lost } else { "no frame was drawn" }
        gfx_close(g)
        w.close()
        return why
    }
    print("size", g.width, g.height, "window", w.width, w.height, "frames ok:", good)
    g.vsync = false
    good = good && frames(g, w, t, 10)
    g.vsync = true
    print("without vsync and back:", good)
    full := follow(g, w, t, true)
    back := follow(g, w, t, false)
    print("fullscreen followed:", full, "back:", back, "size", g.width, g.height)
    print("device lost:", g.lost != "")
    gfx_close(g)
    w.close()
    if good && full && back { "" } else { "the frames above" }
}

fn main() -> i64 {
    runtime, has := env_get("XDG_RUNTIME_DIR")
    if !has {
        print("XDG_RUNTIME_DIR is not set")
        return 1
    }
    socket := fmt("al-gfx-wl-test-", process_id())
    path := path_join(runtime, socket)
    weston: Process
    up := false
    for renderer in []str{"--renderer=gl", ""} {
        args := []str{"env", "-u", "WAYLAND_DISPLAY", "-u", "DISPLAY", "timeout", "-k", "5", "60",
            "weston", "--backend=headless", fmt("--socket=", socket), "--width=800", "--height=600", "--no-config",
            "--log=/dev/null", renderer}
        p, started := spawn(if renderer != "" { args } else { args[..len(args) - 1] })
        if !started {
            print("cannot start weston:", error_text(io_error()))
            return 1
        }
        weston = p
        for i in 0..250 {
            if file_exists(path) { break }
            _, ended := try_wait(weston)
            if ended { break }
            sleep_ns(20_000_000)
        }
        if file_exists(path) {
            up = true
            break
        }
        stop(weston)
    }
    if !up {
        print("weston did not start")
        return 1
    }
    wl_name := concat("wayland:", socket)
    status := 1
    for software in []bool{false, true} {
        skip := false
        err := attempt(wl_name, GfxDesc{debug: true, software: software}, &skip)
        if err == "" {
            status = 0
            break
        }
        eprint(concat(if software { "software device: " } else { "first device: " }, err))
        if skip {
            print("no Vulkan for std.gfx here:", err)
            status = 77
            break
        }
    }
    print("validation messages:", __gfx_vk_messages)
    stop(weston)
    if status == 0 && __gfx_vk_messages != 0 { 1 } else { status }
}
