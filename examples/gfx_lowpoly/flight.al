// The automatic flight of examples/gfx_lowpoly: an aircraft that follows a winding course of
// summed sine waves, climbs over what lies ahead, banks into its turns, and a chase camera
// that trails it with a lag (so the aircraft swings across the frame in a turn) and rolls a
// little with it. Advanced in fixed steps: the same seed and step count give the same picture.

const BASE_SPEED: f32 = 8.5      // units per second at speed 1
const CLEARANCE: f32 = 5.0       // over the highest ground ahead
const CHASE_BACK: f32 = 7.0      // the camera behind the aircraft
const CHASE_UP: f32 = 3.0        // and above it
const CHASE_SIDE: f32 = 2.6      // and to its side: a three-quarter view

struct Flight {
    t: f64
    pos: vec3            // the aircraft
    heading: f32         // radians; 0 flies towards +z
    turn: f32            // radians per second (positive: to the left)
    vy: f32              // climb rate
    bank: f32
    speed: f32           // multiplier, W / S
    eye: vec3            // the camera
    cam_heading: f32
    look_yaw: f32        // mouse look, added to the camera's direction
    look_pitch: f32
    prop: f32            // propeller angle
}

// Where the camera is and what it shows: what the renderer needs, interpolated between steps.
struct Pose {
    eye: vec3
    target: vec3
    up: vec3
    plane: PlaneState
}

fn flight_new(w: *World) -> Flight {
    f := Flight{heading: 0.9, speed: 1.0}
    f.pos = vec3(0.5, 0.0, 0.5)
    fwd := heading_dir(f.heading)
    f.pos.y = alt_target(w, f.pos, fwd)
    f.cam_heading = f.heading
    f.eye = f.pos - fwd * CHASE_BACK + vec3(0.0, CHASE_UP, 0.0)
    f
}

inline fn heading_dir(h: f32) -> vec3 {
    vec3(sin(h), 0.0, cos(h))
}

// The height to fly at: clear of the highest ground on the next 40 units of the course (and
// a little to the sides), never low over the sea.
fn alt_target(w: *World, p: vec3, fwd: vec3) -> f32 {
    side := vec3(fwd.z, 0.0, -fwd.x)
    top := SEA_LEVEL + 3.0
    for k in 0..11 {
        q := p + fwd * (f32(k) * 4.0)
        for j in -1..=1 {
            r := q + side * (f32(j) * 3.0)
            top = fmax(top, terrain_height(w.seed, r.x, r.z))
        }
    }
    top + CLEARANCE
}

fn flight_step(f: *Flight, w: *World, dt: f32, dragging: bool) {
    f.t += f64(dt)
    t := f32(f.t)
    // the heading wanders around a mean direction (the turn rate is the derivative of a sum of
    // sines, so the course never loops back over itself)
    f.turn = 0.040 * cos(t * 0.031) + 0.050 * cos(t * 0.077 + 1.0) + 0.045 * cos(t * 0.19 + 2.0)
    f.heading += f.turn * dt
    fwd := heading_dir(f.heading)
    v := BASE_SPEED * f.speed
    f.pos = f.pos + fwd * (v * dt)
    // climb towards the target height, smoothly and at a limited rate
    want := clamp((alt_target(w, f.pos, fwd) - f.pos.y) * 0.9, -3.0, 6.0)
    f.vy += (want - f.vy) * (1.0 - exp(-2.5 * dt))
    f.pos.y += f.vy * dt
    f.bank += (clamp(f.turn * 4.5, -0.7, 0.7) - f.bank) * (1.0 - exp(-2.0 * dt))
    // the chase camera
    f.cam_heading += wrap_angle(f.heading - f.cam_heading) * (1.0 - exp(-1.1 * dt))
    cf := heading_dir(f.cam_heading)
    side := vec3(-cf.z, 0.0, cf.x)
    want_eye := f.pos - cf * CHASE_BACK + side * CHASE_SIDE + vec3(0.0, CHASE_UP, 0.0)
    f.eye = lerp(f.eye, want_eye, 1.0 - exp(-4.0 * dt))
    f.eye.y = fmax(f.eye.y, fmax(ground(w, 0, f.eye.x, f.eye.z) + 1.5, SEA_LEVEL + 1.0))
    if !dragging {
        k := 1.0 - exp(-1.5 * dt)                 // the view drifts back to the course
        f.look_yaw -= f.look_yaw * k
        f.look_pitch -= f.look_pitch * k
    }
    f.prop = fmod(f.prop + dt * 37.0, TAU)
}

// The pose between steps a and b (alpha 0: a, 1: b).
fn pose_of(a: *Flight, b: *Flight, alpha: f32) -> Pose {
    pos := lerp(a.pos, b.pos, alpha)
    heading := a.heading + wrap_angle(b.heading - a.heading) * alpha
    cam_heading := a.cam_heading + wrap_angle(b.cam_heading - a.cam_heading) * alpha
    bank := lerp(a.bank, b.bank, alpha)
    vy := lerp(a.vy, b.vy, alpha)
    eye := lerp(a.eye, b.eye, alpha)
    // the aircraft's frame: pitched by its climb, rolled by its bank
    pitch := atan2(vy, BASE_SPEED * b.speed)
    up0 := vec3(0.0, 1.0, 0.0)
    fwd := normalize(heading_dir(heading) * cos(pitch) + up0 * sin(pitch))
    r0 := normalize(cross(fwd, up0))
    u0 := cross(r0, fwd)
    right := r0 * cos(bank) + u0 * sin(bank)
    up := u0 * cos(bank) - r0 * sin(bank)
    // the camera looks past the aircraft along the course, turned by the mouse
    cf := heading_dir(cam_heading)
    look := normalize(pos + cf * 9.0 - vec3(0.0, 1.2, 0.0) - eye)
    yaw := b.look_yaw
    pitch_l := b.look_pitch
    look = normalize(vec3(look.x * cos(yaw) + look.z * sin(yaw), look.y, -look.x * sin(yaw) + look.z * cos(yaw)))
    el := clamp(asin(look.y) + pitch_l, -1.3, 1.3)
    flat := normalize(vec3(look.x, 0.0, look.z))
    look = flat * cos(el) + up0 * sin(el)
    // and rolls with the bank, less than the aircraft
    cr := normalize(cross(look, up0))
    cu := cross(cr, look)
    roll := bank * 0.3
    cam_up := cu * cos(roll) - cr * sin(roll)
    Pose{eye: eye, target: eye + look, up: cam_up,
        plane: PlaneState{pos: pos, right: right, up: up, fwd: fwd, prop: b.prop}}
}
