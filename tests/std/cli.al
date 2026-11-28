// std.cli: flags, options, short/long forms, --no-flag, --, error handling, and help_text.
use std.cli

fn main() {
    c := cli_new("demo", "Example tool")
    c.add_flag("verbose", "v", "verbose output")
    c.add_flag("quiet", "q", "quiet mode")
    c.add_str("out", "o", "a.out", "output path")
    c.add_i64("jobs", "j", 4, "worker count")

    ok := c.parse([]str{"-vq", "--out=build.bin", "-j", "8", "--no-quiet", "in1.al", "--", "--not-a-flag"})
    print("ok:", ok, c.flag("verbose"), c.flag("quiet"), c.opt_str("out"), c.opt_i64("jobs"), c.pos())

    ok2 := c.parse([]str{"--jobs", "notanint"})
    print("bad_int:", ok2, c.err)

    ok3 := c.parse([]str{"--unknown"})
    print("unknown:", ok3, c.err)

    ok4 := c.parse([]str{"--help"})
    print("help:", ok4, c.help_requested, find(c.help_text(), "--verbose") >= 0, find(c.help_text(), "default: 4") >= 0)
}
