// config_parse: a section header followed by white space and a comment is still a header (the
// comment rule of the doc holds on every line); its keys used to land in the previous section
use std.asset

fn main() {
    c := config_parse("a = 1\n[video]   ; display settings\nwidth = 1920\n[audio] # sound\nvolume = 0.5\n[x]#y\nk = 1\n[s] = 5\n[\n[ spaced ]\nz = 2\n")
    print(c.keys.items())
    print(c.get_i64("video.width", 0), c.get_f64("audio.volume", 0.0), c.get_str("[s]", "?"))
}
