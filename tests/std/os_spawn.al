// std.os background processes: spawn, wait, try_wait, kill, pid; failures through io_error();
// a waited child leaves no zombie.
use std.os

fn why() -> str { error_text(io_error()) }

fn sh(script: str) -> []str { []str{"/bin/sh", "-c", script} }

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

fn main() {
    // an exit status, waited for twice
    p, ok := spawn(sh("exit 3"))
    print("spawn:", ok, io_error(), pid(p) > 1, pid(p) != process_id())
    print("wait:", wait(p), io_error(), "again:", wait(p), try_wait(p))

    // output goes where this process's output goes; what was printed before comes first
    put("before ")
    q, _ := spawn([]str{"echo", "from the child"})
    print("wait:", wait(q))

    // try_wait while it runs, then until it has ended
    r, _ := spawn(sh("sleep 0.2; exit 7"))
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

    // kill: SIGTERM ends a sleeping program (128 + 15); signal 0 only checks
    s, _ := spawn([]str{"sleep", "30"})
    print("kill 0:", kill(s, 0), "kill 15:", kill(s, 15), "status:", wait(s))
    print("kill after wait:", kill(s, 15), io_error(), why())

    // an ended process stays a zombie until it is waited for; then it is gone
    z, _ := spawn([]str{"true"})
    state := proc_state(pid(z))
    for i in 0..500 {
        if state == 'Z' { break }
        sleep_ns(10_000_000)
        state = proc_state(pid(z))
    }
    print("zombie before wait:", state == 'Z', "wait:", wait(z), "after:", proc_state(pid(z)) == '-')

    // copies are the same process
    c, _ := spawn(sh("exit 5"))
    copy := c
    print("copy:", wait(copy), try_wait(c), kill(c, 0))

    // several at once
    ps := vec[Process]()
    for i in 0..5 {
        x, okx := spawn(sh(fmt("sleep 0.0", i, "; exit ", 10 + i)))
        if okx { ps.push(x) }
    }
    statuses := vec[i64]()
    for x in ps { statuses.push(wait(x)) }
    print("several:", statuses[..])

    // failures
    _, ok1 := spawn([]str{"no-such-program-al"})
    print("missing:", ok1, io_error(), why())
    _, ok2 := spawn([]str{"/etc/passwd"})
    print("not executable:", ok2, why())
    _, ok3 := spawn([]str{"/etc"})
    print("directory:", ok3, why())
    empty: []str
    _, ok4 := spawn(empty)
    print("empty argv:", ok4, why())
    none: Process
    print("not started:", pid(none), wait(none), why(), try_wait(none), kill(none, 15))
    print("no zombies left:", run(sh("exit 0")), io_error())
}
