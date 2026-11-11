# time: clocks, sleeping and frame timing

Always available (no `use`). Source: `std/time.al`.

Times are `f64` seconds unless the name ends in `_ns` or `_ms`. Nothing here allocates, and
everything goes through raw system calls (`clock_gettime`, `nanosleep`).

Only `time_now`, `time_ns`, `wall_time`, the `sleep_*` functions, `Stopwatch` and
`tick(*FrameClock)` look at the real clock. `FixedStep`, `Timer` and `tick_at` work purely on
the numbers they are given. Keep it that way in a game: read the clock once per frame (with
`FrameClock`), pass `dt` down, and the whole simulation can be tested and replayed.

## Clocks and sleeping

| Declaration | Description |
|-------------|-------------|
| `time_now() -> f64` | Monotonic time in seconds. The origin is arbitrary (system start): only differences mean something. Never goes backwards. |
| `time_ns() -> i64` | The same clock in nanoseconds (the prelude's `clock_ns()`). |
| `wall_time() -> i64` | Calendar time: seconds since 1970-01-01 UTC. For time stamps and save files, not for measuring (it can jump). |
| `sleep_ms(ms: i64)` | Suspends the program for `ms` milliseconds. |
| `sleep_ns(ns: i64)` | Suspends the program for `ns` nanoseconds. Zero or negative: returns at once. |
| `sleep_until(t: f64)` | Sleeps until `time_now()` reaches `t`; returns at once if that moment has passed. For frame pacing without drift: `next += 1.0 / 60.0; sleep_until(next)`. |

Sleeping is accurate to a fraction of a millisecond on an idle machine, never shorter than
asked.

## Stopwatch

Measures real elapsed time, for profiling and timeouts.

| Declaration | Description |
|-------------|-------------|
| `struct Stopwatch { start_ns: i64, acc_ns: i64, running: bool }` | |
| `stopwatch() -> Stopwatch` | A running stopwatch started now. |
| `elapsed(s: *Stopwatch) -> f64` | Seconds measured so far. |
| `elapsed_ns(s: *Stopwatch) -> i64` | The same in nanoseconds. |
| `pause(s: *Stopwatch)`, `resume(s: *Stopwatch)` | Stop / continue counting. |
| `restart(s: *Stopwatch) -> f64` | Returns the seconds measured so far and starts again from zero (lap time). |

## FrameClock

Call `tick` once at the top of every frame.

| Declaration | Description |
|-------------|-------------|
| `struct FrameClock { dt: f64, elapsed: f64, frame: i64, fps: f64, max_dt: f64, last_ns: i64, avg: f64 }` | `dt`: seconds since the previous tick, clamped to `[0, max_dt]` (0 on the first tick). `elapsed`: the sum of all `dt`, i.e. game time. `frame`: number of ticks. `fps`: smoothed frames per second. `max_dt`: the clamp, 0.25 s unless changed. `last_ns`, `avg`: internal. |
| `frame_clock() -> FrameClock` | A new clock. |
| `tick(c: *FrameClock) -> f64` | Starts a new frame from the real clock: updates the fields and returns `dt`. |
| `tick_at(c: *FrameClock, now_ns: i64) -> f64` | The same with the time supplied by the caller (a monotonic nanosecond value). For tests, replays and benchmarks. |

`dt` is clamped because a frame can take arbitrarily long (window dragged, debugger, laptop
lid): without the clamp one huge step would tunnel objects through walls. `fps` averages the
unclamped frame time exponentially (each frame counts 10%), which is steady enough to display.

## FixedStep

The fixed-timestep accumulator ("fix your timestep"): rendering runs as fast as it likes, the
simulation advances in steps of constant length. Physics then behaves the same at 30 and at
240 frames per second, and a recorded input sequence replays exactly.

| Declaration | Description |
|-------------|-------------|
| `struct FixedStep { step: f64, acc: f64, max_steps: i64, steps: i64 }` | `step`: seconds per simulation step. `acc`: time not yet simulated (less than `step` after `advance`). `max_steps`: cap on steps per `advance`, 8 unless changed. `steps`: total steps handed out. |
| `fixed_step(hz: f64) -> FixedStep` | An accumulator for `hz` simulation steps per second. |
| `advance(f: *FixedStep, dt: f64) -> i64` | Adds the frame time and returns how many steps to run now, from 0 to `max_steps`. |
| `alpha(f: *FixedStep) -> f32` | How far the current frame lies between the last two simulation states, in `[0, 1)`: draw `lerp(previous, current, alpha)`. |

```
for _ in 0..sim.advance(clock.dt) {
    update(&game, sim.step)
}
render(&game, sim.alpha())
```

If a frame takes longer than `max_steps` steps of simulation, the surplus time is dropped: the
game slows down instead of entering a spiral in which every frame has more to simulate than the
last. With the default `FrameClock.max_dt` of 0.25 s and 60 Hz that cap is reached after a
stall of 0.13 s.

## Timer

A countdown that is advanced with the game's `dt`, so it pauses, slows down and replays with
the game. Timers are plain values: keep them in your entity or state structs.

| Declaration | Description |
|-------------|-------------|
| `struct Timer { duration: f64, left: f64, repeat: bool, active: bool }` | `duration`: seconds per period. `left`: seconds until it fires next. `repeat`: restarts itself. `active`: false after a one-shot timer fired or after `stop`. |
| `timer(seconds: f64, repeat: bool) -> Timer` | An active timer that fires after `seconds` (and then every `seconds` if `repeat`). |
| `tick(t: *Timer, dt: f64) -> i64` | Advances by `dt` and returns how often the timer fired: 0 or 1 for a one-shot timer; for a repeating timer the number of periods that ended (a long `dt` can end several; the remainder carries over, so no time is lost). |
| `done(t: *Timer) -> bool` | True once a one-shot timer has fired. |
| `progress(t: *Timer) -> f32` | Fraction of the current period that has passed, in `[0, 1]` (for cooldown bars and fades). |
| `reset(t: *Timer)` | Starts the countdown again from the full duration. |
| `stop(t: *Timer)` | Deactivates the timer without firing; `reset` starts it again. |

```
if weapon.cooldown.tick(dt) > 0 { weapon.ready = true }      // one-shot
for _ in 0..spawner.tick(dt) { spawn_enemy(&world) }         // repeating
```

## Example

A complete loop: a fixed 50 Hz simulation with interpolated drawing, first fed with recorded
frame times (so the output is reproducible), then running on the real clock at 100 frames per
second.

```
struct Game { x: f64, prev_x: f64, vx: f64, ticks: i64, spawn: Timer, spawned: i64 }

// one simulation step of fixed length: all game logic lives here
fn update(g: *Game, dt: f64) {
    g.prev_x = g.x
    g.x += g.vx * dt
    g.ticks += 1
    g.spawned += g.spawn.tick(dt)
}

// drawing interpolates between the last two states, so motion is smooth at any frame rate
fn render_x(g: *Game, alpha: f32) -> f64 {
    return g.prev_x + (g.x - g.prev_x) * f64(alpha)
}

fn main() {
    game := Game{vx: 10.0, spawn: timer(0.1, true)}
    clock := frame_clock()
    sim := fixed_step(50.0)

    // Part 1: replay recorded frame times (deterministic: same input, same result)
    now := 1000000000
    frames_ms := []i64{0, 16, 17, 16, 40, 16, 300, 16, 16, 15, 17, 500, 16}
    for ms in frames_ms {
        now += ms * 1000000
        clock.tick_at(now)
        for _ in 0..sim.advance(clock.dt) {
            update(&game, sim.step)
        }
    }
    put("frames ", clock.frame, " steps ", game.ticks, " spawned ", game.spawned, " x ")
    putf(game.x, 2)
    put(" drawn at ")
    putf(render_x(&game, sim.alpha()), 2)
    put(" game time ")
    putf(clock.elapsed, 3)
    putc('\n')

    // Part 2: the same loop on the real clock, paced to 100 frames per second
    live := frame_clock()
    sw := stopwatch()
    next := time_now()
    while live.elapsed < 0.1 {
        live.tick()
        for _ in 0..sim.advance(live.dt) {
            update(&game, sim.step)
        }
        next += 0.01
        sleep_until(next)
    }
    print("real loop:", live.frame >= 5, sw.elapsed() >= 0.1, live.fps > 20.0)
}
```

Output:

```
frames 13 steps 24 spawned 4 x 4.80 drawn at 4.76 game time 0.685
real loop: true true true
```

The 300 ms and 500 ms frames are clamped to 0.25 s by the frame clock and then limited to 8
steps by the accumulator, which is why 0.685 s of game time produced 24 steps rather than 34.
