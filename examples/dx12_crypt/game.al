// Crypt: a first-person maze with Direct3D 12 and WASAPI (Windows). Take every gem, then reach
// the exit; three wraiths hunt by sight, and the lantern's flash stuns them for a while. A
// title screen, a pause menu with settings (music, sound, mouse speed, invert look, fullscreen),
// mouse-look, keyboard + mouse or gamepad, the best score and the settings saved in the user's
// data directory, a fixed-step simulation that pauses when the window loses the focus.
//
//   alc build --gui examples/dx12_crypt/game.al -o build/crypt.exe     then run build\crypt.exe
//
//   --headless [N]         no window, GPU or sound device: N frames (default 14000) of a scripted
//                          player, then checksums of the game state and of the mixed sound
//   --test                 the headless run, and pictures of it drawn offscreen on WARP with
//                          pixels checked (tests/sys/dx12_crypt); --shots DIR also saves them
//   --script               the window plays itself (the headless run's player)
//   --shot N FILE          saves frame N of the window as a PNG (read back from the GPU)
//   --frames N             quit after N frames
//   --fullscreen  --warp  --no-vsync  --audio NAME (default, null, ...)
//   --save-dir DIR         keep the save file in DIR instead of the user's data directory
//
// WASD / arrows / left stick walk, the mouse or right stick looks, F / E / right click / pad X
// or RB flashes the lantern, Escape / P / Start pauses (arrows or D-pad and Enter / A in the
// menu, Escape or B back), F11 or Alt+Enter toggles fullscreen, Escape on the title quits.
//
// The parts: logic.al (the game), sound.al (generated sounds), save.al (the save file),
// headless.al (the scripted player and run), render.al (Direct3D 12), front.al (window, GPU,
// sound device), and ../gamekit (device set-up, sprite batcher, font, synthesizer).
use "headless.al"

when TARGET_OS == Windows {
    use "front.al"
} else {
    // Direct3D 12 exists only on Windows: elsewhere only the headless run works
    fn run_window(o: Options) { panic("the window needs Windows (Direct3D 12): use --headless") }
    fn run_test(o: Options) -> i64 { panic("--test needs Windows (Direct3D 12)") }
}

struct Options {
    headless: bool
    selftest: bool
    script: bool
    frames: i64          // -1: until closed
    shot_frame: i64      // -1: none
    shot_file: str
    shots_dir: str
    fullscreen: bool
    warp: bool
    vsync: bool
    audio: str
    save_dir: str
}

fn parse_options(a: []str) -> (Options, str) {
    o := Options{frames: -1, shot_frame: -1, vsync: true, audio: "default"}
    k := 1
    fn number(a: []str, k: i64) -> (i64, bool) {
        if k >= len(a) { return (0, false) }
        parse_i64(a[k])
    }
    while k < len(a) {
        s := a[k]
        if s == "--headless" {
            o.headless = true
            o.frames = 14000
            n, ok := number(a, k + 1)
            if ok {
                o.frames = n
                k += 1
            }
        } else if s == "--test" {
            o.selftest = true
        } else if s == "--script" {
            o.script = true
        } else if s == "--frames" {
            n, ok := number(a, k + 1)
            if !ok { return (o, "--frames needs a number") }
            o.frames = n
            k += 1
        } else if s == "--shot" {
            n, ok := number(a, k + 1)
            if !ok || k + 2 >= len(a) { return (o, "--shot needs a frame number and a file name") }
            o.shot_frame = n
            o.shot_file = a[k + 2]
            k += 2
        } else if s == "--shots" && k + 1 < len(a) {
            o.shots_dir = a[k + 1]
            k += 1
        } else if s == "--audio" && k + 1 < len(a) {
            o.audio = a[k + 1]
            k += 1
        } else if s == "--save-dir" && k + 1 < len(a) {
            o.save_dir = a[k + 1]
            k += 1
        } else if s == "--fullscreen" {
            o.fullscreen = true
        } else if s == "--warp" {
            o.warp = true
        } else if s == "--no-vsync" {
            o.vsync = false
        } else {
            return (o, fmt("unknown option ", s, " (options: --headless [N] --test --shots DIR --script --shot N FILE --frames N",
                " --fullscreen --warp --no-vsync --audio NAME --save-dir DIR)"))
        }
        k += 1
    }
    (o, "")
}

fn main() -> i64 {
    o, err := parse_options(args())
    if err != "" {
        eprint(err)
        return 2
    }
    if o.headless {
        crypt_headless(o.frames)
        return 0
    }
    if o.selftest {
        return run_test(o)
    }
    run_window(o)
    0
}
