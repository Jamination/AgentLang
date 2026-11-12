# std.os: running programs, the process, files for tools

`use std.os`. Source: `std/os.al`. For tools and build scripts: start other programs and read
what they print, find out about the process itself, and work with files and directories. Raw
Linux system calls, no libc: a program using this module stays a static executable.

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

Not there: changing the working directory or the environment of this process, starting a
program without waiting for it, feeding its standard input from a string, time limits.
