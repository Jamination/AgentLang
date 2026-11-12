// hash(vec3), Map[vec2, V] etc.: "values of type vec2 cannot be hashed" (reported inside the prelude), though `==` works on them
// expected: prints, -0.0 and 0.0 lanes hash alike
fn main() {
    t2()
    z: f32 = 0.0
    a := vec3(z, 1.0, 2.0)
    b := vec3(-z, 1.0, 2.0)
    c := vec3(z, 1.0, 3.0)
    print(a == b, a == c, a != c, quat(1.0, 2.0, 3.0, 4.0) == quat(1.0, 2.0, 3.0, 4.0), mat4(1.0) == mat4(1.0), mat4(1.0) == mat4(2.0))
    s := []vec3{a}
    t := []vec3{b}
    print(s == t)
    m := map[vec2, i64]()
    m.set(vec2(1.0, 2.0), 3)
    print(m.get_or(vec2(1.0, 2.0), 0))
}
fn t2() {
    z: f32 = 0.0
    print(hash(vec3(z, 1.0, 2.0)) == hash(vec3(-z, 1.0, 2.0)), hash(vec3(z, 1.0, 2.0)) == hash(vec3(z, 1.0, 3.0)), hash(quat(1.0, 2.0, 3.0, 4.0)) == hash(quat(1.0, 2.0, 3.0, 4.0)), hash(mat4(1.0)) == hash(mat4(1.0)), hash(mat4(1.0)) == hash(mat4(2.0)), vec2(1.0, 2.0).hash() == hash(vec2(1.0, 2.0)))
}
