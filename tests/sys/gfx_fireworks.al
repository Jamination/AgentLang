// examples/gfx_fireworks (a fireworks show on std.gfx) for 600 frames offscreen, one simulation
// step each: the whole pipeline on the GPU (the bright pass and the bloom chain of render
// textures, the scene texture drawn again mirrored in strips for the water, text), nothing
// dropped, no memory growing from frame to frame, and the show's counts and checksum, which
// depend only on the seed (the same on the first device and on WARP). Without a device it says
// why and ends with status 77 (SKIP).
use "../../examples/gfx_fireworks/game.al"
