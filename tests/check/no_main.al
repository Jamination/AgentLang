// `alc check` of one file of a program, without `fn main`: its `use` is relative to this file
// (and geom.al's own `use "more.al"` to geom.al), as when another file includes it
use "../run/lib/geom.al"

fn twice_around(c: Circle) -> f64 {
    2.0 * circumference(c)
}
