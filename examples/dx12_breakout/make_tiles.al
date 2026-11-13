// Draws tiles.png, the sprite sheet of the breakout example (the game embeds the file and
// decodes it with std.image). Run it from the repository root after changing the art:
//   alc run examples/dx12_breakout/make_tiles.al
// The sheet is 64 x 32 RGBA: bricks are drawn in grey and tinted per row by the game.
//   (0, 0) brick 24 x 8   (24, 0) armoured brick   (0, 8) cracked brick
//   (0, 16) paddle 36 x 6   (40, 16) ball 6 x 6
use std.image

fn grey(v: f32) -> vec4 {
    vec4(v, v, v, 1.0)
}

// a bevelled brick: light top and left edges, dark bottom and right edges
fn brick(img: *Image, x0: i64, y0: i64) {
    for y in 0..8 {
        for x in 0..24 {
            v := if y == 0 || x == 0 { 1.0 } else if y == 7 || x == 23 { 0.55 } else { 0.82 }
            img.set(x0 + x, y0 + y, grey(v))
        }
    }
}

fn main() {
    img := image_new(64, 32, 4)
    brick(&img, 0, 0)
    // armoured: rivets in the corners and a darker middle band
    brick(&img, 24, 0)
    for p in [_](i64, i64){(2, 2), (21, 2), (2, 5), (21, 5)} {
        img.set(24 + p.0, p.1, grey(0.4))
    }
    for x in 5..19 {
        img.set(24 + x, 3, grey(0.68))
        img.set(24 + x, 4, grey(0.68))
    }
    // cracked: a jagged dark line across
    brick(&img, 0, 8)
    crack := [_](i64, i64){(4, 1), (5, 2), (6, 3), (7, 3), (8, 4), (9, 5), (10, 4), (11, 3), (12, 3), (13, 4),
        (14, 5), (15, 6), (16, 5), (17, 4), (18, 4), (19, 3)}
    for p in crack {
        img.set(p.0, 8 + p.1, grey(0.3))
    }
    // the paddle: a rounded bar, light on top
    for y in 0..6 {
        for x in 0..36 {
            edge := x == 0 || x == 35
            if edge && (y == 0 || y == 5) {
                continue
            }
            t := f32(y) / 5.0
            img.set(x, 16 + y, vec4(lerp(0.85, 0.35, t), lerp(0.95, 0.55, t), 1.0, 1.0))
        }
    }
    // the ball: a disc with a highlight
    for y in 0..6 {
        for x in 0..6 {
            d := length(vec2(f32(x) - 2.5, f32(y) - 2.5))
            if d <= 3.0 {
                h := length(vec2(f32(x) - 1.5, f32(y) - 1.5))
                img.set(40 + x, 16 + y, grey(clamp(1.1 - h * 0.15, 0.6, 1.0)))
            }
        }
    }
    if !png_save("examples/dx12_breakout/tiles.png", img) {
        eprint("cannot write examples/dx12_breakout/tiles.png")
        exit(1)
    }
    print("wrote examples/dx12_breakout/tiles.png")
}
