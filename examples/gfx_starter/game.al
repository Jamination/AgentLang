// examples/dx12_starter drawn with std.gfx instead of its own Direct3D 12 code: the same rules
// (../starter/logic.al), sounds and music (../dx12_starter/sound.al), headless run
// (../dx12_starter/headless.al) and options (../gamekit/options.al). What dx12_starter takes
// from gamekit's dx12_gpu.al and screen.al (device, swap chain, frames in flight, sprite
// batcher, letterbox, resizing: about 700 lines) is std.gfx here, its bitmap font is a
// TrueType font of the system drawn with std.gfx_text, and the game runs on Linux (Vulkan) as
// well as Windows (Direct3D 12):
//
//   alc run examples/gfx_starter/game.al                 play
//   alc run examples/gfx_starter/game.al -- --headless   no window, GPU or sound device: checksums
//
// Arrows / WASD / D-pad / left stick move, Space / pad A shoots, M music on / off, F11 or
// Alt+Enter fullscreen, Escape / pad Back quits; after the end, fire plays again. The game
// pauses while its window does not have the focus. --warp draws with the software rasterizer.
use std.window
use std.audio
use std.image
use std.gfx
use std.gfx_text
use "../starter/logic.al"
use "../dx12_starter/sound.al"
use "../dx12_starter/headless.al"
use "../gamekit/options.al"

const DISC_SIZE = 16             // the entity sprite: a soft white disc
const WHITE: u32 = 0xFFFFFFFF
const TEXT_PX: f32 = 10.0        // em sizes of the two fonts in virtual pixels
const TITLE_PX: f32 = 20.0

// The disc that every entity is drawn with, tinted.
fn make_disc() -> Image {
    img := image_new(DISC_SIZE, DISC_SIZE, 4)
    c := f32(DISC_SIZE) / 2.0
    for y in 0..DISC_SIZE {
        for x in 0..DISC_SIZE {
            d := length(vec2(f32(x) + 0.5, f32(y) + 0.5) - vec2(c))
            img.set(x, y, vec4(1.0, 1.0, 1.0, clamp(c - d, 0.0, 1.0)))
        }
    }
    img
}

// A font of the system; without one, the font that std.font is tested with (its own letters
// are only A, V, H, o and W: the others show as its missing glyph, a box).
const FONT_PATHS = [_]str{
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
}
const TEST_FONT = embed("../../tests/std/data/font_test.ttf")

fn load_font() -> Font {
    for p in FONT_PATHS {
        f, err := font_load(p)
        if err == "" {
            return f
        }
    }
    eprint("no system font found: the text is drawn with the test font of std.font")
    f, _ := font_parse(TEST_FONT)
    f
}

// The fonts of the HUD. They are rasterised at the size they have on the screen (their size in
// virtual pixels times the scale of the view) and drawn at their virtual size, so the text is
// as sharp in a large window as in a small one; a new window size makes them anew.
struct Text { font: Font, scale: f32, small: GfxFont, big: GfxFont }

text_mem: Region                 // the atlases of the fonts in use (reset when they are made anew)

fn fonts_for(g: *Gfx, t: *Text, scale: f32) {
    if scale == t.scale || !(scale > 0.0) {
        return
    }
    if t.scale > 0.0 {
        gfx_font_free(g, t.small)
        gfx_font_free(g, t.big)
    }
    reset(&text_mem)
    enter(&text_mem)
    err := ""
    t.small, err = gfx_font(g, t.font, TEXT_PX * scale, char_range(32, 126))
    assert err == "", err
    t.big, err = gfx_font(g, t.font, TITLE_PX * scale, char_range(32, 126))
    assert err == "", err
    leave()
    t.small.size = TEXT_PX
    t.big.size = TITLE_PX
    t.scale = scale
}

// Drawing only reads the game. `alpha` is how far the display is between two simulation steps.
fn render(g: *Gfx, disc: Texture, t: *Text, game: *Game, alpha: f32, paused: bool, note: str) -> str {
    if !g.begin_frame(0xFF000000) {
        return ""                                          // minimized
    }
    g.set_view(f32(WORLD_W), f32(WORLD_H))                 // the virtual resolution, letterboxed
    g.rect(vec4(0.0, 0.0, f32(WORLD_W), f32(WORLD_H)), 0xFF201810)
    for i in 0..game.ents.len {
        if !game.ents.is_live(i) {
            continue
        }
        e := &game.ents.items[i]
        p := e.pos + e.vel * (alpha / f32(HZ))
        r := e.radius + 0.5
        g.sprite(disc, vec4(0.0, 0.0, f32(DISC_SIZE), f32(DISC_SIZE)), vec4(p.x - r, p.y - r, 2.0 * r, 2.0 * r), e.color)
    }
    g.draw_text(t.small, 4.0, 2.0, fmt("Score ", game.score), WHITE)
    g.draw_text(t.small, f32(WORLD_W) - 4.0, 2.0, fmt("HP ", player_hp(game)), 0xFF40E0FF, AlignRight)
    cx := f32(WORLD_W) / 2.0
    if game.over {
        g.draw_text(t.big, cx, 64.0, "Game over", 0xFF4060FF, AlignCenter)
        g.draw_text(t.small, cx, 94.0, "Fire to play again, Escape to quit", WHITE, AlignCenter)
    }
    if paused {
        g.rect(vec4(0.0, 0.0, f32(WORLD_W), f32(WORLD_H)), 0x99000000)
        g.draw_text(t.big, cx, 70.0, "Paused", WHITE, AlignCenter)
        g.draw_text(t.small, cx, 100.0, "Click the window to go on", WHITE, AlignCenter)
    }
    if note != "" {
        g.draw_text(t.small, 4.0, f32(WORLD_H) - line_height(t.small) - 1.0, note, 0xFF60C0FF)
    }
    g.end_frame()
}

fn run_window(o: GameOptions) {
    w, ok := window_open(WindowDesc{title: "AL starter (std.gfx)", width: WORLD_W * 3, height: WORLD_H * 3,
        resizable: true, fullscreen: o.fullscreen})
    if !ok {
        panic("cannot open a window")
    }
    g, err := gfx_open(w, GfxDesc{software: o.warp})
    if err != "" {
        panic(err)
    }
    g.vsync = o.vsync
    disc := g.texture(make_disc(), FilterNearest)
    text := Text{font: load_font()}
    snd := starter_sound()
    dev, opened := audio_open(o.audio, AUDIO_RATE, 2, 60)   // no sound device: the audio calls do nothing
    if !opened {
        eprint(fmt("no sound: ", audio_error()))
    }
    pad := &w.input.pad
    gamepad_open(pad, 0)
    game := game_new(u64(time_ns()))
    clock := frame_clock()
    steps := fixed_step(HZ)
    frames := 0
    pad_retry: f64 = 0.0
    while !w.should_close() && frames != o.frames {
        w.poll()
        inp := &w.input
        if pad.connected {
            gamepad_poll(pad)
        } else if clock.elapsed >= pad_retry {             // plugged in later: look every 2 s
            gamepad_open(pad, 0)
            pad_retry = clock.elapsed + 2.0
        }
        if game.keys.action_pressed(inp, game.act.quit) {
            w.closing = true
        }
        if inp.key_pressed(KEY_F11) || (inp.key_pressed(KEY_ENTER) && inp.alt_down()) {
            w.set_fullscreen(!w.fullscreen)
        }
        if inp.key_pressed(KEY_M) {
            toggle_music(&snd)
        }
        if game.over && game.keys.action_pressed(inp, game.act.fire) {
            game = game_new(u64(time_ns()))
            snd.mixer.set_volume(snd.music_voice, 0.55)
        }
        paused := !inp.focused
        dt := clock.tick()
        if !paused {
            for k in 0..steps.advance(dt) {
                update(&game, inp, f32(steps.step))
            }
        }
        play_events(&snd, &game)
        snd.mixer.set_paused(snd.music_voice, paused || !snd.music_on)
        audio_pump(dev, snd.mixer)
        note := if dev != nil && dev.lost { "Sound device lost, reconnecting" } else { "" }
        ww, wh := w.size()                                 // the size begin_frame will draw at
        if ww > 0 && wh > 0 && !w.minimized {
            view, _, _, _, _ := fit_view(f32(WORLD_W), f32(WORLD_H), ww, wh)
            fonts_for(g, &text, view.x.x)                  // (not in the frame's scratch memory)
        }
        frame_begin()                                      // the texts of this frame are scratch memory
        rerr := render(g, disc, &text, &game, steps.alpha(), paused, note)
        if rerr != "" {
            panic(rerr)                                    // the GPU was lost (the text is scratch too: use it before frame_end)
        }
        frame_end()
        frames += 1
    }
    print("score", game.score, "frames", frames, "sound underruns", if dev == nil { 0 } else { dev.underruns })
    audio_close(dev)
    gfx_close(g)
    w.close()
}

fn main() {
    o, err := parse_options(args())
    if err != "" {
        eprint(err)
        exit(2)
    }
    if o.headless {
        starter_headless(o.frames)
        return
    }
    run_window(o)
}
