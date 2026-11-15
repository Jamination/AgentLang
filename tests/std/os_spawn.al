// std.os background processes: spawn, wait, try_wait, kill, pid; failures through io_error();
// a waited child leaves no zombie. The children are this program, started again with
// `child ...`: the same output on every target.
use std.os

fn why() -> str { error_text(io_error()) }

fn num(s: str) -> i64 {
    n, _ := parse_i64(s)
    n
}

// what the program does as a child: `exit N`; `sleep MS N` sleeps, then ends with status N;
// `say TEXT` prints the text
fn child(a: []str) -> i64 {
    if a[0] == "exit" {
        return num(a[1])
    }
    if a[0] == "sleep" {
        sleep_ms(num(a[1]))
        return num(a[2])
    }
    if a[0] == "say" {
        print(a[1])
        return 0
    }
    return 99
}

// the command line that runs this program as a child
fn me(what: []str) -> []str {
    argv := vec_of([]str{args()[0], "child"})
    argv.extend(what)
    argv.items()
}

when TARGET_OS == Linux {
    // the state letter of a process in /proc ('Z': a zombie), '-' if there is no such process
    fn proc_state(id: i64) -> u8 {
        text, ok := read_file(fmt("/proc/", id, "/stat"))
        if !ok {
            return '-'
        }
        // pid (comm) S ...: the letter after the last ')'
        at := len(text) - 1
        while at > 0 && text[at] != ')' { at -= 1 }
        text[at + 2]
    }
}

fn main() -> i64 {
    if len(args()) > 2 && args()[1] == "child" {
        return child(args()[2..])
    }
    // an exit status, waited for twice
    p, ok := spawn(me([]str{"exit", "3"}))
    print("spawn:", ok, io_error(), pid(p) > 1, pid(p) != process_id())
    print("wait:", wait(p), io_error(), "again:", wait(p), try_wait(p))

    // output goes where this process's output goes; what was printed before comes first
    put("before ")
    q, _ := spawn(me([]str{"say", "from the child"}))
    print("wait:", wait(q))

    // try_wait while it runs, then until it has ended
    r, _ := spawn(me([]str{"sleep", "300", "7"}))
    status, done := try_wait(r)
    print("running:", status, done)
    polls := 0
    loop {
        status, done = try_wait(r)
        if done { break }
        polls += 1
        sleep_ns(10_000_000)
    }
    print("ended:", status, done, polls > 0, io_error())

    // kill: 15 (SIGTERM) ends a sleeping program (128 + 15); signal 0 only checks
    s, _ := spawn(me([]str{"sleep", "30000", "0"}))
    print("kill 0:", kill(s, 0), "kill 15:", kill(s, 15), "status:", wait(s))
    print("kill after wait:", kill(s, 15), io_error(), why())

    // an ended process can be waited for (and found by kill) until it has been waited for
    z, _ := spawn(me([]str{"exit", "0"}))
    when TARGET_OS == Linux {
        // there it is a zombie meanwhile, and gone afterwards
        state := proc_state(pid(z))
        for i in 0..500 {
            if state == 'Z' { break }
            sleep_ns(10_000_000)
            state = proc_state(pid(z))
        }
        if state != 'Z' { print("FAILED: no zombie before wait:", state) }
    } else {
        sleep_ms(200)
    }
    print("ended, before wait:", kill(z, 0), "wait:", wait(z), "after:", kill(z, 0), why())
    when TARGET_OS == Linux {
        if proc_state(pid(z)) != '-' { print("FAILED: the process is still there after wait") }
    }

    // copies are the same process
    c, _ := spawn(me([]str{"exit", "5"}))
    copy := c
    print("copy:", wait(copy), try_wait(c), kill(c, 0))

    // several at once
    ps := vec[Process]()
    for i in 0..5 {
        x, okx := spawn(me([]str{"sleep", fmt(10 * i), fmt(10 + i)}))
        if okx { ps.push(x) }
    }
    statuses := vec[i64]()
    for x in ps { statuses.push(wait(x)) }
    print("several:", statuses[..])

    // failures
    _, ok1 := spawn([]str{"no-such-program-al"})
    print("missing:", ok1, io_error(), why())
    _, ok2 := spawn([]str{"./no/such/program"})
    print("missing path:", ok2, io_error(), why())
    when TARGET_OS == Windows {
        // a file that is no program
        _, ok3 := spawn([]str{"tests/std/os_spawn.out"})
        if ok3 || io_error() != 8 { print("FAILED: a text file started:", ok3, why()) }
    } else {
        // a file without the permission to execute it
        _, ok3 := spawn([]str{"/etc/passwd"})
        if ok3 || io_error() != 13 { print("FAILED: /etc/passwd started:", ok3, why()) }
    }
    _, ok4 := spawn([]str{"tests/"})
    print("directory:", ok4, why())
    empty: []str
    _, ok5 := spawn(empty)
    print("empty argv:", ok5, why())
    none: Process
    print("not started:", pid(none), wait(none), why(), try_wait(none), kill(none, 15))
    print("no zombies left:", run(me([]str{"exit", "0"})), io_error())
    return 0
}
