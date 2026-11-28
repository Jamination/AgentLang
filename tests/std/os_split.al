// std.os: temp_dir, run_capture_split (separate stdout/stderr), and run_with_stdin.
use std.os

fn main() -> i64 {
    if len(args()) >= 2 && args()[1] == "child" {
        data := read_all(0)
        print("OUT:", data)
        eprint(fmt("ERR:", data))
        return 0
    }
    print("temp_dir_nonempty:", len(temp_dir()) > 0)
    out, err, st := run_with_stdin([]str{args()[0], "child"}, "hello-pipe")
    print("status:", st)
    print("got_out:", trim(out))
    print("got_err:", trim(err))
    out2, err2, st2 := run_capture_split([]str{args()[0], "child"})
    print("split:", st2, trim(out2), trim(err2))
    return 0
}
