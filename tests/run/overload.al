struct Cat { n i64 }
struct Dog { n i64 }
fn speak(c Cat) str { "meow" }
fn speak(d Dog) str { "woof" }
fn speak(x i64) str { "int" }
fn speak(x f32) str { "f32" }
fn area(a vec2) f32 { a.x * a.y }
fn area(r f32) f32 { r * r * 3.0 }
fn bump(c *Cat) { c.n += 1 }
fn bump(d *Dog) { d.n += 10 }
fn min(a vec3, b vec3) vec3 { fmin(a, b) }
fn main() {
    c := Cat{n: 1}
    d := Dog{n: 2}
    var f f32 = 2.0
    print(speak(c), speak(d), speak(3), speak(f), c.speak(), d.speak())
    print(area(vec2(2.0, 3.0)), area(f), f.area())
    c.bump()
    d.bump()
    bump(&c)
    print(c, d, min(3, 4), min(2.5, 1.5), min(vec3(1.0, 5.0, 3.0), vec3(2.0)))
}
