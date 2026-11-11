Shape :: enum { Ball(vec3, f32), Box(vec3, vec3), Empty }
Particle :: struct { pos: vec3, vel: vec3, life: f32, col: vec4 }
center :: (s: Shape) -> vec3 {
    match s {
        Ball(c, r) => c
        Box(lo, hi) => (lo + hi) * 0.5
        Empty => vec3(0.0)
    }
}
pair :: (a: vec2, b: f32) -> (vec2, f32, vec4) {
    return (a * b, b + 1.0, vec4(a, b, 1.0))
}
sum[T] :: (xs: []T, zero: T) -> T {
    s := zero
    for x in xs {
        s = s + x
    }
    return s
}
many :: (a: vec3, b: vec3, c: vec3, d: vec3, e: vec3, f: vec3, g: vec3, h: vec3, i: vec3, j: vec4, k: f32, l: f64) -> vec4 {
    return vec4(a + b + c + d + e + f + g + h + i, k) + j * f32(l)
}
main :: () {
    v := vec[vec3]()
    for i in 0..5 {
        v.push(vec3(f32(i), 1.0, -f32(i)))
    }
    print(sum(v.items(), vec3(0.0)), sum([]f32{1.5, 2.5}, 0.0), len(v.items()))
    shapes := []Shape{Ball(vec3(1.0, 2.0, 3.0), 2.0), Box(vec3(0.0), vec3(2.0, 4.0, 6.0)), Empty}
    for s in shapes {
        print(center(s), s)
    }
    a, b, c := pair(vec2(1.0, 2.0), 3.0)
    print(a, b, c)
    t := (vec3(1.0), 2, vec2(0.5))
    print(t, t.0.z, t.2.y)
    ps := alloc[Particle](3)
    for i, p in ps {
        ps[i].pos = vec3(f32(i))
        ps[i].vel.y = 2.0
        ps[i].col.a = 1.0
        ps[i].life = 0.5
    }
    for i in 0..3 {
        ps[i].pos = ps[i].pos + ps[i].vel * ps[i].life
    }
    print(ps[2], ps[1].pos.y)
    pp := &ps[0]
    pp.vel.x += 3.0
    pp.pos = pp.pos + pp.vel
    print(pp.pos, pp.vel.xy)
    x := vec3(1.0, 2.0, 3.0)
    px := &x
    px.y = 9.0
    print(*px, px.z, many(x, x, x, x, x, x, x, x, x, vec4(1.0), 2.0, 0.5))
    m: mat4
    m[0][0] = 2.0
    m[1].y = 3.0
    m[2] = vec4(0.0, 0.0, 4.0, 0.0)
    m[3][3] = 1.0
    mp := &m
    print(m * vec4(1.0), mp[1], m == m, m != mat4(1.0))
    grid: [2][2]vec2
    grid[1][0] = vec2(5.0, 6.0)
    grid[1][0].x += 1.0
    print(grid, if x.x < 2.0 { vec2(1.0) } else { vec2(2.0) })
    q := quat(0.0, 0.0, 0.0, 1.0)
    q.w = 0.5
    print(q, q + q, q * 2.0, vec4(q).w)
}
