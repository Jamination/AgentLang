// A declaration rejected as a duplicate is the only error: what would follow from it (its
// type, its variants, its uses) is not reported again.
struct Voice { pitch: f32 }
enum Voice { Kick, Snare, Hat }
const STEPS = 4
fn STEPS() -> i64 { 8 }

fn sound(v: Voice) -> str {
    match v {
        Kick => "kick"
        Snare => "snare"
        Hat => "hat"
    }
}

fn main() {
    pattern := []Voice{Kick, Snare, Kick, Hat}
    for i in 0..STEPS {
        print(sound(pattern[i % len(pattern)]))
    }
    v := Voice.Snare
    w: Voice = Hat
    print(sound(v), sound(w), STEPS(), Voice{pitch: 1.0}.pitch)
}
