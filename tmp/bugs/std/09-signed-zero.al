// trunc(-0.5), round(-0.4), f32 ceil(-0.25), atan(-0.0) returned +0.0; C (which math.md names
// as the reference) returns -0.0. Found by the differential test tmp/fz/mathfz.py vs glibc.
// expected: -0.0 -0.0 -0.0 -0.0   actual (before the fix): 0.0 0.0 0.0 0.0
fn main() {
    y: f32 = -0.25
    print(trunc(-0.5), round(-0.4), ceil(y), atan(-0.0))
}
