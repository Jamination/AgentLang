// A camera looking at a spinning cube corner: the math library end to end.
fn main() {
    eye := vec3(3.0, 2.0, 5.0)
    view := look_at(eye, vec3(0.0), vec3(0.0, 1.0, 0.0))
    proj := perspective(radians(60.0), 16.0 / 9.0, 0.1, 100.0)
    spin := quat_axis_angle(normalize(vec3(0.0, 1.0, 0.0)), radians(45.0))
    model := mat4_trs(vec3(0.0, 0.5, 0.0), spin, vec3(1.0))
    mvp := proj * view * model

    corner := vec3(1.0, 1.0, 1.0)
    ndc := project_point(mvp, corner)
    put("corner in clip space: ")
    putf(ndc.x, 3)
    put(" ")
    putf(ndc.y, 3)
    put(" ")
    putf(ndc.z, 3)
    put("\n")

    // a ray from the camera through the middle of the screen against the cube's bounds
    ray := Ray{origin: eye, dir: normalize(vec3(0.0) - eye)}
    t, hit := ray_hit(ray, Aabb{min: vec3(-1.0), max: vec3(1.0)})
    put("ray hits the cube: ", hit, " at distance ")
    putf(t, 3)
    put("\n")

    // interpolation and easing for animation
    from := quat_identity()
    half := slerp(from, spin, ease_in_out_cubic(0.5))
    axis, angle := axis_angle(half)
    put("halfway rotation: ")
    putf(degrees(angle), 1)
    put(" degrees around y=")
    putf(axis.y, 1)
    put("\n")
    print("sin(30 deg) =", fmtf(sin(radians(30.0)), 6), " atan2(1, 1) =", fmtf(atan2(1.0, 1.0), 6))
}
