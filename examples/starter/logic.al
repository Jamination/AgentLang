// The starter game itself, without any platform: the state, the rules, the fixed simulation
// step. Two front ends use it: examples/starter/game.al (software framebuffer, Linux and
// Windows) and examples/dx12_starter/game.al (Direct3D 12 and WASAPI sound, Windows).
//   - all state in one `Game` struct, no hidden globals
//   - entities are fat structs in a Pool, referred to by generational handles
//   - input goes through an ActionMap, the simulation runs at a fixed timestep with a seeded
//     generator, so a run is reproducible from its inputs
//   - what a front end may want to make audible is reported as events, not played here
use std.input

const WORLD_W = 320
const WORLD_H = 180
const HZ = 120.0

enum Kind { Player, Rock, Shot, Spark }

// One struct for every kind of entity: unused fields cost a few bytes, and every system is a
// plain loop over the pool with no indirection. Each field has a small type that holds its
// values (hp is at most 3, colours are 32 bits): 36 bytes per entity, 4 of them the tag.
struct Entity {
    kind: Kind
    pos: vec2
    vel: vec2
    radius: f32
    life: f32       // seconds left for shots and sparks; 0 = lives until destroyed
    hp: i32         // 3 for the player, 2 for a rock; removed at 0
    color: u32      // 0xAABBGGRR: the byte order of an RGBA framebuffer and of std.dx12_util sprites
}

struct Actions { left: i64, right: i64, up: i64, down: i64, fire: i64, quit: i64 }

// What happened during the steps since the front end last looked: it plays a sound for each
// and clears the list. `x` is where (for stereo panning).
enum Sfx { SfxShot, SfxHit, SfxBreak, SfxHurt, SfxOver }
struct GameEvent { sfx: Sfx, x: f32 }

struct Game {
    ents: Pool[Entity]
    player: Handle
    rng: Rng
    keys: ActionMap
    act: Actions
    score: i64
    cooldown: f32
    spawn: Timer
    step_no: i64
    over: bool
    events: Vec[GameEvent]
}

fn game_new(seed: u64) -> Game {
    g: Game
    g.ents = pool_new[Entity](512)
    g.rng = rng(seed)
    g.keys = action_map()
    g.act = Actions{
        left: g.keys.action("left"), right: g.keys.action("right"), up: g.keys.action("up"),
        down: g.keys.action("down"), fire: g.keys.action("fire"), quit: g.keys.action("quit"),
    }
    g.keys.bind_key(g.act.left, KEY_LEFT)
    g.keys.bind_key(g.act.left, KEY_A)
    g.keys.bind_key(g.act.right, KEY_RIGHT)
    g.keys.bind_key(g.act.right, KEY_D)
    g.keys.bind_key(g.act.up, KEY_UP)
    g.keys.bind_key(g.act.up, KEY_W)
    g.keys.bind_key(g.act.down, KEY_DOWN)
    g.keys.bind_key(g.act.down, KEY_S)
    g.keys.bind_key(g.act.fire, KEY_SPACE)
    g.keys.bind_pad(g.act.fire, PAD_A)
    g.keys.bind_pad(g.act.fire, PAD_RB)
    g.keys.bind_key(g.act.quit, KEY_ESCAPE)
    g.keys.bind_pad(g.act.quit, PAD_BACK)
    g.player = g.ents.insert(Entity{kind: Player, pos: vec2(160.0, 150.0), radius: 5.0, hp: 3, color: 0xFF40E0FF})
    g.spawn = timer(0.35, true)
    g.events.reserve(64)
    return g
}

fn spawn_rock(g: *Game) {
    x := g.rng.range(10.0, f32(WORLD_W) - 10.0)
    speed := g.rng.range(20.0, 70.0)
    g.ents.insert(Entity{kind: Rock, pos: vec2(x, -8.0), vel: vec2(g.rng.range(-15.0, 15.0), speed), radius: g.rng.range(4.0, 9.0), hp: 2, color: 0xFF8090A0})
}

fn burst(g: *Game, at: vec2, n: i64, color: u32) {
    for i in 0..n {
        g.ents.insert(Entity{kind: Spark, pos: at, vel: g.rng.unit_vec2() * g.rng.range(20.0, 90.0), radius: 1.0, life: g.rng.range(0.15, 0.5), color: color})
    }
}

// The direction the player steers: keys, else the gamepad's D-pad, else its left stick.
// x is +1 for right, y +1 for up.
fn steering(g: *Game, inp: *Input) -> vec2 {
    dir := g.keys.action_vec2(inp, g.act.left, g.act.right, g.act.up, g.act.down)
    pad := &inp.pad
    dpad := vec2(pad.pad_axis(PAD_AXIS_DPAD_X), -pad.pad_axis(PAD_AXIS_DPAD_Y))
    stick := pad.pad_stick(PAD_AXIS_LX, PAD_AXIS_LY, 0.2)
    if dir == vec2(0.0) && dpad != vec2(0.0) {
        dir = normalize(dpad)
    }
    if dir == vec2(0.0) && stick != vec2(0.0) {
        dir = vec2(stick.x, -stick.y)
    }
    dir
}

// One fixed simulation step. Everything that changes the game happens here.
fn update(g: *Game, inp: *Input, dt: f32) {
    g.step_no += 1
    if g.over {
        return
    }
    p := g.ents.get(g.player)
    if p != nil {
        dir := steering(g, inp)
        // dir.y is +1 for up; screen y grows downwards
        p.vel = vec2(dir.x, -dir.y) * 110.0
        g.cooldown -= dt
        if g.keys.action_down(inp, g.act.fire) && g.cooldown <= 0.0 {
            g.cooldown = 0.12
            g.ents.insert(Entity{kind: Shot, pos: p.pos + vec2(0.0, -6.0), vel: vec2(0.0, -220.0), radius: 1.5, life: 1.2, color: 0xFFFFFFFF})
            g.events.push(GameEvent{SfxShot, p.pos.x})
        }
    }
    for k in 0..g.spawn.tick(f64(dt)) {
        spawn_rock(g)
    }
    // movement and lifetime
    lo := vec2(0.0, 0.0)
    hi := vec2(f32(WORLD_W), f32(WORLD_H))
    for i in 0..g.ents.len {
        if !g.ents.is_live(i) {
            continue
        }
        e := &g.ents.items[i]
        e.pos = e.pos + e.vel * dt
        match e.kind {
            Player => e.pos = clamp(e.pos, lo + e.radius, hi - e.radius)
            Rock => {
                if e.pos.y > f32(WORLD_H) + 10.0 {
                    g.ents.remove(g.ents.handle_at(i))
                }
            }
            Shot, Spark => {
                e.life -= dt
                if e.life <= 0.0 || e.pos.y < -4.0 {
                    g.ents.remove(g.ents.handle_at(i))
                }
            }
        }
    }
    // collisions: shots and the player against rocks
    for i in 0..g.ents.len {
        if !g.ents.is_live(i) || g.ents.items[i].kind != Rock {
            continue
        }
        rock := &g.ents.items[i]
        for j in 0..g.ents.len {
            if j == i || !g.ents.is_live(j) {
                continue
            }
            o := &g.ents.items[j]
            if (o.kind != Shot && o.kind != Player) || distance(o.pos, rock.pos) > o.radius + rock.radius {
                continue
            }
            rock.hp -= 1
            if o.kind == Shot {
                g.ents.remove(g.ents.handle_at(j))
                g.events.push(GameEvent{SfxHit, rock.pos.x})
            } else {
                o.hp -= 1
                rock.hp = 0
                g.events.push(GameEvent{SfxHurt, o.pos.x})
                if o.hp <= 0 {
                    burst(g, o.pos, 40, 0xFF40E0FF)
                    g.ents.remove(g.ents.handle_at(j))
                    g.over = true
                    g.events.push(GameEvent{SfxOver, o.pos.x})
                }
            }
            if rock.hp <= 0 {
                g.score += 10
                burst(g, rock.pos, 12, 0xFF60A0FF)
                g.events.push(GameEvent{SfxBreak, rock.pos.x})
                g.ents.remove(g.ents.handle_at(i))
                break
            }
        }
    }
}

// The player's hit points (0 once destroyed).
fn player_hp(g: *Game) -> i64 {
    p := g.ents.get(g.player)
    if p == nil { 0 } else { i64(p.hp) }
}

// A hash of everything that decides the future of the game: equal runs give equal values.
fn state_checksum(g: *Game) -> u64 {
    fn fnv(h: u64, x: u64) -> u64 { (h ^ x) * 1099511628211 }
    fn bits(v: vec2) -> u64 { cast[u64](f64(v.x)) ^ rotl(cast[u64](f64(v.y)), 32) }
    h: u64 = 1469598103934665603
    h = fnv(h, u64(g.step_no))
    h = fnv(h, u64(g.score))
    h = fnv(h, if g.over { 1 } else { 0 })
    r := g.rng                                 // a copy: the next number it would give
    h = fnv(h, r.next_u64())
    for i in 0..g.ents.len {
        if !g.ents.is_live(i) {
            continue
        }
        e := &g.ents.items[i]
        kind: u64 = match e.kind { Player => 1; Rock => 2; Shot => 3; Spark => 4 }
        h = fnv(h, u64(i) << 8 | kind)
        h = fnv(h, bits(e.pos))
        h = fnv(h, bits(e.vel))
        h = fnv(h, cast[u64](f64(e.life)) ^ u64(e.hp) ^ (u64(e.color) << 16))
    }
    h
}
