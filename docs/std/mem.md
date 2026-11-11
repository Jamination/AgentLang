# mem: memory building blocks for games

Always available (no `use`). Source: `std/mem.al`.

AL has no `free` and no garbage collector. Dynamic memory comes from an arena: `alloc`/`new`
bump a pointer, `m := mark()` remembers the position and `release(m)` gives back everything
allocated since, in one step. A program starts in the *main arena*; a `Region` (language
reference, "Memory") is a further arena that `enter`/`leave` put in use. Everything in this
module works on the **arena in use**: the main arena, or the innermost entered region. This
module adds the structure a game needs on top:

| Piece | For |
|-------|-----|
| `frame_begin()` / `frame_end()` | scratch memory that lives for one frame (or one nested scope) |
| `Arena` | a fixed block with its own cursor, for data whose lifetime does not nest with the rest |
| `Pool[T]` + `Handle` | objects that are created and destroyed individually (entities, sounds, particles) |
| `Ring[T]` | fixed-size queues: events, input history, "the last N" |
| `SparseSet` | sets of small integers with dense iteration |
| `kb`, `mb`, `mem_used`, `as_bytes`, `from_bytes`, `zero` | sizes, statistics, byte views |

## Lifetimes: how a game allocates

Give every allocation one of three lifetimes and memory management is done:

1. **Program**: window, pools, tables. Allocated during start-up, never released.
2. **Level** (or menu, match, scene): `level := mark()` before loading, `release(level)` when
   leaving. Everything the level allocated is gone at once, with no bookkeeping and no leaks.
3. **Frame**: `frame_begin()` at the top of the frame, `frame_end()` at the bottom. Anything
   allocated in between (`fmt` strings, temporary lists, sort buffers, `Vec`s) is scratch.

These nest like a stack, and that is the one rule: **memory must be released in the reverse
order of the marks**. Data that has to outlive the scope it is created in (an entity spawned
during a frame, a sound started in a level that keeps playing in the next) does not go into
the arena directly but into storage allocated *before* the mark: a `Pool`, a `Ring`, an
`Arena`, a fixed array in a state struct. Those never allocate when used (unless created
growable), so they are unaffected by `release`.

`release` does not run anything and does not clear memory; slices and pointers into released
memory are simply invalid afterwards (using them is a bug the compiler cannot see). Memory is
zeroed when it is handed out again.

## Region, Arena, mark / release: which one

| Tool | What it is | Who allocates from it | Gives memory back by |
|------|------------|-----------------------|----------------------|
| `mark()` / `release(m)` | a position in the arena in use | everything | `release(m)`: all that was allocated after the mark (stack order) |
| `frame_begin()` / `frame_end()` | the same, with the marks kept on an internal stack | everything | `frame_end()` |
| `Region` (prelude) | an arena of its own with its own address space (grows on demand, up to 16 GiB) | everything between `enter(&r)` and `leave()`: `alloc`, `new`, `Vec`, `Map`, `fmt`, literals, `clone` | `reset(&r)` (keeps the memory for reuse), `region_free(&r)` (returns it to the system) |
| `Arena` (this module) | a block of fixed size carved from the arena in use, or over your own buffer | only explicit calls: `a.alloc[T](n)`, `a.new[T]()` | `a.release(m)`, `a.reset()` |

- A mark belongs to the arena it was taken in. `release(m)` with a mark of another arena does
  nothing; a mark taken before the first allocation of an arena releases everything in it.
- Regions do not have to nest with marks or with each other: a region can be reset at any
  time, whatever happened in other arenas. That is what makes them fit for work whose
  temporary data does not form a stack with the rest ("compile one function, keep the
  result"): do the work in the region, `clone` the result into the arena that should own it,
  `reset` the region.
- An `Arena` is passive: it never changes where `Vec`, `Map` or `fmt` allocate. It is carved
  from the arena that is in use when `arena_new` runs and dies with that memory (also when
  that arena is a region that is reset).
- `frame_begin()` / `frame_end()` may be used inside a region (they then release region
  memory), and a frame scope may contain balanced `enter` / `leave` pairs. A scope must be
  closed in the arena it was opened in: `frame_end()` stops the program with `frame_end: the
  arena in use is not the one of the matching frame_begin` otherwise.

```
level: Region                                  // lives until the level is unloaded

enter(&level)
load_level(&game)                              // everything it allocates is level memory
leave()
loop {
    frame_begin()                              // frame scratch in the main arena
    update(&game)
    frame_end()
}
reset(&level)                                  // unload: independent of all marks
```

## Sizes, statistics, byte views

| Declaration | Description |
|-------------|-------------|
| `kb(n: i64) -> i64`, `mb(n: i64) -> i64` | `n` kibibytes / mebibytes in bytes: `arena_new(mb(4))`. |
| `mem_used() -> i64` | Bytes in use in the arena that allocations currently come from (the main arena, or the innermost entered `Region`; `used(&r)` asks a particular region). Print the difference across a frame or a level to find leaks: it must return to the same value. |
| `as_bytes[T](s: []T) -> []u8` | The memory of a slice as bytes (a view, nothing is copied): for writing typed data to files, hashing, uploading to a GPU. |
| `from_bytes[T](b: []u8) -> []T` | The reverse view: `from_bytes[Vertex](data)`. Trailing bytes that do not fill a `T` are dropped. `b` must be suitably aligned for `T` (memory from `alloc` and `read_bytes` is). |
| `zero[T](p: *T)` | Sets the value `p` points to to all zero bytes. |
| `zero[T](s: []T)` | Sets every element of `s` to all zero bytes. |

## Frame scopes

| Declaration | Description |
|-------------|-------------|
| `frame_begin()` | Opens a scratch scope: remembers the position of the arena in use. |
| `frame_end()` | Closes the innermost scope and releases everything allocated from that arena since the matching `frame_begin()`. |

Scopes nest up to 32 deep, so a function that needs a lot of temporary memory can open its own
scope inside the frame. `frame_end` without `frame_begin` is a programming error (panic).
These are exactly `mark()`/`release()` with the marks kept on a small internal stack; use
`mark()`/`release()` directly where a local variable is more convenient.

```
loop {
    frame_begin()
    update(&game)                              // may allocate scratch freely
    draw_text(fmt("score ", game.score))       // fmt allocates: gone at frame_end
    frame_end()
}
```

## Arena

An `Arena` is a block of fixed size with its own bump cursor: a private arena inside (or
beside) the arena it was carved from. Use it when a lifetime does not nest and the size is
known: an audio thread's buffers, a streaming chunk that is replaced while the level stays, a
string table that is rebuilt on its own schedule. Resetting it does not disturb anything
else, and marks of the surrounding arena do not affect what is allocated *inside* it. (For
temporary work of unknown size, and for everything that allocates implicitly, use a
`Region`.)

| Declaration | Description |
|-------------|-------------|
| `struct Arena { base: i64, cur: i64, end: i64, dirty: i64 }` | Addresses of the block and the cursor (`dirty` is internal: how far old data reaches). |
| `arena_new(bytes: i64) -> Arena` | An arena of `bytes` bytes carved from the arena in use. It lives as long as that memory: releasing a mark taken *before* `arena_new` (or resetting the region it was carved from) frees the whole arena. |
| `arena_of(buf: []u8) -> Arena` | An arena over storage you provide, for example a global `buf: [65536]u8`: memory outside every arena. |
| `alloc[T](a: *Arena, n: i64) -> []T` | `n` zeroed elements from the arena: `alloc[f32](&a, 256)` or `a.alloc[f32](256)`. |
| `new[T](a: *Arena) -> *T` | One zeroed `T` from the arena. |
| `mark(a: *Arena) -> i64`, `release(a: *Arena, m: i64)` | Like `mark()`/`release(m)`, for this arena. |
| `reset(a: *Arena)` | Gives back everything allocated from the arena. |
| `used(a: *Arena) -> i64`, `remaining(a: *Arena) -> i64` | Bytes handed out / still available. |

Allocations are zero-initialized and 16-byte aligned (sizes are rounded up to 16), exactly
like `alloc` and `new`. Asking for more than `remaining` is a programming error and stops the
program with `panic: arena exhausted`: size the arena for its worst case, and check
`remaining` first where the amount is not known.

The standard containers (`Vec`, `Map`, `fmt`, `concat`) never allocate from an `Arena`: they
use the arena in use (the main arena or the entered `Region`); an `Arena` serves your own
`alloc`/`new` calls. `reset(a: *Arena)` and `used(a: *Arena)` have the same names as the
`Region` functions `reset(r: *Region)` and `used(r: *Region)`; the argument type selects.

## Pool and Handle

A `Pool[T]` holds up to a fixed number of objects in one array. Slots are reused through a
free list, objects never move, and each object is named by a `Handle`.

| Declaration | Description |
|-------------|-------------|
| `struct Handle { idx: u32, gen: u32 }` | Slot index plus generation. The zero `Handle{}` is never valid and means "none"; handles compare with `==`. |
| `struct Pool[T] { items: []T, gens: []u32, free: []u32, len: i64, used: i64, nfree: i64, growable: bool }` | `items`: the slots. `len`: number of live objects. `used`: number of slots that were ever occupied (the live objects are among `items[0..used]`). The rest is internal. |
| `pool_new[T](cap: i64) -> Pool[T]` | A pool with room for exactly `cap` objects. Allocates once; no later operation allocates. |
| `pool_growable[T](cap: i64) -> Pool[T]` | A pool that doubles its storage when full. Growing allocates and moves the objects (handles stay valid, pointers do not), and the old storage stays in the arena. |
| `insert[T](p: *Pool[T], v: T) -> Handle` | Stores `v` and returns its handle; the zero `Handle` if a fixed-capacity pool is full. |
| `get[T](p: *Pool[T], h: Handle) -> *T` | The object, or `nil` if `h` is stale (the object was removed) or zero. |
| `is_valid[T](p: *Pool[T], h: Handle) -> bool` | True if `h` names an object that is still in the pool. |
| `remove[T](p: *Pool[T], h: Handle) -> bool` | Removes the object; `false` if the handle was stale. |
| `is_live[T](p: *Pool[T], i: i64) -> bool` | True if slot `i` (`0 <= i < p.used`) holds an object. |
| `handle_at[T](p: *Pool[T], i: i64) -> Handle` | The handle of the object in slot `i`. |
| `clear[T](p: *Pool[T])` | Removes every object; all handles become stale, the capacity is kept. |

**Why handles instead of pointers.** A pointer to a removed object silently points at whatever
is stored there next. A handle carries the slot's generation at the time of `insert`; the
generation changes on every `remove`, so `get` with an old handle returns `nil` instead of the
slot's new occupant. Store handles (in other objects, in queues, across frames); use the `*T`
from `get` only within the current function. Handles are 8 plain bytes: they can be saved to
a file and compared.

Iteration visits the slots in index order, which is deterministic:

```
for i in 0..pool.used {
    if pool.is_live(i) {
        e := &pool.items[i]
        ...
    }
}
```

Removing and inserting while iterating is safe, because slots never move: a removed slot is
skipped from then on. The loop bound is read once, so an object inserted during the loop is
visited in the same pass only if it reuses a freed slot ahead of the loop position; one that
is appended at the end is first seen by the next loop.

## Entities: fat structs in a pool

The recommended way to model game entities with this library is the plainest one: **one
struct with the fields any entity may need, a `kind` field to tell them apart, all entities in
one `Pool`, and systems written as ordinary loops**. A few dozen unused bytes per entity cost
nothing at the scale of a game (100 000 entities of 64 bytes are 6.4 MB and are swept in a
fraction of a millisecond), and in exchange everything is visible in one place: a debugger
shows a whole entity, the whole world can be dumped with `as_bytes(pool.items)`, and a new
behaviour is a new field plus a new loop.

```
enum Kind { Player, Enemy, Bullet, Pickup }

// one struct for every kind of entity; fields a kind does not need stay zero
struct Entity {
    kind: Kind
    pos: vec2
    vel: vec2
    hp: i64
    target: Handle      // zero Handle = none
    ttl: f32            // seconds to live, 0 = forever
}

struct World { ents: Pool[Entity], player: Handle, score: i64 }

fn move_system(w: *World, dt: f32) {
    for i in 0..w.ents.used {
        if w.ents.is_live(i) {
            e := &w.ents.items[i]
            e.pos = e.pos + e.vel * dt
        }
    }
}

// enemies walk toward their target; a target that died is seen as nil
fn chase_system(w: *World) {
    for i in 0..w.ents.used {
        if !w.ents.is_live(i) || w.ents.items[i].kind != Enemy {
            continue
        }
        e := &w.ents.items[i]
        t := w.ents.get(e.target)
        e.vel = if t == nil { vec2(0.0) } else if t.pos.x > e.pos.x { vec2(1.0, 0.0) } else { vec2(-1.0, 0.0) }
    }
}

// bullets expire; removing inside the loop is fine because slots never move
fn expire_system(w: *World, dt: f32) {
    for i in 0..w.ents.used {
        if !w.ents.is_live(i) || w.ents.items[i].ttl == 0.0 {
            continue
        }
        e := &w.ents.items[i]
        e.ttl -= dt
        if e.ttl <= 0.0 {
            w.ents.remove(w.ents.handle_at(i))
        }
    }
}

fn main() {
    w := World{ents: pool_new[Entity](1024)}
    w.player = w.ents.insert(Entity{kind: Player, pos: vec2(10.0, 0.0), hp: 3})
    enemy := w.ents.insert(Entity{kind: Enemy, pos: vec2(0.0, 0.0), hp: 1, target: w.player})
    w.ents.insert(Entity{kind: Bullet, pos: vec2(10.0, 0.0), vel: vec2(-8.0, 0.0), ttl: 0.5})

    for frame in 0..60 {
        chase_system(&w)
        move_system(&w, 1.0 / 60.0)
        expire_system(&w, 1.0 / 60.0)
        if frame == 29 {
            w.ents.remove(w.player)
        }
    }
    e := w.ents.get(enemy)
    put("live ", w.ents.len, ", player alive: ", w.ents.is_valid(w.player), ", enemy stopped at x = ")
    putf(f64(e.pos.x), 2)
    putc('\n')
}
```

Output:

```
live 1, player alive: false, enemy stopped at x = 0.50
```

Guidelines:

- References between entities are `Handle` fields, read through `get` and checked for `nil`.
  That makes "my target died" an ordinary case instead of a crash.
- Run the systems in a fixed order from one `update` function. The order is the game's logic:
  keep it visible there rather than spread over callbacks.
- Per-kind data that is large or rare (an inventory, an AI plan) goes into its own pool or
  array, and the entity keeps a `Handle` or an index to it.
- When kinds really are disjoint, an `enum` with data works as the payload:
  `enum Body { Ship(ShipData), Rock(f32), Shot(Handle) }` as a field of the entity, taken apart
  with `match`. Start with plain fields; reach for the enum when the struct gets confusing.
- A system that only concerns a few entities does not need its own storage either: skip the
  others with `continue`. If profiling shows a hot loop over a sparse kind, keep the handles
  of that kind in a `Vec[Handle]` or a `SparseSet` and loop over that.

`tests/std/mem_entities.al` runs this pattern at scale: 100 000 entities, three systems,
100 steps with entities dying and being replaced, in about 0.1 s.

## Ring

A fixed-capacity first-in-first-out queue. Nothing allocates after `ring_new`.

| Declaration | Description |
|-------------|-------------|
| `struct Ring[T] { buf: []T, head: i64, len: i64 }` | `len`: number of queued elements. The capacity is `len(r.buf)`. |
| `ring_new[T](cap: i64) -> Ring[T]` | An empty ring with room for `cap` elements. |
| `push[T](r: *Ring[T], x: T) -> bool` | Appends at the back; `false` (nothing stored) if the ring is full. |
| `push_overwrite[T](r: *Ring[T], x: T)` | Appends at the back, dropping the oldest element if full: the ring keeps the last `cap` values (frame times, a trail, an undo history). |
| `pop[T](r: *Ring[T]) -> (T, bool)` | Removes and returns the oldest element; `(zero value, false)` if empty. |
| `at[T](r: *Ring[T], i: i64) -> T` | The `i`-th oldest element without removing it (`0 <= i < r.len`). |
| `is_full[T](r: *Ring[T]) -> bool` | True if `push` would fail. |
| `clear[T](r: *Ring[T])` | Removes all elements. |

An event queue between systems is a ring that producers `push` to and one consumer drains:
`loop { ev, ok := events.pop(); if !ok { break }; handle(ev) }`.

## SparseSet

A set of small non-negative integers (entity slot indices, tile ids, player numbers) with
constant-time insert, remove and membership test, and with all members in one contiguous
array for iteration.

| Declaration | Description |
|-------------|-------------|
| `struct SparseSet { dense: []u32, sparse: []u32, len: i64 }` | `dense[0..len]` are the members, in unspecified order; `sparse[id]` is the position of `id` in `dense`. |
| `sparse_set(cap: i64) -> SparseSet` | An empty set sized for ids below `cap` and up to `cap` members. It grows (allocating) if a larger id or more members are inserted. |
| `insert(s: *SparseSet, id: u32) -> i64` | Adds `id`; returns its position in `dense` (also if it was a member already). |
| `remove(s: *SparseSet, id: u32) -> i64` | Removes `id` by moving the last member into its place. Returns the position that was refilled, or -1 if `id` was not a member. |
| `has(s: *SparseSet, id: u32) -> bool` | Membership test. |
| `index_of(s: *SparseSet, id: u32) -> i64` | Position of `id` in `dense`, or -1. |
| `items(s: *SparseSet) -> []u32` | The members as a slice (a view, valid until the set changes). |
| `clear(s: *SparseSet)` | Removes all members (constant time). |

Memory is 4 bytes per possible id plus 4 bytes per member. The positions returned by `insert`
and `remove` let a parallel array carry a value per member, kept dense:

```
data[set.insert(id)] = value                // add or overwrite
i := set.remove(id)
if i >= 0 { data[i] = data[set.len] }       // the last member's value follows it
```

## Example

The three lifetimes in one program: pools and a private arena for the whole run, a mark per
level, a frame scope per frame. The numbers at the end show that nothing is left behind.

```
struct Tile { kind: u8, height: u8 }
struct Level { tiles: []Tile, w: i64, h: i64, name: str }
struct Bullet { pos: vec2, vel: vec2, damage: i64 }

fn load_level(n: i64) -> Level {
    lv := Level{w: 64 * n, h: 64, name: fmt("level ", n)}
    lv.tiles = alloc[Tile](lv.w * lv.h)
    for i in 0..len(lv.tiles) {
        lv.tiles[i].height = u8(i % 7)
    }
    return lv
}

fn main() {
    // 1. program lifetime: allocated once, never released
    bullets := pool_new[Bullet](256)
    events := ring_new[str](16)
    audio := arena_new(kb(64))        // private block: unaffected by the releases below
    mix := audio.alloc[f32](4096)
    base := mem_used()

    for n in 1..=2 {
        // 2. level lifetime: everything since this mark goes away when the level ends
        level_mark := mark()
        lv := load_level(n)
        shot := bullets.insert(Bullet{vec2(0.0, 0.0), vec2(1.0, 0.5), 10})
        loaded := mem_used()

        for frame in 0..3 {
            // 3. frame lifetime: scratch memory for strings, lists, sorting
            frame_begin()
            label := fmt(lv.name, " frame ", frame, ": ", bullets.len, " bullets")
            visible := alloc[i64](1000)
            visible[0] = len(label)
            b := bullets.get(shot)
            b.pos = b.pos + b.vel
            if frame == 2 {
                events.push("level done")
            }
            frame_end()
        }
        print(lv.name, "tiles", len(lv.tiles), "bullet at", bullets.get(shot).pos, "level bytes", loaded - base, "frame leak", mem_used() - loaded)
        bullets.clear()
        release(level_mark)
    }
    ev, _ := events.pop()
    print(ev, events.len, len(mix), audio.used(), "left over", mem_used() - base)
}
```

Output:

```
level 1 tiles 4096 bullet at vec2(3.0, 1.5) level bytes 8208 frame leak 0
level 2 tiles 8192 bullet at vec2(3.0, 1.5) level bytes 16400 frame leak 0
level done 1 4096 16384 left over 0
```
