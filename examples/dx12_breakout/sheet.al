// Where everything is in tiles.png, the breakout's sprite sheet: make_tiles.al draws the sheet
// by these numbers and the renderer reads it by them. Pure AL (constants only).
//
// The art is drawn at SHEET_SCALE texels per pixel of the game's 320 x 180 view and sampled
// with bilinear filtering, so it stays smooth in a window of any size. Colours are straight
// RGBA; the game premultiplies the alpha when it loads the sheet.
//
//   y 0     six brick bodies (one per row of the wall), the armour plate, two crack overlays
//   y 40    paddle, ball, glow, flare, shards, soft box, beam, streak, white, rail, corner,
//           panel fill, panel edge, ring
//   y 176   empty in the file: the game puts the letters of a system font there (glyphs.al)

const SHEET_W = 1024
const SHEET_H = 176                      // the sprites (the letters go below them: LETTERS_Y)
const SHEET_SCALE = 4                    // texels per view pixel

// A rectangle of the sheet, in texels.
struct Tile { x: f32, y: f32, w: f32, h: f32 }

// A brick tile is 26 x 10 view pixels: the 24 x 8 cell of the brick and one pixel around it
// (the body itself is inset, which leaves a dark seam between neighbours).
const BRICK_TILE_W = 104
const BRICK_TILE_H = 40
const BRICK_MARGIN: f32 = 1.0            // view pixels from the tile's edge to the brick cell

fn tile_brick(row: i64) -> Tile { Tile{f32(row * BRICK_TILE_W), 0.0, f32(BRICK_TILE_W), f32(BRICK_TILE_H)} }

const TILE_ARMOUR = Tile{624.0, 0.0, 104.0, 40.0}
const TILE_CRACK1 = Tile{728.0, 0.0, 104.0, 40.0}
const TILE_CRACK2 = Tile{832.0, 0.0, 104.0, 40.0}

// The paddle tile is 40 x 10 view pixels around the 36 x 6 paddle.
const TILE_PADDLE = Tile{0.0, 40.0, 160.0, 40.0}
const PADDLE_MARGIN_X: f32 = 2.0
const PADDLE_MARGIN_Y: f32 = 2.0
// The ball tile is 8 x 8 view pixels around the ball (radius 3).
const TILE_BALL = Tile{160.0, 40.0, 32.0, 32.0}
const TILE_GLOW = Tile{192.0, 40.0, 64.0, 64.0}       // a round soft glow, white
const TILE_FLARE = Tile{256.0, 40.0, 64.0, 64.0}      // a four-pointed star, white
const SHARD_COUNT = 4
fn tile_shard(k: i64) -> Tile { Tile{320.0 + f32(k % SHARD_COUNT) * 24.0, 40.0, 24.0, 24.0} }
const TILE_SOFTBOX = Tile{416.0, 40.0, 64.0, 32.0}    // a rounded box with a soft edge (halos)
const TILE_BEAM = Tile{488.0, 40.0, 0.0, 32.0}        // across: a thin line in a glow (stretched along)
const TILE_STREAK = Tile{496.0, 40.0, 64.0, 16.0}     // a spark seen in motion
const TILE_WHITE = Tile{500.0, 60.0, 8.0, 8.0}
const TILE_RAIL = Tile{488.0, 80.0, 0.0, 24.0}        // across: the metal rail of the frame
const TILE_CORNER = Tile{496.0, 72.0, 32.0, 32.0}     // the block where two rails meet
const TILE_PANEL = Tile{560.0, 40.0, 64.0, 64.0}      // a rounded panel (nine slices of 16)
const TILE_EDGE = Tile{624.0, 40.0, 64.0, 64.0}       // its glowing outline
const PANEL_CORNER: f32 = 16.0                        // texels of a panel corner slice
const TILE_RING = Tile{688.0, 40.0, 128.0, 128.0}     // a thin ring (shock waves)

// The letters: glyphs.al writes them below the sprites at start-up, into a sheet LETTERS_H
// texels high (the font is the machine's: it is not in tiles.png).
const LETTERS_Y = 176
const LETTERS_H = 1024
const FONT_SPREAD: f32 = 2.0             // font pixels from a glyph's edge to alpha 0 or 1

// The colours of the six rows of bricks, top to bottom: light, base and shadow (RGB 0..1). The
// sheet bakes them into the bricks; the game uses them for the light a brick gives off and the
// pieces it breaks into.
fn brick_light(row: i64) -> vec3 {
    match row {
        0 => vec3(1.0, 0.62, 0.72)
        1 => vec3(1.0, 0.80, 0.52)
        2 => vec3(1.0, 0.96, 0.62)
        3 => vec3(0.70, 1.0, 0.70)
        4 => vec3(0.62, 0.90, 1.0)
        _ => vec3(0.82, 0.68, 1.0)
    }
}

fn brick_base(row: i64) -> vec3 {
    match row {
        0 => vec3(1.0, 0.18, 0.40)
        1 => vec3(1.0, 0.48, 0.12)
        2 => vec3(1.0, 0.80, 0.16)
        3 => vec3(0.26, 0.90, 0.36)
        4 => vec3(0.16, 0.66, 1.0)
        _ => vec3(0.58, 0.32, 1.0)
    }
}

fn brick_shadow(row: i64) -> vec3 {
    match row {
        0 => vec3(0.40, 0.02, 0.20)
        1 => vec3(0.48, 0.10, 0.06)
        2 => vec3(0.54, 0.26, 0.02)
        3 => vec3(0.02, 0.32, 0.20)
        4 => vec3(0.04, 0.16, 0.48)
        _ => vec3(0.20, 0.06, 0.46)
    }
}
