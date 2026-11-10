// geometry tests, easing curves and colour helpers of the math library
var fails i64

fn ok(name str, c bool) {
    if !c {
        fails += 1
        print("FAILED:", name)
    }
}

fn main() {
    box := Aabb{min: vec3(-1.0), max: vec3(1.0)}
    far := Aabb{min: vec3(2.0, 0.0, 0.0), max: vec3(5.0, 1.0, 1.0)}
    touch := Aabb{min: vec3(1.0, -1.0, -1.0), max: vec3(3.0, 0.0, 0.0)}
    ball := Sphere{center: vec3(0.0, 0.0, -5.0), radius: 1.0}
    floor_ := Plane{normal: vec3(0.0, 1.0, 0.0), d: -2.0}
    ok("contains", contains(box, vec3(0.5)) && contains(box, vec3(1.0)) && !contains(box, vec3(1.5, 0.0, 0.0)) && contains(ball, vec3(0.0, 0.5, -5.0)) && !contains(ball, vec3(0.0)))
    ok("intersects aabb", !intersects(box, far) && intersects(box, touch) && intersects(box, box) && intersects(far, Aabb{min: vec3(4.0, 0.5, 0.5), max: vec3(9.0)}))
    ok("intersects sphere", intersects(ball, Sphere{center: vec3(0.0, 0.0, -3.5), radius: 0.6}) && !intersects(ball, Sphere{center: vec3(0.0, 0.0, -3.0), radius: 0.5}) && intersects(ball, ball))
    u := aabb_union(box, far)
    ok("union", u.min == vec3(-1.0) && u.max == vec3(5.0, 1.0, 1.0))
    ok("closest aabb", closest_point(box, vec3(3.0, 0.5, -4.0)) == vec3(1.0, 0.5, -1.0) && closest_point(box, vec3(0.25)) == vec3(0.25))
    ok("closest sphere", approx_eq(closest_point(ball, vec3(0.0, 0.0, 0.0)), vec3(0.0, 0.0, -4.0)) && approx_eq(closest_point(ball, vec3(0.0, 9.0, -5.0)), vec3(0.0, 1.0, -5.0)))
    ok("closest plane", closest_point(floor_, vec3(3.0, 7.0, 4.0)) == vec3(3.0, -2.0, 4.0) && closest_point(floor_, vec3(1.0, -2.0, 1.0)) == vec3(1.0, -2.0, 1.0))
    ray := Ray{origin: vec3(0.0, 0.0, 5.0), dir: vec3(0.0, 0.0, -1.0)}
    ok("closest ray", closest_point(ray, vec3(3.0, 0.0, 1.0)) == vec3(0.0, 0.0, 1.0) && closest_point(ray, vec3(3.0, 0.0, 9.0)) == ray.origin)
    t, hit := ray_hit(ray, box)
    ok("ray aabb", hit && t == 4.0)
    t2, hit2 := ray_hit(Ray{origin: vec3(0.0), dir: vec3(1.0, 0.0, 0.0)}, box)
    ok("ray inside aabb", hit2 && t2 == 0.0)
    t3, hit3 := ray_hit(Ray{origin: vec3(0.0, 3.0, 5.0), dir: vec3(0.0, 0.0, -1.0)}, box)
    t4, hit4 := ray_hit(Ray{origin: vec3(0.0, 0.0, 5.0), dir: vec3(0.0, 0.0, 1.0)}, box)
    ok("ray misses aabb", !hit3 && !hit4)
    td, hitd := ray_hit(Ray{origin: vec3(-3.0, -3.0, 0.0), dir: normalize(vec3(1.0, 1.0, 0.0))}, box)
    ok("ray aabb diagonal", hitd && approx_eq(td, 2.828427))
    ts, hits := ray_hit(ray, ball)
    ok("ray sphere", hits && approx_eq(ts, 9.0))
    ts2, hits2 := ray_hit(Ray{origin: vec3(2.0, 0.0, 5.0), dir: vec3(0.0, 0.0, -1.0)}, ball)
    ts3, hits3 := ray_hit(Ray{origin: vec3(0.0, 0.0, -5.0), dir: vec3(0.0, 1.0, 0.0)}, ball)
    ok("ray sphere miss / inside", !hits2 && hits3)
    tp, hitp := ray_hit(Ray{origin: vec3(1.0, 3.0, 1.0), dir: vec3(0.0, -1.0, 0.0)}, floor_)
    tp2, hitp2 := ray_hit(Ray{origin: vec3(1.0, 3.0, 1.0), dir: vec3(0.0, 1.0, 0.0)}, floor_)
    tp3, hitp3 := ray_hit(Ray{origin: vec3(1.0, 3.0, 1.0), dir: vec3(1.0, 0.0, 0.0)}, floor_)
    ok("ray plane", hitp && tp == 5.0 && !hitp2 && !hitp3)

    // ---- easing: every curve starts at 0 and ends at 1 ----
    curves := [9]fn(f32) f32{ease_in_quad, ease_out_quad, ease_in_out_quad, ease_in_cubic, ease_out_cubic, ease_in_out_cubic, ease_out_elastic, ease_out_bounce, ease_out_back}
    for i, f in curves {
        ok(fmt("ease ends ", i), approx_eq(f(0.0), 0.0) && approx_eq(f(1.0), 1.0))
    }
    ok("ease quad", ease_in_quad(0.5) == 0.25 && ease_out_quad(0.5) == 0.75 && ease_in_out_quad(0.5) == 0.5 && ease_in_out_quad(0.25) == 0.125)
    ok("ease cubic", ease_in_cubic(0.5) == 0.125 && ease_out_cubic(0.5) == 0.875 && ease_in_out_cubic(0.5) == 0.5 && ease_in_out_cubic(0.25) == 0.0625)
    mono := true
    for i in 0..5 {
        f := curves[i]
        var prev f32 = 0.0
        for k in 1..=100 {
            v := f(f32(k) / 100.0)
            mono = mono && v >= prev
            prev = v
        }
    }
    ok("ease monotonic", mono)
    ok("ease overshoot", ease_out_back(0.6) > 1.0 && ease_out_elastic(0.15) > 1.0 && ease_out_bounce(0.5) < 1.0 && ease_out_bounce(0.5) > 0.5)

    // ---- colour ----
    red := vec3(1.0, 0.0, 0.0)
    ok("hsv primaries", rgb_to_hsv(red) == vec3(0.0, 1.0, 1.0) && approx_eq(rgb_to_hsv(vec3(0.0, 1.0, 0.0)), vec3(0.33333334, 1.0, 1.0)) && approx_eq(rgb_to_hsv(vec3(0.0, 0.0, 1.0)), vec3(0.6666667, 1.0, 1.0)))
    ok("hsv grey", rgb_to_hsv(vec3(0.5)) == vec3(0.0, 0.0, 0.5) && hsv_to_rgb(vec3(0.3, 0.0, 0.25)) == vec3(0.25))
    ok("hsv back", approx_eq(hsv_to_rgb(vec3(0.0, 1.0, 1.0)), red) && approx_eq(hsv_to_rgb(vec3(0.5, 1.0, 1.0)), vec3(0.0, 1.0, 1.0)) && approx_eq(hsv_to_rgb(vec3(0.16666667, 0.5, 0.8)), vec3(0.8, 0.8, 0.4)))
    trip := true
    r := rng(7)
    for i in 0..200 {
        c := vec3(r.next_f32(), r.next_f32(), r.next_f32())
        trip = trip && approx_eq(hsv_to_rgb(rgb_to_hsv(c)), c, 0.00001) && approx_eq(linear_to_srgb(srgb_to_linear(c)), c, 0.00001)
    }
    ok("colour round trips", trip)
    var half f32 = 0.5
    ok("srgb", srgb_to_linear(half - half) == 0.0 && approx_eq(srgb_to_linear(half + half), 1.0) && approx_eq(srgb_to_linear(half), 0.21404114) && approx_eq(linear_to_srgb(half), 0.7353569) && approx_eq(srgb_to_linear(half / 20.0), 0.0019349845))
    ok("pack", color_u32(vec4(1.0, 0.5, 0.0, 1.0)) == 0xFF0080FF && color_u32(vec4(2.0, -1.0, 0.25, 0.0)) == 0x004000FF && color_u32(vec4(0.0)) == 0 && color_u32(vec4(1.0)) == 0xFFFFFFFF)
    ok("unpack", approx_eq(color_vec4(0xFF0080FF), vec4(1.0, 0.5019608, 0.0, 1.0)) && color_u32(color_vec4(0x12345678)) == 0x12345678)
    print("math_geom failures:", fails)
}
