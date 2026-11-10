// A complete small game showing the structure recommended in docs/GAMES.md:
//   - all state in one `Game` struct, no hidden globals
//   - entities are fat structs in a Pool, referred to by generational handles
//   - input goes through an ActionMap, the simulation runs at a fixed timestep with a seeded
//     generator (so a run is reproducible), rendering reads the state and never changes it
//   - the platform layer (window, sound device) is a thin shell around `update` / `render`
//
//   alc run examples/starter/game.al                headless: scripted input, prints a checksum
//   alc run examples/starter/game.al -- --window    play it (arrows / WASD move, space shoots)
use std.input
use std.window

const FB_W = 320
const FB_H = 180
const HZ = 120.0

enum Kind { Player, Rock, Shot, Spark }

// One struct for every kind of entity: unused fields cost a few bytes, and every system is a
// plain loop over the pool with no indirection.
struct Entity {
    kind Kind
    pos vec2
    vel vec2
    radius f32
    life f32        // seconds left for shots and sparks; 0 = lives until destroyed
    hp i64
    color u32       // 0xAABBGGRR, the byte order of the RGBA framebuffer
}

struct Actions { left i64, right i64, up i64, down i64, fire i64, quit i64 }

struct Game {
    ents Pool[Entity]
    player Handle
    rng Rng
    keys ActionMap
    act Actions
    score i64
    cooldown f32
    spawn Timer
    step_no i64
    over bool
}

fn game_new(seed u64) Game {
    var g Game
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
    g.keys.bind_key(g.act.quit, KEY_ESCAPE)
    g.player = g.ents.insert(Entity{kind: Player, pos: vec2(160.0, 150.0), radius: 5.0, hp: 3, color: 0xFF40E0FF})
    g.spawn = timer(0.35, true)
    return g
}

fn spawn_rock(g *Game) {
    x := g.rng.range(10.0, f32(FB_W) - 10.0)
    speed := g.rng.range(20.0, 70.0)
    g.ents.insert(Entity{kind: Rock, pos: vec2(x, -8.0), vel: vec2(g.rng.range(-15.0, 15.0), speed), radius: g.rng.range(4.0, 9.0), hp: 2, color: 0xFF8090A0})
}

fn burst(g *Game, at vec2, n i64, color u32) {
    for i in 0..n {
        g.ents.insert(Entity{kind: Spark, pos: at, vel: g.rng.unit_vec2() * g.rng.range(20.0, 90.0), radius: 1.0, life: g.rng.range(0.15, 0.5), color: color})
    }
}

// One fixed simulation step. Everything that changes the game happens here.
fn update(g *Game, inp *Input, dt f32) {
    g.step_no += 1
    if g.over {
        return
    }
    p := g.ents.get(g.player)
    if p != nil {
        dir := g.keys.action_vec2(inp, g.act.left, g.act.right, g.act.up, g.act.down)
        // screen y grows downwards
        p.vel = vec2(dir.x, -dir.y) * 110.0
        g.cooldown -= dt
        if g.keys.action_down(inp, g.act.fire) && g.cooldown <= 0.0 {
            g.cooldown = 0.12
            g.ents.insert(Entity{kind: Shot, pos: p.pos + vec2(0.0, -6.0), vel: vec2(0.0, -220.0), radius: 1.5, life: 1.2, color: 0xFFFFFFFF})
        }
    }
    for k in 0..g.spawn.tick(f64(dt)) {
        spawn_rock(g)
    }
    // movement and lifetime
    lo := vec2(0.0, 0.0)
    hi := vec2(f32(FB_W), f32(FB_H))
    for i in 0..g.ents.len {
        if !g.ents.is_live(i) {
            continue
        }
        e := &g.ents.items[i]
        e.pos = e.pos + e.vel * dt
        match e.kind {
            Player => e.pos = clamp(e.pos, lo + e.radius, hi - e.radius)
            Rock => {
                if e.pos.y > f32(FB_H) + 10.0 {
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
            } else {
                o.hp -= 1
                rock.hp = 0
                if o.hp <= 0 {
                    burst(g, o.pos, 40, 0xFF40E0FF)
                    g.ents.remove(g.ents.handle_at(j))
                    g.over = true
                }
            }
            if rock.hp <= 0 {
                g.score += 10
                burst(g, rock.pos, 12, 0xFF60A0FF)
                g.ents.remove(g.ents.handle_at(i))
                break
            }
        }
    }
}

fn disc(fb []u32, at vec2, r f32, color u32) {
    x0 := max(i64(floor(at.x - r)), 0)
    x1 := min(i64(ceil(at.x + r)), FB_W - 1)
    y0 := max(i64(floor(at.y - r)), 0)
    y1 := min(i64(ceil(at.y + r)), FB_H - 1)
    for y in y0..=y1 {
        for x in x0..=x1 {
            if length_sq(vec2(f32(x), f32(y)) - at) <= r * r {
                fb[y * FB_W + x] = color
            }
        }
    }
}

// Drawing only reads the game. `alpha` is how far the display is between two simulation steps.
fn render(g *Game, fb []u32, alpha f32) {
    fill(fb, 0xFF201810)
    for i in 0..g.ents.len {
        if g.ents.is_live(i) {
            e := &g.ents.items[i]
            disc(fb, e.pos + e.vel * (alpha / f32(HZ)), e.radius, e.color)
        }
    }
    for i in 0..min(g.score / 10, FB_W / 4) {
        disc(fb, vec2(f32(i * 4 + 3), 3.0), 1.0, 0xFF60FF60)
    }
}

fn checksum(fb []u32) u64 {
    var h u64 = 1469598103934665603
    for p in fb {
        h = (h ^ u64(p)) * 1099511628211
    }
    return h
}

// Headless run: the same update/render driven by scripted input instead of a window.
fn run_headless() {
    g := game_new(2024)
    var inp Input
    fb := alloc[u32](FB_W * FB_H)
    for step in 0..2400 {
        inp.begin_frame()
        // a little script: weave left and right, hold fire
        if step == 0 {
            inp.feed(Event{kind: EventKeyDown, key: KEY_SPACE})
        }
        if step % 240 == 0 {
            inp.feed(Event{kind: EventKeyUp, key: KEY_RIGHT})
            inp.feed(Event{kind: EventKeyDown, key: KEY_LEFT})
        }
        if step % 240 == 120 {
            inp.feed(Event{kind: EventKeyUp, key: KEY_LEFT})
            inp.feed(Event{kind: EventKeyDown, key: KEY_RIGHT})
        }
        update(&g, &inp, 1.0 / f32(HZ))
    }
    render(&g, fb, 0.0)
    print("steps", g.step_no, "score", g.score, "entities", g.ents.used, "over", g.over)
    print("frame", hex(checksum(fb)))
}

fn run_window() {
    w, ok := window_open(WindowDesc{title: "AL starter", width: FB_W * 3, height: FB_H * 3, resizable: true})
    if !ok {
        print("no display: run without --window")
        return
    }
    g := game_new(u64(time_ns()))
    fb := alloc[u32](FB_W * FB_H)
    clock := frame_clock()
    steps := fixed_step(HZ)
    while !w.should_close() {
        w.poll()
        if g.keys.action_pressed(&w.input, g.act.quit) {
            w.closing = true
        }
        for k in 0..steps.advance(clock.tick()) {
            update(&g, &w.input, f32(steps.step))
        }
        render(&g, fb, steps.alpha())
        w.present(as_bytes(fb), FB_W, FB_H)
        sleep_ms(4)
    }
    w.close()
    print("score", g.score)
}

fn main() {
    for a in args() {
        if a == "--window" {
            run_window()
            return
        }
    }
    run_headless()
}
