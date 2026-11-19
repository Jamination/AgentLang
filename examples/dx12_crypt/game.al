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
//   --still FILE           no window: the scripted run for --frames N frames (default 120), that
//                          frame drawn offscreen (--size W H, default 1280 720) and saved as a PNG
//   --record FILE          no window: the video's scripted game (record.al) for --frames N frames
//                          (default 1230), every frame drawn offscreen (--size W H) and read back,
//                          written raw (RGBA, top row first) in chunks FILE.000, FILE.001, ... of
//                          30 frames, and its sound as FILE.wav (16-bit stereo); join the chunks
//                          with copy /b for an encoder
//   --debug                the Direct3D debug layer on, its messages printed
//   --fullscreen  --warp  --no-vsync  --audio NAME (default, null, ...)
//   --save-dir DIR         keep the save file in DIR instead of the user's data directory
//
// WASD / arrows / left stick walk, the mouse or right stick looks, F / E / right click / pad X
// or RB flashes the lantern, Escape / P / Start pauses (arrows or D-pad and Enter / A in the
// menu, Escape or B back), F11 or Alt+Enter toggles fullscreen, Escape on the title quits.
//
// The parts: logic.al (the game), sound.al (generated sounds), save.al (the save file),
// headless.al (the scripted player and run), record.al (the player of the --record video),
// render.al (Direct3D 12: the passes of a frame),
// shaders.al (its HLSL), scene.al (meshes, lights and effects), materials.al (the procedural
// textures), ui.al and hud.al (the 2D layer: batcher, atlas, HUD and menus), front.al (window,
// GPU, sound device), and ../gamekit (device set-up, font, synthesizer).
use "headless.al"

when TARGET_OS == Windows {
    use "front.al"
} else {
    // Direct3D 12 exists only on Windows: elsewhere only the headless run works
    fn run_window(o: Options) { panic("the window needs Windows (Direct3D 12): use --headless") }
    fn run_test(o: Options) -> i64 { panic("--test needs Windows (Direct3D 12)") }
    fn run_still(o: Options) -> i64 { panic("--still needs Windows (Direct3D 12)") }
    fn run_record(o: Options) -> i64 { panic("--record needs Windows (Direct3D 12)") }
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
    still_file: str      // "": no --still
    record_file: str     // "": no --record
    still_w: i64
    still_h: i64
    debug: bool
}

fn parse_options(a: []str) -> (Options, str) {
    o := Options{frames: -1, shot_frame: -1, vsync: true, audio: "default", still_w: 1280, still_h: 720}
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
        } else if s == "--still" && k + 1 < len(a) {
            o.still_file = a[k + 1]
            k += 1
        } else if s == "--record" && k + 1 < len(a) {
            o.record_file = a[k + 1]
            k += 1
        } else if s == "--size" {
            w, wok := number(a, k + 1)
            h, hok := number(a, k + 2)
            if !wok || !hok || w < 1 || h < 1 { return (o, "--size needs a width and a height") }
            o.still_w = w
            o.still_h = h
            k += 2
        } else if s == "--debug" {
            o.debug = true
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
                " --still FILE --record FILE --size W H --debug --fullscreen --warp --no-vsync --audio NAME --save-dir DIR)"))
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
    if o.still_file != "" {
        return run_still(o)
    }
    if o.record_file != "" {
        return run_record(o)
    }
    run_window(o)
    0
}
