// -D NAME=VALUE: constants of the program set on the command line (when_defines.flags), used
// by `when` and by ordinary code
const DEMO = false
const LEVEL: i32 = 1
const NAME = "x"
const RATE: f64 = 1.0
enum Mode { Fast, Slow }
const MODE = Mode.Fast
const BIG: u8 = 1
const KEEP = 5

when DEMO && LEVEL == 3 {
    fn banner() -> str { "demo, level 3" }
} else {
    fn banner() -> str { "full" }
}

fn main() {
    print(banner(), DEMO, LEVEL, NAME, RATE, MODE, BIG, KEEP)
    if DEMO {
        print("demo build")
    } else {
        print("full build")
    }
    when MODE == Slow { print("slow") }
    x: i32 = LEVEL * 2
    print(x)
}
