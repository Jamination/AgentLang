Vert :: struct { pos: vec3, uv: vec2, col: vec4 }
up := vec3(0.0, 1.0, 0.0)
dot3 :: (a: vec3, b: vec3) -> f32 {
    m := a * b
    return m.x + m.y + m.z
}
main :: () {
    x: f32 = 1.5
    y := x * 2.0 + 0.25
    print(x, y, f64(y), i64(y), f32(7), sqrt(y), -y, fabs(-y))
    z: f32 = 0.1
    print(z, z + z + z, f32(1) / 3.0, cast[u32](z))
    a := vec3(1.0, 2.0, 3.0)
    b := vec3(4.0)
    c := a + b * 2.0 - a / 2.0
    print(a, b, c, -c, c.zyx, c.xy, dot3(a, b), up)
    c.y = 100.0
    c.z += 1.0
    print(c, c[0], c == c, a == b, a != b)
    v4 := vec4(a, 1.0)
    print(v4, vec3(v4), vec4(c.xy, 7.0, 8.0), sizeof[vec3](), sizeof[Vert](), sizeof[mat4]())
    arr: [4]vec3
    for i in 0..4 {
        arr[i] = vec3(f32(i), f32(i) * 2.0, 1.0)
    }
    s := vec3(0.0)
    for i in 0..4 {
        s = s + arr[i]
    }
    print(s, arr[2].y)
    m := mat4(1.0)
    m[3] = vec4(1.0, 2.0, 3.0, 1.0)
    p := m * vec4(1.0, 1.0, 1.0, 1.0)
    print(m, p, (m * m)[3])
    q := quat(0.0, 0.0, 0.70710677, 0.70710677)
    print(q * vec3(1.0, 0.0, 0.0), q * q)
    vt := Vert{pos: a, uv: vec2(0.5, 0.25), col: v4}
    print(vt)
    i := 2
    print(a[i], fmin(x, 1.0), fmax(2.0, x), fmin(a, b))
}
