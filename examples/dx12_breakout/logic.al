// Breakout: the game without any platform. The front end (game.al) and the headless run
// (headless.al) drive it the same way, once per displayed frame:
//
//   if !inp.focused { lose_focus(&g) }         // a game in the background pauses
//   handle_input(&g, inp)                      // menus and commands: reads key edges, once
//   for each fixed step { update(&g, inp, dt) }   // the simulation: reads held keys only
//   ... play g.events, draw, clear g.events ...
//
// Edges ("pressed this frame") are read once per frame in handle_input and latched as commands
// for update, because a frame runs any number of fixed steps, including none.
use std.input

const VIEW_W = 320
const VIEW_H = 180
const HZ = 120.0

const COLS = 12
const ROWS = 6
const BRICK_W: f32 = 24.0
const BRICK_H: f32 = 8.0
const FIELD_L: f32 = 16.0                    // inner edges of the walls
const FIELD_R: f32 = FIELD_L + 12.0 * BRICK_W
const FIELD_T: f32 = 18.0
const BRICKS_T: f32 = 34.0                   // top of the first row of bricks
const PADDLE_Y: f32 = 166.0                  // top of the paddle
const PADDLE_W: f32 = 36.0
const PADDLE_H: f32 = 6.0
const PADDLE_SPEED: f32 = 230.0
const BALL_R: f32 = 3.0
const LIVES = 3
const VOLUME_STEPS = 10

// The pause menu
const MENU_RESUME = 0
const MENU_MUSIC = 1
const MENU_SOUND = 2
const MENU_FULLSCREEN = 3
const MENU_QUIT = 4
const MENU_ITEMS = 5

// Brick layouts, one string per row: '.' empty, '1' .. '3' hit points.
const LEVELS = [3][ROWS]str{
    [ROWS]str{"333333333333", "222222222222", "111111111111", "111111111111", "111111111111", "111111111111"},
    [ROWS]str{"3..3333333.3", "2.22....22.2", "1.11.11.11.1", "1.11.11.11.1", "1....11....1", "111111111111"},
    [ROWS]str{".3.3.3.3.3.3", "3.3.3.3.3.3.", "222222222222", ".2.2.2.2.2.2", "111111111111", "1.1.1.1.1.1."},
}

enum Mode { Title, Playing, Paused, GameOver }

// Sounds the front end plays for what happened; `x` is where (for stereo panning), `n` a
// detail (the row of a brick).
enum Sfx { SfxWall, SfxPaddle, SfxBrick, SfxBreak, SfxLaunch, SfxLost, SfxLevel, SfxOver, SfxMove, SfxSelect }
struct GameEvent { sfx: Sfx, x: f32, n: i64 }

struct Actions { left: i64, right: i64, up: i64, down: i64, fire: i64, confirm: i64, pause: i64, back: i64 }

struct Spark { pos: vec2, vel: vec2, life: f32, color: u32 }

struct Settings {
    music: i64           // 0 .. VOLUME_STEPS
    sound: i64
}

struct Game {
    mode: Mode
    menu: i64                    // selected item of the pause menu
    settings: Settings
    level: i64                   // 1, 2, ...; the layouts repeat, faster
    score: i64
    best: i64
    lives: i64
    paddle: f32                  // x of the paddle's centre
    paddle_prev: f32             // one step ago (for interpolated drawing)
    ball: vec2
    ball_prev: vec2
    vel: vec2
    stuck: bool                  // the ball waits on the paddle for a launch
    launch: bool                 // latched command: launch at the next step
    bricks: [ROWS * COLS]i32     // hit points left, 0 = gone
    left: i64                    // bricks left
    banner: f32                  // seconds the "LEVEL n" banner still shows
    sparks: Pool[Spark]
    rng: Rng
    keys: ActionMap
    act: Actions
    step_no: i64
    time: f64                    // seconds of simulation (blinking text)
    events: Vec[GameEvent]
    want_fullscreen: bool        // requests to the front end, which clears them
    want_quit: bool
    dpad: vec2                   // the gamepad's D-pad in the last frame (its presses are edges)
}

fn game_new(seed: u64) -> Game {
    g: Game
    g.mode = Title
    g.settings = Settings{music: 6, sound: 8}
    g.sparks = pool_new[Spark](256)
    g.rng = rng(seed)
    g.keys = action_map()
    k := &g.keys
    g.act = Actions{left: k.action("left"), right: k.action("right"), up: k.action("up"), down: k.action("down"),
        fire: k.action("fire"), confirm: k.action("confirm"), pause: k.action("pause"), back: k.action("back")}
    a := g.act
    for key in [_]i64{KEY_LEFT, KEY_A} { k.bind_key(a.left, key) }
    for key in [_]i64{KEY_RIGHT, KEY_D} { k.bind_key(a.right, key) }
    for key in [_]i64{KEY_UP, KEY_W} { k.bind_key(a.up, key) }
    for key in [_]i64{KEY_DOWN, KEY_S} { k.bind_key(a.down, key) }
    k.bind_key(a.fire, KEY_SPACE)
    k.bind_key(a.fire, KEY_UP)
    k.bind_pad(a.fire, PAD_A)
    k.bind_key(a.confirm, KEY_ENTER)
    k.bind_key(a.confirm, KEY_KP_ENTER)
    k.bind_key(a.confirm, KEY_SPACE)
    k.bind_pad(a.confirm, PAD_A)
    k.bind_key(a.pause, KEY_ESCAPE)
    k.bind_key(a.pause, KEY_P)
    k.bind_pad(a.pause, PAD_START)
    k.bind_key(a.back, KEY_ESCAPE)
    k.bind_pad(a.back, PAD_B)
    g.paddle = (FIELD_L + FIELD_R) / 2.0
    g.paddle_prev = g.paddle
    g.events.reserve(64)
    g
}

priv fn event(g: *Game, sfx: Sfx, x: f32, n: i64) {
    g.events.push(GameEvent{sfx, x, n})
}

// The rectangle of brick i: x, y, width, height.
fn brick_rect(i: i64) -> vec4 {
    vec4(FIELD_L + f32(i % COLS) * BRICK_W, BRICKS_T + f32(i / COLS) * BRICK_H, BRICK_W, BRICK_H)
}

priv fn start_level(g: *Game) {
    layout := LEVELS[(g.level - 1) % len(LEVELS)]
    g.left = 0
    for r in 0..ROWS {
        for c in 0..COLS {
            ch := layout[r][c]
            hp := if ch >= '1' && ch <= '3' { i32(ch - '0') } else { 0 }
            g.bricks[r * COLS + c] = hp
            if hp > 0 {
                g.left += 1
            }
        }
    }
    g.stuck = true
    g.launch = false
    g.banner = 2.0
}

priv fn start_game(g: *Game) {
    g.mode = Playing
    g.level = 1
    g.score = 0
    g.lives = LIVES
    g.sparks.clear()
    start_level(g)
}

// Back to the title screen (from the menu or after the end): the field is cleared.
priv fn to_title(g: *Game) {
    g.mode = Title
    g.best = max(g.best, g.score)
    g.score = 0
    g.level = 0
    g.lives = 0
    fill(g.bricks[..], 0)
    g.left = 0
}

// The ball speed of the current level, in pixels per second.
fn ball_speed(g: *Game) -> f32 {
    150.0 + 15.0 * f32(min(g.level - 1, 8))
}

// The window lost the focus: a running game pauses.
fn lose_focus(g: *Game) {
    if g.mode == Playing {
        g.mode = Paused
        g.menu = MENU_RESUME
    }
}

// Menus and commands, once per frame (edges are only seen here).
fn handle_input(g: *Game, inp: *Input) {
    k := &g.keys
    a := g.act
    match g.mode {
        Title => {
            if k.action_pressed(inp, a.confirm) {
                start_game(g)
                event(g, SfxSelect, 160.0, 0)
            } else if k.action_pressed(inp, a.back) {
                g.want_quit = true
            }
        }
        Playing => {
            if k.action_pressed(inp, a.pause) {
                g.mode = Paused
                g.menu = MENU_RESUME
                event(g, SfxSelect, 160.0, 0)
            } else if k.action_pressed(inp, a.fire) && g.stuck {
                g.launch = true
            }
        }
        Paused => menu_input(g, inp, dpad_pushed(g, &inp.pad))
        GameOver => {
            if k.action_pressed(inp, a.confirm) || k.action_pressed(inp, a.back) {
                to_title(g)
                event(g, SfxSelect, 160.0, 0)
            }
        }
    }
    g.dpad = vec2(inp.pad.pad_axis(PAD_AXIS_DPAD_X), inp.pad.pad_axis(PAD_AXIS_DPAD_Y))
}

// The D-pad directions pushed this frame (-1, 0, 1 per axis, y down): it is a pair of axes.
priv fn dpad_pushed(g: *Game, pad: *Gamepad) -> vec2 {
    now := vec2(pad.pad_axis(PAD_AXIS_DPAD_X), pad.pad_axis(PAD_AXIS_DPAD_Y))
    vec2(if now.x != g.dpad.x { now.x } else { 0.0 }, if now.y != g.dpad.y { now.y } else { 0.0 })
}

priv fn menu_input(g: *Game, inp: *Input, dpad: vec2) {
    k := &g.keys
    a := g.act
    up := k.action_pressed(inp, a.up) || dpad.y < 0.0
    down := k.action_pressed(inp, a.down) || dpad.y > 0.0
    left := k.action_pressed(inp, a.left) || dpad.x < 0.0
    right := k.action_pressed(inp, a.right) || dpad.x > 0.0
    if k.action_pressed(inp, a.pause) || k.action_pressed(inp, a.back) {
        g.mode = Playing
        event(g, SfxSelect, 160.0, 0)
        return
    }
    if up || down {
        step := if up { MENU_ITEMS - 1 } else { 1 }
        g.menu = (g.menu + step) % MENU_ITEMS
        event(g, SfxMove, 160.0, 0)
    }
    if left || right {
        d := if right { 1 } else { -1 }
        if g.menu == MENU_MUSIC {
            g.settings.music = clamp(g.settings.music + d, 0, VOLUME_STEPS)
            event(g, SfxMove, 160.0, 0)
        } else if g.menu == MENU_SOUND {
            g.settings.sound = clamp(g.settings.sound + d, 0, VOLUME_STEPS)
            event(g, SfxBrick, 160.0, 0)                    // a sample at the new volume
        }
    }
    if k.action_pressed(inp, a.confirm) {
        match g.menu {
            MENU_RESUME => g.mode = Playing
            MENU_FULLSCREEN => g.want_fullscreen = true
            MENU_QUIT => to_title(g)
            _ => {}
        }
        event(g, SfxSelect, 160.0, 0)
    }
}

// Where the player steers the paddle, -1 .. 1: keys, D-pad or the left stick (analog).
fn paddle_input(g: *Game, inp: *Input) -> f32 {
    d := g.keys.action_axis(inp, g.act.left, g.act.right)
    if d == 0.0 {
        d = inp.pad.pad_axis(PAD_AXIS_DPAD_X)
    }
    if d == 0.0 {
        d = inp.pad.pad_stick(PAD_AXIS_LX, PAD_AXIS_LY, 0.2).x
    }
    d
}

// One fixed simulation step.
fn update(g: *Game, inp: *Input, dt: f32) {
    g.step_no += 1
    g.time += f64(dt)
    move_sparks(g, dt)
    if g.mode != Playing {
        return
    }
    g.banner = fmax(g.banner - dt, 0.0)
    g.paddle_prev = g.paddle
    half := PADDLE_W / 2.0
    g.paddle = clamp(g.paddle + paddle_input(g, inp) * PADDLE_SPEED * dt, FIELD_L + half, FIELD_R - half)
    g.ball_prev = g.ball
    if g.stuck {
        g.ball = vec2(g.paddle, PADDLE_Y - BALL_R - 0.5)
        g.ball_prev = g.ball
        if g.launch && g.banner <= 1.0 {
            g.stuck = false
            g.launch = false
            g.vel = normalize(vec2(0.45, -1.0)) * ball_speed(g)
            event(g, SfxLaunch, g.ball.x, 0)
        }
        return
    }
    g.ball = g.ball + g.vel * dt
    walls(g)
    hit_brick(g)
    hit_paddle(g)
    if g.ball.y > f32(VIEW_H) + 8.0 {
        lose_ball(g)
    } else if g.left == 0 {
        g.level += 1
        start_level(g)
        event(g, SfxLevel, 160.0, g.level)
    }
}

priv fn walls(g: *Game) {
    if g.ball.x < FIELD_L + BALL_R {
        g.ball.x = FIELD_L + BALL_R
        g.vel.x = fabs(g.vel.x)
        event(g, SfxWall, g.ball.x, 0)
    } else if g.ball.x > FIELD_R - BALL_R {
        g.ball.x = FIELD_R - BALL_R
        g.vel.x = -fabs(g.vel.x)
        event(g, SfxWall, g.ball.x, 0)
    }
    if g.ball.y < FIELD_T + BALL_R {
        g.ball.y = FIELD_T + BALL_R
        g.vel.y = fabs(g.vel.y)
        event(g, SfxWall, g.ball.x, 0)
    }
}

// At most one brick per step: the ball moves less than a pixel and a half in a step, far less
// than a brick, so it cannot pass through one.
priv fn hit_brick(g: *Game) {
    p := g.ball
    for i in 0..ROWS * COLS {
        if g.bricks[i] == 0 {
            continue
        }
        r := brick_rect(i)
        if p.x + BALL_R < r.x || p.x - BALL_R > r.x + r.z || p.y + BALL_R < r.y || p.y - BALL_R > r.y + r.w {
            continue
        }
        // the side it came from: where the previous position was outside the brick
        q := g.ball_prev
        if q.x + BALL_R < r.x || q.x - BALL_R > r.x + r.z {
            g.vel.x = -g.vel.x
        } else {
            g.vel.y = -g.vel.y
        }
        g.ball = q                                       // back to where it did not touch
        g.bricks[i] -= 1
        row := i / COLS
        centre := vec2(r.x + r.z / 2.0, r.y + r.w / 2.0)
        if g.bricks[i] == 0 {
            g.left -= 1
            g.score += 10 * i64(ROWS - row)
            burst(g, centre, 10, row_color(row))
            event(g, SfxBreak, centre.x, row)
        } else {
            g.score += 1
            event(g, SfxBrick, centre.x, row)
        }
        return
    }
}

priv fn hit_paddle(g: *Game) {
    if g.vel.y <= 0.0 || g.ball.y + BALL_R < PADDLE_Y || g.ball.y - BALL_R > PADDLE_Y + PADDLE_H {
        return
    }
    off := (g.ball.x - g.paddle) / (PADDLE_W / 2.0 + BALL_R)
    if fabs(off) > 1.0 {
        return
    }
    // the further out it hits, the flatter it leaves (up to 60 degrees); a little faster each time
    angle := off * 1.0472
    speed := fmin(length(g.vel) * 1.01, ball_speed(g) * 1.5)
    g.vel = vec2(sin(angle), -cos(angle)) * speed
    g.ball.y = PADDLE_Y - BALL_R
    event(g, SfxPaddle, g.ball.x, 0)
}

priv fn lose_ball(g: *Game) {
    g.lives -= 1
    event(g, SfxLost, g.ball.x, 0)
    if g.lives > 0 {
        g.stuck = true
        g.launch = false
        return
    }
    g.mode = GameOver
    g.best = max(g.best, g.score)
    event(g, SfxOver, 160.0, 0)
}

priv const ROW_COLORS = [ROWS]u32{0xFF5050F0, 0xFF40A0F8, 0xFF40E0F0, 0xFF60D060, 0xFFE0B040, 0xFFE070A0}

// The colour of a row of bricks (RGBA8, red in the lowest byte).
fn row_color(row: i64) -> u32 {
    ROW_COLORS[row]
}

priv fn burst(g: *Game, at: vec2, n: i64, color: u32) {
    for k in 0..n {
        g.sparks.insert(Spark{at, g.rng.unit_vec2() * g.rng.range(30.0, 110.0), g.rng.range(0.2, 0.6), color})
    }
}

priv fn move_sparks(g: *Game, dt: f32) {
    for i in 0..g.sparks.len {
        if !g.sparks.is_live(i) {
            continue
        }
        s := &g.sparks.items[i]
        s.pos = s.pos + s.vel * dt
        s.vel.y += 200.0 * dt
        s.life -= dt
        if s.life <= 0.0 {
            g.sparks.remove(g.sparks.handle_at(i))
        }
    }
}

// A hash of everything that decides the future of the game: equal runs give equal values.
fn state_checksum(g: *Game) -> u64 {
    fn fnv(h: u64, x: u64) -> u64 { (h ^ x) * 1099511628211 }
    fn bits(x: f32) -> u64 { cast[u64](f64(x)) }
    h: u64 = 1469598103934665603
    mode: u64 = match g.mode { Title => 1; Playing => 2; Paused => 3; GameOver => 4 }
    for x in [_]u64{mode, u64(g.menu), u64(g.settings.music), u64(g.settings.sound), u64(g.level), u64(g.score),
            u64(g.best), u64(g.lives), u64(g.left), u64(g.step_no), bits(g.paddle), bits(g.ball.x), bits(g.ball.y),
            bits(g.vel.x), bits(g.vel.y), if g.stuck { 1 } else { 0 }, bits(g.banner)} {
        h = fnv(h, x)
    }
    for b in g.bricks {
        h = fnv(h, u64(b))
    }
    r := g.rng                                 // a copy: the next number it would give
    h = fnv(h, r.next_u64())
    h = fnv(h, u64(g.sparks.used))
    h
}
