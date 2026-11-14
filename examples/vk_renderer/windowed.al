// The scene of renderer.al in a window (present.al): X11 through std.window or a raw Wayland
// surface, a swapchain recreated on resize, a choice of present modes.
//
//     alc run examples/vk_renderer/windowed.al -- [x11|wayland] [fifo|mailbox|immediate] [seconds]
//
// Keys (X11): 1 / 2 / 3 switch to fifo / mailbox / immediate, F11 toggles fullscreen, Escape
// quits; minimising pauses rendering. With `seconds` it stops by itself after going fullscreen
// halfway. Exit status 1 if the validation layer reported an error or a warning.
use "present.al"

fn main() -> i64 {
    a := args()
    run := Run{wayland: a.len > 1 && a[1] == "wayland", mode: VK_PRESENT_MODE_FIFO_KHR, verbose: true}
    if a.len > 1 && a[1] != "wayland" && a[1] != "x11" || a.len > 4 {
        print("usage: windowed [x11|wayland] [fifo|mailbox|immediate] [seconds]")
        return 2
    }
    if a.len > 2 {
        run.mode = match a[2] {
            "fifo" => VK_PRESENT_MODE_FIFO_KHR
            "mailbox" => VK_PRESENT_MODE_MAILBOX_KHR
            "immediate" => VK_PRESENT_MODE_IMMEDIATE_KHR
            _ => {
                print("unknown present mode", a[2])
                return 2
            }
        }
    }
    if a.len > 3 {
        run.seconds = parse_f64(a[3]).0
        run.scripted = true
    }
    s, problem := run_windowed(run)
    if problem != "" {
        print(problem)
        return 77
    }
    print("frames:", s.frames, "| swapchain recreations:", s.recreated, "| size", s.first.width, "x", s.first.height, "->",
        s.last.width, "x", s.last.height, "| validation errors:", debug_stats.errors, "warnings:", debug_stats.warnings)
    if debug_stats.errors + debug_stats.warnings > 0 { 1 } else { 0 }
}
