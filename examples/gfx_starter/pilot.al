// The player of the recorded gameplay video (game.al --record): a small autopilot that reads
// the game and presses the same keys a person would. It holds fire, lines up under the rock
// that will come down to it first, slides out of the way of rocks about to hit it, and drifts
// up and down a little. Once, in the window `ram_from`..`ram_to` seconds, it flies into a rock
// on purpose, so that the video shows a hit. It only feeds key events to an Input, as
// starter_script of ../dx12_starter/headless.al does: the game sees nothing else.
use std.input
use "../starter/logic.al"

struct Pilot {
    left: bool                   // the keys held now
    right: bool
    up: bool
    down: bool
    fire: bool
    hit: bool                    // the planned hit has happened
    ram_from: f32
    ram_to: f32
}

priv fn hold(inp: *Input, now: *bool, want: bool, k: i64) {
    if *now != want {
        inp.feed(Event{kind: if want { EventKeyDown } else { EventKeyUp }, key: k})
        *now = want
    }
}

// The keys of frame f (60 per second).
fn pilot_input(pl: *Pilot, inp: *Input, game: *Game, f: i64) {
    p := game.ents.get(game.player)
    if p == nil {
        hold(inp, &pl.left, false, KEY_LEFT)
        hold(inp, &pl.right, false, KEY_RIGHT)
        hold(inp, &pl.up, false, KEY_UP)
        hold(inp, &pl.down, false, KEY_DOWN)
        hold(inp, &pl.fire, false, KEY_SPACE)
        return
    }
    if p.hp < 3 {
        pl.hit = true
    }
    t := f32(f) / 60.0
    ram := !pl.hit && t >= pl.ram_from && t < pl.ram_to
    target := p.pos.x
    soonest: f32 = 1e9
    push: f32 = 0.0                                       // away from what is about to hit
    ram_x := p.pos.x
    ram_t: f32 = 1e9
    for i in 0..game.ents.len {
        if !game.ents.is_live(i) || game.ents.items[i].kind != Rock {
            continue
        }
        e := &game.ents.items[i]
        dy := p.pos.y - e.pos.y
        if dy < -4.0 {
            continue                                      // already past
        }
        reach := fmax(dy, 0.0) / e.vel.y                 // seconds until it is level with the ship
        across := e.pos.x + e.vel.x * reach
        if reach < 0.85 && fabs(across - p.pos.x) < e.radius + 10.0 {
            side := if across > p.pos.x { -1.0 } else { 1.0 }
            if p.pos.x < 24.0 { side = 1.0 }
            if p.pos.x > f32(WORLD_W) - 24.0 { side = -1.0 }
            push += side * (1.0 - reach / 0.85 + 0.2)
        }
        if reach < ram_t && dy > 20.0 {
            ram_t = reach
            ram_x = across
        }
        // the shot needs dy / (220 + speed) seconds to get there: aim where the rock will be
        if reach > 0.45 && reach < soonest && e.pos.y > 0.0 {
            soonest = reach
            target = e.pos.x + e.vel.x * (dy / (220.0 + e.vel.y))
        }
    }
    dx := target - p.pos.x
    if ram {
        dx = ram_x - p.pos.x
    } else if push != 0.0 {
        dx = push * 40.0
    }
    hold(inp, &pl.left, dx < -1.5, KEY_LEFT)
    hold(inp, &pl.right, dx > 1.5, KEY_RIGHT)
    want_y := 146.0 - 18.0 * sin(t * 0.55) * sin(t * 0.23)
    dy := want_y - p.pos.y
    hold(inp, &pl.up, dy < -3.0, KEY_UP)
    hold(inp, &pl.down, dy > 3.0, KEY_DOWN)
    hold(inp, &pl.fire, true, KEY_SPACE)
}
