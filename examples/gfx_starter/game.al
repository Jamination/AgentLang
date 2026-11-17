// examples/dx12_starter drawn with std.gfx instead of its own Direct3D 12 code: the same rules
// (../starter/logic.al), sounds and music (../dx12_starter/sound.al), headless run
// (../dx12_starter/headless.al), options (../gamekit/options.al) and bitmap font
// (../gamekit/font.al, baked into the atlas). What dx12_starter takes from gamekit's
// dx12_gpu.al and screen.al (device, swap chain, frames in flight, sprite batcher, letterbox,
// resizing: about 700 lines) is std.gfx here, and the game runs on Linux (Vulkan) as well as
// Windows (Direct3D 12):
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
use "../starter/logic.al"
use "../dx12_starter/sound.al"
use "../dx12_starter/headless.al"
use "../gamekit/options.al"
use "../gamekit/font.al"

const DISC_X = 0                 // the entity sprite in the atlas: a soft white disc
const DISC_Y = FONT_ATLAS_H
const DISC_SIZE = 16
const WHITE: u32 = 0xFFFFFFFF

// The atlas: the font, and below it a disc that every entity is drawn with, tinted.
fn make_atlas() -> (Image, Font) {
    img := image_new(FONT_ATLAS_W, FONT_ATLAS_H + DISC_SIZE, 4)
    font := font_bake(&img, 0, 0)
    c := f32(DISC_SIZE) / 2.0
    for y in 0..DISC_SIZE {
        for x in 0..DISC_SIZE {
            d := length(vec2(f32(x) + 0.5, f32(y) + 0.5) - vec2(c))
            img.set(DISC_X + x, DISC_Y + y, vec4(1.0, 1.0, 1.0, clamp(c - d, 0.0, 1.0)))
        }
    }
    (img, font)
}

// A line of text with its top left corner at (x, y), each font pixel `scale` pixels large.
fn draw_text(g: *Gfx, atlas: Texture, f: Font, x: f32, y: f32, scale: f32, text: str, color: u32) {
    cx := x
    for c in text {
        if c != ' ' {
            gx, gy := cell(f, c)
            g.sprite(atlas, vec4(f32(gx), f32(gy), f32(GLYPH_W), f32(GLYPH_H)),
                vec4(cx, y, f32(GLYPH_W) * scale, f32(GLYPH_H) * scale), color)
        }
        cx += f32(GLYPH_ADVANCE) * scale
    }
}

fn draw_centered(g: *Gfx, atlas: Texture, f: Font, x: f32, y: f32, scale: f32, text: str, color: u32) {
    draw_text(g, atlas, f, floor(x - text_width(text, scale) / 2.0), y, scale, text, color)
}

// Drawing only reads the game. `alpha` is how far the display is between two simulation steps.
fn render(g: *Gfx, atlas: Texture, font: Font, game: *Game, alpha: f32, paused: bool, note: str) -> str {
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
        g.sprite(atlas, vec4(f32(DISC_X), f32(DISC_Y), f32(DISC_SIZE), f32(DISC_SIZE)), vec4(p.x - r, p.y - r, 2.0 * r, 2.0 * r), e.color)
    }
    draw_text(g, atlas, font, 4.0, 4.0, 1.0, fmt("SCORE ", game.score), WHITE)
    hp := fmt("HP ", player_hp(game))
    draw_text(g, atlas, font, f32(WORLD_W) - 4.0 - text_width(hp, 1.0), 4.0, 1.0, hp, 0xFF40E0FF)
    cx := f32(WORLD_W) / 2.0
    if game.over {
        draw_centered(g, atlas, font, cx, 70.0, 2.0, "GAME OVER", 0xFF4060FF)
        draw_centered(g, atlas, font, cx, 96.0, 1.0, "FIRE TO PLAY AGAIN, ESCAPE TO QUIT", WHITE)
    }
    if paused {
        g.rect(vec4(0.0, 0.0, f32(WORLD_W), f32(WORLD_H)), 0x99000000)
        draw_centered(g, atlas, font, cx, 76.0, 2.0, "PAUSED", WHITE)
        draw_centered(g, atlas, font, cx, 100.0, 1.0, "CLICK THE WINDOW TO GO ON", WHITE)
    }
    if note != "" {
        draw_text(g, atlas, font, 4.0, f32(WORLD_H) - 11.0, 1.0, note, 0xFF60C0FF)
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
    img, font := make_atlas()
    atlas := g.texture(img, FilterNearest)
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
        note := if dev != nil && dev.lost { "SOUND DEVICE LOST, RECONNECTING" } else { "" }
        frame_begin()                                      // the texts of this frame are scratch memory
        rerr := render(g, atlas, font, &game, steps.alpha(), paused, note)
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
