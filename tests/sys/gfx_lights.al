// examples/gfx_lights (2D lights with soft shadows on std.gfx) without a window: the art is
// baked, 120 steps of the scripted run are simulated (lights added and removed by clicks) and
// every step is drawn offscreen (light map, visibility polygons, the three channel products,
// glows, text). What it prints comes from the simulation and the batcher only (the checksum
// of the state, nothing dropped), not from the GPU or the clock. Without a device for std.gfx
// it says why and ends with status 77 (SKIP).
use "../../examples/gfx_lights/game.al"
