use "more.al"

Circle :: struct { r: f64 }
TAU :: 6.283185307179586

circumference :: (c: Circle) -> f64 {
    TAU * c.r
}
