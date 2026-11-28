// Helpers shared by the compiler sources: Vec conveniences, processes, worker threads, working
// memory.

// ---------- fuzzy matching (did-you-mean suggestions) ----------
// ASCII lower-case byte (for case-insensitive typo matching)
priv inline fn ascii_lower(c: u8) -> u8 {
    return if c >= 'A' && c <= 'Z' { c + 32 } else { c }
}

// Damerau-Levenshtein edit distance (transposition = 1), capped at `lim + 1` for fast early exit.
// Compares case-insensitively first; an exact case-insensitive match with different casing gets
// distance 1 so `myvar` suggests `myVar`.
priv fn edit_dist(a: str, b: str, lim: i64) -> i64 {
    na := len(a)
    nb := len(b)
    if na == 0 || nb == 0 || abs(na - nb) > lim {
        return lim + 1
    }
    if na > 64 || nb > 64 {
        return lim + 1
    }
    prev2: [65]i64
    prev: [65]i64
    cur: [65]i64
    for j in 0..=nb {
        prev[j] = j
    }
    for i in 1..=na {
        cur[0] = i
        row_min := i
        ca := ascii_lower(a[i - 1])
        for j in 1..=nb {
            cb := ascii_lower(b[j - 1])
            cost := if ca == cb { 0 } else { 1 }
            d := min(prev[j] + 1, min(cur[j - 1] + 1, prev[j - 1] + cost))
            if i > 1 && j > 1 && ca == ascii_lower(b[j - 2]) && ascii_lower(a[i - 2]) == cb {
                d = min(d, prev2[j - 2] + 1)
            }
            cur[j] = d
            if d < row_min {
                row_min = d
            }
        }
        if row_min > lim {
            return lim + 1
        }
        for j in 0..=nb {
            prev2[j] = prev[j]
            prev[j] = cur[j]
        }
    }
    d := prev[nb]
    if d == 0 && a != b {
        return 1
    }
    return d
}

// closest candidate name to `name` within a small typo distance, or "" if none fits
fn did_you_mean(name: str, cands: []str) -> str {
    n := len(name)
    if n < 2 {
        return ""
    }
    lim := if n <= 3 { 1 } else if n <= 8 { 2 } else { 3 }
    best := ""
    best_d := lim + 1
    for c in cands {
        if len(c) == 0 || c == name || starts_with(c, "__") {
            continue
        }
        d := edit_dist(name, c, best_d - 1)
        if d < best_d {
            best_d = d
            best = c
            if best_d == 1 && len(c) == n {
                // exact length 1-edit match is hard to beat, keep scanning only for case-only match
                if to_lower(c) == to_lower(name) {
                    return best
                }
            }
        }
    }
    return best
}

// "; did you mean `best`?" if a close candidate exists, else ""
fn did_you_mean_hint(name: str, cands: []str) -> str {
    b := did_you_mean(name, cands)
    if len(b) == 0 {
        return ""
    }
    return fmt(" (did you mean `", b, "`?)")
}

// ---------- Vec ----------
// Vecs of one and two elements without an intermediate slice (`succs` in ir.al is hot:
// vec_of([]i64{t}) there costs 15 % of the whole compile time)
fn vec_one[T](a: T) -> Vec[T] {
    buf := mkslice[T](__alloc_raw(sizeof[T]()), 1)
    buf[0] = a
    return Vec[T]{buf: buf, len: 1}
}

fn vec_two[T](a: T, b: T) -> Vec[T] {
    buf := mkslice[T](__alloc_raw(2 * sizeof[T]()), 2)
    buf[0] = a
    buf[1] = b
    return Vec[T]{buf: buf, len: 2}
}

// ---------- numbers ----------
// x rounded up to a multiple of a (a > 0)
fn align_up(x: i64, a: i64) -> i64 {
    (x + a - 1) / a * a
}

// ---------- process ----------
// The system the compiler runs on (its host) is TARGET_OS: the target the compiler was built
// for. src/host_linux.al and src/host_windows.al define for it:
//   make_executable(path) -> bool  marks a file as executable (mode 0755; nothing to do on
//                                  Windows)
//   unlink_file(path) -> bool      removes a file (Linux: also an executable that is still
//                                  mapped by a process being torn down, which cannot be written)
//   run_program_env(path, argv, drop, add) -> i64
//                                  runs a program with arguments and the current environment
//                                  without the variables named in `drop` and with the
//                                  `NAME=value` entries of `add`, waits for it and returns its
//                                  exit status (128 + signal number if a signal ended it, -1 if
//                                  it could not be started); it gets the stack limit and the
//                                  environment the compiler was started with (see with_stack)
//   with_stack(bytes, f) -> i64    deep recursion needs a big stack: calls f with a stack of at
//                                  least `bytes` and returns its result. Linux raises the stack
//                                  limit and starts the compiler again; Windows runs f on a
//                                  thread with a stack of that size. Call first in main.
//   stack_size() -> i64            the stack the compiler has (its limit), -1 if it is
//                                  unlimited or not known
//   file_id(path) -> (str, bool)   the identity of an existing file (device and inode, or
//                                  volume and file index), or false
//   cpu_count() -> i64             the number of CPUs this process may use, at least 1
// The rest goes through the OS layer of the run-time library (the `__os_*` functions of
// src/prelude_linux.al / prelude_windows.al).
// (HOST_ARM64: the compiler built for linux-arm64, `alc build --target linux-arm64 -D
// HOST_ARM64=true src/main.al`, whose host has the system calls of arm64)
const HOST_ARM64 = false

when TARGET_OS == Windows {
    use "host_windows.al"
} else when HOST_ARM64 {
    use "host_linux_arm64.al"
} else {
    use "host_linux.al"
}

// run_program_env without changes to the environment
fn run_program(path: str, argv: []str) -> i64 {
    return run_program_env(path, argv, nil, nil)
}

// a byte that separates path components on the host: `/`, on Windows also `\`
fn host_sep(c: u8) -> bool {
    return __os_is_sep(c)
}

// the length of the root at the start of a path on the host ("/" 1; on Windows also "C:\" 3,
// "C:" 2, "\\server\share\" its length, "\" 1), 0 for a relative path
fn host_root(p: str) -> i64 {
    return __os_path_root(p)
}

// ---------- paths ----------
// `p` seen from `dir` (an absolute `p` stays as it is)
fn path_join(dir: str, p: str) -> str {
    if host_root(p) > 0 || len(dir) == 0 {
        return p
    }
    if host_sep(dir[len(dir) - 1]) {
        return concat(dir, p)
    }
    return fmt(dir, "/", p)
}

// the path without trailing separators and trailing "." components
fn path_trim(p: str) -> str {
    n := len(p)
    keep := max(host_root(p), 1)
    loop {
        if n > keep && host_sep(p[n - 1]) {
            n -= 1
        } else if n >= 2 && n > keep && p[n - 1] == '.' && host_sep(p[n - 2]) {
            n -= 1
        } else {
            break
        }
    }
    return p[..n]
}

// the path without its last component
fn path_parent(p: str) -> Opt[str] {
    t := path_trim(p)
    root := host_root(t)
    if len(t) == 0 || len(t) == root {
        return None
    }
    k := len(t)
    while k > root && !host_sep(t[k - 1]) {
        k -= 1
    }
    // separators between the parent and the last component do not belong to the parent
    while k > max(root, 1) && host_sep(t[k - 1]) {
        k -= 1
    }
    return Some(t[..k])
}

// ---------- files ----------
// names.get(file) or "?"
fn file_name(names: *Vec[str], file: i64) -> str {
    if file >= 0 && file < names.len {
        return names[file]
    }
    return "?"
}

// the text for an errno, as in diagnostics: "No such file or directory (os error 2)"
fn os_error(errno: i64) -> str {
    text := match errno {
        1 => "Operation not permitted"
        2 => "No such file or directory"
        5 => "Input/output error"
        11 => "Resource temporarily unavailable"
        12 => "Cannot allocate memory"
        13 => "Permission denied"
        17 => "File exists"
        20 => "Not a directory"
        21 => "Is a directory"
        23 => "Too many open files in system"
        24 => "Too many open files"
        26 => "Text file busy"
        27 => "File too large"
        28 => "No space left on device"
        30 => "Read-only file system"
        36 => "File name too long"
        40 => "Too many levels of symbolic links"
        _ => fmt("Unknown error ", errno)
    }
    return fmt(text, " (os error ", errno, ")")
}

// ---------- worker threads (the parallel back end) ----------
// The run-time library's threads, as std.os's thread_spawn / thread_join make them (the
// compiler does not load std.os: its cpu_count is the host's). A thread allocates from an arena
// of its own; what it allocated stays valid after worker_join (that arena is never freed). A
// panic in a worker thread ends the compiler, as in any thread.

// the stack of a worker thread (reserved; committed as it is used). Nothing that runs there
// (opt_finish, compile_fn) recurses deeper with the size or nesting of a function: every
// program measured needs about 12 KiB, see "Parallel back end" in docs/BOOTSTRAP.md
priv const WORKER_STACK = 2 << 20

// starts a thread that runs f(ctx); nil if it cannot be started
fn worker_start[C](f: fn(C), ctx: C) -> *__ThreadCtl {
    return __thread_start(f, ctx, WORKER_STACK)
}

// waits until the thread of worker_start has ended; the bytes its arena holds
fn worker_join(c: *__ThreadCtl) -> i64 {
    r := __thread_join(c)
    return used(&r)
}

// ---------- working memory ----------
// The compiler never frees: everything lives in an arena. Passes over one function create a
// lot of short-lived data, so besides the arena of the thread the compiler uses two regions:
//   work     one function being optimised or compiled. work_begin(w) makes every allocation
//            come from it, work_end(w) goes back and empties it. Whatever must survive is
//            copied (deep `clone`) right after work_end(w): the discarded memory stays readable
//            until the next work_begin(w).
//   scratch  tables that a pass rebuilds on every round of a loop (predecessors, orderings,
//            use counts). scratch_on(w) / scratch_off(w) bracket their construction and
//            scratch_reset(w) at the top of the next round discards them. Nothing reachable
//            from the function may be allocated between scratch_on(w) and scratch_off(w).
// Every thread that optimises or compiles functions has a Work of its own (the compiler's
// main thread the one of work_main(), each worker thread of the back end one): the two regions
// and what the passes keep between calls. While a thread works on a function, `Func.w` is its
// Work: the passes reach it through the function they are given, so no thread touches the
// Work of another.
struct Work {
    work: Region
    scratch: Region
    working: bool
    scratching: bool
    memo: Memo          // the CFG analyses of the function (ir.al)
    insts_main: bool    // mk grows the instruction list outside the work region (ir.al)
    gen: i64            // the optimiser's count of changes (opt_pass in opt/mod.al)
    clean: [16]i64      // the passes known to change nothing (opt_pass in opt/mod.al)
    esc_f: *Func        // the escaping allocas last remembered (opt/alias.al)
    esc_gen: i64
    esc_last: Vec[bool]
    preheaders: i64     // preheaders made so far (opt/licm.al)
    settled: bool       // see mem2reg_settled (opt/mem2reg.al)
}

priv main_work: Work

// the Work of the compiler's main thread (no other thread may use it)
fn work_main() -> *Work {
    return &main_work
}

fn work_begin(w: *Work) {
    assert !w.working, "work_begin: already working"
    w.working = true
    enter(&w.work)
}

fn work_end(w: *Work) {
    assert w.working && !w.scratching, "work_end without work_begin"
    w.working = false
    leave()
    reset(&w.work)
    reset(&w.scratch)
}

// allocate from the arena below the work region for a moment while working (for results that
// must stay)
fn work_pause(w: *Work) {
    assert w.working && !w.scratching, "work_pause without work_begin"
    leave()
}

fn work_resume(w: *Work) {
    enter(&w.work)
}

fn scratch_on(w: *Work) {
    assert !w.scratching, "scratch_on: already on"
    w.scratching = true
    enter(&w.scratch)
}

fn scratch_off(w: *Work) {
    assert w.scratching, "scratch_off without scratch_on"
    w.scratching = false
    leave()
}

fn scratch_reset(w: *Work) {
    assert !w.scratching, "scratch_reset while the scratch region is in use"
    reset(&w.scratch)
}

// is address p in memory of the work or the scratch region (discarded at work_end)? (not to be
// asked while working: the fields of an entered region are not up to date)
inline fn work_holds(w: *Work, p: i64) -> bool {
    return (p >= w.work.base && p < w.work.end) || (p >= w.scratch.base && p < w.scratch.end)
}

// the largest size the work region has had, in bytes (not to be called while working)
fn work_peak(w: *Work) -> i64 {
    return max(w.work.hwm, w.work.cur) - w.work.base
}

// the memory the regions of w hold, given back (w is not in use)
fn work_free(w: *Work) {
    region_free(&w.work)
    region_free(&w.scratch)
}
