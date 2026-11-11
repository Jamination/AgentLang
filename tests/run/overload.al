Cat :: struct { n: i64 }
Dog :: struct { n: i64 }
speak :: (c: Cat) -> str { "meow" }
speak :: (d: Dog) -> str { "woof" }
speak :: (x: i64) -> str { "int" }
speak :: (x: f32) -> str { "f32" }
area :: (a: vec2) -> f32 { a.x * a.y }
area :: (r: f32) -> f32 { r * r * 3.0 }
bump :: (c: *Cat) { c.n += 1 }
bump :: (d: *Dog) { d.n += 10 }
min :: (a: vec3, b: vec3) -> vec3 { fmin(a, b) }
main :: () {
    c := Cat{n: 1}
    d := Dog{n: 2}
    f: f32 = 2.0
    print(speak(c), speak(d), speak(3), speak(f), c.speak(), d.speak())
    print(area(vec2(2.0, 3.0)), area(f), f.area())
    c.bump()
    d.bump()
    bump(&c)
    print(c, d, min(3, 4), min(2.5, 1.5), min(vec3(1.0, 5.0, 3.0), vec3(2.0)))
}
