// std.mem: the fat-struct entity pattern at scale. 100000 entities in one Pool, systems are
// plain loops over the slots; entities die and are replaced while the simulation runs.
enum Kind { Rock, Ship, Shot }

struct Entity {
    kind: Kind
    pos: vec3
    vel: vec3
    life: f32
    target: Handle
}

struct World { ents: Pool[Entity], rng: Rng, spawned: i64, died: i64 }

fn spawn(w: *World) -> Handle {
    k := w.rng.range(0, 3)
    e := Entity{
        kind: if k == 0 { Rock } else if k == 1 { Ship } else { Shot },
        pos: w.rng.in_sphere() * 100.0,
        vel: w.rng.unit_vec3() * w.rng.range(1.0, 5.0),
        life: w.rng.range(0.5, 8.0),
    }
    w.spawned += 1
    return w.ents.insert(e)
}

fn move_system(w: *World, dt: f32) {
    es := w.ents.items
    for i in 0..w.ents.used {
        if w.ents.is_live(i) {
            es[i].pos = es[i].pos + es[i].vel * dt
        }
    }
}

fn life_system(w: *World, dt: f32) {
    for i in 0..w.ents.used {
        if !w.ents.is_live(i) {
            continue
        }
        e := &w.ents.items[i]
        if e.kind != Rock {
            e.life -= dt
            if e.life <= 0.0 {
                w.ents.remove(w.ents.handle_at(i))
                w.died += 1
            }
        }
    }
}

// ships steer toward their target; a dead target is noticed through its stale handle
fn steer_system(w: *World, dt: f32) {
    for i in 0..w.ents.used {
        if !w.ents.is_live(i) || w.ents.items[i].kind != Ship {
            continue
        }
        e := &w.ents.items[i]
        t := w.ents.get(e.target)
        if t == nil {
            e.target = w.ents.handle_at(i64(w.rng.below(u64(w.ents.used))))
            continue
        }
        e.vel = e.vel + (t.pos - e.pos) * (dt * 0.01)
    }
}

fn main() {
    n := 100000
    w := World{ents: pool_new[Entity](n), rng: rng(2024)}
    for i in 0..n {
        spawn(&w)
    }
    dt: f32 = 1.0 / 60.0
    for step in 0..100 {
        move_system(&w, dt)
        steer_system(&w, dt)
        life_system(&w, dt)
        while w.ents.len < n {
            spawn(&w)
        }
    }
    sum := vec3(0.0)
    kinds := [3]i64{0, 0, 0}
    check := u64(0)
    for i in 0..w.ents.used {
        if w.ents.is_live(i) {
            e := w.ents.items[i]
            sum = sum + e.pos
            kinds[if e.kind == Rock { 0 } else if e.kind == Ship { 1 } else { 2 }] += 1
            check = check * 31 + u64(cast[u32](e.pos.x)) + u64(cast[u32](e.pos.y)) * 7 + u64(cast[u32](e.pos.z)) * 13
        }
    }
    print("live", w.ents.len, "slots", w.ents.used, "spawned", w.spawned, "died", w.died)
    print("kinds", kinds, kinds[0] + kinds[1] + kinds[2])
    print("checksum", check)
    putf(f64(sum.x) / f64(n), 2)
    putc(' ')
    putf(f64(sum.y) / f64(n), 2)
    putc(' ')
    putf(f64(sum.z) / f64(n), 2)
    putc('\n')
}
