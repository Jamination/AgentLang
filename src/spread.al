// What the two back-end drivers (src/x86/mod.al, src/arm64/mod.al) share: the reachable
// functions, and the compilation of functions by several threads together (see "Parallel back
// end" in docs/BOOTSTRAP.md).

// The functions that each function calls or takes the address of, from its optimised IR (in
// the order of its IR): of[f] once known[f]. While functions are compiled in threads each entry
// is written by the thread that optimises the function (the slice in its arena).
struct Refs {
    of: Vec[[]i64]
    known: Vec[bool]
}

fn refs_new(n: i64) -> Refs {
    none: []i64
    return Refs{of: vec_fill(n, none), known: vec_fill(n, false)}
}

// records the references of function fid
fn refs_add(r: *Refs, m: *Module, fid: i64) {
    f := &m.funcs[fid]
    list := vec[i64]()
    for bi in 0..f.blocks.len {
        for v in f.blocks[bi].insts {
            i := &f.insts[v]
            if i.op == Call || i.op == FAddr {
                list.push(i.k)
            }
        }
    }
    r.of[fid] = list.items()
    r.known[fid] = true
}

// The functions to compile, in increasing order: the entry, the functions whose address is in
// global data, and whatever these call or take the address of (r: the references of every
// function).
fn reachable_funcs(m: *Module, r: *Refs) -> Vec[i64] {
    seen := vec_fill(m.funcs.len, false)
    work := vec_of([]i64{m.entry})
    seen[m.entry] = true
    // function pointers stored in global data: these functions are roots as well (what they
    // call must be compiled too)
    for gi in 0..m.globals.len {
        for rl in m.globals[gi].relocs {
            match rl.1 {
                Func(f) if !seen[f] => {
                    seen[f] = true
                    work.push(f)
                }
                _ => {}
            }
        }
    }
    out := vec[i64]()
    while !work.is_empty() {
        f := work.pop()
        out.push(f)
        for k in r.of[f] {
            if !seen[k] {
                seen[k] = true
                work.push(k)
            }
        }
    }
    sort(out.items())
    return out
}

// The number of threads that compile functions together: one per CPU, at most MAX_THREADS,
// and with at least SPREAD_PER_O0 functions per thread at -O0 (optimised and compiled),
// SPREAD_PER when optimising (only compiled, but bigger after inlining): a thread costs its
// start and some memory, which a few small functions do not repay. ALC_JOBS=n sets the number
// exactly. Below SPREAD_MIN functions the compile stays on the compiler's thread.
priv const MAX_THREADS = 32
const SPREAD_PER_O0 = 24
const SPREAD_PER = 12
const SPREAD_MIN = 64

// the threads available (one per CPU, or ALC_JOBS), and whether ALC_JOBS fixed the number
fn spread_jobs() -> (i64, bool) {
    nw := min(cpu_count(), MAX_THREADS)
    jobs, jobs_set := env_get("ALC_JOBS")
    if jobs_set {
        j, jok := parse_i64(jobs)
        if jok && j >= 1 {
            return (j, true)
        }
    }
    return (nw, false)
}

// the threads for count functions with per functions per thread: nw unless exact (ALC_JOBS)
// says it is fixed
fn spread_threads(nw: i64, exact: bool, count: i64, per: i64) -> i64 {
    if exact {
        return nw
    }
    return max(1, min(nw, count / per))
}

// the functions cand, largest first (so that all threads finish at about the same time)
fn spread_order(m: *Module, cand: []i64) -> Vec[i64] {
    sizes := vec_fill(m.funcs.len, 0)
    order := vec_of(cand)
    for f in cand {
        sizes[f] = m.funcs[f].insts.len
    }
    sort_by(order.items(), sizes.items(), fn(s: []i64, a: i64, b: i64) -> bool { s[a] > s[b] || (s[a] == s[b] && a < b) })
    return order
}

// What the threads of spread_run share. Only `next` is written by several of them (with
// atomic_add).
priv struct Job[C] {
    ctx: C
    order: []i64
    next: *i64 // the position in `order` of the next function to take
    w: *Work   // the thread's own
    f: fn(C, i64, *Work)
}

// the bytes the arenas of the joined worker threads hold (for ALC_DEBUG=mem)
priv thread_bytes: i64

fn spread_thread_mem() -> i64 {
    return thread_bytes
}

// Runs f(ctx, fid, w) for every function fid of `order` in nt threads: this one and nt - 1
// worker threads (fewer if they cannot be started), which take the functions in turn from the
// list. Every thread works in a Work w of its own, and what it keeps is in its arena, which
// stays after the join; f writes its results where only it writes (an element per function,
// read after the join).
fn spread_run[C](order: []i64, nt: i64, ctx: C, f: fn(C, i64, *Work)) {
    fn worker(j: Job[C]) {
        loop {
            k := atomic_add(j.next, 1)
            if k >= len(j.order) {
                return
            }
            j.f(j.ctx, j.order[k], j.w)
        }
    }
    next := 0
    // (works[t]: the Work of worker thread t)
    works := alloc[Work](nt)
    threads := vec[*__ThreadCtl]()
    for t in 1..nt {
        c := worker_start(worker, Job[C]{ctx: ctx, order: order, next: &next, w: &works[t], f: f})
        if c == nil {
            break
        }
        threads.push(c)
    }
    worker(Job[C]{ctx: ctx, order: order, next: &next, w: work_main(), f: f})
    for t in 0..threads.len {
        thread_bytes += worker_join(threads[t])
        work_free(&works[t + 1])
    }
}
