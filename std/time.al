// std.time: clocks, sleeping and frame timing. Core module: available in every program.
// Times are f64 seconds unless a name ends in _ns or _ms. Nothing here allocates.
// Only time_now/time_ns/wall_time/sleep_* and tick(*FrameClock) read the real clock; every
// other function works on the numbers it is given, so game logic stays deterministic.

// monotonic time in nanoseconds (arbitrary origin; never goes backwards)
fn time_ns() -> i64 {
    return clock_ns()
}

// monotonic time in seconds
fn time_now() -> f64 {
    return f64(clock_ns()) * 1e-9
}

// wall-clock time: seconds since 1970-01-01 UTC (can jump when the system clock is set)
fn wall_time() -> i64 {
    ts: [2]i64
    syscall(228, 0, ptr(ts))
    return ts[0]
}

// suspends the program for `ns` nanoseconds (returns at once when ns <= 0)
fn sleep_ns(ns: i64) {
    if ns <= 0 {
        return
    }
    ts: [2]i64
    ts[0] = ns / 1000000000
    ts[1] = ns % 1000000000
    // nanosleep stores the remaining time back into ts when a signal interrupts it (EINTR)
    while syscall(35, ptr(ts), ptr(ts)) == -4 {
    }
}

// suspends the program for `ms` milliseconds
fn sleep_ms(ms: i64) {
    sleep_ns(ms * 1000000)
}

// sleeps until time_now() reaches `t` (returns at once if that time has passed)
fn sleep_until(t: f64) {
    sleep_ns(i64((t - time_now()) * 1e9))
}

// ---------- Stopwatch ----------
// Measures real elapsed time; can be paused and resumed.
struct Stopwatch { start_ns: i64, acc_ns: i64, running: bool }

// a running stopwatch started now
fn stopwatch() -> Stopwatch {
    return Stopwatch{start_ns: clock_ns(), acc_ns: 0, running: true}
}

// nanoseconds measured so far
fn elapsed_ns(s: *Stopwatch) -> i64 {
    return if s.running { s.acc_ns + clock_ns() - s.start_ns } else { s.acc_ns }
}

// seconds measured so far
fn elapsed(s: *Stopwatch) -> f64 {
    return f64(elapsed_ns(s)) * 1e-9
}

// stops counting; elapsed() keeps its value until resume()
fn pause(s: *Stopwatch) {
    if s.running {
        s.acc_ns += clock_ns() - s.start_ns
        s.running = false
    }
}

// continues counting after pause()
fn resume(s: *Stopwatch) {
    if !s.running {
        s.start_ns = clock_ns()
        s.running = true
    }
}

// returns the seconds measured so far and starts again from zero (lap time)
fn restart(s: *Stopwatch) -> f64 {
    t := elapsed(s)
    s.start_ns = clock_ns()
    s.acc_ns = 0
    s.running = true
    return t
}

// ---------- FrameClock ----------
// Per-frame timing for a game loop: call tick() once at the top of every frame.
//   dt       seconds since the previous tick, clamped to [0, max_dt] (0 on the first tick)
//   elapsed  sum of all dt: game time, which does not jump after a stall
//   frame    number of ticks so far
//   fps      smoothed frames per second (exponential average of the unclamped frame time)
//   max_dt   clamp for dt, default 0.25 s (a debugger stop or window drag must not explode physics)
struct FrameClock { dt: f64, elapsed: f64, frame: i64, fps: f64, max_dt: f64, last_ns: i64, avg: f64 }

// a frame clock with max_dt = 0.25 s
fn frame_clock() -> FrameClock {
    return FrameClock{max_dt: 0.25}
}

// advances the clock to the monotonic time `now_ns` and returns dt; tick() calls this with
// time_ns(), tests and replays can feed recorded times
fn tick_at(c: *FrameClock, now_ns: i64) -> f64 {
    raw := if c.frame == 0 { 0.0 } else { f64(now_ns - c.last_ns) * 1e-9 }
    c.last_ns = now_ns
    c.dt = if raw < 0.0 { 0.0 } else if raw > c.max_dt { c.max_dt } else { raw }
    c.elapsed += c.dt
    c.frame += 1
    if raw > 0.0 {
        c.avg = if c.avg == 0.0 { raw } else { c.avg + (raw - c.avg) * 0.1 }
        c.fps = 1.0 / c.avg
    }
    return c.dt
}

// starts a new frame: updates dt, elapsed, frame and fps from the real clock and returns dt
fn tick(c: *FrameClock) -> f64 {
    return tick_at(c, clock_ns())
}

// ---------- FixedStep ----------
// Fixed-timestep accumulator ("fix your timestep"): the simulation always advances in steps of
// `step` seconds, however long frames take, so it is deterministic and frame-rate independent.
//   for _ in 0..fs.advance(clock.dt) { update(&game, fs.step) }
//   render(&game, fs.alpha())
//   step       length of one simulation step in seconds
//   acc        time not yet simulated, always < step after advance()
//   max_steps  cap on the steps per advance (default 8); time beyond it is dropped, so a
//              slow machine slows the game down instead of spiralling
//   steps      total number of steps handed out
struct FixedStep { step: f64, acc: f64, max_steps: i64, steps: i64 }

// a fixed-step accumulator running at `hz` simulation steps per second
fn fixed_step(hz: f64) -> FixedStep {
    assert hz > 0.0, "fixed_step: hz must be positive"
    return FixedStep{step: 1.0 / hz, acc: 0.0, max_steps: 8, steps: 0}
}

// adds the frame time `dt` (ignored if negative) and returns how many fixed updates to run
// now (0..max_steps)
fn advance(f: *FixedStep, dt: f64) -> i64 {
    if dt > 0.0 {
        f.acc += dt
    }
    n := i64(f.acc / f.step)
    if n > f.max_steps {
        n = f.max_steps
        f.acc = 0.0
    } else {
        f.acc = max(f.acc - f64(n) * f.step, 0.0)
    }
    f.steps += n
    return n
}

// how far the frame is between the last two simulation states, in [0, 1): draw
// lerp(previous, current, alpha)
fn alpha(f: *FixedStep) -> f32 {
    return f32(f.acc / f.step)
}

// ---------- Timer ----------
// Countdown driven by the game's dt (not by the real clock): one-shot or repeating.
//   duration  seconds per period
//   left      seconds until it fires next
//   repeat    restart automatically after firing
//   active    false once a one-shot timer has fired (or after stop())
struct Timer { duration: f64, left: f64, repeat: bool, active: bool }

// an active timer that fires after `seconds`, and every `seconds` again if `repeat`
fn timer(seconds: f64, repeat: bool) -> Timer {
    assert seconds > 0.0 || !repeat, "timer: a repeating timer needs a positive period"
    return Timer{duration: seconds, left: seconds, repeat: repeat, active: true}
}

// advances the timer by dt and returns how often it fired: 0 or 1 for a one-shot timer, the
// number of elapsed periods for a repeating one (the remainder carries over)
fn tick(t: *Timer, dt: f64) -> i64 {
    if !t.active {
        return 0
    }
    t.left -= dt
    if t.left > 0.0 {
        return 0
    }
    if !t.repeat {
        t.left = 0.0
        t.active = false
        return 1
    }
    n := 1 + i64(-t.left / t.duration)
    t.left += f64(n) * t.duration
    return n
}

// true when a one-shot timer has fired
fn done(t: *Timer) -> bool {
    return !t.active && t.left == 0.0
}

// fraction of the current period that has passed, in [0, 1]
fn progress(t: *Timer) -> f32 {
    if t.duration <= 0.0 {
        return 1.0
    }
    return f32(1.0 - t.left / t.duration)
}

// starts the countdown again from the full duration
fn reset(t: *Timer) {
    t.left = t.duration
    t.active = true
}

// deactivates the timer without firing; reset() starts it again
fn stop(t: *Timer) {
    t.active = false
}
