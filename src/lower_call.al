// Calls: user functions (with generic inference and UFCS), indirect calls, builtins, printing.

enum Callee {
    CalleeDirect(i64),
    CalleeInd(i64),
}

fn lower_call_has_call(e *Expr) bool {
    match e.k {
        EKCall(_, _) => {
            return true
        }
        EKMatch(_, _) => {
            return true
        }
        EKIf(_, _, _) => {
            return true
        }
        EKUn(_, x) => {
            return lower_call_has_call(x)
        }
        EKBin(_, a, b) => {
            return lower_call_has_call(a) || lower_call_has_call(b)
        }
        EKIndex(b, i) => {
            if lower_call_has_call(b) {
                return true
            }
            for j in 0..i.len {
                if lower_call_has_call(&i[j]) {
                    return true
                }
            }
            return false
        }
        EKSlice(b, l, h) => {
            if lower_call_has_call(b) {
                return true
            }
            match l {
                Some(x) => {
                    if lower_call_has_call(x) {
                        return true
                    }
                }
                None => {}
            }
            match h {
                Some(x) => {
                    if lower_call_has_call(x) {
                        return true
                    }
                }
                None => {}
            }
            return false
        }
        EKField(b, _) => {
            return lower_call_has_call(b)
        }
        EKLit(_, items) => {
            for j in 0..items.len {
                if lower_call_has_call(&items[j].1) {
                    return true
                }
            }
            return false
        }
        EKTuple(es) => {
            for j in 0..es.len {
                if lower_call_has_call(&es[j]) {
                    return true
                }
            }
            return false
        }
        _ => {
            return false
        }
    }
    return false
}

// `later.iter().any(has_call)`
fn lower_call_any_has_call(later []Expr) bool {
    for j in 0..later.len {
        if lower_call_has_call(&later[j]) {
            return true
        }
    }
    return false
}

// `ts.iter().any(|a| mentions_unbound(a, tparams, env))`
fn lower_call_any_mentions_unbound(ts *Vec[TypeAst], tparams []str, env *Map[str, i64]) bool {
    for j in 0..ts.len {
        if lower_call_mentions_unbound(&ts[j], tparams, env) {
            return true
        }
    }
    return false
}

fn lower_call_mentions_unbound(t *TypeAst, tparams []str, env *Map[str, i64]) bool {
    match *t {
        TypeAstName(n, args, _) => {
            return (args.len == 0 && contains(tparams, n) && !env.has(n)) || lower_call_any_mentions_unbound(&args, tparams, env)
        }
        TypeAstPtr(e) => {
            return lower_call_mentions_unbound(e, tparams, env)
        }
        TypeAstSlice(e) => {
            return lower_call_mentions_unbound(e, tparams, env)
        }
        TypeAstArray(_, e) => {
            return lower_call_mentions_unbound(e, tparams, env)
        }
        TypeAstFn(ps, r) => {
            if lower_call_any_mentions_unbound(&ps, tparams, env) {
                return true
            }
            match r {
                Some(rt) => {
                    return lower_call_mentions_unbound(rt, tparams, env)
                }
                None => {
                    return false
                }
            }
        }
        TypeAstTuple(ts) => {
            return lower_call_any_mentions_unbound(&ts, tparams, env)
        }
    }
    return false
}

// an independent copy of a unification environment (assigning a Map shares its storage)
fn lower_call_clone_env(m *Map[str, i64]) Map[str, i64] {
    out := map[str, i64]()
    for key in m.keys() {
        out.set(key, m.get_or(key, 0))
    }
    return out
}

// `!env.contains_key(p)` for any type parameter
fn lower_call_any_unbound(tparams *Vec[str], env *Map[str, i64]) bool {
    for j in 0..tparams.len {
        if !env.has(tparams[j]) {
            return true
        }
    }
    return false
}

fn lower_call_is_ptr(k TyK) bool {
    match k {
        TyKPtr(_) => true
        _ => false
    }
}

fn lower_call_is_fn(k TyK) bool {
    match k {
        TyKFn(_, _) => true
        _ => false
    }
}


fn lower_call_is_slice(k TyK) bool {
    match k {
        TyKSlice(_) => true
        _ => false
    }
}

fn lower_call_is_enum(k TyK) bool {
    match k {
        TyKEnum(_) => true
        _ => false
    }
}

fn lower_call_is_f64(k TyK) bool {
    match k {
        TyKF64 => true
        _ => false
    }
}

fn lower_call_is_f32(k TyK) bool {
    match k {
        TyKF32 => true
        _ => false
    }
}

// matches!(k, TyK::Int(bits, _))
fn lower_call_is_int_bits(k TyK, bits i64) bool {
    match k {
        TyKInt(b, _) => i64(b) == bits
        _ => false
    }
}

// matches!(k, TyK::Ptr(i) if i == inner)
fn lower_call_is_ptr_to(k TyK, inner i64) bool {
    match k {
        TyKPtr(i) => i == inner
        _ => false
    }
}

// the element type of a slice type
fn lower_call_slice_elem(k TyK) i64 {
    match k {
        TyKSlice(e) => {
            return e
        }
        _ => {}
    }
    panic("unreachable")
}

fn lower_call_is_cv_float(o Opt[CV]) bool {
    match o {
        Some(cv) => {
            match cv {
                CVFloat(_) => {
                    return true
                }
                _ => {
                    return false
                }
            }
        }
        None => {
            return false
        }
    }
    return false
}

fn lower_call_unwrap(o Opt[Val]) Val {
    match o {
        Some(v) => {
            return v
        }
        None => {}
    }
    panic("called `Option::unwrap()` on a `None` value")
}

// `explicit.as_deref()`
fn lower_call_as_slice(o Opt[Vec[i64]]) Opt[[]i64] {
    match o {
        Some(v) => {
            return Some(v.items())
        }
        None => {
            return None
        }
    }
    return None
}

// the empty list of already evaluated arguments
fn lower_call_no_pre() [](i64, Val) {
    return [](i64, Val){}
}

// `Path::parent` of a source file name (empty if there is none)
fn lower_call_parent_dir(src str) str {
    n := len(src)
    // trailing separators do not form a component
    while n > 1 && src[n - 1] == '/' {
        n -= 1
    }
    if n == 0 || (n == 1 && src[0] == '/') {
        return ""
    }
    i := n - 1
    while i >= 0 && src[i] != '/' {
        i -= 1
    }
    if i < 0 {
        return ""
    }
    while i > 0 && src[i - 1] == '/' {
        i -= 1
    }
    if i == 0 {
        return "/"
    }
    return src[..i]
}

// `PathBuf::join`
fn lower_call_path_join(dir str, rel str) str {
    if len(rel) > 0 && rel[0] == '/' {
        return rel
    }
    if len(dir) == 0 {
        return rel
    }
    if dir[len(dir) - 1] == '/' {
        return concat(dir, rel)
    }
    return fmt(dir, "/", rel)
}

// why `path` could not be read, in the words of `std::io::Error`
fn lower_call_io_error(path str) str {
    e := 0
    fd := syscall(2, cstr(path), 0, 0)
    if fd < 0 {
        e = -fd
    } else {
        var b [1]u8
        r := syscall(0, fd, ptr(b), 1)
        if r < 0 {
            e = -r
        }
        syscall(3, fd)
    }
    text := match e {
        2 => "No such file or directory"
        13 => "Permission denied"
        20 => "Not a directory"
        21 => "Is a directory"
        _ => ""
    }
    if len(text) == 0 {
        return fmt("os error ", e)
    }
    return fmt(text, " (os error ", e, ")")
}

fn unify(self *Fx, t *TypeAst, ty i64, tparams []str, env *Map[str, i64]) bool {
    if ty == T_ERR {
        return false
    }
    match *t {
        TypeAstName(n, args, _) => {
            if args.len == 0 && contains(tparams, n) {
                b, found := env.get(n)
                if found {
                    return b == ty
                }
                env.set(n, ty)
                return true
            }
            if args.len == 0 {
                return true // concrete; checked after resolution
            }
            var decl_name str
            var targs Vec[i64]
            match self.cx.types.k(ty) {
                TyKStruct(s) => {
                    si := &self.cx.types.structs[s]
                    decl_name = self.cx.struct_decls[si.decl].name
                    targs = clone(si.targs)
                }
                TyKEnum(e) => {
                    ei := &self.cx.types.enums[e]
                    decl_name = self.cx.enum_decls[ei.decl].name
                    targs = clone(ei.targs)
                }
                _ => {
                    return false
                }
            }
            if decl_name != n || targs.len != args.len {
                return false
            }
            ok := true
            for i in 0..args.len {
                if !self.unify(&args[i], targs[i], tparams, env) {
                    ok = false
                }
            }
            return ok
        }
        TypeAstPtr(e) => {
            match self.cx.types.k(ty) {
                TyKPtr(t2) => {
                    return self.unify(e, t2, tparams, env)
                }
                _ => {
                    return false
                }
            }
        }
        TypeAstSlice(e) => {
            match self.cx.types.k(ty) {
                TyKSlice(t2) => {
                    return self.unify(e, t2, tparams, env)
                }
                _ => {
                    return false
                }
            }
        }
        TypeAstArray(_, e) => {
            match self.cx.types.k(ty) {
                TyKArray(t2, _) => {
                    return self.unify(e, t2, tparams, env)
                }
                _ => {
                    return false
                }
            }
        }
        TypeAstFn(ps, r) => {
            match self.cx.types.k(ty) {
                TyKFn(pt, rt) => {
                    if pt.len != ps.len {
                        return false
                    }
                    ok := true
                    for i in 0..ps.len {
                        if !self.unify(&ps[i], pt[i], tparams, env) {
                            ok = false
                        }
                    }
                    match r {
                        Some(ra) => {
                            if !self.unify(ra, rt, tparams, env) {
                                ok = false
                            }
                        }
                        None => {}
                    }
                    return ok
                }
                _ => {
                    return false
                }
            }
        }
        TypeAstTuple(ts) => {
            match self.cx.types.k(ty) {
                TyKTuple(tt) => {
                    if tt.len != ts.len {
                        return false
                    }
                    ok := true
                    for i in 0..ts.len {
                        if !self.unify(&ts[i], tt[i], tparams, env) {
                            ok = false
                        }
                    }
                    return ok
                }
                _ => {
                    return false
                }
            }
        }
    }
    return false
}

fn call_rt(self *Fx, name str, targs Vec[i64], args Vec[Val], pos Pos) Val {
    di, found := self.cx.p_fn_names.get(name)
    if !found {
        di, found = self.cx.fn_names.get(name)
    }
    if !found {
        self.err(pos, fmt("internal: runtime function `", name, "` is missing"))
        return val_err()
    }
    fid := self.cx.inst_fn(di, targs)
    sig := self.cx.fn_sigs[fid]
    ptys := sig.0
    rty := sig.1
    return self.emit_call(CalleeDirect(fid), ptys.items(), rty, args)
}

// call of a C function through its import slot, with the C calling convention
fn emit_extern_call(self *Fx, x i64, ptys []i64, rty i64, args Vec[Val]) Val {
    got := self.cx.module.externs[x].got
    a := self.ins(OpGAddr, TI64, vec[i64](), got)
    target := self.load_raw(a, TI64, AK_PTR)
    ir_args := vec_of([]i64{target})
    for i in 0..min(args.len, len(ptys)) {
        v := args[i]
        pt := ptys[i]
        s := self.scalar(v)
        // C callees expect narrow integers extended to 32 bits
        it := self.irt(pt)
        if it == TI8 || it == TI16 {
            var op Op
            if self.cx.types.is_signed(pt) {
                op = OpSExt
            } else {
                op = OpZExt
            }
            s = self.ins(op, TI32, vec_of([]i64{s}), 0)
        }
        ir_args.push(s)
    }
    var rt T
    match self.cx.abi_ret(rty) {
        RetAbiScalar(t) => {
            rt = t
        }
        _ => {
            rt = TVoid
        }
    }
    c := self.ins(OpCallInd, rt, ir_args, 0)
    self.f.im(c).aux = 1
    if rty == T_NEVER {
        self.terminate(TermTrap)
        return val_never()
    }
    if rt == TVoid {
        return val_unit()
    }
    return self.sval(rty, c)
}

fn emit_call(self *Fx, callee Callee, ptys []i64, rty i64, args Vec[Val]) Val {
    any_err := false
    for i in 0..args.len {
        if args[i].ty == T_ERR {
            any_err = true
            break
        }
    }
    if any_err || rty == T_ERR {
        return val_err()
    }
    match callee {
        CalleeDirect(fid) => {
            match self.cx.module.funcs[fid].ext {
                Some(x) => {
                    return self.emit_extern_call(x, ptys, rty, args)
                }
                None => {}
            }
        }
        _ => {}
    }
    ir_args := vec[i64]()
    match callee {
        CalleeInd(f) => {
            ir_args.push(f)
        }
        _ => {}
    }
    rabi := self.cx.abi_ret(rty)
    sret_tmp := NOV
    match rabi {
        RetAbiSRet => {
            sret_tmp = self.temp(rty)
            ir_args.push(sret_tmp)
        }
        _ => {}
    }
    for i in 0..min(args.len, len(ptys)) {
        a := args[i]
        pt := ptys[i]
        match self.cx.abi_param(pt) {
            ParamAbiScalar(_) => {
                s := self.scalar(a)
                ir_args.push(s)
            }
            ParamAbiFlat(leaves) => {
                for j in 0..leaves.len {
                    l := leaves[j]
                    ad := self.add_off(a.v, i64(l.off))
                    v := self.load_raw(ad, l.t, l.alias)
                    ir_args.push(v)
                }
            }
            ParamAbiByRef => {
                t := self.temp(pt)
                tv := self.mval(pt, t)
                self.store(tv, a)
                ir_args.push(t)
            }
        }
    }
    var op Op
    k := 0
    match callee {
        CalleeDirect(fid) => {
            op = OpCall
            k = fid
        }
        CalleeInd(_) => {
            op = OpCallInd
            k = 0
        }
    }
    var res Val
    match rabi {
        RetAbiNone => {
            self.ins(op, TVoid, ir_args, k)
            res = val_unit()
        }
        RetAbiSRet => {
            self.ins(op, TVoid, ir_args, k)
            res = self.mval(rty, sret_tmp)
        }
        RetAbiScalar(t) => {
            c := self.ins(op, t, ir_args, k)
            res = self.sval(rty, c)
        }
        RetAbiFlat(leaves) => {
            tmp := self.temp(rty)
            if leaves.len == 1 {
                l0 := leaves[0]
                c := self.ins(op, l0.t, ir_args, k)
                a := self.add_off(tmp, i64(l0.off))
                self.store_raw(a, c, l0.t, l0.alias)
            } else {
                c := self.ins(op, TVoid, ir_args, k)
                for i in 0..leaves.len {
                    l := leaves[i]
                    p := self.ins(OpProj, l.t, vec_of([]i64{c}), i)
                    a := self.add_off(tmp, i64(l.off))
                    self.store_raw(a, p, l.t, l.alias)
                }
            }
            res = self.mval(rty, tmp)
        }
    }
    if rty == T_NEVER {
        self.terminate(TermTrap)
        return val_never()
    }
    return res
}

// copy aggregate lvalues that later argument expressions could modify
fn stabilize(self *Fx, v Val, later []Expr) Val {
    if v.mem && lower_call_any_has_call(later) {
        t := self.temp(v.ty)
        tv := self.mval(v.ty, t)
        self.store(tv, v)
        return tv
    }
    return v
}

fn call_indirect(self *Fx, fv Val, args []Expr, pos Pos) Val {
    var ptys Vec[i64]
    rty := 0
    match self.cx.types.k(fv.ty) {
        TyKFn(p, r) => {
            ptys = p
            rty = r
        }
        TyKErr => {
            return val_err()
        }
        _ => {
            tn := self.tyname(fv.ty)
            self.err(pos, fmt(tn, " is not callable"))
            return val_err()
        }
    }
    if ptys.len != len(args) {
        self.err(pos, fmt("function value expects ", ptys.len, " argument(s), got ", len(args)))
        return val_err()
    }
    f := self.scalar(fv)
    vals := vec[Val]()
    for i in 0..len(args) {
        a := &args[i]
        v := self.expr(a, Some(ptys[i]))
        v = self.coerce(v, ptys[i], a.pos)
        v = self.stabilize(v, args[i + 1..])
        vals.push(v)
    }
    return self.emit_call(CalleeInd(f), ptys.items(), rty, vals)
}

// evaluates every argument for its diagnostics
fn lower_call_eval_all(s *Fx, args []Expr) {
    for i in 0..len(args) {
        s.expr(&args[i], None)
    }
}

// The receiver of a method call `recv.f(...)`: like `expr`, but a variable, field or element
// stays a place also when its type is a scalar, so that `f` can be given its address if it
// takes a pointer (`call_decl` loads the value at once if it does not).
fn recv_val(self *Fx, recv *Expr) Val {
    match recv.k {
        EKField(b, name) => {
            if self.qual_enum(b).0 >= 0 {
                // `Enum.Variant`
                return self.expr(recv, None)
            }
            if name == "len" {
                // the length of a slice or array, or a field called `len`
                bv := self.lvalue_base(b)
                match self.len_of(bv) {
                    Some(v) => {
                        return v
                    }
                    None => {}
                }
                match self.field_of(bv, name, recv.pos) {
                    Some(p) => {
                        return p
                    }
                    None => {
                        return val_err()
                    }
                }
            }
        }
        EKIndex(b, _) => {
            // `f[T]`: an instantiation of a generic function, not an element
            match b.k {
                EKIdent(n) => {
                    if !is_some(self.lookup(n)) && self.cx.fn_candidates(n).len != 0 && !self.cx.global_decls.has(n) {
                        return self.expr(recv, None)
                    }
                }
                _ => {}
            }
        }
        _ => {}
    }
    return self.lvalue_base(recv)
}

fn call(self *Fx, c *Expr, args []Expr, expect Opt[i64], pos Pos) Val {
    match c.k {
        EKIdent(n) => {
            match self.lookup(n) {
                Some(x) => {
                    if x.0 < 0 && x.0 != LOWER_NESTED_OUTER {
                        return self.call_nested(-x.0 - 1, None, args, expect, pos)
                    }
                    fv := self.expr(c, None)
                    if fv.ty == T_ERR {
                        lower_call_eval_all(self, args)
                        return val_err()
                    }
                    return self.call_indirect(fv, args, pos)
                }
                None => {}
            }
            // a variant; in a call, a builtin function or type of the same name wins
            // (`len(x)`, `i64(x)`): such a variant is constructed as `Enum.Variant(..)`
            bv := self.bare_variant(n, expect)
            if bv.2 != 0 && !lower_match_builtin_name(n) {
                if bv.2 == 1 {
                    return self.construct_variant(bv.0, bv.1, args, expect, pos)
                }
                self.variant_ambiguous(n, pos)
                lower_call_eval_all(self, args)
                return val_err()
            }
            cands := self.cx.fn_candidates(n)
            if cands.len != 0 && lower_mem_is_builtin(n) {
                return self.call_shared(n, cands, None, None, c, args, expect, pos)
            }
            if cands.len == 1 {
                return self.call_decl(cands[0], None, None, args, expect, pos, lower_call_no_pre())
            }
            if cands.len > 1 {
                return self.call_overloaded(cands.items(), None, None, args, expect, pos)
            }
            match self.builtin(n, None, args, expect, pos) {
                Some(v) => {
                    return v
                }
                None => {}
            }
            env := self.tenv
            match self.cx.expr_type(c, &env) {
                Some(t) => {
                    return self.conversion(t, args, pos)
                }
                None => {}
            }
            if self.cx.global_decls.has(n) {
                fv := self.expr(c, None)
                return self.call_indirect(fv, args, pos)
            }
            hint := match n {
                "println", "printf", "echo", "puts", "console" => " (use `print(a, b, ...)`)"
                "length", "size", "count" => " (use `len(x)`)"
                "malloc", "calloc" => " (use `alloc[T](n)` or `new[T]()`)"
                "str", "string", "to_string", "format", "sprintf" => " (use `fmt(a, b, ...)`)"
                "append" => " (use a `Vec`: `v.push(x)`)"
                "int", "float" => " (convert with a type name: `i64(x)`, `f64(x)`)"
                _ => ""
            }
            self.err(pos, fmt("unknown function `", n, "`", hint, self.nested_hint(n, pos), self.cx.priv_hint(n)))
            lower_call_eval_all(self, args)
            return val_err()
        }
        EKIndex(b, targs) => {
            match b.k {
                EKIdent(n) => {
                    if self.nested_named(n) >= 0 {
                        self.err(pos, fmt("the nested function `", n, "` takes no type arguments (a nested function has no type parameters of its own)"))
                        lower_call_eval_all(self, args)
                        return val_err()
                    }
                    is_var := is_some(self.lookup(n)) || (self.cx.global_decls.has(n) && !is_some(self.cx.find_fn(n)))
                    if !is_var {
                        env := self.tenv
                        cands := self.cx.fn_candidates(n)
                        is_builtin := n == "sizeof" || n == "cast" || n == "mkslice"
                        if cands.len != 0 || is_builtin {
                            tys := vec[i64]()
                            for i in 0..targs.len {
                                t := &targs[i]
                                match self.cx.expr_type(t, &env) {
                                    Some(ty) => {
                                        if ty != T_ERR {
                                            tys.push(ty)
                                        } else {
                                            return val_err()
                                        }
                                    }
                                    None => {
                                        self.err(t.pos, "expected a type argument")
                                        return val_err()
                                    }
                                }
                            }
                            if cands.len != 0 && lower_mem_is_builtin(n) {
                                return self.call_shared(n, cands, Some(tys), None, c, args, expect, pos)
                            }
                            if cands.len == 1 {
                                return self.call_decl(cands[0], Some(tys), None, args, expect, pos, lower_call_no_pre())
                            }
                            if cands.len > 1 {
                                return self.call_overloaded(cands.items(), Some(tys), None, args, expect, pos)
                            }
                            match self.builtin(n, Some(tys.items()), args, expect, pos) {
                                Some(v) => {
                                    return v
                                }
                                None => {
                                    return val_err()
                                }
                            }
                        }
                        match self.cx.expr_type(c, &env) {
                            Some(t) => {
                                return self.conversion(t, args, pos)
                            }
                            None => {}
                        }
                    }
                }
                _ => {}
            }
            // x.f[T](a): a method call with explicit type arguments
            match b.k {
                EKField(recv, name) => {
                    cands := self.cx.fn_candidates(name)
                    if cands.len != 0 {
                        env := self.tenv
                        saved := self.cx.errs.len
                        tys := vec[i64]()
                        all := true
                        for i in 0..targs.len {
                            match self.cx.expr_type(&targs[i], &env) {
                                Some(x) => {
                                    if x != T_ERR {
                                        tys.push(x)
                                    } else {
                                        all = false
                                    }
                                }
                                None => {
                                    all = false
                                }
                            }
                            if !all {
                                break
                            }
                        }
                        self.cx.errs.truncate(saved)
                        if all {
                            rv := self.recv_val(recv)
                            if rv.ty == T_ERR {
                                return val_err()
                            }
                            if lower_mem_is_builtin(name) {
                                return self.call_shared(name, cands, Some(tys), Some(rv), recv, args, expect, pos)
                            }
                            if cands.len == 1 {
                                return self.call_decl(cands[0], Some(tys), Some(rv), args, expect, pos, lower_call_no_pre())
                            }
                            return self.call_overloaded(cands.items(), Some(tys), Some(rv), args, expect, pos)
                        }
                    }
                }
                _ => {}
            }
            fv := self.expr(c, None)
            return self.call_indirect(fv, args, pos)
        }
        EKField(recv, name) => {
            // Enum.Variant(args)
            q := self.qual_enum(recv)
            if q.0 >= 0 {
                return self.qual_variant(q.0, q.1, name, args, expect, pos)
            }
            rv := self.recv_val(recv)
            if rv.ty == T_ERR {
                return val_err()
            }
            // a struct field holding a function value?
            dv := self.auto_deref(rv)
            match self.cx.types.k(dv.ty) {
                TyKStruct(sid) => {
                    is_fn_field := false
                    nf := self.cx.types.structs[sid].fields.len
                    for j in 0..nf {
                        f := self.cx.types.structs[sid].fields[j]
                        if f.0 == ast_plain(name) && lower_call_is_fn(self.cx.types.k(f.1)) {
                            is_fn_field = true
                            break
                        }
                    }
                    if is_fn_field {
                        var fp Val
                        match self.field_of(dv, name, pos) {
                            Some(p) => {
                                fp = self.rvalue(p)
                            }
                            None => {
                                return val_err()
                            }
                        }
                        return self.call_indirect(fp, args, pos)
                    }
                }
                _ => {}
            }
            // a nested function in scope comes before the top-level functions and builtins
            ni := self.nested_method(name)
            if ni >= 0 {
                return self.call_nested(ni, Some(rv), args, expect, pos)
            }
            cands := self.cx.fn_candidates(name)
            if lower_mem_is_builtin(name) {
                return self.call_shared(name, cands, None, Some(rv), recv, args, expect, pos)
            }
            if cands.len == 1 {
                return self.call_decl(cands[0], None, Some(rv), args, expect, pos, lower_call_no_pre())
            }
            if cands.len > 1 {
                return self.call_overloaded(cands.items(), None, Some(rv), args, expect, pos)
            }
            if name == "len" && len(args) == 0 {
                match self.len_of(rv) {
                    Some(v) => {
                        return v
                    }
                    None => {}
                }
            }
            tn := self.tyname(rv.ty)
            self.err(pos, fmt("no function `", name, "` to call on ", tn, " (method calls `x.f(a)` mean `f(x, a)`)", self.cx.priv_hint(name)))
            return val_err()
        }
        EKTypeE(t) => {
            env := self.tenv
            ty := self.cx.resolve(&t, &env)
            return self.conversion(ty, args, pos)
        }
        _ => {
            fv := self.expr(c, None)
            return self.call_indirect(fv, args, pos)
        }
    }
    return val_err()
}

// literals convert directly
fn lower_call_conversion_has_float(e *Expr) bool {
    match e.k {
        EKFloat(_) => {
            return true
        }
        EKUn(_, x) => {
            return lower_call_conversion_has_float(x)
        }
        EKBin(_, a, b) => {
            return lower_call_conversion_has_float(a) || lower_call_conversion_has_float(b)
        }
        _ => {
            return false
        }
    }
    return false
}

fn conversion(self *Fx, to i64, args []Expr, pos Pos) Val {
    if to != T_ERR && self.is_vecish(to) {
        return self.vec_construct(to, args, pos)
    }
    if len(args) != 1 {
        self.err(pos, "a type conversion takes exactly one argument")
        return val_err()
    }
    if to == T_ERR {
        return val_err()
    }
    floaty := lower_call_conversion_has_float(&args[0]) || lower_call_is_cv_float(self.cx.const_eval(&args[0]))
    var exp Opt[i64] = None
    if self.is_untyped(&args[0]) && (self.cx.types.is_float(to) || (self.cx.types.is_int(to) && !floaty)) {
        exp = Some(to)
    }
    v := self.expr(&args[0], exp)
    return self.convert(v, to, pos)
}

// The value of function `n`: with explicit type arguments, or with the types taken from
// the expected function type; of several definitions the one that fits is used.
fn fn_value(self *Fx, n str, explicit Opt[Vec[i64]], expect Opt[i64]) Opt[Val] {
    cands := self.cx.fn_candidates(n)
    has_want := false
    var wp Vec[i64]
    wr := 0
    match expect {
        Some(t) => {
            match self.cx.types.k(t) {
                TyKFn(p, r) => {
                    has_want = true
                    wp = p
                    wr = r
                }
                _ => {}
            }
        }
        None => {}
    }
    for ci in 0..cands.len {
        di := cands[ci]
        d := self.cx.fn_decls[di]
        var targs Vec[i64]
        match explicit {
            Some(t) => {
                if t.len == d.tparams.len {
                    targs = clone(t)
                } else {
                    continue
                }
            }
            None => {
                if d.tparams.len == 0 {
                    targs = vec[i64]()
                } else {
                    // infer the type arguments from the expected function type
                    if !has_want || wp.len != d.params.len {
                        continue
                    }
                    ps := clone(wp)
                    r := wr
                    env := map[str, i64]()
                    ok := true
                    for i in 0..d.params.len {
                        if !self.unify(&d.params[i].1, ps[i], d.tparams.items(), &env) {
                            ok = false
                        }
                    }
                    match d.ret {
                        Some(rt) => {
                            if !self.unify(&rt, r, d.tparams.items(), &env) {
                                ok = false
                            }
                        }
                        None => {}
                    }
                    if !ok || lower_call_any_unbound(&d.tparams, &env) {
                        continue
                    }
                    targs = vec[i64]()
                    for i in 0..d.tparams.len {
                        targs.push(env.get_or(d.tparams[i], 0))
                    }
                }
            }
        }
        fid := self.cx.inst_fn(di, targs)
        sig := self.cx.fn_sigs[fid]
        ptys := clone(sig.0)
        rty := sig.1
        if has_want {
            if cands.len > 1 && (wp.items() != ptys.items() || wr != rty) {
                continue
            }
        }
        ty := self.cx.types.intern(TyKFn(ptys, rty))
        match self.cx.module.funcs[fid].ext {
            Some(x) => {
                // the address of a C function comes from its import slot
                got := self.cx.module.externs[x].got
                a := self.ins(OpGAddr, TI64, vec[i64](), got)
                v := self.load_raw(a, TI64, AK_PTR)
                return Some(self.sval(ty, v))
            }
            None => {}
        }
        v := self.ins(OpFAddr, TI64, vec[i64](), fid)
        return Some(self.sval(ty, v))
    }
    return None
}

fn lower_call_param_accepts_adjust(s *Fx, is_recv bool, ty i64, t i64) bool {
    return is_recv && (lower_call_is_ptr_to(s.cx.types.k(t), ty) || lower_call_is_ptr_to(s.cx.types.k(ty), t))
}

// a type written in declaration `d`, resolved as `d`'s own file sees it (a prelude function
// keeps meaning the prelude's types where the user shadows their names); errors are dropped
fn lower_call_resolve_in(s *Fx, d *FnDecl, pt *TypeAst, env *Map[str, i64]) i64 {
    saved := s.cx.errs.len
    save_scope := s.cx.scope_prelude
    s.cx.scope_prelude = s.cx.internal_file(d.pos.file)
    t := s.cx.resolve(pt, env)
    s.cx.scope_prelude = save_scope
    s.cx.errs.truncate(saved)
    return t
}

// unification binds the type parameters; the concrete parts are compared after resolution
fn lower_call_param_accepts_fits(s *Fx, d *FnDecl, base *Map[str, i64], pt *TypeAst, ty i64) bool {
    env := lower_call_clone_env(base)
    if !s.unify(pt, ty, d.tparams.items(), &env) {
        return false
    }
    if lower_call_mentions_unbound(pt, d.tparams.items(), &env) {
        return true
    }
    t := lower_call_resolve_in(s, d, pt, &env)
    return t == ty
}

// does parameter type `pt` of declaration `d` accept a value of type `ty`?
// (`explicit`: type arguments written at the call)
fn param_accepts(self *Fx, d *FnDecl, pt *TypeAst, ty i64, is_recv bool, explicit Opt[[]i64]) bool {
    if d.tparams.len == 0 {
        empty := map[str, i64]()
        t := lower_call_resolve_in(self, d, pt, &empty)
        return t == ty || lower_call_param_accepts_adjust(self, is_recv, ty, t)
    }
    base := map[str, i64]()
    match explicit {
        Some(tys) => {
            for i in 0..min(d.tparams.len, len(tys)) {
                base.set(d.tparams[i], tys[i])
            }
        }
        None => {}
    }
    if lower_call_param_accepts_fits(self, d, &base, pt, ty) {
        return true
    }
    if !is_recv {
        return false
    }
    match *pt {
        TypeAstPtr(inner) => {
            return lower_call_param_accepts_fits(self, d, &base, inner, ty)
        }
        _ => {}
    }
    match self.cx.types.k(ty) {
        TyKPtr(t) => {
            return lower_call_param_accepts_fits(self, d, &base, pt, t)
        }
        _ => {
            return false
        }
    }
    return false
}

// how well parameter `pi` of `d` fits an untyped literal argument: 0 = its default type,
// 1 = same kind, 2 = generic, 3 = integer literal for a float; None = does not fit
fn literal_fit(self *Fx, d *FnDecl, pi i64, a *Expr) Opt[i64] {
    pt := &d.params[pi].1
    empty := map[str, i64]()
    if lower_call_mentions_unbound(pt, d.tparams.items(), &empty) {
        return Some(2)
    }
    empty2 := map[str, i64]()
    t := lower_call_resolve_in(self, d, pt, &empty2)
    k := self.cx.types.k(t)
    is_i := self.cx.types.is_int(t)
    is_f := self.cx.types.is_float(t)
    vn := self.variant_ref(a)
    if vn != "" {
        // a variant fits an enum that has it
        match k {
            TyKEnum(eid) => {
                nv := self.cx.types.enums[eid].variants.len
                for vi in 0..nv {
                    if self.cx.types.enums[eid].variants[vi].0 == vn {
                        return Some(0)
                    }
                }
            }
            _ => {}
        }
        return None
    }
    match a.k {
        EKNil => {
            if lower_call_is_ptr(k) || lower_call_is_fn(k) || lower_call_is_slice(k) {
                return Some(0)
            }
            return None
        }
        _ => {}
    }
    if lower_call_is_cv_float(self.cx.const_eval(a)) {
        if t == T_F64 {
            return Some(0)
        } else if is_f {
            return Some(1)
        } else {
            return None
        }
    }
    if t == T_I64 {
        return Some(0)
    } else if is_i {
        return Some(1)
    } else if is_f {
        return Some(3)
    }
    return None
}

fn lower_call_call_overloaded_sigs(s *Fx, cands []i64) str {
    parts := vec[str]()
    for ci in 0..len(cands) {
        d := s.cx.fn_decls[cands[ci]]
        ps := vec[str]()
        for j in 0..d.params.len {
            ps.push(ast_type_str(&d.params[j].1))
        }
        parts.push(fmt(d.name, "(", join(ps.items(), ", "), ")"))
    }
    return join(parts.items(), "; ")
}

// A name with several definitions. The receiver and the arguments are looked at from left
// to right until one definition is left: typed arguments must match the parameter type,
// untyped literals must be acceptable to it. Remaining ties go to the definition whose
// parameters are the literals' default types, then to one returning the expected type.
fn call_overloaded(self *Fx, cands []i64, explicit Opt[Vec[i64]], recv Opt[Val], args []Expr, expect Opt[i64], pos Pos) Val {
    off := if is_some(recv) { 1 } else { 0 }
    total := len(args) + off
    name := self.cx.fn_decls[cands[0]].name
    alive := vec[i64]()
    for ci in 0..len(cands) {
        di := cands[ci]
        d := self.cx.fn_decls[di]
        targs_ok := true
        match explicit {
            Some(t) => {
                targs_ok = t.len == d.tparams.len
            }
            None => {}
        }
        if d.params.len == total && targs_ok {
            alive.push(di)
        }
    }
    if alive.len == 0 {
        s := lower_call_call_overloaded_sigs(self, cands)
        self.err(pos, fmt("no definition of `", name, "` takes ", total, " argument(s); candidates: ", s))
        lower_call_eval_all(self, args)
        return val_err()
    }
    match recv {
        Some(rv) => {
            keep := vec[i64]()
            for ai in 0..alive.len {
                di := alive[ai]
                d := self.cx.fn_decls[di]
                if self.param_accepts(d, &d.params[0].1, rv.ty, true, lower_call_as_slice(explicit)) {
                    keep.push(di)
                }
            }
            if keep.len == 0 {
                tn := self.tyname(rv.ty)
                s := lower_call_call_overloaded_sigs(self, cands)
                self.err(pos, fmt("no definition of `", name, "` can be called on ", tn, "; candidates: ", s))
                lower_call_eval_all(self, args)
                return val_err()
            }
            alive = keep
        }
        None => {}
    }
    pre := vec[(i64, Val)]()
    for i in 0..len(args) {
        a := &args[i]
        if alive.len <= 1 {
            break
        }
        keep := vec[i64]()
        if self.is_untyped(a) {
            for ai in 0..alive.len {
                di := alive[ai]
                if is_some(self.literal_fit(self.cx.fn_decls[di], off + i, a)) {
                    keep.push(di)
                }
            }
            if keep.len != 0 {
                alive = keep
            }
            continue
        }
        var v Val = self.expr(a, None)
        if v.ty != T_ERR {
            v = self.stabilize(v, args[i + 1..])
            pre.push((i, v))
            for ai in 0..alive.len {
                di := alive[ai]
                d := self.cx.fn_decls[di]
                if self.param_accepts(d, &d.params[off + i].1, v.ty, false, lower_call_as_slice(explicit)) {
                    keep.push(di)
                }
            }
            if keep.len == 0 {
                tn := self.tyname(v.ty)
                s := lower_call_call_overloaded_sigs(self, cands)
                self.err(a.pos, fmt("no definition of `", name, "` takes ", tn, " as argument ", off + i + 1, " here; candidates: ", s))
            }
        }
        if keep.len == 0 {
            lower_call_eval_all(self, args[i + 1..])
            return val_err()
        }
        alive = keep
    }
    if alive.len > 1 && ast_is_private(name) {
        // private definitions of the file win over public ones of the same written name
        own := vec[i64]()
        for ai in 0..alive.len {
            if ast_is_private(self.cx.fn_decls[alive[ai]].name) {
                own.push(alive[ai])
            }
        }
        if own.len != 0 {
            alive = own
        }
    }
    pick := alive[0]
    if alive.len > 1 {
        // rank by how naturally the literal arguments fit, then by the expected result type
        ranked := vec[(i64, i64)]()
        for ai in 0..alive.len {
            di := alive[ai]
            d := self.cx.fn_decls[di]
            // a definition with exactly these types beats a generic one
            rank := if d.tparams.len == 0 { 0 } else { 1 }
            for i in 0..len(args) {
                a := &args[i]
                if self.is_untyped(a) {
                    fit := 4
                    match self.literal_fit(d, off + i, a) {
                        Some(x) => {
                            fit = x
                        }
                        None => {}
                    }
                    rank += 10 * fit
                }
            }
            ranked.push((rank, di))
        }
        sort_by(ranked.items(), fn(a (i64, i64), b (i64, i64)) bool { a.0 < b.0 })
        pick = ranked[0].1
        by_ret := false
        match expect {
            Some(et) => {
                for ri in 0..ranked.len {
                    di := ranked[ri].1
                    d := self.cx.fn_decls[di]
                    if d.tparams.len == 0 {
                        match d.ret {
                            Some(rt) => {
                                empty := map[str, i64]()
                                t := lower_call_resolve_in(self, d, &rt, &empty)
                                if t == et {
                                    pick = di
                                    by_ret = true
                                    break
                                }
                            }
                            None => {}
                        }
                    }
                }
            }
            None => {}
        }
        if !by_ret && ranked[1].0 == ranked[0].0 {
            // a variant that fits the enums of two definitions equally well decides nothing
            for i in 0..len(args) {
                a := &args[i]
                vn := self.variant_ref(a)
                if vn == "" {
                    continue
                }
                saved := self.cx.errs.len
                empty := map[str, i64]()
                t0 := self.cx.resolve(&self.cx.fn_decls[ranked[0].1].params[off + i].1, &empty)
                t1 := self.cx.resolve(&self.cx.fn_decls[ranked[1].1].params[off + i].1, &empty)
                self.cx.errs.truncate(saved)
                if t0 != t1 && lower_call_is_enum(self.cx.types.k(t0)) && lower_call_is_enum(self.cx.types.k(t1)) {
                    s := lower_call_call_overloaded_sigs(self, cands)
                    self.err(a.pos, fmt("`", vn, "` is a variant of ", self.tyname(t0), " and of ", self.tyname(t1), ", and `", name, "` is defined for both; write `Enum.", vn, "` (candidates: ", s, ")"))
                    return val_err()
                }
            }
        }
    }
    return self.call_decl(pick, explicit, recv, args, expect, pos, pre.items())
}

fn call_decl(self *Fx, di i64, explicit Opt[Vec[i64]], recv Opt[Val], args []Expr, expect Opt[i64], pos Pos, pre [](i64, Val)) Val {
    return self.call_fn(self.cx.fn_decls[di], di, -1, explicit, recv, args, expect, pos, pre)
}

// A call of the function declared by `d`: the top-level declaration `di`, or (`nest` >= 0)
// the nested function `self.cx.nested[nest]`, whose types are resolved already and which gets
// the addresses of the variables it uses as extra arguments.
fn call_fn(self *Fx, d *FnDecl, di i64, nest i64, explicit Opt[Vec[i64]], recv Opt[Val], args []Expr, expect Opt[i64], pos Pos, pre [](i64, Val)) Val {
    nrecv := if is_some(recv) { 1 } else { 0 }
    if d.params.len != len(args) + nrecv {
        sig := vec[str]()
        for j in 0..d.params.len {
            sig.push(d.params[j].0)
        }
        self.err(pos, fmt("function `", d.name, "(", join(sig.items(), ", "), ")` expects ", d.params.len, " argument(s), got ", len(args) + nrecv))
        lower_call_eval_all(self, args)
        return val_err()
    }
    var no_val Opt[Val] = None
    vals := vec_fill(d.params.len, no_val)
    env := map[str, i64]()
    generic := d.tparams.len != 0
    if generic {
        match explicit {
            Some(tys) => {
                if tys.len != d.tparams.len {
                    self.err(pos, fmt("function `", d.name, "` expects ", d.tparams.len, " type argument(s), got ", tys.len))
                    return val_err()
                }
                for j in 0..d.tparams.len {
                    env.set(d.tparams[j], tys[j])
                }
            }
            None => {}
        }
    } else {
        has_targs := false
        match explicit {
            Some(t) => {
                has_targs = t.len != 0
            }
            None => {}
        }
        if has_targs {
            self.err(pos, fmt("function `", d.name, "` is not generic"))
            return val_err()
        }
    }
    failed := false
    match recv {
        Some(rv) => {
            // does the function take the address of the receiver (`*T` for a receiver `T`)?
            by_ref := false
            if generic {
                // try by value, then through a pointer in either direction
                pt := &d.params[0].1
                e2 := lower_call_clone_env(&env)
                if self.unify(pt, rv.ty, d.tparams.items(), &e2) {
                    env = e2
                } else {
                    e3 := lower_call_clone_env(&env)
                    ok := false
                    is_ptr_param := false
                    match *pt {
                        TypeAstPtr(inner) => {
                            is_ptr_param = true
                            ok = self.unify(inner, rv.ty, d.tparams.items(), &e3)
                        }
                        _ => {}
                    }
                    if !is_ptr_param {
                        match self.cx.types.k(rv.ty) {
                            TyKPtr(t) => {
                                ok = self.unify(pt, t, d.tparams.items(), &e3)
                            }
                            _ => {}
                        }
                    }
                    if ok {
                        env = e3
                        by_ref = is_ptr_param
                    }
                }
            } else if rv.mem && rv.ty != T_ERR && self.cx.types.is_scalar(rv.ty) {
                p0 := T_ERR
                if nest >= 0 {
                    p0 = self.cx.nested[nest].ptys[0]
                } else {
                    empty := map[str, i64]()
                    p0 = lower_call_resolve_in(self, d, &d.params[0].1, &empty)
                }
                by_ref = lower_call_is_ptr_to(self.cx.types.k(p0), rv.ty)
            }
            // a scalar receiver that is passed by value is read now, before the arguments
            // are evaluated; one that is passed by pointer stays a place
            rv0 := rv
            if !by_ref {
                rv0 = self.rvalue(rv)
            }
            vals[0] = Some(rv0)
        }
        None => {}
    }
    // pass 1: typed arguments; pass 2: untyped literals
    for pass in 0..2 {
        for i in 0..len(args) {
            a := &args[i]
            pi := i + nrecv
            has_pre := false
            var pv Val
            for j in 0..len(pre) {
                if pre[j].0 == i {
                    has_pre = true
                    pv = pre[j].1
                    break
                }
            }
            if has_pre {
                // an argument that overload resolution already evaluated
                if pass == 0 {
                    if generic && !self.unify(&d.params[pi].1, pv.ty, d.tparams.items(), &env) {
                        tn := self.tyname(pv.ty)
                        self.err(a.pos, fmt("argument ", i + 1, " of `", d.name, "` has type ", tn, ", which does not match the parameter type"))
                        failed = true
                    }
                    pv = self.stabilize(pv, args[i + 1..])
                    vals[pi] = Some(pv)
                }
                continue
            }
            untyped := self.is_untyped(a)
            if (pass == 0) == untyped && generic {
                continue
            }
            if !generic && pass == 1 {
                continue
            }
            pt := &d.params[pi].1
            var exp Opt[i64] = None
            if generic && lower_call_mentions_unbound(pt, d.tparams.items(), &env) {
                exp = None
            } else if nest >= 0 {
                exp = Some(self.cx.nested[nest].ptys[pi])
            } else {
                // (errors in the parameter type are reported where the function is declared)
                t := lower_call_resolve_in(self, d, pt, &env)
                exp = Some(t)
            }
            v := self.expr(a, exp)
            if v.ty == T_ERR {
                failed = true
            }
            if generic && !is_some(exp) && v.ty != T_ERR && !self.unify(pt, v.ty, d.tparams.items(), &env) {
                tn := self.tyname(v.ty)
                self.err(a.pos, fmt("argument ", i + 1, " of `", d.name, "` has type ", tn, ", which does not match the parameter type"))
                failed = true
            }
            v = self.stabilize(v, args[i + 1..])
            vals[pi] = Some(v)
        }
    }
    if failed {
        return val_err()
    }
    targs := vec[i64]()
    if generic {
        // the expected result type can bind remaining parameters
        match expect {
            Some(et) => {
                match d.ret {
                    Some(rt) => {
                        if lower_call_any_unbound(&d.tparams, &env) {
                            e2 := lower_call_clone_env(&env)
                            if self.unify(&rt, et, d.tparams.items(), &e2) {
                                env = e2
                            }
                        }
                    }
                    None => {}
                }
            }
            None => {}
        }
        for j in 0..d.tparams.len {
            p := d.tparams[j]
            t, bound := env.get(p)
            if bound {
                targs.push(t)
            } else {
                self.err(pos, fmt("cannot infer type parameter `", p, "` of `", d.name, "`; write `", d.name, "[T](...)`"))
                return val_err()
            }
        }
    }
    fid := 0
    var ptys Vec[i64]
    rty := T_UNIT
    if nest >= 0 {
        fid = self.cx.nested[nest].fid
        ptys = clone(&self.cx.nested[nest].ptys)
        rty = self.cx.nested[nest].rty
    } else {
        self.cx.inst_depth += 1
        if self.cx.inst_depth > 200 {
            self.err(pos, "generic instantiation is too deep")
            self.cx.inst_depth -= 1
            return val_err()
        }
        fid = self.cx.inst_fn(di, targs)
        self.cx.inst_depth -= 1
        fsig := self.cx.fn_sigs[fid]
        ptys = clone(fsig.0)
        rty = fsig.1
    }
    final_vals := vec[Val]()
    for i in 0..vals.len {
        v := lower_call_unwrap(vals[i])
        pt := ptys[i]
        if i == 0 && is_some(recv) && v.ty != pt {
            // UFCS receiver adjustment: auto-ref / auto-deref
            adjusted := false
            match self.cx.types.k(pt) {
                TyKPtr(inner) => {
                    if inner == v.ty && v.mem && is_some(v.lane) {
                        self.err(pos, fmt("cannot pass a vector component by pointer to `", d.name, "` (copy it to a variable first)"))
                        failed = true
                        v = val_err()
                        adjusted = true
                    } else if inner == v.ty && v.mem && !v.ro {
                        if v.alias >> 4 != 0 {
                            self.cx.exposed.set(v.alias >> 4, true)
                        }
                        v = self.sval(pt, v.v)
                        adjusted = true
                    } else if inner == v.ty && v.ty != T_ERR {
                        // not addressable (a computed value, a constant): the function
                        // gets the address of a temporary copy
                        t := self.temp(v.ty)
                        tv := self.mval(v.ty, t)
                        self.store(tv, v)
                        v = self.sval(pt, t)
                        adjusted = true
                    }
                }
                _ => {}
            }
            if !adjusted {
                match self.cx.types.k(v.ty) {
                    TyKPtr(inner) => {
                        if inner == pt {
                            a := self.scalar(v)
                            m := self.mval(pt, a)
                            v = self.rvalue(m)
                        }
                    }
                    _ => {}
                }
            }
        }
        apos := pos
        if i >= nrecv {
            apos = args[i - nrecv].pos
        }
        if v.ty != pt && v.ty != T_ERR && pt != T_ERR && v.ty != T_NEVER {
            a := self.tyname(pt)
            b := self.tyname(v.ty)
            var hint str = lower_match_same_name(a, b)
            if lower_call_is_ptr_to(self.cx.types.k(pt), v.ty) {
                hint = " (pass its address with `&`; only the receiver of a method call `x.f()` is referenced automatically)"
            }
            self.err(apos, fmt("argument `", d.params[i].0, "` of `", d.name, "`: expected ", a, ", found ", b, hint))
            failed = true
        }
        final_vals.push(v)
    }
    if failed {
        return val_err()
    }
    return self.emit_call(CalleeDirect(fid), ptys.items(), rty, final_vals)
}

fn lower_call_builtin_word(k TyK) bool {
    return lower_call_is_ptr(k) || lower_call_is_fn(k) || lower_call_is_int_bits(k, 64)
}

fn lower_call_builtin_okp(k TyK) bool {
    return lower_call_is_ptr(k) || lower_call_is_int_bits(k, 64)
}

// ---------- builtins ----------
fn builtin(self *Fx, name str, targs Opt[[]i64], args []Expr, expect Opt[i64], pos Pos) Opt[Val] {
    nargs := len(args)
    match name {
        "len" => {
            if nargs != 1 {
                self.err(pos, fmt("`", name, "` takes ", 1, " argument(s), got ", nargs))
                return Some(val_err())
            }
            v := self.expr(&args[0], None)
            if v.ty == T_ERR {
                return Some(val_err())
            }
            match self.len_of(v) {
                Some(l) => {
                    return Some(l)
                }
                None => {
                    tn := self.tyname(v.ty)
                    self.err(pos, fmt("`len` needs a slice, array, str or Vec, found ", tn))
                    return Some(val_err())
                }
            }
        }
        "sizeof" => {
            if nargs != 0 {
                self.err(pos, fmt("`", name, "` takes ", 0, " argument(s), got ", nargs))
                return Some(val_err())
            }
            t := 0
            one := false
            match targs {
                Some(ts) => {
                    if len(ts) == 1 {
                        t = ts[0]
                        one = true
                    }
                }
                None => {}
            }
            if !one {
                self.err(pos, fmt("`", name, "` needs one type argument: `", name, "[T](...)`"))
                return Some(val_err())
            }
            s := self.cx.types.size_of(t)
            v := self.iconst(TI64, i64(s))
            return Some(self.sval(T_I64, v))
        }
        "cast" => {
            if nargs != 1 {
                self.err(pos, fmt("`", name, "` takes ", 1, " argument(s), got ", nargs))
                return Some(val_err())
            }
            to := 0
            one := false
            match targs {
                Some(ts) => {
                    if len(ts) == 1 {
                        to = ts[0]
                        one = true
                    }
                }
                None => {}
            }
            if !one {
                self.err(pos, fmt("`", name, "` needs one type argument: `", name, "[T](...)`"))
                return Some(val_err())
            }
            v := self.expr(&args[0], None)
            if v.ty == T_ERR {
                return Some(val_err())
            }
            fk := self.cx.types.k(v.ty)
            tk := self.cx.types.k(to)
            if lower_call_builtin_word(fk) && lower_call_builtin_word(tk) {
                s := self.scalar(v)
                return Some(self.sval(to, s))
            } else if lower_call_is_f64(fk) && lower_call_is_int_bits(tk, 64) {
                s := self.scalar(v)
                r := self.ins(OpFToBits, TI64, vec_of([]i64{s}), 0)
                return Some(self.sval(to, r))
            } else if lower_call_is_int_bits(fk, 64) && lower_call_is_f64(tk) {
                s := self.scalar(v)
                r := self.ins(OpBitsToF, TF64, vec_of([]i64{s}), 0)
                return Some(self.sval(to, r))
            } else if lower_call_is_f32(fk) && lower_call_is_int_bits(tk, 32) {
                s := self.scalar(v)
                r := self.ins(OpFToBits, TI32, vec_of([]i64{s}), 0)
                return Some(self.sval(to, r))
            } else if lower_call_is_int_bits(fk, 32) && lower_call_is_f32(tk) {
                s := self.scalar(v)
                r := self.ins(OpBitsToF, TF32, vec_of([]i64{s}), 0)
                return Some(self.sval(to, r))
            } else if lower_call_is_enum(tk) && self.cx.types.is_scalar(to) && lower_call_is_int_bits(fk, 64) {
                s := self.scalar(v)
                return Some(self.sval(to, s))
            } else if lower_call_is_slice(fk) && lower_call_is_slice(tk) {
                // reinterpret a slice: the byte length is preserved
                fe := lower_call_slice_elem(fk)
                te := lower_call_slice_elem(tk)
                p, l := self.slice_parts(v)
                fs := i64(self.cx.types.size_of(fe))
                ts := i64(self.cx.types.size_of(te))
                n := l
                if fs != ts {
                    a := self.iconst(TI64, fs)
                    bytes := self.ins(OpMul, TI64, vec_of([]i64{l, a}), 0)
                    b := self.iconst(TI64, max(ts, 1))
                    n = self.ins(OpUDiv, TI64, vec_of([]i64{bytes, b}), 0)
                }
                t := self.temp(to)
                sv := self.mval(to, t)
                self.store_slice(sv, p, n)
                return Some(sv)
            } else {
                a := self.tyname(v.ty)
                b := self.tyname(to)
                self.err(pos, fmt("cannot cast ", a, " to ", b))
                return Some(val_err())
            }
        }
        "mkslice" => {
            if nargs != 2 {
                self.err(pos, fmt("`", name, "` takes ", 2, " argument(s), got ", nargs))
                return Some(val_err())
            }
            et := 0
            one := false
            match targs {
                Some(ts) => {
                    if len(ts) == 1 {
                        et = ts[0]
                        one = true
                    }
                }
                None => {}
            }
            if !one {
                self.err(pos, fmt("`", name, "` needs one type argument: `", name, "[T](...)`"))
                return Some(val_err())
            }
            p := self.expr(&args[0], None)
            n := self.expr(&args[1], Some(T_I64))
            n = self.coerce(n, T_I64, args[1].pos)
            if p.ty == T_ERR || n.ty == T_ERR {
                return Some(val_err())
            }
            if !lower_call_builtin_okp(self.cx.types.k(p.ty)) {
                self.err(args[0].pos, "`mkslice` needs a pointer or i64 address")
                return Some(val_err())
            }
            pv := self.scalar(p)
            nv := self.scalar(n)
            sty := self.cx.types.slice(et)
            t := self.temp(sty)
            sv := self.mval(sty, t)
            self.store_slice(sv, pv, nv)
            return Some(sv)
        }
        "ptr" => {
            if nargs != 1 {
                self.err(pos, fmt("`", name, "` takes ", 1, " argument(s), got ", nargs))
                return Some(val_err())
            }
            v := self.expr(&args[0], None)
            v = self.auto_deref(v)
            match self.cx.types.k(v.ty) {
                TyKSlice(et) => {
                    p, _ := self.slice_parts(v)
                    pt := self.cx.types.ptr_to(et)
                    return Some(self.sval(pt, p))
                }
                TyKArray(et, _) => {
                    pt := self.cx.types.ptr_to(et)
                    return Some(self.sval(pt, v.v))
                }
                TyKErr => {
                    return Some(val_err())
                }
                _ => {
                    self.err(pos, "`ptr` needs a slice or array")
                    return Some(val_err())
                }
            }
        }
        "syscall" => {
            if nargs == 0 || nargs > 7 {
                self.err(pos, "`syscall` takes a number and up to 6 arguments")
                return Some(val_err())
            }
            vs := vec[i64]()
            for i in 0..nargs {
                a := &args[i]
                v := self.expr(a, Some(T_I64))
                if v.ty == T_ERR {
                    return Some(val_err())
                }
                if !self.cx.types.is_scalar(v.ty) || self.cx.types.is_float(v.ty) || self.is_vecish(v.ty) {
                    self.err(a.pos, "syscall arguments must be integers or pointers")
                    return Some(val_err())
                }
                s := 0
                if self.cx.types.is_int(v.ty) || v.ty == T_BOOL {
                    s = self.to_i64(v)
                } else {
                    s = self.scalar(v)
                }
                vs.push(s)
            }
            r := self.ins(OpSyscall, TI64, vs, 0)
            return Some(self.sval(T_I64, r))
        }
        "sqrt", "fabs", "fmin", "fmax" => {
            two := name == "fmin" || name == "fmax"
            if two {
                if nargs != 2 {
                    self.err(pos, fmt("`", name, "` takes ", 2, " argument(s), got ", nargs))
                    return Some(val_err())
                }
            } else {
                if nargs != 1 {
                    self.err(pos, fmt("`", name, "` takes ", 1, " argument(s), got ", nargs))
                    return Some(val_err())
                }
            }
            // an untyped literal takes the type of the other operand, else of the context
            first := 0
            if two && self.is_untyped(&args[0]) && !self.is_untyped(&args[1]) {
                first = 1
            }
            var exp0 Opt[i64] = None
            if self.is_untyped(&args[first]) {
                exp0 = Some(self.float_expect(expect))
            }
            v := self.expr(&args[first], exp0)
            if v.ty == T_ERR {
                return Some(val_err())
            }
            if !self.cx.types.is_float(v.ty) && !is_some(self.cx.types.vec_lanes(v.ty)) {
                tn := self.tyname(v.ty)
                self.err(args[first].pos, fmt("`", name, "` needs f32, f64 or a vector, found ", tn))
                return Some(val_err())
            }
            it := self.irt(v.ty)
            s := self.scalar(v)
            r := 0
            if two {
                w := self.expr(&args[1 - first], Some(v.ty))
                w = self.coerce(w, v.ty, args[1 - first].pos)
                if w.ty == T_ERR {
                    return Some(val_err())
                }
                t := self.scalar(w)
                a := s
                b := t
                if first != 0 {
                    a = t
                    b = s
                }
                var op Op
                if name == "fmin" {
                    op = OpFMin
                } else {
                    op = OpFMax
                }
                r = self.ins(op, it, vec_of([]i64{a, b}), 0)
            } else {
                var op Op
                if name == "sqrt" {
                    op = OpFSqrt
                } else {
                    op = OpFAbs
                }
                r = self.ins(op, it, vec_of([]i64{s}), 0)
            }
            return Some(self.sval(v.ty, r))
        }
        "popcnt", "ctz", "clz", "bswap" => {
            if nargs != 1 {
                self.err(pos, fmt("`", name, "` takes ", 1, " argument(s), got ", nargs))
                return Some(val_err())
            }
            v := self.expr(&args[0], None)
            if v.ty == T_ERR {
                return Some(val_err())
            }
            if !self.cx.types.is_int(v.ty) {
                self.err(pos, fmt("`", name, "` needs an integer"))
                return Some(val_err())
            }
            it := self.irt(v.ty)
            s := self.scalar(v)
            op := match name {
                "popcnt" => OpPopcnt
                "ctz" => OpCtz
                "clz" => OpClz
                _ => OpBswap
            }
            r := self.ins(op, it, vec_of([]i64{s}), 0)
            return Some(self.sval(v.ty, r))
        }
        "rotl", "rotr" => {
            if nargs != 2 {
                self.err(pos, fmt("`", name, "` takes ", 2, " argument(s), got ", nargs))
                return Some(val_err())
            }
            v := self.expr(&args[0], None)
            n := self.expr(&args[1], None)
            if v.ty == T_ERR || n.ty == T_ERR {
                return Some(val_err())
            }
            if !self.cx.types.is_int(v.ty) || !self.cx.types.is_int(n.ty) {
                self.err(pos, fmt("`", name, "` needs integers"))
                return Some(val_err())
            }
            it := self.irt(v.ty)
            nt := self.irt(n.ty)
            s := self.scalar(v)
            c := self.scalar(n)
            if nt.size() > it.size() {
                c = self.ins(OpTrunc, it, vec_of([]i64{c}), 0)
            } else if nt.size() < it.size() {
                c = self.ins(OpZExt, it, vec_of([]i64{c}), 0)
            }
            var op Op
            if name == "rotl" {
                op = OpRotl
            } else {
                op = OpRotr
            }
            r := self.ins(op, it, vec_of([]i64{s, c}), 0)
            return Some(self.sval(v.ty, r))
        }
        "mulhi" => {
            // the high half of the full (double-width) product of two integers of one type
            if nargs != 2 {
                self.err(pos, fmt("`", name, "` takes ", 2, " argument(s), got ", nargs))
                return Some(val_err())
            }
            // an untyped literal takes the type of the other operand, else of the context
            first := 0
            if self.is_untyped(&args[0]) && !self.is_untyped(&args[1]) {
                first = 1
            }
            var exp0 Opt[i64] = None
            if self.is_untyped(&args[first]) {
                match expect {
                    Some(et) => {
                        if self.cx.types.is_int(et) {
                            exp0 = expect
                        }
                    }
                    None => {}
                }
            }
            v := self.expr(&args[first], exp0)
            if v.ty == T_ERR {
                return Some(val_err())
            }
            if !self.cx.types.is_int(v.ty) {
                tn := self.tyname(v.ty)
                self.err(args[first].pos, fmt("`mulhi` needs two integers of the same type, found ", tn))
                return Some(val_err())
            }
            w := self.expr(&args[1 - first], Some(v.ty))
            if w.ty == T_ERR {
                return Some(val_err())
            }
            if w.ty != v.ty {
                a := self.tyname(v.ty)
                b := self.tyname(w.ty)
                if first != 0 {
                    a = self.tyname(w.ty)
                    b = self.tyname(v.ty)
                }
                self.err(pos, fmt("`mulhi` needs two integers of the same type, found ", a, " and ", b, " (convert one explicitly, e.g. `", a, "(y)`)"))
                return Some(val_err())
            }
            signed := self.cx.types.is_signed(v.ty)
            it := self.irt(v.ty)
            a := self.scalar(v)
            b := self.scalar(w)
            if it == TI64 {
                var hop Op
                if signed {
                    hop = OpMulHiS
                } else {
                    hop = OpMulHiU
                }
                r := self.ins(hop, TI64, vec_of([]i64{a, b}), 0)
                return Some(self.sval(v.ty, r))
            }
            // narrower types: the full product fits in 64 bits
            var ext Op
            var shr Op
            if signed {
                ext = OpSExt
                shr = OpAShr
            } else {
                ext = OpZExt
                shr = OpLShr
            }
            wa := self.ins(ext, TI64, vec_of([]i64{a}), 0)
            wb := self.ins(ext, TI64, vec_of([]i64{b}), 0)
            prod := self.ins(OpMul, TI64, vec_of([]i64{wa, wb}), 0)
            bits := self.iconst(TI64, it.size() * 8)
            hi := self.ins(shr, TI64, vec_of([]i64{prod, bits}), 0)
            r := self.ins(OpTrunc, it, vec_of([]i64{hi}), 0)
            return Some(self.sval(v.ty, r))
        }
        "memcopy", "memfill" => {
            if nargs != 3 {
                self.err(pos, fmt("`", name, "` takes ", 3, " argument(s), got ", nargs))
                return Some(val_err())
            }
            d := self.expr(&args[0], None)
            var sexp Opt[i64] = None
            if name == "memfill" {
                sexp = Some(T_U8)
            }
            s := self.expr(&args[1], sexp)
            n := self.expr(&args[2], Some(T_I64))
            n = self.coerce(n, T_I64, args[2].pos)
            if d.ty == T_ERR || s.ty == T_ERR || n.ty == T_ERR {
                return Some(val_err())
            }
            dk := self.cx.types.k(d.ty)
            sk := self.cx.types.k(s.ty)
            if !lower_call_builtin_okp(dk) || (name == "memcopy" && !lower_call_builtin_okp(sk)) || (name == "memfill" && s.ty != T_U8) {
                self.err(pos, fmt("`", name, "` arguments have the wrong types"))
                return Some(val_err())
            }
            dv := self.scalar(d)
            sv := self.scalar(s)
            nv := self.scalar(n)
            var op Op
            if name == "memcopy" {
                op = OpMemCpy
            } else {
                op = OpMemSet
            }
            self.ins(op, TVoid, vec_of([]i64{dv, sv, nv}), 0)
            return Some(val_unit())
        }
        "embed" => {
            // the bytes of a file, read at compile time (path relative to the source file)
            match self.cx.embed_bytes(args, pos) {
                Some(bytes) => {
                    return Some(self.str_val(bytes))
                }
                None => {
                    return Some(val_err())
                }
            }
        }
        "panic" => {
            if nargs != 1 {
                self.err(pos, fmt("`", name, "` takes ", 1, " argument(s), got ", nargs))
                return Some(val_err())
            }
            m := self.expr(&args[0], Some(T_STR))
            m = self.coerce(m, T_STR, args[0].pos)
            loc := self.loc_str(pos)
            return Some(self.call_rt("__panic", vec[i64](), vec_of([]Val{loc, m}), pos))
        }
        "fmt" => {
            // evaluate everything first: output produced by the arguments themselves is not captured
            vals := vec[(Val, Pos)]()
            for i in 0..nargs {
                a := &args[i]
                v := self.expr(a, None)
                if v.mem && v.ty != T_ERR {
                    t := self.temp(v.ty)
                    tv := self.mval(v.ty, t)
                    self.store(tv, v)
                    v = tv
                }
                vals.push((v, a.pos))
            }
            start := self.call_rt("__cap_begin", vec[i64](), vec[Val](), pos)
            for i in 0..vals.len {
                self.put_val(vals[i].0, vals[i].1, 0)
            }
            return Some(self.call_rt("__cap_end", vec[i64](), vec_of([]Val{start}), pos))
        }
        "hash" => {
            if nargs != 1 {
                self.err(pos, fmt("`", name, "` takes ", 1, " argument(s), got ", nargs))
                return Some(val_err())
            }
            v := self.expr(&args[0], None)
            if v.ty == T_ERR {
                return Some(val_err())
            }
            match self.hash_val(v, pos) {
                Some(h) => {
                    return Some(self.sval(T_U64, h))
                }
                None => {
                    return Some(val_err())
                }
            }
        }
        "clone" => {
            return Some(self.clone_builtin(args, expect, pos))
        }
        "put", "print" => {
            for i in 0..nargs {
                a := &args[i]
                if i > 0 && name == "print" {
                    sp := self.str_val(" ")
                    self.call_rt("__put_str", vec[i64](), vec_of([]Val{sp}), pos)
                }
                v := self.expr(a, None)
                self.put_val(v, a.pos, 0)
            }
            if name == "print" {
                nl := self.str_val("\n")
                self.call_rt("__put_str", vec[i64](), vec_of([]Val{nl}), pos)
            }
            return Some(val_unit())
        }
        _ => {
            return None
        }
    }
    return None
}

// the common tail of the scalar cases of `hash_val`: hash the 64-bit pattern `x`
fn lower_call_hash_u64(s *Fx, x i64, pos Pos) Opt[i64] {
    a := s.sval(T_U64, x)
    r := s.call_rt("__hash_u64", vec[i64](), vec_of([]Val{a}), pos)
    return Some(s.scalar(r))
}

// hash of any value that supports `==`
fn hash_val(self *Fx, v Val, pos Pos) Opt[i64] {
    match self.cx.types.k(v.ty) {
        TyKInt(_, _) => {
            x := self.to_i64(v)
            return lower_call_hash_u64(self, x, pos)
        }
        TyKBool => {
            x := self.to_i64(v)
            return lower_call_hash_u64(self, x, pos)
        }
        TyKPtr(_) => {
            x := self.scalar(v)
            return lower_call_hash_u64(self, x, pos)
        }
        TyKFn(_, _) => {
            x := self.scalar(v)
            return lower_call_hash_u64(self, x, pos)
        }
        TyKEnum(_) => {
            if self.cx.types.is_scalar(v.ty) {
                x := self.scalar(v)
                return lower_call_hash_u64(self, x, pos)
            }
        }
        TyKF32 => {
            d := self.convert(v, T_F64, pos)
            return self.hash_val(d, pos)
        }
        TyKF64 => {
            // -0.0 == 0.0, so both must hash alike
            x := self.scalar(v)
            z := self.ins(OpFConst, TF64, vec[i64](), 0)
            n := self.ins(OpFAdd, TF64, vec_of([]i64{x, z}), 0)
            bits := self.ins(OpFToBits, TI64, vec_of([]i64{n}), 0)
            return lower_call_hash_u64(self, bits, pos)
        }
        TyKSlice(et) => {
            var r Val
            if et == T_U8 {
                r = self.call_rt("__hash_str", vec[i64](), vec_of([]Val{v}), pos)
            } else {
                r = self.call_rt("__hash_slice", vec_of([]i64{et}), vec_of([]Val{v}), pos)
            }
            return Some(self.scalar(r))
        }
        TyKArray(et, n) => {
            sty := self.cx.types.slice(et)
            t := self.temp(sty)
            sv := self.mval(sty, t)
            nv := self.iconst(TI64, i64(n))
            self.store_slice(sv, v.v, nv)
            var r Val
            if et == T_U8 {
                r = self.call_rt("__hash_str", vec[i64](), vec_of([]Val{sv}), pos)
            } else {
                r = self.call_rt("__hash_slice", vec_of([]i64{et}), vec_of([]Val{sv}), pos)
            }
            return Some(self.scalar(r))
        }
        TyKStruct(sid) => {
            names := vec[str]()
            nf := self.cx.types.structs[sid].fields.len
            for j in 0..nf {
                names.push(self.cx.types.structs[sid].fields[j].0)
            }
            return lower_call_hash_fields(self, v, names, pos)
        }
        TyKTuple(ts) => {
            names := vec[str]()
            for i in 0..ts.len {
                names.push(fmt(i))
            }
            return lower_call_hash_fields(self, v, names, pos)
        }
        _ => {}
    }
    tn := self.tyname(v.ty)
    self.err(pos, fmt("values of type ", tn, " cannot be hashed"))
    return None
}

// the struct / tuple case of `hash_val`: mixes the hashes of the named fields
fn lower_call_hash_fields(s *Fx, v Val, names Vec[str], pos Pos) Opt[i64] {
    h := s.iconst(TI64, 0x51ed270b)
    for j in 0..names.len {
        n := names[j]
        var p Val
        match s.field_of(v, n, pos) {
            Some(x) => {
                p = x
            }
            None => {
                return None
            }
        }
        fv := s.rvalue(p)
        fh := 0
        match s.hash_val(fv, pos) {
            Some(x) => {
                fh = x
            }
            None => {
                return None
            }
        }
        a := s.sval(T_U64, h)
        b := s.sval(T_U64, fh)
        r := s.call_rt("__hash_mix", vec[i64](), vec_of([]Val{a, b}), pos)
        h = s.scalar(r)
    }
    return Some(h)
}

fn put_lit_pub(self *Fx, s str, pos Pos) {
    self.put_lit(s, pos)
}

fn put_lit(self *Fx, s str, pos Pos) {
    v := self.str_val(s)
    self.call_rt("__put_str", vec[i64](), vec_of([]Val{v}), pos)
}

fn put_val(self *Fx, v Val, pos Pos, depth i64) {
    if v.ty == T_ERR || v.ty == T_NEVER {
        return
    }
    match self.cx.types.k(v.ty) {
        TyKUnit => {
            self.put_lit("()", pos)
        }
        TyKInt(bits, signed) => {
            s := self.scalar(v)
            if i64(bits) < 64 {
                var op Op
                if signed {
                    op = OpSExt
                } else {
                    op = OpZExt
                }
                s = self.ins(op, TI64, vec_of([]i64{s}), 0)
            }
            f := "__put_u64"
            t := T_U64
            if signed {
                f = "__put_i64"
                t = T_I64
            }
            a := self.sval(t, s)
            self.call_rt(f, vec[i64](), vec_of([]Val{a}), pos)
        }
        TyKF32 => {
            self.call_rt("__put_f32", vec[i64](), vec_of([]Val{v}), pos)
        }
        TyKVec(_) => {
            self.put_vec(v, pos)
        }
        TyKQuat => {
            self.put_vec(v, pos)
        }
        TyKMat4 => {
            self.put_vec(v, pos)
        }
        TyKF64 => {
            self.call_rt("__put_f64", vec[i64](), vec_of([]Val{v}), pos)
        }
        TyKBool => {
            self.call_rt("__put_bool", vec[i64](), vec_of([]Val{v}), pos)
        }
        TyKPtr(_) => {
            s := self.scalar(v)
            a := self.sval(T_I64, s)
            self.call_rt("__put_ptr", vec[i64](), vec_of([]Val{a}), pos)
        }
        TyKFn(_, _) => {
            s := self.scalar(v)
            a := self.sval(T_I64, s)
            self.call_rt("__put_ptr", vec[i64](), vec_of([]Val{a}), pos)
        }
        TyKSlice(et) => {
            if et == T_U8 {
                self.call_rt("__put_str", vec[i64](), vec_of([]Val{v}), pos)
            } else {
                self.call_rt("__put_slice", vec_of([]i64{et}), vec_of([]Val{v}), pos)
            }
        }
        TyKArray(et, n) => {
            sty := self.cx.types.slice(et)
            t := self.temp(sty)
            sv := self.mval(sty, t)
            nv := self.iconst(TI64, i64(n))
            self.store_slice(sv, v.v, nv)
            self.call_rt("__put_slice", vec_of([]i64{et}), vec_of([]Val{sv}), pos)
        }
        TyKStruct(sid) => {
            if depth > 8 {
                self.put_lit("...", pos)
                return
            }
            name := self.cx.types.structs[sid].name
            fields := clone(self.cx.types.structs[sid].fields)
            self.put_lit(fmt(name, "{"), pos)
            for i in 0..fields.len {
                fname := fields[i].0
                sep := if i > 0 { ", " } else { "" }
                self.put_lit(fmt(sep, fname, ": "), pos)
                match self.field_of(v, fname, pos) {
                    Some(p) => {
                        fv := self.rvalue(p)
                        self.put_val(fv, pos, depth + 1)
                    }
                    None => {}
                }
            }
            self.put_lit("}", pos)
        }
        TyKTuple(tys) => {
            self.put_lit("(", pos)
            for i in 0..tys.len {
                if i > 0 {
                    self.put_lit(", ", pos)
                }
                match self.field_of(v, fmt(i), pos) {
                    Some(p) => {
                        fv := self.rvalue(p)
                        self.put_val(fv, pos, depth + 1)
                    }
                    None => {}
                }
            }
            self.put_lit(")", pos)
        }
        TyKEnum(eid) => {
            if depth > 8 {
                self.put_lit("...", pos)
                return
            }
            simple := self.cx.types.enums[eid].simple
            variants := clone(self.cx.types.enums[eid].variants)
            tag := 0
            if simple {
                tag = self.scalar(v)
            } else {
                tag = self.load_raw(v.v, TI64, AK_ANY)
            }
            bj := self.new_block()
            for vi in 0..variants.len {
                vname := variants[vi].0
                ptys := variants[vi].1
                bt := self.new_block()
                bn := self.new_block()
                c := self.iconst(TI64, vi)
                eq := self.ins(OpEq, TI8, vec_of([]i64{tag, c}), 0)
                self.br(eq, bt, bn)
                self.switch_to(bt)
                self.put_lit(vname, pos)
                if ptys.len != 0 {
                    self.put_lit("(", pos)
                    offs := self.cx.types.variant_offsets(eid, vi)
                    for i in 0..ptys.len {
                        if i > 0 {
                            self.put_lit(", ", pos)
                        }
                        src := self.add_off(v.v, i64(offs[i]))
                        pv := self.load_any(src, ptys[i])
                        pv = self.rvalue(pv)
                        self.put_val(pv, pos, depth + 1)
                    }
                    self.put_lit(")", pos)
                }
                self.jmp(bj)
                self.switch_to(bn)
            }
            self.put_lit("<invalid enum>", pos)
            self.jmp(bj)
            self.switch_to(bj)
        }
        TyKErr => {}
        TyKNever => {}
    }
}
