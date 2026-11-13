// std.window and std.dx12 in one program: both declare Win32 names (std.dx12 publicly,
// std.window privately), which must not clash. The window's HWND works with the user32
// functions of std.dx12.
use std.window
use std.dx12

fn main() {
    w, ok := window_open(WindowDesc{title: "window + dx12", width: 300, height: 150, resizable: true})
    print("open:", ok)
    if !ok {
        exit(1)
    }
    r: RECT
    print("client:", GetClientRect(win32_hwnd(w), &r) != 0, r.right - r.left, r.bottom - r.top, w.size())
    w.poll()
    w.close()
    print("closed:", w.should_close(), win32_hwnd(w) == nil)
}
