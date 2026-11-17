// Crypt: a first-person maze. Collect every gem, then reach the exit before the wraiths
// catch you three times. This file is the game without any platform: the front end
// (game.al) and the scripted runs (headless.al) drive it the same way, once per frame:
//
//   if !inp.focused { lose_focus(&g) }          // a game in the background pauses
//   handle_input(&g, inp)                       // menus, commands and mouse-look: once per frame
//   for each fixed step { update(&g, inp, dt) } // the simulation: reads held keys and sticks only
//   ... play g.events, draw, clear g.events ...
//
// World coordinates: x to the right, y up, z towards the viewer; the map lies in the x-z plane
// and a position on the floor is a vec2 (x, z). Cell (c, r) of the map covers x in
// [c * CELL, (c + 1) * CELL] and z in [r * CELL, (r + 1) * CELL].
use std.input

const HZ = 120.0
const CELL: f32 = 2.0
const WALL_H: f32 = 2.4
const EYE_H: f32 = 1.1
const PLAYER_R: f32 = 0.3
const ENEMY_R: f32 = 0.35
const PLAYER_SPEED: f32 = 3.4
const ENEMY_PATROL: f32 = 1.5
const ENEMY_CHASE: f32 = 2.3
const SIGHT: f32 = 9.0
const TOUCH: f32 = 0.7
const PICKUP: f32 = 0.7
const MAX_HP = 3
const PAD_TURN: f32 = 3.0         // radians per second at full right stick and speed 5
const VOLUME_STEPS = 10
const FLASH_TIME: f32 = 0.35
const FLASH_WAIT: f32 = 5.0      // seconds between two flashes of the lantern
const FLASH_RANGE: f32 = 6.0
const FLASH_STUN: f32 = 3.0

const MAP_W = 17
const MAP_H = 17
// '#' wall, '.' floor, 'P' the player's start, 'G' a gem, 'E' a wraith, 'X' the exit.
const MAZE = [MAP_H]str{
    "#################",
    "#P..#.....#....G#",
    "#.#.#.###.#.##..#",
    "#.#...#G..#....##",
    "#.#####.#####.#.#",
    "#...E.#.....#...#",
    "###.#.#####.#.#.#",
    "#G..#.....#...#.#",
    "#.#######.###.#.#",
    "#...#...#...#.#.#",
    "#.#.#.#.###.#E#.#",
    "#.#...#G..#.#...#",
    "#.#####.#.#.###.#",
    "#..E....#...#G..#",
    "#.###.#####.#.#.#",
    "#G..#.......#..X#",
    "#################",
}
const MAX_GEMS = 8
const MAX_ENEMIES = 4

// The pause menu
const MENU_RESUME = 0
const MENU_MUSIC = 1
const MENU_SOUND = 2
const MENU_MOUSE = 3
const MENU_INVERT = 4
const MENU_FULLSCREEN = 5
const MENU_QUIT = 6
const MENU_ITEMS = 7

enum Mode { Title, Playing, Paused, Won, Lost }

// Sounds the front end plays for what happened, where it happened (for panning and distance).
enum Sfx { SfxStep, SfxGem, SfxHurt, SfxOpen, SfxWin, SfxLose, SfxAlert, SfxMove, SfxSelect, SfxFlash }
struct GameEvent { sfx: Sfx, at: vec2 }

struct Actions {
    forward: i64, back: i64, left: i64, right: i64
    confirm: i64, pause: i64, cancel: i64, up: i64, down: i64, flash: i64
}

struct Settings {
    music: i64           // 0 .. VOLUME_STEPS
    sound: i64
    mouse: i64           // 1 .. 10: mouse and stick speed
    invert: bool         // invert the vertical look
}

struct Enemy {
    pos: vec2
    prev: vec2           // one step ago (interpolated drawing)
    target: vec2         // the cell centre it walks to while patrolling
    dir: vec2            // the direction of its last patrol move (it does not turn back if it can help it)
    chasing: bool
    stun: f32            // seconds it stays still after a hit
}

struct Gem { pos: vec2, taken: bool }

struct Game {
    mode: Mode
    menu: i64                     // the selected item of the pause menu
    settings: Settings
    settings_changed: bool        // the front end saves the settings and clears it
    best: i64
    best_changed: bool            // the front end saves the best score and clears it
    score: i64
    pos: vec2                     // the player on the floor (x, z)
    prev_pos: vec2
    yaw: f32                      // 0: looking along -z; positive turns left
    pitch: f32
    hp: i64
    hurt: f32                     // seconds of protection left after a hit
    flash_wanted: bool            // latched command: raise the lantern at the next step
    flash: f32                    // seconds the lantern's flash still shines (drawing)
    flash_wait: f32               // seconds until the lantern can flash again
    enemies: [MAX_ENEMIES]Enemy
    n_enemies: i64
    gems: [MAX_GEMS]Gem
    n_gems: i64
    got: i64                      // gems taken
    exit: vec2
    start: vec2
    run_time: f32                 // seconds of this run
    end_time: f32                 // seconds since winning or losing
    walked: f32                   // distance since the last footstep
    rng: Rng
    keys: ActionMap
    act: Actions
    step_no: i64
    time: f64                     // seconds of simulation (animations)
    events: Vec[GameEvent]
    want_fullscreen: bool         // requests to the front end, which clears them
    want_quit: bool
    dpad: vec2                    // the gamepad's D-pad in the last frame (its pushes are edges)
}

fn game_new(seed: u64) -> Game {
    g: Game
    g.mode = Title
    g.settings = Settings{music: 6, sound: 8, mouse: 4}
    g.rng = rng(seed)
    g.keys = action_map()
    k := &g.keys
    g.act = Actions{forward: k.action("forward"), back: k.action("back"), left: k.action("left"), right: k.action("right"),
        confirm: k.action("confirm"), pause: k.action("pause"), cancel: k.action("cancel"), up: k.action("up"),
        down: k.action("down"), flash: k.action("flash")}
    a := g.act
    for key in [_]i64{KEY_W, KEY_UP} { k.bind_key(a.forward, key) }
    for key in [_]i64{KEY_S, KEY_DOWN} { k.bind_key(a.back, key) }
    for key in [_]i64{KEY_A, KEY_LEFT} { k.bind_key(a.left, key) }
    for key in [_]i64{KEY_D, KEY_RIGHT} { k.bind_key(a.right, key) }
    for key in [_]i64{KEY_UP, KEY_W} { k.bind_key(a.up, key) }
    for key in [_]i64{KEY_DOWN, KEY_S} { k.bind_key(a.down, key) }
    for key in [_]i64{KEY_F, KEY_E, KEY_LSHIFT} { k.bind_key(a.flash, key) }
    k.bind_mouse(a.flash, MOUSE_RIGHT)
    k.bind_pad(a.flash, PAD_X)
    k.bind_pad(a.flash, PAD_RB)
    k.bind_key(a.confirm, KEY_ENTER)
    k.bind_key(a.confirm, KEY_KP_ENTER)
    k.bind_key(a.confirm, KEY_SPACE)
    k.bind_mouse(a.confirm, MOUSE_LEFT)
    k.bind_pad(a.confirm, PAD_A)
    k.bind_key(a.pause, KEY_ESCAPE)
    k.bind_key(a.pause, KEY_P)
    k.bind_pad(a.pause, PAD_START)
    k.bind_key(a.cancel, KEY_ESCAPE)
    k.bind_pad(a.cancel, PAD_B)
    g.events.reserve(64)
    load_map(&g)
    g
}

// ---- the map -----------------------------------------------------------------------------

fn is_wall(c: i64, r: i64) -> bool {
    if c < 0 || r < 0 || c >= MAP_W || r >= MAP_H {
        return true
    }
    MAZE[r][c] == '#'
}

fn cell_center(c: i64, r: i64) -> vec2 {
    vec2((f32(c) + 0.5) * CELL, (f32(r) + 0.5) * CELL)
}

fn cell_of(p: vec2) -> (i64, i64) {
    (i64(floor(p.x / CELL)), i64(floor(p.y / CELL)))
}

fn wall_at(p: vec2) -> bool {
    c, r := cell_of(p)
    is_wall(c, r)
}

// Puts everything where the map says: the player, gems, wraiths and the exit.
priv fn load_map(g: *Game) {
    g.n_gems = 0
    g.n_enemies = 0
    for r in 0..MAP_H {
        for c in 0..MAP_W {
            p := cell_center(c, r)
            match MAZE[r][c] {
                'P' => g.start = p
                'X' => g.exit = p
                'G' => {
                    assert g.n_gems < MAX_GEMS, "too many gems in the map"
                    g.gems[g.n_gems] = Gem{pos: p}
                    g.n_gems += 1
                }
                'E' => {
                    assert g.n_enemies < MAX_ENEMIES, "too many wraiths in the map"
                    g.enemies[g.n_enemies] = Enemy{pos: p, prev: p, target: p}
                    g.n_enemies += 1
                }
                _ => {}
            }
        }
    }
}

// Moves a circle of radius `r` at `p` out of the walls around it.
fn collide(p: vec2, r: f32) -> vec2 {
    c, row := cell_of(p)
    for pass in 0..2 {
        for dr in -1..2 {
            for dc in -1..2 {
                if !is_wall(c + dc, row + dr) {
                    continue
                }
                lo := vec2(f32(c + dc) * CELL, f32(row + dr) * CELL)
                q := clamp(p, lo, lo + vec2(CELL))
                d := p - q
                dist := length(d)
                if dist < r && dist > 0.000001 {
                    p = q + d * (r / dist)
                }
            }
        }
    }
    p
}

// True if nothing but floor lies between a and b.
fn line_of_sight(a: vec2, b: vec2) -> bool {
    d := b - a
    n := i64(length(d) / 0.15) + 1
    for i in 1..n {
        if wall_at(a + d * (f32(i) / f32(n))) {
            return false
        }
    }
    true
}

// The centre of the next cell on a shortest path from `from` to `to` through the maze (`to`
// itself once both are in the same cell). Breadth-first search over the cells.
fn path_next(from: vec2, to: vec2) -> vec2 { path_next(from, to, nil) }

// The same, through no cell whose entry in `blocked` (MAP_W * MAP_H, row by row; nil: none) is
// true; `from` itself if there is no such way.
fn path_next(from: vec2, to: vec2, blocked: []bool) -> vec2 {
    fc, fr := cell_of(from)
    tc, tr := cell_of(to)
    if fc == tc && fr == tr {
        return to
    }
    // search from the goal, so that each cell knows its next step towards it
    next: [MAP_W * MAP_H]i64
    fill(next[..], -1)
    queue: [MAP_W * MAP_H]i64
    head := 0
    tail := 0
    goal := tr * MAP_W + tc
    next[goal] = goal
    queue[tail] = goal
    tail += 1
    while head < tail {
        cur := queue[head]
        head += 1
        cc := cur % MAP_W
        cr := cur / MAP_W
        for d in [_](i64, i64){(1, 0), (-1, 0), (0, 1), (0, -1)} {
            nc := cc + d.0
            nr := cr + d.1
            if is_wall(nc, nr) || next[nr * MAP_W + nc] >= 0 || (len(blocked) > 0 && blocked[nr * MAP_W + nc]) {
                continue
            }
            next[nr * MAP_W + nc] = cur
            queue[tail] = nr * MAP_W + nc
            tail += 1
        }
    }
    step := next[fr * MAP_W + fc]
    if step < 0 {
        return from                        // unreachable: stay
    }
    cell_center(step % MAP_W, step / MAP_W)
}

// ---- views of the state -------------------------------------------------------------------

// The direction the player looks along on the floor (x, z), and to its right.
fn forward_of(yaw: f32) -> vec2 { vec2(-sin(yaw), -cos(yaw)) }
fn right_of(yaw: f32) -> vec2 { vec2(cos(yaw), -sin(yaw)) }

fn exit_open(g: *Game) -> bool { g.got == g.n_gems }

fn mouse_scale(s: Settings) -> f32 { 0.0006 * f32(s.mouse) }

// ---- modes ---------------------------------------------------------------------------------

priv fn event(g: *Game, sfx: Sfx, at: vec2) {
    g.events.push(GameEvent{sfx, at})
}

priv fn start_game(g: *Game) {
    load_map(g)
    g.mode = Playing
    g.score = 0
    g.got = 0
    g.hp = MAX_HP
    g.hurt = 0.0
    g.flash = 0.0
    g.flash_wait = 0.0
    g.flash_wanted = false
    g.run_time = 0.0
    g.end_time = 0.0
    g.walked = 0.0
    g.pos = g.start
    g.prev_pos = g.start
    g.yaw = 3.14159265 / 2.0 * -1.0       // facing +x, along the first corridor
    g.pitch = 0.0
}

priv fn to_title(g: *Game) {
    g.mode = Title
    g.score = 0
}

priv fn finish(g: *Game, won: bool) {
    g.mode = if won { Won } else { Lost }
    g.end_time = 0.0
    g.score = g.got * 100
    if won {
        g.score += 500 + i64(fmax(240.0 - g.run_time, 0.0)) * 5 + g.hp * 100
    }
    if g.score > g.best {
        g.best = g.score
        g.best_changed = true
    }
    event(g, if won { SfxWin } else { SfxLose }, g.pos)
}

// The window lost the focus: a running game pauses.
fn lose_focus(g: *Game) {
    if g.mode == Playing {
        g.mode = Paused
        g.menu = MENU_RESUME
    }
}

// Menus, commands and mouse-look, once per displayed frame (edges are only seen here). The
// mouse turns the view here and not in update: its motion is a per-frame quantity, and turning
// once per frame keeps the view smooth whatever the number of steps in the frame.
fn handle_input(g: *Game, inp: *Input) {
    k := &g.keys
    a := g.act
    match g.mode {
        Title => {
            if k.action_pressed(inp, a.confirm) {
                start_game(g)
                event(g, SfxSelect, g.pos)
            } else if k.action_pressed(inp, a.cancel) {
                g.want_quit = true
            }
        }
        Playing => {
            if k.action_pressed(inp, a.pause) {
                g.mode = Paused
                g.menu = MENU_RESUME
                event(g, SfxSelect, g.pos)
            } else {
                d := inp.mouse_delta() * mouse_scale(g.settings)
                turn(g, d.x, d.y)
                if k.action_pressed(inp, a.flash) {
                    g.flash_wanted = true
                }
            }
        }
        Paused => menu_input(g, inp, dpad_pushed(g, &inp.pad))
        Won, Lost => {
            if g.end_time > 1.0 && (k.action_pressed(inp, a.confirm) || k.action_pressed(inp, a.cancel)) {
                to_title(g)
                event(g, SfxSelect, g.pos)
            }
        }
    }
    g.dpad = vec2(inp.pad.pad_axis(PAD_AXIS_DPAD_X), inp.pad.pad_axis(PAD_AXIS_DPAD_Y))
}

// Turns the view by `dx` (to the right) and `dy` (down) radians.
priv fn turn(g: *Game, dx: f32, dy: f32) {
    g.yaw = wrap_angle(g.yaw - dx)
    up := if g.settings.invert { dy } else { -dy }
    g.pitch = clamp(g.pitch + up, -1.3, 1.3)
}

// The D-pad directions pushed this frame (-1, 0, 1 per axis, y down): it is a pair of axes.
priv fn dpad_pushed(g: *Game, pad: *Gamepad) -> vec2 {
    now := vec2(pad.pad_axis(PAD_AXIS_DPAD_X), pad.pad_axis(PAD_AXIS_DPAD_Y))
    vec2(if now.x != g.dpad.x { now.x } else { 0.0 }, if now.y != g.dpad.y { now.y } else { 0.0 })
}

priv fn menu_input(g: *Game, inp: *Input, dpad: vec2) {
    k := &g.keys
    a := g.act
    if k.action_pressed(inp, a.pause) || k.action_pressed(inp, a.cancel) {
        g.mode = Playing
        event(g, SfxSelect, g.pos)
        return
    }
    up := k.action_pressed(inp, a.up) || dpad.y < 0.0
    down := k.action_pressed(inp, a.down) || dpad.y > 0.0
    left := k.action_pressed(inp, a.left) || dpad.x < 0.0
    right := k.action_pressed(inp, a.right) || dpad.x > 0.0
    if up || down {
        g.menu = (g.menu + if up { MENU_ITEMS - 1 } else { 1 }) % MENU_ITEMS
        event(g, SfxMove, g.pos)
    }
    if left || right {
        d := if right { 1 } else { -1 }
        s := &g.settings
        match g.menu {
            MENU_MUSIC => s.music = clamp(s.music + d, 0, VOLUME_STEPS)
            MENU_SOUND => s.sound = clamp(s.sound + d, 0, VOLUME_STEPS)
            MENU_MOUSE => s.mouse = clamp(s.mouse + d, 1, 10)
            MENU_INVERT => s.invert = !s.invert
            _ => {}
        }
        if g.menu >= MENU_MUSIC && g.menu <= MENU_INVERT {
            g.settings_changed = true
            event(g, if g.menu == MENU_SOUND { SfxGem } else { SfxMove }, g.pos)
        }
    }
    if k.action_pressed(inp, a.confirm) {
        match g.menu {
            MENU_RESUME => g.mode = Playing
            MENU_INVERT => {
                g.settings.invert = !g.settings.invert
                g.settings_changed = true
            }
            MENU_FULLSCREEN => g.want_fullscreen = true
            MENU_QUIT => to_title(g)
            _ => {}
        }
        event(g, SfxSelect, g.pos)
    }
}

// ---- the simulation ------------------------------------------------------------------------

// Where the player wants to go: x to the right, y forward, length 0..1 (keys or left stick).
fn move_input(g: *Game, inp: *Input) -> vec2 {
    a := g.act
    m := g.keys.action_vec2(inp, a.left, a.right, a.forward, a.back)
    stick := inp.pad.pad_stick(PAD_AXIS_LX, PAD_AXIS_LY, 0.2)
    if stick != vec2(0.0) {
        m = vec2(stick.x, -stick.y)
    }
    m
}

// One fixed simulation step.
fn update(g: *Game, inp: *Input, dt: f32) {
    g.step_no += 1
    g.time += f64(dt)
    if g.mode == Won || g.mode == Lost {
        g.end_time += dt
    }
    g.prev_pos = g.pos
    for i in 0..g.n_enemies {
        g.enemies[i].prev = g.enemies[i].pos
    }
    if g.mode != Playing {
        return
    }
    g.run_time += dt
    g.hurt = fmax(g.hurt - dt, 0.0)
    g.flash = fmax(g.flash - dt, 0.0)
    g.flash_wait = fmax(g.flash_wait - dt, 0.0)
    if g.flash_wanted {
        g.flash_wanted = false
        if g.flash_wait <= 0.0 {
            lantern(g)
        }
    }

    // looking with the right stick: a rate, so it goes with dt
    look := inp.pad.pad_stick(PAD_AXIS_RX, PAD_AXIS_RY, 0.15)
    if look != vec2(0.0) {
        speed := PAD_TURN * f32(g.settings.mouse) / 5.0 * dt
        turn(g, look.x * speed, look.y * speed)
    }

    // walking, sliding along the walls
    m := move_input(g, inp)
    wish := right_of(g.yaw) * m.x + forward_of(g.yaw) * m.y
    g.pos = collide(g.pos + wish * (PLAYER_SPEED * dt), PLAYER_R)
    g.walked += length(g.pos - g.prev_pos)
    if g.walked > 1.7 {
        g.walked = 0.0
        event(g, SfxStep, g.pos)
    }

    // gems, then the exit
    for i in 0..g.n_gems {
        gem := &g.gems[i]
        if !gem.taken && distance(gem.pos, g.pos) < PICKUP {
            gem.taken = true
            g.got += 1
            event(g, SfxGem, gem.pos)
            if exit_open(g) {
                event(g, SfxOpen, g.exit)
            }
        }
    }
    if exit_open(g) && distance(g.exit, g.pos) < PICKUP {
        finish(g, true)
        return
    }

    for i in 0..g.n_enemies {
        move_enemy(g, &g.enemies[i], dt)
        if g.mode != Playing {
            return
        }
    }
}

// The lantern flashes: wraiths it reaches (near and in sight) stand still for a while.
priv fn lantern(g: *Game) {
    g.flash = FLASH_TIME
    g.flash_wait = FLASH_WAIT
    event(g, SfxFlash, g.pos)
    for i in 0..g.n_enemies {
        e := &g.enemies[i]
        if distance(e.pos, g.pos) < FLASH_RANGE && line_of_sight(e.pos, g.pos) {
            e.stun = fmax(e.stun, FLASH_STUN)
            e.chasing = false
            c, r := cell_of(e.pos)
            e.target = cell_center(c, r)
        }
    }
}

priv fn move_enemy(g: *Game, e: *Enemy, dt: f32) {
    if e.stun > 0.0 {
        e.stun -= dt
        return
    }
    sees := distance(e.pos, g.pos) < SIGHT && line_of_sight(e.pos, g.pos)
    if sees && !e.chasing {
        event(g, SfxAlert, e.pos)
    }
    if !sees && e.chasing {
        c, r := cell_of(e.pos)
        e.target = cell_center(c, r)          // back on the grid, then patrol again
    }
    e.chasing = sees
    if sees {
        // along the maze, not straight at the player: a straight line catches on corners
        to := path_next(e.pos, g.pos)
        e.pos = collide(e.pos + normalize(to - e.pos) * (ENEMY_CHASE * dt), ENEMY_R)
    } else {
        to := e.target - e.pos
        dist := length(to)
        stride := ENEMY_PATROL * dt
        if dist <= stride {
            e.pos = e.target
            pick_target(g, e)
        } else {
            e.pos = e.pos + to * (stride / dist)
        }
    }
    if g.hurt <= 0.0 && distance(e.pos, g.pos) < TOUCH {
        g.hp -= 1
        g.hurt = 1.5
        e.stun = 1.2
        event(g, SfxHurt, e.pos)
        // the hit throws the player back a little
        g.pos = collide(g.pos + normalize(g.pos - e.pos) * 0.5, PLAYER_R)
        if g.hp <= 0 {
            finish(g, false)
        }
    }
}

// A random neighbouring floor cell for a patrolling wraith; it turns back only at a dead end.
priv fn pick_target(g: *Game, e: *Enemy) {
    c, r := cell_of(e.pos)
    options: [4]vec2
    n := 0
    back := vec2(0.0)
    for d in [_]vec2{vec2(1.0, 0.0), vec2(-1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, -1.0)} {
        if is_wall(c + i64(d.x), r + i64(d.y)) {
            continue
        }
        if d == -e.dir {
            back = d
            continue
        }
        options[n] = d
        n += 1
    }
    d := if n > 0 { options[g.rng.range(0, n)] } else { back }
    e.dir = d
    e.target = cell_center(c + i64(d.x), r + i64(d.y))
}

// A hash of everything that decides the future of the game: equal runs give equal values.
fn state_checksum(g: *Game) -> u64 {
    fn fnv(h: u64, x: u64) -> u64 { (h ^ x) * 1099511628211 }
    fn bits(x: f32) -> u64 { u64(cast[u32](x)) }
    h: u64 = 1469598103934665603
    mode: u64 = match g.mode { Title => 1; Playing => 2; Paused => 3; Won => 4; Lost => 5 }
    for x in [_]u64{mode, u64(g.menu), u64(g.settings.music), u64(g.settings.sound), u64(g.settings.mouse),
            u64(g.score), u64(g.best), u64(g.hp), u64(g.got), u64(g.step_no), bits(g.flash_wait), bits(g.pos.x), bits(g.pos.y),
            bits(g.yaw), bits(g.pitch), bits(g.hurt)} {
        h = fnv(h, x)
    }
    for i in 0..g.n_enemies {
        e := g.enemies[i]
        h = fnv(fnv(fnv(h, bits(e.pos.x)), bits(e.pos.y)), if e.chasing { 1 } else { 0 })
    }
    for i in 0..g.n_gems {
        h = fnv(h, if g.gems[i].taken { 1 } else { 0 })
    }
    r := g.rng                                 // a copy: the next number it would give
    h = fnv(h, r.next_u64())
    h
}

test "the map is closed and everything in it can be reached" {
    for r in 0..MAP_H {
        assert len(MAZE[r]) == MAP_W, fmt("row ", r, " has ", len(MAZE[r]), " cells")
        for c in 0..MAP_W {
            if r == 0 || c == 0 || r == MAP_H - 1 || c == MAP_W - 1 {
                assert is_wall(c, r), fmt("the border is open at ", c, " ", r)
            }
        }
    }
    g := game_new(1)
    for i in 0..g.n_gems {
        p := g.start
        for k in 0..MAP_W * MAP_H {
            p = path_next(p, g.gems[i].pos)
        }
        assert p == g.gems[i].pos, fmt("gem ", i, " cannot be reached")
    }
    p := g.start
    for k in 0..MAP_W * MAP_H {
        p = path_next(p, g.exit)
    }
    assert p == g.exit, "the exit cannot be reached"
}

test "walls stop the player" {
    p := collide(cell_center(1, 1) + vec2(-0.9, 0.0), PLAYER_R)
    assert approx_eq(p.x, CELL + PLAYER_R), fmt("x ", p.x)
    assert line_of_sight(cell_center(1, 1), cell_center(1, 3))
    assert !line_of_sight(cell_center(1, 1), cell_center(5, 1))
}
