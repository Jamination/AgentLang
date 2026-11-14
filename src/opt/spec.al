// Specialisation of functions for constant function arguments.
//
// A call g(.., f, ..) that passes the address of function f to a function g that calls that
// parameter (or hands it on to a function that does) costs an indirect call per call of the
// parameter when g is not inlined there (inlining g makes the calls direct: inline_run). The
// specialiser makes a copy of g in which the parameter is f's address, points the call at the
// copy, and optimises the copy like any function: inline_run makes its calls of f direct and
// inlines f. The copy keeps g's parameters (the call still passes f; the copy does not read
// it). There is one copy for each (g, parameter, f), shared by every call that passes f there,
// the calls the copies make included: a recursive g that hands the parameter on calls its own
// copy. The copies are capped in number, so recursion cannot make the specialiser loop.
// Only where it pays: f is small enough to be inlined (a direct call alone gains little), and g
// small enough to copy.
const SPEC_MAX = 64 // copies in a module
const SPEC_PER_FUNC = 8 // copies of one function
const SPEC_MAX_COST = 600 // the size of a function copied (inline_cost) at most

struct Spec {
    on: bool // (ALC_DISABLE=spec or devirt: off)
    copies: Map[(i64, i64, i64), i64] // (g, parameter, f) -> the copy
    made: i64
    per_func: Vec[i64] // the copies made of each function
    // called[g]: bit j set when parameter j of g (final) is called or handed on to a call
    // that calls it; -1: not known yet, -2: being worked out
    called: Vec[i64]
}

fn spec_new(n: i64, on: bool) -> Spec {
    return Spec{on: on, copies: map[(i64, i64, i64), i64](), made: 0, per_func: vec_fill(n, 0), called: vec_fill(n, -1)}
}

fn spec_grow(s: *Spec) {
    s.per_func.push(0)
    s.called.push(-1)
}

// the parameters of function g (final) that it calls, or hands on to a final function that
// calls them, as a bit set (parameters from 63 on are left out)
priv fn called_params(m: *Module, st: *OptState, g: i64) -> i64 {
    if st.spec.called[g] != -1 {
        // (a recursive function that hands the parameter on to itself calls it as well)
        return max(st.spec.called[g], 0)
    }
    st.spec.called[g] = -2
    bits := 0
    f := &m.funcs[g]
    for bi in 0..f.blocks.len {
        for v in f.blocks[bi].insts {
            i := &f.insts[v]
            if i.op == CallInd && i.aux == 0 {
                p := &f.insts[i.args[0]]
                if p.op == Param && p.k < 63 {
                    bits |= 1 << p.k
                }
            } else if i.op == Call && st.done[i.k] {
                for ai in 0..min(i.args.len, 63) {
                    p := &f.insts[i.args[ai]]
                    if p.op == Param && p.k < 63 && called_params(m, st, i.k) & (1 << ai) != 0 {
                        bits |= 1 << p.k
                    }
                }
            }
        }
    }
    st.spec.called[g] = bits
    return bits
}

// is function k (final) small enough to be inlined where it is called?
priv fn spec_inlinable(m: *Module, st: *OptState, k: i64) -> bool {
    f := &m.funcs[k]
    if !st.done[k] || !f.lowered || f.ext != None || f.inl < 0 || f.noreturn {
        return false
    }
    if st.costs[k] < 0 {
        st.costs[k] = inline_cost(f)
    }
    return st.costs[k] <= if f.inl > 0 { st.pol.hinted } else { st.pol.small }
}

// a copy of function gid in which parameter j is the address of function k, in the main arena
priv fn spec_copy(m: *Module, gid: i64, j: i64, k: i64) -> Func {
    g := &m.funcs[gid]
    c := *g
    c.name = fmt(g.name, "~", m.funcs[k].name)
    c.copy_of = if g.copy_of >= 0 { g.copy_of } else { gid }
    c.params = vec_of(g.params.items())
    c.rets = vec_of(g.rets.items())
    c.insts = vec_of(g.insts.items())
    for v in 0..c.insts.len {
        i := &c.insts[v]
        n := len(i.args)
        if i.op == Phi {
            i.phi_set(i.args, i.from())
        } else if n > 0 {
            a := mkslice[i64](__alloc_raw(n * 8), n)
            memcopy(ptr(a), ptr(i.args), n * 8)
            i.args = a
        } else if i.op == Param && i.k == j {
            i.op = FAddr
            i.k = k
        }
    }
    c.blocks = vec_of(g.blocks.items())
    for b in 0..c.blocks.len {
        blk := &c.blocks[b]
        blk.insts = vec_of(blk.insts.items())
        match blk.term {
            Ret(vs) => blk.term = Ret(vec_of(vs.items()))
            _ => {}
        }
    }
    return c
}

// The copy of function g (final) for function k as its parameter j, made and optimised on
// first use; -1 where none is made.
priv fn spec_get(m: *Module, st: *OptState, g: i64, j: i64, k: i64) -> i64 {
    c, found := st.spec.copies.get((g, j, k))
    if found {
        return c
    }
    if st.spec.made >= SPEC_MAX || st.spec.per_func[g] >= SPEC_PER_FUNC || j >= 63 || !st.done[g] {
        return -1
    }
    gf := &m.funcs[g]
    if !gf.lowered || gf.ext != None || gf.inl < 0 {
        return -1
    }
    if called_params(m, st, g) & (1 << j) == 0 || !spec_inlinable(m, st, k) {
        return -1
    }
    if st.costs[g] < 0 {
        st.costs[g] = inline_cost(gf)
    }
    if st.costs[g] > SPEC_MAX_COST {
        return -1
    }
    c = opt_add_func(m, st, spec_copy(m, g, j, k))
    st.spec.copies.set((g, j, k), c)
    st.spec.made += 1
    st.spec.per_func[g] += 1
    // its calls that pass k on (to g itself: recursion) go to copies, then it is optimised
    // (and may inline those), then the calls its inlining exposed
    spec_calls(m, c, st)
    opt_func(m, c, st)
    spec_calls(m, c, st)
    return c
}

// points the calls of function fid that pass a function's address at specialised copies
fn spec_calls(m: *Module, fid: i64, st: *OptState) {
    if !st.spec.on {
        return
    }
    // (by index: making a copy adds to m.funcs)
    for bi in 0..m.funcs[fid].blocks.len {
        for ii in 0..m.funcs[fid].blocks[bi].insts.len {
            v := m.funcs[fid].blocks[bi].insts[ii]
            if m.funcs[fid].insts[v].op != Call {
                continue
            }
            for j in 0..m.funcs[fid].insts[v].args.len {
                a := m.funcs[fid].insts[v].args[j]
                if m.funcs[fid].insts[a].op != FAddr {
                    continue
                }
                k := m.funcs[fid].insts[a].k
                g := m.funcs[fid].insts[v].k
                c := spec_get(m, st, g, j, k)
                if c >= 0 && c != g {
                    m.funcs[fid].insts[v].k = c
                    st.call_counts[g] -= 1
                    st.call_counts[c] += 1
                }
            }
        }
    }
}
