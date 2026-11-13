// The command line both Direct3D 12 games accept.
//   --headless [N]   no window, GPU or sound device: N frames (default 1800) of scripted input,
//                    then checksums of the game state and of the mixed sound
//   --frames N       quit after N frames (smoke tests)
//   --fullscreen     start fullscreen (F11 or Alt+Enter toggles)
//   --warp           draw with WARP, the software rasterizer of Direct3D 12
//   --no-vsync       present as fast as possible
//   --audio NAME     the sound device ("default"; "null" discards the sound; audio_devices()
//                    names the others)
struct GameOptions {
    headless: bool
    frames: i64          // -1: until closed
    fullscreen: bool
    warp: bool
    vsync: bool
    audio: str
}

// The options of args(), or the reason they are wrong.
fn parse_options(a: []str) -> (GameOptions, str) {
    o := GameOptions{frames: -1, vsync: true, audio: "default"}
    k := 1
    while k < len(a) {
        s := a[k]
        if s == "--headless" {
            o.headless = true
            o.frames = 1800
            if k + 1 < len(a) {
                n, ok := parse_i64(a[k + 1])
                if ok {
                    o.frames = n
                    k += 1
                }
            }
        } else if s == "--frames" && k + 1 < len(a) {
            n, ok := parse_i64(a[k + 1])
            if !ok {
                return (o, fmt("--frames: not a number: ", a[k + 1]))
            }
            o.frames = n
            k += 1
        } else if s == "--audio" && k + 1 < len(a) {
            o.audio = a[k + 1]
            k += 1
        } else if s == "--fullscreen" {
            o.fullscreen = true
        } else if s == "--warp" {
            o.warp = true
        } else if s == "--no-vsync" {
            o.vsync = false
        } else {
            return (o, fmt("unknown option ", s, " (options: --headless [N] --frames N --fullscreen --warp --no-vsync --audio NAME)"))
        }
        k += 1
    }
    (o, "")
}
