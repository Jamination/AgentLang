// An independent implementation of the AAPCS64 argument and result classification ("Procedure
// Call Standard for the Arm 64-bit Architecture", section 6.8 "Parameter passing", rules B.1-B.6
// and C.1-C.17), table-driven over C types, with Apple's variant of it (arm64 macOS: "Writing
// ARM64 code for Apple platforms"). Used by tests/arm64/check.al to check the C calls of
// executables, and tested by tests/unit/aapcs64.al against placements that clang 19 gives for
// the same C signatures (`clang --target=aarch64-linux-gnu -S`, `--target=arm64-apple-macos`).
// It shares no code with the compiler (src/lower_ccall.al).

// a C type: an integer or pointer of `size` bytes (signed or not), a float of 4 or 8 bytes, a
// struct of fields (C layout: each field at its natural alignment), an array of n elements
enum CT {
    Int(i64, bool),
    Flt(i64),
    Rec(Vec[CT]),
    Arr(Vec[CT], i64), // (the element type is the one element of the Vec)
}

fn ct_size(t: *CT) -> i64 {
    match *t {
        Int(n, _) => return n
        Flt(n) => return n
        Arr(e, n) => return ct_size(&e[0]) * n
        Rec(fs) => {
            off := 0
            a := 1
            for f in fs {
                fa := ct_align(&f)
                off = (off + fa - 1) / fa * fa + ct_size(&f)
                a = max(a, fa)
            }
            return (off + a - 1) / a * a
        }
    }
}

fn ct_align(t: *CT) -> i64 {
    match *t {
        Int(n, _) => return n
        Flt(n) => return n
        Arr(e, _) => return ct_align(&e[0])
        Rec(fs) => {
            a := 1
            for f in fs {
                a = max(a, ct_align(&f))
            }
            return a
        }
    }
}

// the fundamental types of t in order (arrays expanded)
priv fn flatten(t: *CT, out: *Vec[CT]) {
    match *t {
        Rec(fs) => {
            for f in fs {
                flatten(&f, out)
            }
        }
        Arr(e, n) => {
            for _ in 0..n {
                flatten(&e[0], out)
            }
        }
        _ => out.push(*t)
    }
}

// B.? / 5.9.5: a homogeneous floating-point aggregate: a composite of 1 to 4 members of one
// floating-point type: (member size, count), or (0, 0)
fn ct_hfa(t: *CT) -> (i64, i64) {
    match *t {
        Int(_, _), Flt(_) => return (0, 0)
        _ => {}
    }
    fl := vec[CT]()
    flatten(t, &fl)
    if fl.len < 1 || fl.len > 4 {
        return (0, 0)
    }
    es := match fl[0] {
        Flt(n) => n
        _ => return (0, 0)
    }
    for f in fl {
        if f != Flt(es) {
            return (0, 0)
        }
    }
    return (es, fl.len)
}

// where an argument or result goes
enum Loc {
    X(i64, i64),          // x registers: first, count (a composite: its bytes in order)
    V(i64, i64, i64),     // v registers: first, count, bytes of each (4 or 8)
    Stack(i64, i64),      // the stack: offset from sp at the call, bytes
    RefX(i64),            // a copy, its address in x register k
    RefStack(i64),        // a copy, its address at this stack offset
    XR,                   // results: memory whose address the caller passes in x8
    Nothing,
}

priv fn round_up(n: i64, a: i64) -> i64 {
    return (n + a - 1) / a * a
}

// The locations of the arguments `args` of a call (`nfixed`: how many are named; the rest are
// variadic) and of its result `ret` (None: void) on Linux (`apple`: false) or macOS.
fn aapcs64(args: []CT, nfixed: i64, ret: Opt[CT], apple: bool) -> (Vec[Loc], Loc) {
    ngrn := 0
    nsrn := 0
    nsaa := 0
    out := vec[Loc]()
    // stage A/B: the result first (an indirect result does not take x0: it is x8)
    rloc := Loc.Nothing
    match ret {
        Some(r) => {
            es, n := ct_hfa(&r)
            rloc = match r {
                Flt(sz) => V(0, 1, sz)
                Int(_, _) => X(0, 1)
                _ if n > 0 => V(0, n, es)
                _ if ct_size(&r) > 16 => XR
                _ => X(0, round_up(ct_size(&r), 8) / 8)
            }
        }
        None => {}
    }
    // a value of `size` bytes and alignment `align` on the stack (C.12-C.17; Apple: a scalar takes
    // its own size and alignment, a composite 8-byte aligned slots, variadic arguments 8 each)
    fn stack(nsaa: *i64, size: i64, align: i64, composite: bool, apple: bool, variadic: bool) -> i64 {
        a := if apple && !variadic && !composite { align } else { max(8, align) }
        if a > 16 {
            a = 16
        }
        *nsaa = round_up(*nsaa, a)
        at := *nsaa
        *nsaa += if apple && !variadic && !composite { size } else { round_up(size, 8) }
        return at
    }
    for k, t in args {
        variadic := k >= nfixed
        // Apple: every variadic argument on the stack, in an 8-byte slot
        if apple && variadic {
            size := ct_size(&t)
            if size > 16 && ct_hfa(&t).1 == 0 {
                out.push(RefStack(stack(&nsaa, 8, 8, false, apple, true)))
            } else {
                out.push(Stack(stack(&nsaa, size, ct_align(&t), true, apple, true), size))
            }
            continue
        }
        size := ct_size(&t)
        align := ct_align(&t)
        es, n := ct_hfa(&t)
        match t {
            Flt(sz) => {
                // C.1: a float in the next v register; C.3-C.5 otherwise
                if nsrn < 8 {
                    out.push(V(nsrn, 1, sz))
                    nsrn += 1
                } else {
                    out.push(Stack(stack(&nsaa, sz, sz, false, apple, false), sz))
                }
                continue
            }
            Int(_, _) => {
                // C.9: an integer in the next x register; C.14-C.15 otherwise
                if ngrn < 8 {
                    out.push(X(ngrn, 1))
                    ngrn += 1
                } else {
                    out.push(Stack(stack(&nsaa, size, size, false, apple, false), size))
                }
                continue
            }
            _ => {}
        }
        if n > 0 {
            // C.2: an HFA in consecutive v registers if they are all free; C.3: else NSRN = 8
            // and it goes to the stack (C.4-C.5: aligned to 8, size rounded to 8)
            if nsrn + n <= 8 {
                out.push(V(nsrn, n, es))
                nsrn += n
            } else {
                nsrn = 8
                out.push(Stack(stack(&nsaa, size, align, true, apple, false), size))
            }
            continue
        }
        if size > 16 {
            // B.4: a copy, passed by its address (an integer argument)
            if ngrn < 8 {
                out.push(RefX(ngrn))
                ngrn += 1
            } else {
                out.push(RefStack(stack(&nsaa, 8, 8, false, apple, false)))
            }
            continue
        }
        // C.10: a composite of 16-byte alignment starts at an even register; C.12: in
        // consecutive x registers if they are all free; C.13: else NGRN = 8 and the stack
        words := round_up(size, 8) / 8
        if align == 16 {
            ngrn = round_up(ngrn, 2)
        }
        if ngrn + words <= 8 {
            out.push(X(ngrn, words))
            ngrn += words
        } else {
            ngrn = 8
            out.push(Stack(stack(&nsaa, size, align, true, apple, false), size))
        }
    }
    return (out, rloc)
}

// the registers a placement reads at the call: bit k of the first result for xk, of the second
// for vk (x8 for an indirect result)
fn loc_regs(args: []Loc, ret: Loc) -> (u64, u64) {
    g := u64(0)
    f := u64(0)
    for l in args {
        match l {
            X(r, n) => {
                for j in 0..n {
                    g |= u64(1) << u64(r + j)
                }
            }
            RefX(r) => g |= u64(1) << u64(r)
            V(r, n, _) => {
                for j in 0..n {
                    f |= u64(1) << u64(r + j)
                }
            }
            _ => {}
        }
    }
    if ret == XR {
        g |= u64(1) << 8
    }
    return (g, f)
}

// a placement as text: "x0 v1-v3 [sp+0,4] &x2 &[sp+8]", then "-> x0" / "-> v0-v3" / "-> [x8]"
fn loc_text(args: []Loc, ret: Loc) -> str {
    fn one(l: Loc) -> str {
        match l {
            X(r, 1) => return fmt("x", r)
            X(r, n) => return fmt("x", r, "-x", r + n - 1)
            V(r, 1, _) => return fmt("v", r)
            V(r, n, _) => return fmt("v", r, "-v", r + n - 1)
            Stack(o, s) => return fmt("[sp+", o, ",", s, "]")
            RefX(r) => return fmt("&x", r)
            RefStack(o) => return fmt("&[sp+", o, "]")
            XR => return "[x8]"
            Nothing => return "void"
        }
    }
    parts := vec[str]()
    for l in args {
        parts.push(one(l))
    }
    return fmt(join(parts.items(), " "), " -> ", one(ret))
}
