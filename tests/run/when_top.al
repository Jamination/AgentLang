// `when` at top level: chains of branches, conditions over constants (also private ones and
// constants computed from others), `use` and generic declarations in a branch, nesting
const LEVEL: i32 = 2
const NAME = "full"
const DEBUG = false
priv const LOCAL = 3
enum Mode { Fast, Slow }
const MODE = Mode.Slow
const VERBOSE = LEVEL >= 2

when LEVEL == 1 {
    fn level_name() -> str { "one" }
} else when LEVEL == 2 && NAME == "full" {
    fn level_name() -> str { "two, full" }
} else {
    fn level_name() -> str { "other" }
}

when !DEBUG && (MODE == Slow || LOCAL != 3) {
    use "lib/when_slow.al"
    struct Pair[T] { a: T, b: T }
    priv fn pair_sum(p: Pair[i64]) -> i64 { p.a + p.b }
}

when DEBUG {
    use "lib/no_such_file.al"
    fn helper() -> i64 { undefined_function() }
} else {
    fn helper() -> i64 { 7 }
}

when VERBOSE { const SHOWN = "verbose" } else { const SHOWN = "quiet" }
when TARGET_ARCH == X86_64 { const ARCH = "x86-64" }
when TARGET_OS == Windows {
    const OS_NAME = "Windows"
} else when TARGET_OS == Linux {
    const OS_NAME = "Linux"
}

when true {
    when LEVEL != 2 { const NESTED = "wrong" } else { const NESTED = "nested" }
    test "a test in a branch" {}
}

fn main() {
    print(level_name(), slow_name(), pair_sum(Pair[i64]{2, 3}), helper(), SHOWN, ARCH, NESTED)
    print(OS_NAME == fmt(TARGET_OS), TARGET_ARCH)
}
