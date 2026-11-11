use "more.al"

struct Circle { r: f64 }
const TAU = 6.283185307179586

fn circumference(c: Circle) -> f64 {
    TAU * c.r
}
