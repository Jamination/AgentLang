// config_parse ignored "[video]   ; display settings": a comment after white space is allowed on every line
// by the doc, but a header only counted if the line ended in "]"; the keys below went to the previous section.
// expected: [a, video.width, audio.volume]   actual (before the fix): [a, width, volume]
use std.asset
fn main() {
    c := config_parse("a = 1\n[video]   ; display settings\nwidth = 1920\n[audio] # sound\nvolume = 0.5\n")
    print(c.keys.items())
}
