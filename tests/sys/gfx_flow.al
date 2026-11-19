// examples/gfx_flow (generative art: particles in a curl-noise flow field, trails by
// render-texture feedback) offscreen at 640 x 360 for 240 frames, one simulation step per
// frame: a cross-fade from Aurora to Solar wind, a reseed, the mouse pulling at the centre.
// Every frame's passes are drawn (fade, segments, bloom, final picture); what is printed is
// the particles' checksum (the simulation alone, the same on every GPU), their number and the
// quads std.gfx dropped (none: GfxDesc.max_quads covers the segments). Without a device it
// says why and ends with status 77 (SKIP).
use "../../examples/gfx_flow/game.al"
