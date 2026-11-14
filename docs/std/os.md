# std.os: running programs, the process, files for tools

`use std.os`. Source: `std/os.al`. For tools and build scripts: start other programs and read
what they print, or let them run alongside; shared memory; find out about the process itself,
and work with files and directories; threads with mutexes and condition variables. Raw
Linux system calls, no libc: a program using this module stays a static executable. Built with
`--target windows` it calls kernel32.dll; the differences are listed under [Windows](#windows).

`use std.os` also loads [std.asset](asset.md), where the file and directory functions live
(there is one set of them, not two).

## Running programs

| Declaration | Description |
|-------------|-------------|
| `run(argv: []str) -> i64` | Runs the program `argv[0]` with the arguments `argv[1..]` and waits for it. Its output goes where the output of this process goes. Returns the status. |
| `run_capture(argv: []str) -> (str, i64)` | The same, but what the program writes to standard output is returned (any amount) instead of shown; its standard error still goes where that of this process goes. `("", -1)` if it could not be started. |
| `run_capture_all(argv: []str) -> (str, i64)` | The same with standard output and standard error together in one text, in the order written. |

- **The program.** A name without `/` is looked up in the directories of the environment
  variable `PATH` (`/usr/local/bin:/usr/bin:/bin` if it is not set); a name with `/` is a path,
  relative to the working directory unless it starts with `/`. Arguments are passed as they
  are: no shell is involved, nothing is split or expanded (`run([]str{"ls", "my file"})` lists
  one file). For pipes, redirection or wildcards run a shell: `run([]str{"sh", "-c", "ls *.al | wc -l"})`.
- **The status** is the exit status of the program (0 to 255; 0 means success by convention),
  or 128 + the signal number if a signal ended it (137: killed, 139: memory fault, as a shell
  and `alc run` report it), or **-1 if the program could not be started**. Then, and only then,
  `io_error()` is not 0: the Linux error number of the reason, `error_text(io_error())` its
  text (`no such file or directory`: no program of that name; `permission denied`: not
  executable, or a directory; `exec format error`: not a program; `invalid argument`: `argv`
  is empty). A program that started and failed has a status above 0 and `io_error()` 0.
- The program gets the environment and the standard input of this process, and runs in its
  working directory. To give it another variable or directory, run it through `env`
  (`[]str{"env", "CC=clang", "make"}`, `[]str{"env", "-C", dir, "make"}`) or `sh -c`.
- Output that this process has printed but not yet written is written first (`flush()`), so
  the texts of both appear in order. The call returns when the program has ended **and**
  nothing holds its output open any more (a background process it started keeps
  `run_capture` waiting).

```
use std.os

fn main() -> i64 {
    out, status := run_capture([]str{"cc", "--version"})
    if status < 0 {
        eprint(fmt("cannot run cc: ", error_text(io_error())))     // cannot run cc: no such file or directory
        return 1
    }
    print("compiler:", lines(out)[0])
    if !make_dir("tmp/os_doc") { return 1 }
    write_file("tmp/os_doc/hello.c", "#include <stdio.h>\nint main(void) { puts(\"hello from C\"); return 3; }\n")
    if run([]str{"cc", "-o", "tmp/os_doc/hello", "tmp/os_doc/hello.c"}) != 0 { return 1 }     // the compiler's messages are shown
    text, code := run_capture([]str{"tmp/os_doc/hello"})
    print(trim(text), code, list_dir("tmp/os_doc"))               // hello from C 3 [hello, hello.c]
    both, _ := run_capture_all([]str{"sh", "-c", "echo to stdout; echo to stderr >&2; kill -9 $$"})
    print(lines(both), run([]str{"sh", "-c", "kill -9 $$"}), run([]str{"no-such-program"}), error_text(io_error()))
    // [to stdout, to stderr] 137 -1 no such file or directory
    remove_file("tmp/os_doc/hello")
    remove_file("tmp/os_doc/hello.c")
    remove_dir("tmp/os_doc")
    0
}
```

## Background processes

| Declaration | Description |
|-------------|-------------|
| `spawn(argv: []str) -> (Process, bool)` | Starts the program `argv[0]` (found as by `run`) with the arguments `argv[1..]` and returns at once. `(Process{}, false)` if it could not be started; `io_error()` is the reason, as for `run`. |
| `wait(p: Process) -> i64` | Waits until it has ended; the status as for `run` (exit status, 128 + signal). Waiting again returns the same status. |
| `try_wait(p: Process) -> (i64, bool)` | Does not block: `(status, true)` once it has ended (it is then waited for), `(0, false)` while it runs, `(-1, true)` if it cannot be waited for (`io_error()`). |
| `kill(p: Process, signal: i64) -> bool` | Sends a signal: 15 (SIGTERM) asks it to end, 9 (SIGKILL) ends it, 2 is SIGINT, 0 only checks that it is there. `false` with `io_error()` 3 (`no such process`) once it has been waited for. |
| `pid(p: Process) -> i64` | Its process id. |

- The program shares the environment, working directory, standard input, output and error of
  this process; what this process printed before is written first (`flush()`).
- A copy of a `Process` is the same process (waiting through one copy is seen by the others).
  `Process{}` was not started: `wait` returns -1 with `io_error()` 10 (`no child processes`).
- **Wait for every process.** A program that has ended stays in the system's process table (a
  *zombie*) until it is waited for with `wait` or `try_wait`; a process that this program
  never waits for is reaped by the system when this program exits. After it has been waited
  for, its id may be given to a new process, which is why `kill` refuses then.
- A program that should not outlive this one (if this one crashes) can be started through
  `timeout` (`[]str{"timeout", "-k", "5", "60", "server", ...}`): it passes SIGTERM on to the
  program and ends it after 60 s in any case.

```
use std.os

fn main() {
    server, ok := spawn([]str{"sleep", "30"})
    if !ok {
        eprint(fmt("cannot start: ", error_text(io_error())))
        return
    }
    _, ended := try_wait(server)
    print(pid(server) > 0, ended)                   // true false
    kill(server, 15)
    print(wait(server), kill(server, 15))           // 143 false
    jobs := vec[Process]()
    for i in 0..3 {
        p, _ := spawn([]str{"sh", "-c", fmt("exit ", i)})
        jobs.push(p)
    }
    for p in jobs { put(wait(p), " ") }             // 0 1 2
    print()
}
```

## Shared memory

Memory that another process maps as well, for example the pixels of a Wayland `wl_shm` buffer
([std.wayland](wayland.md)): the file descriptor is what is handed over.

| Declaration | Description |
|-------------|-------------|
| `shm_create(size: i64) -> (i64, bool)` | A new anonymous file of `size` zero bytes in memory (`memfd_create`, closed when a program is started): `(fd, true)`, or `(-1, false)` with `io_error()`. |
| `map_shared(fd: i64, size: i64) -> ([]u8, bool)` | The first `size` bytes of the file as memory shared with every other mapping of it, readable and writable. |
| `map_readonly(fd: i64, size: i64) -> ([]u8, bool)` | Read-only and private to this process (a file the other side may have opened read-only, like the keymap of `wl_keyboard.keymap`). Writing to it stops the program with a memory fault. |
| `unmap(s: []u8) -> bool` | Gives back a mapping (the whole slice that was returned). Using it afterwards is a memory fault. |
| `close_fd(fd: i64) -> bool` | Closes a file descriptor; a mapping stays valid after its descriptor is closed. |

All report failures through their result and `io_error()` (`bad file descriptor`, `invalid
argument` for a size of 0, ...). View the bytes as other types with `mkslice` and `cast`:
`pixels := mkslice[u32](cast[*u32](ptr(mem)), width * height)`.

## The process

| Declaration | Description |
|-------------|-------------|
| `process_id() -> i64` | The process id: a number no other running process has (for names of temporary files). |
| `current_dir() -> str` | The absolute path of the working directory (`""` if it cannot be told; see `io_error()`). |
| `args() -> []str`, `env_get(name: str) -> (str, bool)`, `exit(code: i64) -> never` | Core functions (language reference): the program's arguments, an environment variable, ending with a status. |

## Files and directories

From [std.asset](asset.md) (loaded by `use std.os`) and the core library; all report failures
through their result and `io_error()`, none panics.

| Task | Function |
|------|----------|
| does it exist, is it a directory | `file_exists(path) -> bool`, `is_dir(path) -> bool` |
| size, time of the last change | `file_size(path) -> i64` (-1 if missing), `modified_time(path) -> i64` (ns since 1970, 0 if missing) |
| read, write | `read_file(path) -> (str, bool)`, `write_file(path, data) -> bool` (core) |
| create a directory with its parents | `make_dir(path) -> bool` (true also if it exists) |
| names in a directory | `list_dir(path) -> []str` (sorted, without `.` and `..`; empty if it cannot be read) |
| rename or move | `rename(from, to) -> bool` (replaces an existing file `to`) |
| delete | `remove_file(path) -> bool`, `remove_dir(path) -> bool` (an empty directory); `false` with `io_error()` 2 if it is missing |
| path text | `path_join(a, b)`, `path_dir(p)`, `path_base(p)`, `path_ext(p)`, `path_stem(p)` |

Not there: changing the working directory or the environment of this process, feeding the
standard input of a program from a string, time limits (use `timeout`, or `try_wait` and
`kill`).

## Threads

| Declaration | Description |
|-------------|-------------|
| `thread_spawn[C](f: fn(C), ctx: C) -> (Thread, bool)` | Starts a thread that runs `f(ctx)`; `ctx` is copied (as `sort_by`'s context; what its slices and pointers refer to is shared). `f` may be a top-level, nested or anonymous function. `(Thread{}, false)` if it cannot be started, with `io_error()` (12: no memory; 38: a dynamically linked program whose libraries lack the C library's `pthread_create`). Stack: 8 MiB, reserved and committed as used, with a guard page. |
| `thread_spawn[C](f: fn(C), ctx: C, stack: i64) -> (Thread, bool)` | The same with a stack of `stack` bytes (at least 64 KiB). |
| `thread_join(t: *Thread)` | Waits until the thread has ended. Then `t.region` holds everything the thread allocated: an ordinary `Region` of the caller, valid until `region_free(&t.region)`. Joining twice (also through a copy of the `Thread`), joining `Thread{}` or the calling thread panics. |
| `thread_id() -> i64` | The calling thread's id: 0 in the main thread, then 1, 2, ... in the order threads were started (`t.id` of a `Thread`). |
| `cpu_count() -> i64` | The CPUs this process may use (Linux: its affinity mask), at least 1: how many workers to start. |
| `struct Mutex` | A lock; the zero value is unlocked (a field of a struct needs no setup). Not recursive; must not be copied while in use. |
| `lock(m: *Mutex)`, `unlock(m: *Mutex)`, `try_lock(m: *Mutex) -> bool` | Lock (waits), unlock, lock if free. `unlock` by a thread that does not hold it and `lock` by the thread that holds it panic; `try_lock` returns `false` then. |
| `struct Cond` | A condition variable; the zero value is usable. |
| `wait(c: *Cond, m: *Mutex)`, `wait(c: *Cond, m: *Mutex, timeout_ns: i64) -> bool` | Unlocks `m` (held by the caller), waits until `c` is signalled, locks `m` again; the second form gives up after `timeout_ns` (`false`). It may return without a signal: wait in a loop that checks the condition. |
| `signal(c: *Cond)`, `broadcast(c: *Cond)` | Wakes one / every thread waiting on `c`. |

- **Rules** (language reference, [DETAILS.md](../DETAILS.md#threads)): threads share all memory;
  memory written by one thread while another uses it must be guarded by a `Mutex` or accessed
  with the atomic builtins (`atomic_add`, `atomic_cas`, ...), else the behaviour is undefined;
  each thread allocates from its own arena; a region is entered by one thread at a time; a panic
  in any thread ends the program, naming the thread; when `main` returns, the program ends.
- **Memory.** A worker that runs for long bounds its memory with `mark` / `release` or regions.
  A thread that is never joined keeps its memory until the program ends.
- **Output** of threads is written line by line: lines never mix. A partial line of a thread
  still running when the program ends is lost.
- Linux: in a dynamically linked program threads are made by the C library's `pthread_create`
  (C code called from them works as in a C program); a static program stays static (`clone`).
  Windows: `CreateThread`, SRW locks and condition variables of kernel32.dll.
- No semaphore or once-flag: a `Mutex` with a `Cond`, or `atomic_cas` on a flag, does it.

```
use std.os

struct Job { lo: i64, hi: i64, total: *i64, mu: *Mutex, names: *Vec[str] }

fn work(j: Job) {
    s := 0
    for i in j.lo..j.hi { s += i }
    atomic_add(j.total, s)
    name := fmt("part ", j.lo / 1000)      // in this thread's arena
    lock(j.mu)
    j.names.push(name)
    unlock(j.mu)
}

fn main() {
    total: i64 = 0
    mu: Mutex
    names := vec[str]()
    ts := vec[Thread]()
    for k in 0..4 {
        t, _ := thread_spawn(work, Job{k * 1000, (k + 1) * 1000, &total, &mu, &names})
        ts.push(t)
    }
    for i in 0..ts.len { thread_join(&ts[i]) }
    sort(names[..])
    print(total, names[..])                 // 7998000 [part 0, part 1, part 2, part 3]
    for i in 0..ts.len { region_free(&ts[i].region) }   // the names were in these regions
}
```

## Windows

With `--target windows` the module works through kernel32.dll (`CreateProcessW`,
`CreateFileMappingW`, ...); the same calls give the same results except:

- **Finding the program.** A name without `/`, `\` or a drive is looked up in the
  directories of `PATH` (separated by `;`), with `.exe` appended if the name has no extension;
  a path is used as it is (also with `.exe` appended if it has no extension). Run batch files
  (`.bat`, `.cmd`) as `[]str{"cmd", "/c", file, ...}`.
- **Arguments** are joined into one command line with the quoting of the Microsoft C library,
  so a program that splits its command line by those rules (every AL program, every C
  program) gets `argv` back unchanged. `cmd.exe` has rules of its own: arguments with quotes or
  `&|<>^` reach it altered.
- **Status.** The exit code of the program, of which the low 8 bits are the status as on Linux.
  A program ended by an exception gets the status of the matching Linux signal: access
  violation and stack overflow 139 (SIGSEGV), integer or float faults 136 (SIGFPE), illegal
  instruction 132, fail-fast 134 (SIGABRT), Ctrl+C 130 (SIGINT).
- **Signals.** There are none. `kill(p, 0)` checks that the process can be waited for;
  `kill(p, s)` with any other `s` from 1 to 64 ends the process at once (`TerminateProcess`)
  with the exit code 128 + `s`, so `wait` returns 137 after `kill(p, 9)` and 143 after
  `kill(p, 15)` as on Linux. A process cannot handle or ignore it.
- **Shared memory.** `shm_create` makes a file mapping object in the paging file; the
  "descriptor" is its handle, which is not inherited by programs this process starts.
  `map_shared` / `map_readonly` map such a handle or the handle of an open file; `close_fd`
  closes a handle.
- **The process.** `process_id()` is the Windows process id; `current_dir()` is in Windows form
  (`C:\work\game`).
