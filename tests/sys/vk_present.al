// The windowed path of examples/vk_renderer (present.al) on a real compositor: the test starts
// its own `weston --backend=headless --renderer=gl` (it shows nothing) on a private socket and
// renders into a raw std.wayland surface through VK_KHR_wayland_surface, once per present mode
// (FIFO, MAILBOX, IMMEDIATE; an unsupported one falls back to FIFO), going fullscreen halfway so
// that the swapchain is recreated for the new size. Any validation error or warning fails it.
// Exit code 77: weston cannot start with the GL renderer, or no Vulkan device can present to it.
use "../../examples/vk_renderer/present.al"
use std.os

// SIGTERM to `timeout`, which passes it on to weston; waits at most 10 s.
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

fn main() -> i64 {
    runtime, has := env_get("XDG_RUNTIME_DIR")
    if !has {
        print("XDG_RUNTIME_DIR is not set")
        return 77
    }
    socket := fmt("al-vk-present-", process_id())
    weston, started := spawn([]str{"env", "-u", "WAYLAND_DISPLAY", "-u", "DISPLAY", "timeout", "-k", "5", "60",
        "weston", "--backend=headless", "--renderer=gl", fmt("--socket=", socket), "--width=640", "--height=480",
        "--no-config", "--log=/dev/null"})
    if !started {
        print("cannot start weston:", error_text(io_error()))
        return 77
    }
    up := false
    for attempt in 0..500 {
        if file_exists(path_join(runtime, socket)) {
            up = true
            break
        }
        _, ended := try_wait(weston)
        if ended { break }
        sleep_ns(20_000_000)
    }
    if !up {
        stop(weston)
        print("weston did not start with the GL renderer")
        return 77
    }

    status := 0
    for mode in []i32{VK_PRESENT_MODE_FIFO_KHR, VK_PRESENT_MODE_MAILBOX_KHR, VK_PRESENT_MODE_IMMEDIATE_KHR} {
        s, problem := run_windowed(Run{wayland: true, wayland_socket: socket, mode: mode, seconds: 1.5, scripted: true})
        if problem != "" {
            stop(weston)
            print(problem)
            return 77
        }
        mode_ok := s.present_mode == mode || s.present_mode == VK_PRESENT_MODE_FIFO_KHR
        ok := s.frames >= 20 && s.recreated == 1 && s.first.width == 800 && s.first.height == 600 &&
            s.last.width == 640 && s.last.height == 480 && mode_ok
        print(mode_name(mode), if ok { "ok" } else { "FAILED" }, "| frames presented: at least 20 | swapchain 800 x 600,",
            "recreated once for fullscreen 640 x 480")
        if !ok {
            print("  frames", s.frames, "recreated", s.recreated, "first", s.first.width, s.first.height, "last",
                s.last.width, s.last.height, "mode", mode_name(s.present_mode))
            status = 1
        }
    }
    stop(weston)
    print("validation errors:", debug_stats.errors, "warnings:", debug_stats.warnings)
    status
}
