// A 5 x 7 pixel bitmap font, drawn here as text (no font file), baked into a sprite atlas at
// start-up. Upper case letters, digits and common punctuation; lower case letters are shown
// as upper case, bytes outside ASCII as '?', other characters without a glyph as a blank. Pure
// AL (std.image only): the drawing half is in screen.al, whose sprite batcher needs Windows.
use std.image

const GLYPH_W = 5
const GLYPH_H = 7
const GLYPH_ADVANCE = 6         // pixels from one character to the next (at scale 1)
const LINE_ADVANCE = 9
const FONT_CELL = 8             // each glyph has an 8 x 8 cell in the atlas, 16 cells per row
const FONT_ATLAS_W = 16 * FONT_CELL
const FONT_ATLAS_H = 6 * FONT_CELL   // characters 32..127

// Where the font was baked into an atlas.
struct Font { x: i64, y: i64 }

// A line with one character starts a glyph; the 7 lines after it are its rows ('#' = ink).
priv const GLYPHS = `
A
.###.
#...#
#...#
#####
#...#
#...#
#...#
B
####.
#...#
#...#
####.
#...#
#...#
####.
C
.###.
#...#
#....
#....
#....
#...#
.###.
D
####.
#...#
#...#
#...#
#...#
#...#
####.
E
#####
#....
#....
####.
#....
#....
#####
F
#####
#....
#....
####.
#....
#....
#....
G
.###.
#...#
#....
#.###
#...#
#...#
.####
H
#...#
#...#
#...#
#####
#...#
#...#
#...#
I
.###.
..#..
..#..
..#..
..#..
..#..
.###.
J
..###
...#.
...#.
...#.
...#.
#..#.
.##..
K
#...#
#..#.
#.#..
##...
#.#..
#..#.
#...#
L
#....
#....
#....
#....
#....
#....
#####
M
#...#
##.##
#.#.#
#.#.#
#...#
#...#
#...#
N
#...#
#...#
##..#
#.#.#
#..##
#...#
#...#
O
.###.
#...#
#...#
#...#
#...#
#...#
.###.
P
####.
#...#
#...#
####.
#....
#....
#....
Q
.###.
#...#
#...#
#...#
#.#.#
#..#.
.##.#
R
####.
#...#
#...#
####.
#.#..
#..#.
#...#
S
.####
#....
#....
.###.
....#
....#
####.
T
#####
..#..
..#..
..#..
..#..
..#..
..#..
U
#...#
#...#
#...#
#...#
#...#
#...#
.###.
V
#...#
#...#
#...#
#...#
#...#
.#.#.
..#..
W
#...#
#...#
#...#
#.#.#
#.#.#
#.#.#
.#.#.
X
#...#
#...#
.#.#.
..#..
.#.#.
#...#
#...#
Y
#...#
#...#
.#.#.
..#..
..#..
..#..
..#..
Z
#####
....#
...#.
..#..
.#...
#....
#####
0
.###.
#...#
#..##
#.#.#
##..#
#...#
.###.
1
..#..
.##..
..#..
..#..
..#..
..#..
.###.
2
.###.
#...#
....#
...#.
..#..
.#...
#####
3
####.
....#
....#
.###.
....#
....#
####.
4
...#.
..##.
.#.#.
#..#.
#####
...#.
...#.
5
#####
#....
####.
....#
....#
#...#
.###.
6
..##.
.#...
#....
####.
#...#
#...#
.###.
7
#####
....#
...#.
..#..
.#...
.#...
.#...
8
.###.
#...#
#...#
.###.
#...#
#...#
.###.
9
.###.
#...#
#...#
.####
....#
...#.
.##..
.
.....
.....
.....
.....
.....
.##..
.##..
,
.....
.....
.....
.....
.##..
..#..
.#...
:
.....
.##..
.##..
.....
.##..
.##..
.....
!
..#..
..#..
..#..
..#..
..#..
.....
..#..
?
.###.
#...#
....#
...#.
..#..
.....
..#..
-
.....
.....
.....
#####
.....
.....
.....
+
.....
..#..
..#..
#####
..#..
..#..
.....
/
....#
....#
...#.
..#..
.#...
#....
#....
%
##..#
##..#
...#.
..#..
.#...
#..##
#..##
(
...#.
..#..
.#...
.#...
.#...
..#..
...#.
)
.#...
..#..
...#.
...#.
...#.
..#..
.#...
'
..#..
..#..
.#...
.....
.....
.....
.....
<
...#.
..#..
.#...
#....
.#...
..#..
...#.
>
.#...
..#..
...#.
....#
...#.
..#..
.#...
=
.....
.....
#####
.....
#####
.....
.....
*
.....
#.#.#
.###.
#####
.###.
#.#.#
.....
`

// Draws the glyphs in white (alpha = ink) into `img` (4 channels) with the cell of character
// c at (x + (c - 32) % 16 * 8, y + (c - 32) / 16 * 8); the area must be FONT_ATLAS_W x
// FONT_ATLAS_H pixels and transparent.
fn font_bake(img: *Image, x: i64, y: i64) -> Font {
    rows := lines(trim(GLYPHS))
    i := 0
    while i + GLYPH_H < len(rows) {
        assert len(rows[i]) == 1, fmt("font: glyph header expected: ", rows[i])
        cx, cy := cell(Font{x, y}, rows[i][0])
        for r in 0..GLYPH_H {
            row := rows[i + 1 + r]
            for col in 0..GLYPH_W {
                if row[col] == '#' {
                    img.set(cx + col, cy + r, vec4(1.0))
                }
            }
        }
        i += 1 + GLYPH_H
    }
    Font{x, y}
}

// Top left corner of the glyph of byte c in the atlas ('?' for what the font does not have).
fn cell(f: Font, c: u8) -> (i64, i64) {
    if c >= 'a' && c <= 'z' {
        c -= 32
    }
    if c < 32 || c > 127 {
        c = '?'
    }
    k := i64(c) - 32
    (f.x + k % 16 * FONT_CELL, f.y + k / 16 * FONT_CELL)
}

// Width in pixels of a line of text at `scale` (without the gap after the last character).
fn text_width(text: str, scale: f32) -> f32 {
    if len(text) == 0 { 0.0 } else { f32(len(text) * GLYPH_ADVANCE - 1) * scale }
}
