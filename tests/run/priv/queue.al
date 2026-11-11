// Helper of tests/run/priv_files.al: private names again, and a public interface over them.
priv const LIMIT = 3
priv struct Ctx { items [LIMIT]i64, n i64 }
priv enum Mode { QueueEmpty, QueueFull(i64) }
priv var counter = 100

priv fn find(c *Ctx, x i64) i64 {
    for i in 0..c.n {
        if c.items[i] == x {
            return i
        }
    }
    -1
}
priv fn bump() i64 {
    counter *= 2
    counter
}
priv fn state(c *Ctx) Mode {
    if c.n == 0 { QueueEmpty } else { QueueFull(c.n) }
}
priv fn show(m Mode) str { fmt("queue-mode:", m) }
// the same parameter types as the public `show` of the main file: this one is called here
priv fn show(x i64) str { fmt("queue-int:", x) }

fn queue_make() Ctx { Ctx{} }

fn queue_put(c *Ctx, x i64) {
    if c.n < LIMIT {
        c.items[c.n] = x
        c.n += 1
    }
}

fn queue_total(c *Ctx) i64 {
    t := 0
    for i in 0..c.n {
        t += c.items[i]
    }
    t
}

fn queue_run() {
    var c Ctx
    print(c.state(), show(c.state()))
    c.queue_put(4)
    c.queue_put(9)
    c.queue_put(2)
    c.queue_put(1)
    print(c, c.find(9), find(&c, 5), LIMIT, bump(), bump(), counter)
    print(show(state(&c)), show(12))
}
