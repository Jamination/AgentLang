// `when`: compile-time choices between declarations or statements, and `-D NAME=VALUE`.
//
// The driver (main.al) decides every `when` while it loads the files, before anything is
// type-checked, and keeps only the declarations / statements of the taken branch; the other
// branches are parsed and dropped. A condition is made of literals, constants, `==`, `!=`,
// `&&`, `||`, `!` and parentheses. Its names are looked up among the constants (and enums,
// for variants) declared at top level outside every `when`:
// - a private constant of the condition's own file first, then a public one of the program,
//   then one of the library; library files (prelude, OS layer, std modules) see only the
//   library's constants;
// - a constant used in a condition may have any value made of literals, other such constants,
//   variants of enums without data and operators (`const VERBOSE = LEVEL >= 2`), and the -D
//   value of the command line replaces the declared one.
// Library files decide their `when`s right after they are parsed (the run-time library, which
// declares TARGET_OS, is loaded first). The program's `when`s are decided after every file it
// includes outside `when` is loaded; a taken branch may include more files, whose `when`s are
// decided in the next round. A condition whose names are not all known yet waits for a later
// round; after the last round a name that is still unknown is an error. Each decided
// condition of the program is checked again at the end, with all files loaded.
// A `when` in a function body is decided last (all files are known by then) and replaced by
// the statements of its branch, in the enclosing block: it opens no scope.

// a value in a condition
priv enum WV {
    B(bool),
    // an integer: the value (u64 as its bits), its type ("" for an untyped literal or constant)
    I(i64, str),
    F(f64),
    S(str),
    // a variant of an enum without data: the enum (index into WhenCx.enums), the variant
    V(i64, i64),
}

// a constant declared at top level outside `when`
struct WhenConst {
    decl: *ConstDecl
    file: i64
    lib: bool
    // 0 = not evaluated, 1 = being evaluated, 2 = `val` is its value, 3 = not usable (`why`)
    state: i64
    val: WV
    why: str
}

struct WhenEnum {
    decl: *EnumDecl
    file: i64
    lib: bool
}

struct WhenCx {
    consts: Vec[WhenConst]
    const_names: Map[str, Vec[i64]]
    enums: Vec[WhenEnum]
    enum_names: Map[str, Vec[i64]]
    // variant name -> the enums (indices into `enums`) that have it
    variants: Map[str, Vec[i64]]
    // other top-level names, for the diagnostics: name -> what it is
    others: Map[str, str]
    // constants declared inside a branch of a `when`
    inner: Map[str, bool]
    // -D NAME=VALUE: name -> (value, whether `=VALUE` was given), in command-line order
    defs: Map[str, (str, bool)]
    // the -D names that name a constant of the program
    defs_used: Map[str, bool]
    // while deciding: the first name that is not known yet ("" for none; only before the
    // last round), the first error (position and message; "" for none or already reported)
    missing: str
    final_pass: bool
    fail: bool
    fail_pos: Pos
    fail_msg: str
}

// -D NAME=VALUE (`has_value` false for -D NAME); false if NAME was given before
fn when_define(w: *WhenCx, name: str, value: str, has_value: bool) -> bool {
    if w.defs.has(name) {
        return false
    }
    w.defs.set(name, (value, has_value))
    return true
}

priv fn add_name(m: *Map[str, Vec[i64]], n: str, i: i64) {
    l, _ := m.get(n)
    l.push(i)
    m.set(n, l)
}

// the values of the constants are computed again when they are next used
fn when_forget(w: *WhenCx) {
    for i in 0..w.consts.len {
        w.consts[i].state = 0
    }
}

// the constants inside the branches of a `when` (taken or not)
priv fn inner_names(w: *WhenCx, wd: *WhenDecl) {
    for arm in wd.arms {
        for d in arm.decls {
            match d {
                Const(c) => w.inner.set(c.name, true)
                When(x) => inner_names(w, &x)
                _ => {}
            }
        }
    }
}

// Records the top-level declarations of file `file` (outside `when`) that conditions can use.
fn when_register(w: *WhenCx, decls: *Vec[Decl], file: i64, lib: bool) {
    for i in 0..decls.len {
        match decls[i] {
            Const(c) => {
                p := new[ConstDecl]()
                *p = c
                add_name(&w.const_names, c.name, w.consts.len)
                w.consts.push(WhenConst{decl: p, file: file, lib: lib, state: 0, val: B(false), why: ""})
            }
            Enum(e) => {
                p := new[EnumDecl]()
                *p = e
                ei := w.enums.len
                add_name(&w.enum_names, e.name, ei)
                w.enums.push(WhenEnum{decl: p, file: file, lib: lib})
                for v in e.variants {
                    add_name(&w.variants, v.0, ei)
                }
            }
            Fn(f) => {
                if !w.others.has(f.name) {
                    w.others.set(f.name, "function")
                }
            }
            Global(g) => {
                if !w.others.has(g.name) {
                    w.others.set(g.name, "global variable")
                }
            }
            Struct(s) => {
                if !w.others.has(s.name) {
                    w.others.set(s.name, "struct")
                }
            }
            When(x) => inner_names(w, &x)
            _ => {}
        }
    }
}

// The declaration a name of file `file` refers to among `l` (constants or enums): a private
// one of the file, else a public one of the program, else one of the library; -1 if none.
priv fn pick(w: *WhenCx, l: *Vec[i64], consts: bool, file: i64, lib: bool) -> i64 {
    for round in 0..3 {
        for k in 0..l.len {
            i := l[k]
            dfile, dlib, dpriv := if consts {
                c := &w.consts[i]
                (c.file, c.lib, c.decl.is_priv)
            } else {
                e := &w.enums[i]
                (e.file, e.lib, e.decl.is_priv)
            }
            ok := match round {
                0 => dpriv && dfile == file
                1 => !dpriv && !dlib && !lib
                _ => !dpriv && dlib
            }
            if ok {
                return i
            }
        }
    }
    return -1
}

priv fn find_const(w: *WhenCx, n: str, file: i64, lib: bool) -> i64 {
    l, has := w.const_names.get(n)
    if !has {
        return -1
    }
    return pick(w, &l, true, file, lib)
}

priv fn find_enum(w: *WhenCx, n: str, file: i64, lib: bool) -> i64 {
    l, has := w.enum_names.get(n)
    if !has {
        return -1
    }
    return pick(w, &l, false, file, lib)
}

// the index of variant `n` of enum `ei`, or -1
priv fn variant_of(w: *WhenCx, ei: i64, n: str) -> i64 {
    vs := &w.enums[ei].decl.variants
    for i in 0..vs.len {
        if vs[i].0 == n {
            return i
        }
    }
    return -1
}

// the first error of the condition being decided
priv fn fail[T](w: *WhenCx, pos: Pos, msg: str) -> Opt[T] {
    if !w.fail {
        w.fail = true
        w.fail_pos = pos
        w.fail_msg = msg
    }
    return None
}

// a name that is not known (yet): before the last round the condition waits
priv fn unknown[T](w: *WhenCx, n: str, pos: Pos) -> Opt[T] {
    if !w.final_pass {
        if w.missing == "" {
            w.missing = n
        }
        return None
    }
    what, known := w.others.get(n)
    msg := if w.inner.has(n) {
        fmt("`", n, "` is declared inside a `when`: a condition can use only constants declared outside every `when`")
    } else if known {
        fmt("`", n, "` is a ", what, ", not a constant: a `when` condition is decided at compile time and can use only constants (`const`), TARGET_OS, TARGET_ARCH and literals")
    } else {
        fmt("unknown name `", n, "` in a `when` condition (a condition can use only constants declared with `const` outside `when`, TARGET_OS, TARGET_ARCH and literals)")
    }
    return fail[T](w, pos, msg)
}

priv fn kind_name(w: *WhenCx, v: WV) -> str {
    return match v {
        B(_) => "bool"
        I(_, t) => if t == "" { "an integer" } else { t }
        F(_) => "a float"
        S(_) => "str"
        V(e, _) => w.enums[e].decl.name
    }
}

// a variant `n` of enum `ei` as a value
priv fn variant_val(w: *WhenCx, ei: i64, n: str, pos: Pos) -> Opt[WV] {
    vi := variant_of(w, ei, n)
    d := w.enums[ei].decl
    if vi < 0 {
        return fail[WV](w, pos, fmt("enum `", d.name, "` has no variant `", n, "`"))
    }
    if d.tparams.len != 0 || d.variants[vi].1.len != 0 {
        return fail[WV](w, pos, fmt("`", d.name, ".", n, "` cannot be used in a `when` condition: only variants of enums without type parameters and without data can"))
    }
    return Some(V(ei, vi))
}

// A bare name: a variant of the expected enum `want`, a constant, the variant of the one enum
// that has it.
priv fn name_val(w: *WhenCx, n: str, pos: Pos, file: i64, lib: bool, want: i64) -> Opt[WV] {
    if want >= 0 && variant_of(w, want, n) >= 0 {
        return variant_val(w, want, n, pos)
    }
    ci := find_const(w, n, file, lib)
    if ci >= 0 {
        return const_val(w, ci, pos)
    }
    l, has := w.variants.get(n)
    if has {
        // the program's enums first (for a program file), then the library's
        for layer in 0..2 {
            found := -1
            count := 0
            for ei in l {
                e := &w.enums[ei]
                visible := !e.decl.is_priv || e.file == file
                if visible && e.lib == (layer == 1) && !(lib && !e.lib) {
                    if found < 0 {
                        found = ei
                    }
                    count += 1
                }
            }
            if count > 1 {
                return fail[WV](w, pos, fmt("`", n, "` is a variant of several enums: write `Enum.", n, "`"))
            }
            if found >= 0 {
                return variant_val(w, found, n, pos)
            }
        }
    }
    return unknown[WV](w, n, pos)
}

// The value of constant `ci` (used at `pos`).
priv fn const_val(w: *WhenCx, ci: i64, pos: Pos) -> Opt[WV] {
    c := &w.consts[ci]
    name := c.decl.name
    match c.state {
        1 => return fail[WV](w, pos, fmt("constant `", name, "` depends on itself"))
        2 => return Some(c.val)
        3 => return fail[WV](w, pos, c.why)
        _ => {}
    }
    if !c.lib && w.defs.has(name) {
        // the value of -D (its errors are reported with the declaration: when_apply_defs)
        c.state = 1
        r, err := def_value(w, c.decl, c.file)
        match r {
            Some(x) => {
                c.state = 2
                c.val = x.0
                return Some(x.0)
            }
            None => {}
        }
        if err == "" {
            // the type of the constant depends on a name that is not known yet
            c.state = 0
            return unknown[WV](w, name, pos)
        }
        c.state = 3
        c.why = ""
        return fail[WV](w, pos, "")
    }
    c.state = 1
    saved := (w.fail, w.fail_pos, w.fail_msg)
    w.fail = false
    want := ann_enum(w, c.decl, c.file, c.lib)
    v := ev(w, &c.decl.val, c.file, c.lib, want, true)
    match v {
        Some(x) => v = typed(w, c.decl, x, c.file, c.lib)
        None => {}
    }
    match v {
        Some(x) => {
            c.state = 2
            c.val = x
            w.fail, w.fail_pos, w.fail_msg = saved
            return v
        }
        None => {}
    }
    if !w.fail {
        // a name that is not known yet: evaluated again in the next round
        c.state = 0
        w.fail, w.fail_pos, w.fail_msg = saved
        return None
    }
    why := if w.fail_msg == "" { "" } else { fmt("constant `", name, "` (line ", c.decl.pos.line, ") cannot be used in a `when` condition: ", w.fail_msg) }
    c.state = 3
    c.why = why
    w.fail, w.fail_pos, w.fail_msg = saved
    return fail[WV](w, pos, why)
}

// the enum (index) of the declared type of a constant, or -1
priv fn ann_enum(w: *WhenCx, d: *ConstDecl, file: i64, lib: bool) -> i64 {
    match d.ty {
        Some(Name(tn, args, _)) if args.is_empty() => return find_enum(w, tn, file, lib)
        _ => return -1
    }
}

// the integer types: (bits, signed)
priv fn int_type(t: str) -> (i64, bool) {
    return match t {
        "i8" => (8, true)
        "i16" => (16, true)
        "i32" => (32, true)
        "i64" => (64, true)
        "u8" => (8, false)
        "u16" => (16, false)
        "u32" => (32, false)
        "u64" => (64, false)
        _ => (0, false)
    }
}

priv fn wrap(v: i64, t: str) -> i64 {
    return match t {
        "i8" => i64(i8(v))
        "i16" => i64(i16(v))
        "i32" => i64(i32(v))
        "u8" => i64(u8(v))
        "u16" => i64(u16(v))
        "u32" => i64(u32(v))
        _ => v
    }
}

// the value of a constant converted to its declared type
priv fn typed(w: *WhenCx, d: *ConstDecl, v: WV, file: i64, lib: bool) -> Opt[WV] {
    tn := match d.ty {
        Some(Name(n, args, _)) if args.is_empty() => n
        Some(_) => return fail[WV](w, d.pos, "its type cannot be used in a condition")
        None => return Some(v)
    }
    bits, _ := int_type(tn)
    ok := match v {
        B(_) => tn == "bool"
        S(_) => tn == "str"
        F(_) => tn == "f32" || tn == "f64"
        I(x, t) => {
            if bits > 0 && (t == "" || t == tn) {
                return Some(I(wrap(x, tn), tn))
            }
            if (tn == "f32" || tn == "f64") && t == "" {
                return Some(F(f64(x)))
            }
            false
        }
        V(e, _) => e == find_enum(w, tn, file, lib)
    }
    if !ok {
        return fail[WV](w, d.val.pos, fmt("its value (", kind_name(w, v), ") does not have its declared type ", tn))
    }
    return Some(v)
}

priv fn as_bool(w: *WhenCx, v: Opt[WV], what: str, pos: Pos) -> Opt[bool] {
    match v {
        Some(B(b)) => return Some(b)
        Some(x) => return fail[bool](w, pos, fmt(what, " needs a bool, not ", kind_name(w, x)))
        None => return None
    }
}

// a bare name that is not a constant: a variant whose enum the other operand decides
priv fn bare_variant(w: *WhenCx, e: *Expr, file: i64, lib: bool) -> bool {
    match e.k {
        Ident(n) => return find_const(w, n, file, lib) < 0 && w.variants.has(n)
        _ => return false
    }
}

// The value of `e` in a condition (or, with `in_const`, in the value of a constant used by
// one). None after an error (w.fail) or with a name that is not known yet (w.missing).
priv fn ev(w: *WhenCx, e: *Expr, file: i64, lib: bool, want: i64, in_const: bool) -> Opt[WV] {
    match e.k {
        Bool(b) => return Some(B(b))
        Int(n, _) => return Some(I(i64(n), ""))
        Float(f, _) => return Some(F(f))
        Str(s) => return Some(S(s))
        Ident(n) => return name_val(w, n, e.pos, file, lib, want)
        Field(b, n) => {
            match b.k {
                Ident(q) => {
                    ei := find_enum(w, q, file, lib)
                    if ei >= 0 {
                        return variant_val(w, ei, n, e.pos)
                    }
                    if find_const(w, q, file, lib) < 0 && !w.others.has(q) {
                        return unknown[WV](w, q, b.pos)
                    }
                }
                _ => {}
            }
        }
        Un(Not, x) => {
            match as_bool(w, ev(w, x, file, lib, -1, in_const), "`!`", e.pos) {
                Some(b) => return Some(B(!b))
                None => return None
            }
        }
        Un(Neg, x) => {
            v := ev(w, x, file, lib, -1, in_const)
            match v {
                Some(I(i, t)) if in_const || t == "" && is_lit(x) => return Some(I(wrap(-i, t), t))
                Some(F(f)) if in_const || is_lit(x) => return Some(F(-f))
                None => return None
                _ => {}
            }
        }
        Un(BitNot, x) if in_const => {
            match ev(w, x, file, lib, -1, in_const) {
                Some(I(i, t)) => return Some(I(wrap(~i, t), t))
                None => return None
                _ => {}
            }
        }
        Bin(op, a, b) => {
            if op == LAnd || op == LOr {
                what := fmt("`", ast_bin_text(op), "`")
                x := as_bool(w, ev(w, a, file, lib, -1, in_const), what, a.pos)
                y := as_bool(w, ev(w, b, file, lib, -1, in_const), what, b.pos)
                if !is_some(x) || !is_some(y) {
                    return None
                }
                return Some(B(if op == LAnd { x.unwrap() && y.unwrap() } else { x.unwrap() || y.unwrap() }))
            }
            if op == Eq || op == Ne || in_const {
                // a bare variant takes its enum from the other operand
                xv: Opt[WV] = None
                yv: Opt[WV] = None
                if bare_variant(w, a, file, lib) && !bare_variant(w, b, file, lib) {
                    yv = ev(w, b, file, lib, -1, in_const)
                    xv = ev(w, a, file, lib, enum_of(yv), in_const)
                } else {
                    xv = ev(w, a, file, lib, -1, in_const)
                    yv = ev(w, b, file, lib, enum_of(xv), in_const)
                }
                if !is_some(xv) || !is_some(yv) {
                    return None
                }
                return binary(w, op, xv.unwrap(), yv.unwrap(), e.pos)
            }
            return fail[WV](w, e.pos, fmt("the operator `", ast_bin_text(op), "` cannot be used in a `when` condition (only `==`, `!=`, `&&`, `||` and `!`); a constant can hold the result: `const BIG = ", ast_expr_str(e), "`"))
        }
        _ => {}
    }
    if in_const {
        return fail[WV](w, e.pos, fmt("its value `", ast_expr_str(e), "` is not made of literals, constants, variants and operators"))
    }
    return fail[WV](w, e.pos, fmt("`", ast_expr_str(e), "` cannot be used in a `when` condition: a condition is decided at compile time and is made of constants, literals, `==`, `!=`, `&&`, `||`, `!` and parentheses"))
}

priv fn is_lit(e: *Expr) -> bool {
    return match e.k {
        Int(_, _), Float(_, _) => true
        _ => false
    }
}

priv fn enum_of(v: Opt[WV]) -> i64 {
    return match v {
        Some(V(e, _)) => e
        _ => -1
    }
}

// x (op) y for operands of the same type
priv fn binary(w: *WhenCx, op: BinOp, x: WV, y: WV, pos: Pos) -> Opt[WV] {
    mismatch := fmt("`", ast_bin_text(op), "` on different types: ", kind_name(w, x), " and ", kind_name(w, y))
    match (x, y) {
        (I(a, ta), I(b, tb)) => {
            if ta != "" && tb != "" && ta != tb {
                return fail[WV](w, pos, mismatch)
            }
            t := if ta == "" { tb } else { ta }
            return int_op(w, op, a, b, t, pos)
        }
        (F(_), F(_)), (F(_), I(_, "")), (I(_, ""), F(_)) => return float_op(w, op, x, y, pos)
        (B(a), B(b)) => {
            match op {
                Eq => return Some(B(a == b))
                Ne => return Some(B(a != b))
                _ => {}
            }
        }
        (S(a), S(b)) => {
            match op {
                Eq => return Some(B(a == b))
                Ne => return Some(B(a != b))
                _ => {}
            }
        }
        (V(ea, a), V(eb, b)) => {
            if ea != eb {
                return fail[WV](w, pos, mismatch)
            }
            match op {
                Eq => return Some(B(a == b))
                Ne => return Some(B(a != b))
                _ => {}
            }
        }
        _ => return fail[WV](w, pos, mismatch)
    }
    return fail[WV](w, pos, fmt("`", ast_bin_text(op), "` does not apply to ", kind_name(w, x)))
}

priv fn int_op(w: *WhenCx, op: BinOp, a: i64, b: i64, t: str, pos: Pos) -> Opt[WV] {
    bits, signed := int_type(t)
    if bits == 0 {
        bits = 64
        signed = true
    }
    uns := !signed
    r: i64 = 0
    match op {
        Add => r = a + b
        Sub => r = a - b
        Mul => r = a * b
        And => r = a & b
        Or => r = a | b
        Xor => r = a ^ b
        Shl => r = a << (b & (bits - 1))
        Shr => r = if uns { i64(u64(a) >> u64(b & (bits - 1))) } else { a >> (b & (bits - 1)) }
        Div, Rem => {
            if b == 0 {
                return fail[WV](w, pos, "division by zero")
            }
            if uns {
                r = i64(if op == Div { u64(a) / u64(b) } else { u64(a) % u64(b) })
            } else if b == -1 {
                r = if op == Div { -a } else { 0 }
            } else {
                r = if op == Div { a / b } else { a % b }
            }
        }
        Eq => return Some(B(a == b))
        Ne => return Some(B(a != b))
        Lt => return Some(B(if uns { u64(a) < u64(b) } else { a < b }))
        Le => return Some(B(if uns { u64(a) <= u64(b) } else { a <= b }))
        Gt => return Some(B(if uns { u64(a) > u64(b) } else { a > b }))
        Ge => return Some(B(if uns { u64(a) >= u64(b) } else { a >= b }))
        _ => return None
    }
    return Some(I(wrap(r, t), t))
}

priv fn float_op(w: *WhenCx, op: BinOp, x: WV, y: WV, pos: Pos) -> Opt[WV] {
    a := match x {
        F(f) => f
        I(i, _) => f64(i)
        _ => 0.0
    }
    b := match y {
        F(f) => f
        I(i, _) => f64(i)
        _ => 0.0
    }
    return match op {
        Add => Some(F(a + b))
        Sub => Some(F(a - b))
        Mul => Some(F(a * b))
        Div => Some(F(a / b))
        Eq => Some(B(a == b))
        Ne => Some(B(a != b))
        Lt => Some(B(a < b))
        Le => Some(B(a <= b))
        Gt => Some(B(a > b))
        Ge => Some(B(a >= b))
        _ => fail[WV](w, pos, fmt("`", ast_bin_text(op), "` does not apply to floats"))
    }
}

// Decides a `when` of file `file`: the index of the taken branch, -1 if none is taken (no
// condition holds, or after an error, which is reported), -2 if a name is not known yet
// (only before the last round: `final_pass` false).
fn when_decide(w: *WhenCx, wd: *WhenDecl, file: i64, lib: bool, final_pass: bool, errs: *Vec[Diag]) -> i64 {
    w.final_pass = final_pass
    w.missing = ""
    taken := -1
    failed := false
    found := vec[Diag]()
    for i in 0..wd.arms.len {
        c := match wd.arms[i].cond {
            Some(x) => x
            None => {
                if taken < 0 && !failed {
                    taken = i
                }
                break
            }
        }
        w.fail = false
        v := ev(w, c, file, lib, -1, false)
        match v {
            Some(B(b)) => {
                if b && taken < 0 && !failed {
                    taken = i
                }
            }
            Some(x) => {
                failed = true
                found.push(Diag{pos: c.pos, msg: fmt("the condition of `when` must be a bool, not ", kind_name(w, x))})
            }
            None => {
                failed = true
                if w.fail && w.fail_msg != "" {
                    found.push(Diag{pos: w.fail_pos, msg: w.fail_msg})
                }
            }
        }
    }
    if w.missing != "" {
        return -2
    }
    errs.extend(found.items())
    return if failed && taken < 0 { -1 } else { taken }
}

// ---------- `when` in function bodies ----------

// Replaces every `when` statement in the declarations of a file by the statements of its
// taken branch (all files are loaded: these are decided once).
fn when_stmts(w: *WhenCx, decls: *Vec[Decl], file: i64, lib: bool, errs: *Vec[Diag]) {
    s := Walk{w: w, file: file, lib: lib, errs: errs}
    for i in 0..decls.len {
        match decls[i] {
            Fn(&f) => s.block(&f.body)
            Test(&t) => s.block(&t.body)
            Const(&c) => s.expr(&c.val)
            Global(&g) => {
                match g.init {
                    Some(&e) => s.expr(e)
                    None => {}
                }
            }
            _ => {}
        }
    }
}

priv struct Walk {
    w: *WhenCx
    file: i64
    lib: bool
    errs: *Vec[Diag]
}

priv fn block(s: *Walk, b: *Block) {
    has := false
    for i in 0..b.stmts.len {
        match b.stmts[i].k {
            When(_) => {
                has = true
            }
            _ => s.stmt(&b.stmts[i])
        }
    }
    if !has {
        return
    }
    out := vec[Stmt]()
    for st in b.stmts {
        match st.k {
            When(wd) => {
                k := when_decide(s.w, wd, s.file, s.lib, true, s.errs)
                if k >= 0 {
                    body := wd.arms[k].body
                    s.block(body)
                    out.extend(body.stmts.items())
                }
            }
            _ => out.push(st)
        }
    }
    b.stmts = out
}

priv fn opt_expr(s: *Walk, o: Opt[*Expr]) {
    match o {
        Some(e) => s.expr(e)
        None => {}
    }
}

priv fn stmt(s: *Walk, st: *Stmt) {
    match st.k {
        Expr(e), Let(_, e), Assign(_, _, e), MultiAssign(_, e) => s.expr(e)
        Var(_, _, init) => s.opt_expr(init)
        If(c, t, eo) => {
            s.expr(c)
            s.block(t)
            match eo {
                Some(e) => s.block(e)
                None => {}
            }
        }
        While(c, b) => {
            s.expr(c)
            s.block(b)
        }
        Loop(b), Block(b), Defer(b) => s.block(b)
        For(f) => {
            s.expr(f.lo)
            s.opt_expr(f.hi)
            s.opt_expr(f.step)
            s.block(f.body)
        }
        Return(v) => s.opt_expr(v)
        Assert(c, m) => {
            s.expr(c)
            s.opt_expr(m)
        }
        Labeled(_, inner) => s.stmt(inner)
        Fn(d) => s.block(&d.body)
        _ => {}
    }
}

// expressions hold blocks too: `if` / `match` values, anonymous functions
priv fn expr(s: *Walk, e: *Expr) {
    match e.k {
        Un(_, x), Field(x, _) => s.expr(x)
        Bin(_, a, b) => {
            s.expr(a)
            s.expr(b)
        }
        Call(c, args), Index(c, args) => {
            s.expr(c)
            for i in 0..args.len {
                s.expr(&args[i])
            }
        }
        Slice(b, lo, hi) => {
            s.expr(b)
            s.opt_expr(lo)
            s.opt_expr(hi)
        }
        Lit(te, items) => {
            s.expr(te)
            for i in 0..items.len {
                s.expr(&items[i].1)
            }
        }
        Tuple(es) => {
            for i in 0..es.len {
                s.expr(&es[i])
            }
        }
        If(c, t, el) => {
            s.expr(c)
            s.block(t)
            s.block(el)
        }
        Match(sc, arms) => {
            s.expr(sc)
            for i in 0..arms.len {
                s.opt_expr(arms[i].guard)
                s.block(&arms[i].body)
            }
        }
        Fn(d) => s.block(&d.body)
        _ => {}
    }
}

// ---------- -D NAME=VALUE ----------

// The value of `-D NAME=...` for the constant `d` of file `file`: (value, its expression) or
// None with the reason ("" if the type of the constant is not known yet).
priv fn def_value(w: *WhenCx, d: *ConstDecl, file: i64) -> (Opt[(WV, Expr)], str) {
    none: Opt[(WV, Expr)] = None
    text, has_value := w.defs.get_or(d.name, ("", false))
    shown := if has_value { fmt("-D ", d.name, "=", text) } else { fmt("-D ", d.name) }
    // the type: as declared, else that of the declared value
    tn := ""
    ei := -1
    match d.ty {
        Some(Name(n, args, _)) if args.is_empty() => {
            tn = n
            ei = find_enum(w, n, file, false)
        }
        Some(t) => return (none, fmt(shown, ": -D cannot set a constant of type ", ast_type_str(&t)))
        None => {
            saved := (w.fail, w.fail_pos, w.fail_msg, w.missing, w.final_pass)
            w.fail = false
            w.missing = ""
            w.final_pass = false
            v := ev(w, &d.val, file, false, -1, true)
            missing := w.missing
            w.fail, w.fail_pos, w.fail_msg, w.missing, w.final_pass = saved
            match v {
                Some(B(_)) => tn = "bool"
                Some(I(_, t)) => tn = if t == "" { "int" } else { t }
                Some(F(_)) => tn = "float"
                Some(S(_)) => tn = "str"
                Some(V(e, _)) => {
                    ei = e
                    tn = w.enums[e].decl.name
                }
                None => {
                    if missing != "" && !w.final_pass {
                        return (none, "")
                    }
                    return (none, fmt(shown, ": the type of `", d.name, "` cannot be told from its value; declare it: `const ", d.name, ": T = ...`"))
                }
            }
        }
    }
    if !has_value && tn != "bool" {
        return (none, fmt(shown, ": only a bool constant may be set without a value; write -D ", d.name, "=VALUE"))
    }
    at := d.val.pos
    bad := fmt(shown, ": `", text, "` is not a value of type ", if tn == "int" { "i64" } else if tn == "float" { "f32 / f64" } else { tn }, " (the type of `", d.name, "`)")
    if tn == "bool" {
        if !has_value || text == "true" {
            return (Some((B(true), Expr{k: Bool(true), pos: at})), "")
        }
        if text == "false" {
            return (Some((B(false), Expr{k: Bool(false), pos: at})), "")
        }
        return (none, bad)
    }
    if tn == "str" {
        return (Some((S(text), Expr{k: Str(text), pos: at})), "")
    }
    if ei >= 0 {
        vi := variant_of(w, ei, text)
        ed := w.enums[ei].decl
        if vi < 0 || ed.tparams.len != 0 || ed.variants[vi].1.len != 0 {
            return (none, bad)
        }
        q := Expr{k: Ident(ast_intern(ed.name)), pos: at}
        return (Some((V(ei, vi), Expr{k: Field(parser_box(q), ast_intern(text)), pos: at})), "")
    }
    // a number: an integer or float literal, maybe negative
    errs := vec[Diag]()
    toks := lexer_lex(text, file, &errs)
    ts := vec[Tk]()
    for t in toks {
        if t.t != Nl && t.t != Eof {
            ts.push(t.t)
        }
    }
    neg := !ts.is_empty() && ts[0] == P('-')
    if !errs.is_empty() || ts.len != (if neg { 2 } else { 1 }) {
        return (none, bad)
    }
    bits, signed := int_type(tn)
    match ts.last() {
        Int(n, dec) => {
            if tn == "float" || tn == "f32" || tn == "f64" {
                f := if neg { -f64(n) } else { f64(n) }
                return (Some((F(f), Expr{k: Float(f, f32(f)), pos: at})), "")
            }
            if tn == "int" {
                bits = 64
                signed = true
            }
            if bits == 0 {
                return (none, bad)
            }
            max_pos := if signed { (u64(1) << u64(bits - 1)) - 1 } else { u64(0xFFFFFFFFFFFFFFFF) >> u64(64 - bits) }
            if (neg && (!signed || n > max_pos + 1)) || (!neg && n > max_pos) {
                return (none, fmt(shown, ": ", text, " does not fit in ", if tn == "int" { "i64" } else { tn }))
            }
            lit := Expr{k: Int(n, dec), pos: at}
            v := if neg { -i64(n) } else { i64(n) }
            ty := if tn == "int" { "" } else { tn }
            if neg {
                return (Some((I(v, ty), Expr{k: Un(Neg, parser_box(lit)), pos: at})), "")
            }
            return (Some((I(v, ty), lit)), "")
        }
        Float(f, g) => {
            if !(tn == "float" || tn == "f32" || tn == "f64") {
                return (none, bad)
            }
            if neg {
                return (Some((F(-f), Expr{k: Un(Neg, parser_box(Expr{k: Float(f, g), pos: at})), pos: at})), "")
            }
            return (Some((F(f), Expr{k: Float(f, g), pos: at})), "")
        }
        _ => return (none, bad)
    }
}

// Gives the constants of a program file (`lib` false) their -D values: the declared value is
// replaced by the literal of the command line.
fn when_apply_defs(w: *WhenCx, decls: *Vec[Decl], file: i64, errs: *Vec[Diag]) {
    if w.defs.len == 0 {
        return
    }
    for i in 0..decls.len {
        match decls[i] {
            Const(&c) => {
                if !w.defs.has(c.name) {
                    continue
                }
                w.defs_used.set(c.name, true)
                saved := w.final_pass
                w.final_pass = true
                r, err := def_value(w, c, file)
                w.final_pass = saved
                match r {
                    Some(x) => {
                        c.val = x.1
                    }
                    None => errs.push(Diag{pos: c.pos, msg: err})
                }
            }
            _ => {}
        }
    }
}

// the -D names that no constant of the program has (positions in file -1: the command line)
fn when_unused_defs(w: *WhenCx, errs: *Vec[Diag]) {
    for name in w.defs.keys() {
        if w.defs_used.has(name) {
            continue
        }
        why := ""
        l, has := w.const_names.get(name)
        if has && l.len > 0 && w.consts[l[0]].lib {
            why = fmt(": `", name, "` is a constant of the library, which -D does not change")
        } else if w.inner.has(name) {
            why = fmt(": `", name, "` is declared only in a branch of `when` that is not taken")
        } else {
            what, known := w.others.get(name)
            if known {
                why = fmt(": `", name, "` is a ", what, ", not a `const`")
            }
        }
        errs.push(Diag{pos: Pos{file: -1, line: 0, col: 0}, msg: fmt("-D ", name, ": the program declares no constant `", name, "`", why)})
    }
}
