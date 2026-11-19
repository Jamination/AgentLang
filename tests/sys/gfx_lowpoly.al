// examples/gfx_lowpoly (a 3D landscape drawn with nothing but std.gfx triangles) offscreen with
// the backend of the target: after 600 steps of its automatic flight one frame at each time of
// day, printing the triangles it sent, the vertices std.gfx took and that none were dropped
// (all decided on the CPU: the same on every GPU), and where the aircraft is. Without a device
// it says why and ends with status 77 (SKIP).
use "../../examples/gfx_lowpoly/game.al"
