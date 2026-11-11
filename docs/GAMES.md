# Structuring a game in AL

This is the shape the standard library is built to support. The complete example is
[examples/starter/game.al](../examples/starter/game.al) (about 250 lines: a playable shooter
that also runs headless and prints a checksum, which is how it is tested).

## The frame

```
input ──> update (fixed step, repeated 0..n times) ──> render (reads state only) ──> present
```

```
clock := frame_clock()
steps := fixed_step(120.0)                     // simulation rate, independent of display rate
while !w.should_close() {
    w.poll()                                   // the only place the outside world enters
    for k in 0..steps.advance(clock.tick()) {
        update(&g, &w.input, f32(steps.step))  // every change to the game happens here
    }
    render(&g, fb, steps.alpha())              // alpha: how far between two steps we are
    w.present(as_bytes(fb), FB_W, FB_H)
}
```

- **Fixed timestep.** `update` always gets the same `dt`; physics and timers behave the same
  at 30 and 240 frames per second, and a run can be replayed from its inputs.
- **Rendering does not mutate.** `render` takes the game and draws it. Interpolate with
  `alpha` instead of simulating in the renderer.
- **One state struct.** Everything the game is lives in a `Game` value passed by pointer:
  no hidden globals, so saving, resetting and running two games side by side are trivial.
- **Seeded randomness.** The game owns an `Rng`; nothing uses a global generator.
- **Input through actions.** Game code asks `keys.action_down(inp, act.fire)`, never
  `key_down(KEY_SPACE)`; bindings are data.
- **Headless first.** `update` and `render` need no window. Drive them with scripted `Event`s
  fed to an `Input` and compare a checksum: that is a regression test for the whole game.

## Entities: fat structs and tagged unions

AL has no entity-component framework, on purpose. Two plain representations cover games well
and keep every system a simple loop:

**Fat struct**: one struct with every field any kind of entity needs, plus a `kind`.

```
enum Kind { Player, Rock, Shot }
struct Entity { kind: Kind, pos: vec2, vel: vec2, radius: f32, life: f32, hp: i64, color: u32 }

for i in 0..g.ents.len {
    if !g.ents.is_live(i) { continue }
    e := &g.ents.items[i]
    e.pos = e.pos + e.vel * dt                 // shared behaviour: no dispatch at all
    match e.kind {                             // kind-specific behaviour
        Shot => { e.life -= dt }
        _ => {}
    }
}
```

**Tagged union**: an `enum` with data when the kinds share little. `match` must cover every
variant, so adding a kind makes the compiler point at every place that has to handle it.

```
enum Item { Weapon(i64, f32), Potion(i64), Key(str) }

fn describe(it: Item) -> str {
    match it {
        Weapon(damage, range) => fmt("weapon ", damage)
        Potion(heal) => fmt("potion +", heal)
        Key(door) => fmt("key to ", door)
    }
}
```

Mix them freely: a fat `Entity` whose `brain` field is a tagged union of AI states.

Store entities in a `Pool[Entity]` and keep `Handle`s, never pointers or indices, across
frames: a handle to a removed entity simply stops resolving (`get` returns nil), even when its
slot has been reused.

```
g.target = g.ents.insert(Entity{kind: Rock, pos: p})
...
t := g.ents.get(g.target)
if t != nil { aim_at(t.pos) }
```

## Memory

There is no `free` and no garbage collector, so there is nothing to leak or double-free:
memory is an arena that is released in bulk at the points where a game naturally forgets
things.

| Lifetime | How |
|----------|-----|
| the whole program (window, assets, pools) | allocate at start-up, never release |
| a level | `m := mark()` before loading, `release(m)` when leaving; or a `Region` entered while loading and `reset` when leaving |
| a frame (scratch strings, lists built for one frame) | `frame_begin()` ... `frame_end()` around the frame |
| objects that come and go (entities, particles, sounds) | a `Pool[T]`: slots are reused, the pool itself never grows past its capacity unless asked to |

Do not allocate per entity or per frame outside these patterns; `mem_used()` at the end of
each frame should be constant once a level is running.

## Systems are functions

A system is a function over the state, called from `update` in a fixed order:

```
fn update(g: *Game, inp: *Input, dt: f32) {
    control_player(g, inp, dt)
    spawn(g, dt)
    move_all(g, dt)
    collide(g)
    reap(g)
}
```

Overloading keeps names short and uniform across types (`update(p: *Player)`,
`update(e: *Emitter)`, `length(v)`, `draw(s: Sprite)`), and `x.f()` is only another spelling of
`f(x)`, so there is no method/free-function split to design around.

## Data layout

- `vec2`/`vec3`/`vec4`/`quat`/`mat4` are values in SSE registers; arithmetic on them compiles
  to packed instructions. Write `p = p + v * dt`, not per-component code.
- Structs have C layout, vectors are plain `f32`s in memory: a `[]Vertex` is ready to upload
  (`as_bytes(vertices)`), and a struct matches the same struct in a shader or a C header.
- Hot loops over one or two fields of many entities are the case for splitting those fields
  into their own arrays (`pos: []vec3`, `vel: []vec3`); start with the fat struct and split only
  what a profile points at.

## Platform shell

- `std.window` + `std.input`: window, events, software `present` for 2D or CPU rendering.
- `std.vk`: Vulkan through `x11_display(w)` / `x11_window(w)` for a surface.
- `std.audio`: mix in the game loop with `audio_pump(dev, &mixer)` once per frame; the mixer is
  pure code and can be tested without a device.
- `std.image`, `std.asset`: loading; keep file access in a load phase, not in `update`.

A program that never opens a window or a device (a test run, a server, a tool) uses none of
the system libraries and is a static executable.
