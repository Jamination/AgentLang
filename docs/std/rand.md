# rand: random numbers and noise

Always available (no `use`). Source: `std/rand.al`.

- `Rng`: a small, fast, seedable generator (xoshiro256**). The same seed gives the same
  sequence on every run, machine and build mode, which is what replays, tests and procedural
  worlds need.
- Helpers on top of it: unbiased integer ranges, floats, coin flips, shuffling, picking,
  random directions and points, normal distribution.
- A process-wide default generator for code that does not care (`rand_u64`, `rand_range`, ...).
- Hash-based gradient noise (`noise2`, `noise3`, `fbm2`): pure functions of their arguments.

Nothing in this module allocates, reads the clock or touches the operating system (its only
dependency is `log` from [math](math.md), for `normal`). There is
deliberately no "seed from time" function: pass `u64(time_ns())` to `rng` if you want a
different game every run, and log the seed so that the run can be reproduced.

## Generator

| Declaration | Description |
|-------------|-------------|
| `struct Rng { s0: u64, s1: u64, s2: u64, s3: u64 }` | Generator state: 32 bytes, no pointers. Copying it forks the sequence; storing it in a save file resumes it. The all-zero state is invalid (always create it with `rng`). |
| `rng(seed: u64) -> Rng` | A generator determined by `seed`. The state is expanded from the seed with splitmix64, so nearby seeds (0, 1, 2) give unrelated sequences. |
| `next_u64(r: *Rng) -> u64` | The next 64 random bits. |
| `next_u32(r: *Rng) -> u32` | The next 32 random bits (high half of `next_u64`). |
| `next_f32(r: *Rng) -> f32` | Uniform in `[0, 1)`, 24 random bits. |
| `next_f64(r: *Rng) -> f64` | Uniform in `[0, 1)`, 53 random bits. |
| `below(r: *Rng, n: u64) -> u64` | Unbiased integer in `[0, n)`; `n` must not be 0. |
| `range(r: *Rng, lo: i64, hi: i64) -> i64` | Unbiased integer in `[lo, hi)` (like `for i in lo..hi`); requires `lo < hi`. A die is `r.range(1, 7)`. |
| `range(r: *Rng, lo: f32, hi: f32) -> f32` | Uniform float in `[lo, hi)`. |
| `chance(r: *Rng, p: f32) -> bool` | `true` with probability `p`. |
| `shuffle[T](r: *Rng, xs: []T)` | Reorders `xs` in place, every permutation equally likely (Fisher-Yates). |
| `pick[T](r: *Rng, xs: []T) -> T` | A uniformly chosen element; `xs` must not be empty. |
| `unit_vec2(r: *Rng) -> vec2`, `unit_vec3(r: *Rng) -> vec3` | Uniformly distributed direction of length 1. |
| `in_circle(r: *Rng) -> vec2`, `in_sphere(r: *Rng) -> vec3` | Uniformly distributed point inside the unit disc / unit ball; scale and offset as needed. |
| `normal(r: *Rng, mean: f32, stddev: f32) -> f32` | Normally (Gaussian) distributed value. |

All of these are methods in the usual sense: `r.range(0, 10)` is `range(&r, 0, 10)`. The two
`range` functions are told apart by the argument types: integer arguments give an integer,
`f32` arguments (or float literals) give an `f32`.

"Unbiased" means exactly uniform: `below` rejects the few raw values that would make some
results more likely than others (`x % n` does not). An empty range or slice is a programming
error and stops the program with a message.

Use one `Rng` per subsystem that must be reproducible on its own (world generation, AI,
particles), kept in that subsystem's state struct. Drawing cosmetic random numbers from the
gameplay generator makes the simulation depend on what was drawn on screen.

## Default generator

| Declaration | Description |
|-------------|-------------|
| `rand_seed(seed: u64)` | Restarts the default generator from `seed`. |
| `rand_u64() -> u64` | Next 64 bits. |
| `rand_f32() -> f32` | Uniform in `[0, 1)`. |
| `rand_range(lo: i64, hi: i64) -> i64` | Unbiased integer in `[lo, hi)`. |
| `rand_range(lo: f32, hi: f32) -> f32` | Uniform float in `[lo, hi)`. |

The default generator starts in the state of `rng(0)`: a program that never calls `rand_seed`
still behaves the same on every run. It is one hidden global, so prefer an explicit `Rng`
wherever order of use matters.

## Noise

| Declaration | Description |
|-------------|-------------|
| `noise2(x: f32, y: f32) -> f32`, `noise2(x: f32, y: f32, seed: u32) -> f32` | 2D gradient ("Perlin") noise. Smooth, in `[-1, 1]` (mostly within ±0.7), exactly 0 at integer coordinates, about one bump per unit. |
| `noise3(x: f32, y: f32, z: f32) -> f32`, `noise3(x: f32, y: f32, z: f32, seed: u32) -> f32` | 3D gradient noise in `[-1, 1]`. Use `z` as time to animate a 2D field. |
| `fbm2(x: f32, y: f32, octaves: i64) -> f32`, `fbm2(x: f32, y: f32, octaves: i64, seed: u32) -> f32` | Fractal sum of `octaves` layers of `noise2`, each with twice the frequency and half the amplitude of the one before, normalized to `[-1, 1]`. 4 to 6 octaves give natural-looking terrain and clouds. |
| `noise_hash(x: i64, y: i64, z: i64, seed: u32) -> u32` | The lattice hash behind the noise: a well-mixed 32-bit value for an integer point. Useful for per-tile randomness without storing anything (`noise_hash(tx, ty, 0, world_seed) % 4` picks a tile variant). |

Noise is a pure function: the same arguments always give the same value, with no state and no
set-up, so any part of an endless world can be generated in any order. `seed` selects an
independent field; the versions without `seed` use seed 0. Scale the inputs to choose the
feature size (`noise2(x * 0.05, y * 0.05)` has features about 20 units wide) and remap the
output as needed (`n * 0.5 + 0.5` for `[0, 1]`).

## Algorithms

- Generator: xoshiro256** 1.0 (Blackman, Vigna), period 2^256 - 1, seeded through splitmix64.
  `rng(0).next_u64()` is `11091344671253066420`.
- `below`: Lemire's multiply-and-reject method on 32 bits when `n < 2^32` (no division in the
  common case), masked rejection for larger `n`.
- `unit_vec3`: Marsaglia (1972); `normal`: Marsaglia polar method; `in_circle`/`in_sphere`:
  rejection sampling. These draw a varying number of values from the generator.
- Noise: gradients from an integer hash of the lattice point, quintic fade
  `6t^5 - 15t^4 + 10t^3`.

## Example

```
struct Loot { name: str, weight: i64 }

// weighted choice: walk the table until the roll is used up
fn roll_loot(r: *Rng, table: []Loot) -> str {
    total := 0
    for l in table {
        total += l.weight
    }
    roll := r.range(0, total)
    for l in table {
        if roll < l.weight {
            return l.name
        }
        roll -= l.weight
    }
    return ""
}

fn main() {
    // one generator per subsystem: world generation does not disturb combat rolls
    world := rng(2024)
    combat := rng(7)

    // dice and chances
    put("3d6:")
    for i in 0..5 {
        put(" ", combat.range(1, 7) + combat.range(1, 7) + combat.range(1, 7))
    }
    print("  crit:", combat.chance(0.1))

    // shuffle a deck, pick a card, weighted loot
    deck := []str{"A", "K", "Q", "J", "10", "9", "8", "7"}
    combat.shuffle(deck)
    print(deck, "picked", combat.pick(deck))
    table := []Loot{Loot{"gold", 70}, Loot{"potion", 25}, Loot{"sword", 5}}
    for i in 0..6 {
        put(roll_loot(&combat, table), " ")
    }
    print("")

    // scatter: direction, spread and speed of a particle
    dir := world.unit_vec2()
    offset := world.in_circle() * 3.0
    speed := world.normal(10.0, 2.0)
    print(dir.x * dir.x + dir.y * dir.y > 0.999, offset.x * offset.x + offset.y * offset.y < 9.0, speed > 0.0)

    // terrain from fractal noise: the same seed always gives the same map
    shades := " .:-=+*#"
    for y in 0..8 {
        for x in 0..48 {
            h := fbm2(f32(x) * 0.08, f32(y) * 0.16, 4, 99) * 1.5 + 0.5
            putc(shades[max(min(i64(h * 8.0), 7), 0)])
        }
        putc('\n')
    }
}
```

Output (identical on every run):

```
3d6: 13 18 5 10 15  crit: false
[8, 7, K, 10, 9, A, J, Q] picked K
potion gold gold gold gold gold 
true true true
=-==++*+=======--:--==---==--:.....:--===++*#**+
--======--=====-====+====+++=-:::..::--==+**###+
===+==+=--==-::------=++====-:::.:::--=++*#####*
+++++++=---:::::::.:---==----:-::..:-===++*#####
*+++++==-:......:...:--==-------:::-=======+****
-----===--::::::. .:------:-====-::--===+++=====
==-----=-------:-::-===+=----===--:::-=++*++==-=
--===--===-=====---==++===-====--::::-===++=====
```
