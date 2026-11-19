// examples/gfx_parallax (a procedural pixel-art landscape on std.gfx) without a window: the
// art is painted and uploaded, then 400 frames are drawn offscreen at 1440 x 810, one fixed
// step each (scene render texture, mirrored lake rows, additive glows, text). Nobody plays,
// so after 4 seconds the attract mode walks; what is printed depends only on the seed (the
// wanderer's position, the clock, a hash of the world) and on no draw being dropped, not on
// the GPU. Without a device it says why and ends with status 77 (SKIP).
use "../../examples/gfx_parallax/game.al"
