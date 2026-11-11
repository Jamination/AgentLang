// std.time: clocks, sleeping, FrameClock, FixedStep, Timer
main :: () {
    // real clocks: only loose facts
    t0 := time_now()
    n0 := time_ns()
    sw := stopwatch()
    sleep_ms(20)
    ms := sw.elapsed() * 1000.0
    print("sleep_ms", ms >= 15.0 && ms < 500.0, time_now() - t0 >= 0.015, time_ns() - n0 >= 15000000)
    print("wall clock", wall_time() > 1700000000)
    target := time_now() + 0.01
    sleep_until(target)
    print("sleep_until", time_now() >= target, time_now() - target < 0.5)
    sleep_until(0.0)
    sleep_ms(-5)
    sleep_ns(0)
    sw.pause()
    e := sw.elapsed()
    sleep_ms(5)
    print("paused", sw.elapsed() == e, sw.elapsed_ns() >= 25000000)
    sw.resume()
    sleep_ms(5)
    print("resumed", sw.elapsed() > e)
    lap := sw.restart()
    print("restart", lap > e, sw.elapsed() < lap, sw.running)

    // FrameClock with recorded times (nanoseconds)
    fc := frame_clock()
    print(fc.tick_at(5000000000), fc.frame, fc.fps)
    for i in 1..=60 {
        fc.tick_at(5000000000 + i * 16000000)
    }
    putf(fc.dt, 3)
    putc(' ')
    putf(fc.elapsed, 3)
    putc(' ')
    putf(fc.fps, 1)
    print("", fc.frame)
    // a long stall is clamped to max_dt and does not jump game time
    print(fc.tick_at(5000000000 + 60 * 16000000 + 3000000000), fc.fps < 62.5)
    fc.max_dt = 0.1
    print(fc.tick_at(fc.last_ns + 2000000000), fc.tick_at(fc.last_ns - 5), fc.frame)
    putf(fc.elapsed, 3)
    putc('\n')
    live := frame_clock()
    live.tick()
    sleep_ms(10)
    dt := live.tick()
    print("live tick", dt >= 0.005 && dt <= 0.25, live.frame, live.fps > 1.0)

    // FixedStep: 60 Hz simulation driven by uneven frames
    fs := fixed_step(60.0)
    frames := []f64{0.016, 0.017, 0.033, 0.005, 0.005, 0.1, 0.0, 0.021}
    total := 0
    for f in frames {
        k := fs.advance(f)
        total += k
        put(k, " ")
    }
    print("| steps", total, fs.steps, "alpha in [0,1)", fs.alpha() >= 0.0 && fs.alpha() < 1.0)
    putf(f64(fs.alpha()), 2)
    putc('\n')
    // one second in 1 ms frames is exactly 60 steps; the cap drops time after a stall
    fs = fixed_step(60.0)
    total = 0
    for i in 0..1000 {
        total += fs.advance(0.001)
    }
    print(total, fs.advance(5.0), fs.acc, fs.advance(-1.0), fs.steps)
    fs.max_steps = 3
    put(fs.advance(0.05), " ", fs.advance(0.06), " ")
    putf(fs.acc, 4)
    putc('\n')

    // Timer: one-shot and repeating
    once := timer(1.0, false)
    print(once.tick(0.4), once.done(), once.progress(), once.tick(0.7), once.done(), once.tick(5.0), once.progress())
    once.reset()
    print(once.active, once.left, once.tick(1.0), once.done())
    rep := timer(0.25, true)
    fired := 0
    for i in 0..64 {
        fired += rep.tick(0.015625)
    }
    print(fired, rep.tick(1.0), rep.tick(0.1), rep.done())
    putf(rep.left, 2)
    putc(' ')
    putf(f64(rep.progress()), 2)
    putc('\n')
    rep.stop()
    print(rep.tick(10.0), rep.active, rep.done())
    rep.reset()
    print(rep.tick(0.25), rep.left)
}
