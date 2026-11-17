// Crypt without window, GPU or sound device: a scripted player feeds keyboard, mouse and
// gamepad events into an Input, frame by frame, through the same calls as the front end. It
// starts a game, goes through the pause menu, loses the focus once, walks the maze with the
// mouse and keyboard (a breadth-first search picks the way) until it has every gem and reaches
// the exit, then plays a second game with the gamepad, walking into the wraiths until it loses.
// The sounds are mixed into a buffer; checksums of the state and of the mix are printed.
// Pure AL: the same numbers on every system.
use std.input
use std.audio
use "logic.al"
use "sound.al"
use "save.al"

const HEADLESS_FPS = 60
const MIX_FRAMES = AUDIO_RATE / HEADLESS_FPS

// The scripted player's own memory.
struct Bot {
    games: i64            // games started
    wins: i64
    losses: i64
    last_mode: Mode
    gem: i64              // the gem it walks to, until it has it (a new choice on the way would dither)
}

// A whole scripted run: the game, its input and sound, and the bot.
struct Headless {
    g: Game
    inp: Input
    snd: CryptSound
    bot: Bot
    frame: i64
    buf: []i16
    audio: u64
    fullscreen_requests: i64
    log: bool             // print a line when the mode changes
}

fn headless_new(log: bool) -> Headless {
    h := Headless{g: game_new(11), snd: crypt_sound(), buf: alloc[i16](MIX_FRAMES * 2), audio: 1469598103934665603, log: log}
    h.inp.focused = true                               // as a window that has the focus
    h
}

priv fn key(inp: *Input, k: i64, down: bool) {
    inp.feed(Event{kind: if down { EventKeyDown } else { EventKeyUp }, key: k})
}

// a key pressed and released within the frame
priv fn tap(inp: *Input, k: i64) {
    key(inp, k, true)
    key(inp, k, false)
}

// holds `k` if `want`, else releases it
priv fn hold(inp: *Input, k: i64, want: bool) {
    if want != inp.key_down(k) {
        key(inp, k, want)
    }
}

// Where the bot goes: the nearest gem it has not taken, else the exit (or, `hunt`, the
// nearest wraith).
priv fn goal(g: *Game, b: *Bot, hunt: bool) -> vec2 {
    best := g.exit
    best_d: f32 = 1.0e9
    if hunt {
        for i in 0..g.n_enemies {
            d := distance(g.enemies[i].pos, g.pos)
            if d < best_d {
                best_d = d
                best = g.enemies[i].pos
            }
        }
        return best
    }
    if b.gem >= 0 && !g.gems[b.gem].taken {
        return g.gems[b.gem].pos
    }
    b.gem = -1
    for i in 0..g.n_gems {
        d := distance(g.gems[i].pos, g.pos)
        if !g.gems[i].taken && d < best_d {
            best_d = d
            best = g.gems[i].pos
            b.gem = i
        }
    }
    best
}

// The bot's way around the wraiths: the next cell on a way to the goal that keeps a cell away
// from every wraith; if there is none, the neighbouring cell farthest from the nearest wraith
// that comes close.
priv fn avoid(g: *Game, target: vec2, to: vec2) -> vec2 {
    blocked: [MAP_W * MAP_H]bool
    pc, pr := cell_of(g.pos)
    for i in 0..g.n_enemies {
        if g.enemies[i].stun > 0.5 {
            continue                                   // stunned by the lantern: walk past it
        }
        ec, er := cell_of(g.enemies[i].pos)
        for dr in -1..2 {
            for dc in -1..2 {
                c := ec + dc
                r := er + dr
                if c >= 0 && r >= 0 && c < MAP_W && r < MAP_H && !(c == pc && r == pr) {
                    blocked[r * MAP_W + c] = true
                }
            }
        }
    }
    way := path_next(g.pos, target, blocked[..])
    if way != g.pos {
        return way
    }
    for i in 0..g.n_enemies {
        e := g.enemies[i]
        if distance(e.pos, g.pos) > 3.0 {
            continue
        }
        c, r := cell_of(g.pos)
        best := to
        best_d: f32 = 0.0
        for d in [_](i64, i64){(1, 0), (-1, 0), (0, 1), (0, -1)} {
            if is_wall(c + d.0, r + d.1) {
                continue
            }
            p := cell_center(c + d.0, r + d.1)
            if distance(p, e.pos) > best_d {
                best_d = distance(p, e.pos)
                best = p
            }
        }
        return best
    }
    to
}

// How far (radians) the bot must turn to the left to face `to`.
priv fn turn_needed(g: *Game, to: vec2) -> f32 {
    d := to - g.pos
    wrap_angle(atan2(-d.x, -d.y) - g.yaw)
}

// The scripted player of frame f: events for this frame into `inp` (after begin_frame or a
// window's poll). The window's front end runs it too (--script).
fn script(g: *Game, inp: *Input, b: *Bot, f: i64) {
    playing := g.mode == Playing
    if g.mode == Title && b.games < 2 && f % 120 == 20 {
        tap(inp, KEY_ENTER)                            // start a game from the title screen (two in all)
    }
    // the pause menu: music up, sound down, mouse speed up, invert on and off, resume
    menu := [_](i64, i64){(300, KEY_ESCAPE), (306, KEY_DOWN), (310, KEY_RIGHT), (314, KEY_DOWN), (318, KEY_LEFT),
        (322, KEY_DOWN), (326, KEY_RIGHT), (330, KEY_DOWN), (334, KEY_ENTER), (338, KEY_ENTER), (342, KEY_UP),
        (346, KEY_UP), (350, KEY_UP), (354, KEY_UP), (360, KEY_ENTER)}
    for m in menu {
        if f == m.0 {
            tap(inp, m.1)
        }
    }
    // the focus goes away (the game pauses), comes back, and Escape resumes the game
    if f == 700 {
        inp.feed(Event{kind: EventUnfocus})
    }
    if f == 760 {
        inp.feed(Event{kind: EventFocus})
    }
    if f == 770 {
        tap(inp, KEY_ESCAPE)
    }
    // after the end of a game, back to the title screen
    if (g.mode == Won || g.mode == Lost) && g.end_time > 1.5 {
        tap(inp, KEY_ENTER)
    }
    pad := b.games >= 2
    if !playing || !inp.focused {
        hold(inp, KEY_W, false)
        if pad {
            gamepad_event(&inp.pad, 2, u8(PAD_AXIS_LY), 0)
            gamepad_event(&inp.pad, 2, u8(PAD_AXIS_RX), 0)
        }
        return
    }
    // walking: face the next cell on the way, walk when roughly facing it
    // the lantern when a wraith comes for it
    for i in 0..g.n_enemies {
        e := g.enemies[i]
        if e.stun <= 0.0 && distance(e.pos, g.pos) < 5.0 && line_of_sight(e.pos, g.pos) && g.flash_wait <= 0.0 {
            if pad { gamepad_event(&inp.pad, 1, u8(PAD_X), 1) } else { tap(inp, KEY_F) }
        }
    }
    if pad && f % 30 == 15 {
        gamepad_event(&inp.pad, 1, u8(PAD_X), 0)
    }
    target := goal(g, b, pad)
    to := path_next(g.pos, target)
    if !pad {
        to = avoid(g, target, to)
    }
    turn_left := turn_needed(g, to)
    if pad {
        // the right stick turns (a rate), the left stick walks
        rx: i16 = if turn_left > 0.05 { -20000 } else if turn_left < -0.05 { 20000 } else { 0 }
        gamepad_event(&inp.pad, 2, u8(PAD_AXIS_RX), rx)
        ly: i16 = if fabs(turn_left) < 0.5 { -32000 } else { 0 }
        gamepad_event(&inp.pad, 2, u8(PAD_AXIS_LY), ly)
    } else {
        counts := i64(round(-turn_left / mouse_scale(g.settings)))
        // positions, not motion: the Input takes the difference to the last position
        inp.feed(Event{kind: EventMouseMove, x: i64(inp.mouse_x) + clamp(counts, -60, 60), y: i64(inp.mouse_y)})
        hold(inp, KEY_W, fabs(turn_left) < 0.5)
    }
}

fn mode_name(m: Mode) -> str {
    match m { Title => "title"; Playing => "playing"; Paused => "paused"; Won => "won"; Lost => "lost" }
}

// Counts the games the bot played after a frame's steps; true if the mode changed.
fn bot_track(g: *Game, b: *Bot) -> bool {
    if g.mode == b.last_mode {
        return false
    }
    if g.mode == Playing && b.last_mode == Title {
        b.games += 1
    }
    if g.mode == Won { b.wins += 1 }
    if g.mode == Lost { b.losses += 1 }
    b.last_mode = g.mode
    true
}

// One displayed frame: input, two fixed steps, sound.
fn headless_frame(h: *Headless) {
    g := &h.g
    h.inp.begin_frame()
    script(g, &h.inp, &h.bot, h.frame)
    if !h.inp.focused {
        lose_focus(g)
    }
    handle_input(g, &h.inp)
    if g.want_fullscreen {
        g.want_fullscreen = false
        h.fullscreen_requests += 1
    }
    for k in 0..2 {
        update(g, &h.inp, 1.0 / f32(HZ))
    }
    if bot_track(g, &h.bot) && h.log {
        print("frame", h.frame, mode_name(g.mode), "gems", g.got, "hp", g.hp, "score", g.score)
    }
    play_events(&h.snd, g)
    h.snd.mixer.mix_i16(h.buf, MIX_FRAMES)
    h.audio = audio_checksum(h.audio, h.buf)
    h.frame += 1
}

fn headless_report(h: *Headless) {
    g := &h.g
    // the save file's text survives a round trip (the user's files are not touched)
    copy := game_new(3)
    copy.load_text(save_text(g))
    print("frames", h.frame, "steps", g.step_no, "mode", mode_name(g.mode), "games", h.bot.games, "wins", h.bot.wins,
        "losses", h.bot.losses, "best", g.best, "settings", g.settings.music, g.settings.sound, g.settings.mouse,
        g.settings.invert, "fullscreen requests", h.fullscreen_requests, "save round trip",
        copy.best == g.best && copy.settings == g.settings)
    print("state", hex(state_checksum(g), 16), "audio", hex(h.audio, 16))
}

// Runs `frames` frames and prints the results.
fn crypt_headless(frames: i64) {
    h := headless_new(true)
    for f in 0..frames {
        headless_frame(&h)
    }
    headless_report(&h)
}
