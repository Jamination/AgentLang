// Lowering of the memory features: calls of names shared by a builtin and declared functions,
// the library's `Vec` as an indexable value, and the builtin `clone`.

// ---------- names that are builtins ----------
// every name `builtin` (lower_call.al) answers to
fn lower_mem_is_builtin(name: str) -> bool {
    // (a `priv` function named like a builtin shares the name in its file as well)
    match ast_plain(name) {
        "len", "sizeof", "cast", "mkslice", "ptr", "syscall", "sqrt", "fabs", "fmin", "fmax" => true
        "popcnt", "ctz", "clz", "bswap", "rotl", "rotr", "memcopy", "memfill", "embed", "panic" => true
        "fmt", "hash", "put", "print", "clone", "mulhi" => true
        _ => false
    }
}

// builtins that can be called as a method: `x.f(a)` means `f(x, a)`
priv fn is_method_builtin(name: str) -> bool {
    match name {
        "len", "clone", "hash", "ptr", "sqrt", "fabs", "fmin", "fmax" => true
        "popcnt", "ctz", "clz", "bswap", "rotl", "rotr" => true
        _ => false
    }
}

// Would `call_decl` accept these arguments for declaration `d`? `tys[i]` is the type of
// argument i, or -1 for an untyped literal (which is not evaluated).
priv fn decl_accepts(self: *Fx, d: *FnDecl, explicit: Opt[Vec[i64]], recv: Opt[Val], args: []Expr, tys: []i64) -> bool {
    nrecv := if is_some(recv) { 1 } else { 0 }
    if d.params.len != len(args) + nrecv {
        return false
    }
    generic := d.tparams.len != 0
    env := map[str, i64]()
    match explicit {
        Some(t) => {
            if t.len != d.tparams.len {
                return false
            }
            for j in 0..t.len {
                env.set(d.tparams[j], t[j])
            }
        }
        None => {}
    }
    match recv {
        Some(rv) => {
            pt := &d.params[0].1
            if !self.param_accepts(d, pt, rv.ty, true, lower_call_as_slice(explicit)) {
                return false
            }
            if generic {
                // bind the type parameters the way `call_decl` does: by value, then through
                // a pointer in either direction
                e2 := clone(env)
                if self.unify(pt, rv.ty, d.tparams.items(), &e2) {
                    env = e2
                } else {
                    e3 := clone(env)
                    ok := match *pt {
                        Ptr(inner) => self.unify(inner, rv.ty, d.tparams.items(), &e3)
                        _ => match self.cx.types.k(rv.ty) {
                            Ptr(t) => self.unify(pt, t, d.tparams.items(), &e3)
                            _ => false
                        }
                    }
                    if ok {
                        env = e3
                    }
                }
            }
        }
        None => {}
    }
    // typed arguments first: they bind the type parameters (as in `call_decl`)
    for i in 0..len(args) {
        pt := &d.params[nrecv + i].1
        ty := tys[i]
        if ty < 0 || ty == T_NEVER {
            continue
        }
        if generic {
            if !self.unify(pt, ty, d.tparams.items(), &env) {
                return false
            }
            if lower_call_mentions_unbound(pt, d.tparams.items(), &env) {
                continue
            }
        }
        saved := self.cx.errs.len
        t := self.cx.resolve(pt, &env)
        self.cx.errs.truncate(saved)
        if t != ty {
            return false
        }
    }
    // then the untyped literals: each must be acceptable to the type of its parameter
    for i in 0..len(args) {
        if tys[i] >= 0 {
            continue
        }
        pt := &d.params[nrecv + i].1
        a := &args[i]
        if generic && lower_call_mentions_unbound(pt, d.tparams.items(), &env) {
            // a literal binds a type parameter to its default type, when it has one
            dt := literal_type(self, a)
            if dt < 0 || !self.unify(pt, dt, d.tparams.items(), &env) {
                return false
            }
            continue
        }
        saved := self.cx.errs.len
        t := self.cx.resolve(pt, &env)
        self.cx.errs.truncate(saved)
        if !literal_ok(self, a, t) {
            return false
        }
    }
    return true
}

// can the untyped literal (or constant) `a` be a value of type `t`?
priv fn literal_ok(s: *Fx, a: *Expr, t: i64) -> bool {
    k := s.cx.types.k(t)
    match a.k {
        Nil => {
            return lower_call_is_ptr(k) || lower_call_is_fn(k) || lower_call_is_slice(k)
        }
        _ => {}
    }
    vn := s.variant_ref(a)
    if vn != "" {
        return match k {
            Enum(eid) => s.cx.variant_of(s.cx.types.enums[eid].decl, vn) >= 0
            _ => false
        }
    }
    match s.cx.const_eval(a) {
        Some(Str(_)) => t == T_STR
        Some(Bool(_)) => t == T_BOOL
        Some(Float(_)) => s.cx.types.is_float(t)
        _ => s.cx.types.is_int(t) || s.cx.types.is_float(t)
    }
}

// the type an untyped literal (or constant) takes without context; -1 if it has none
priv fn literal_type(s: *Fx, a: *Expr) -> i64 {
    match a.k {
        Nil => {
            return -1
        }
        Ident(n) => {
            if !is_some(s.lookup(n)) {
                bv := s.bare_variant(n, None)
                if bv.2 == 2 {
                    return -1
                }
                if bv.2 == 1 {
                    if s.cx.enum_decls[bv.0].tparams.len != 0 {
                        return -1
                    }
                    return s.cx.inst_enum(bv.0, vec[i64](), a.pos)
                }
            }
        }
        _ => {}
    }
    if s.variant_ref(a) != "" {
        return -1
    }
    match s.cx.const_eval(a) {
        Some(Str(_)) => T_STR
        Some(Bool(_)) => T_BOOL
        Some(Float(_)) => T_F64
        _ => T_I64
    }
}

// A call of a name that is a builtin and may also be declared as a function. The declared
// functions are tried by the usual rules; when none of them accepts the arguments (their
// number or their types), the builtin is used. `recv` / `recv_e`: the receiver of a method
// call and its expression.
//
// The typed arguments must be evaluated to know their types, and they must be evaluated only
// once: their values are remembered in `memo`, where the code that finally lowers the call
// (`call_decl`, `call_overloaded` or `builtin`) finds them.
fn call_shared(self: *Fx, name: str, cands0: Vec[i64], explicit: Opt[Vec[i64]], recv: Opt[Val], recv_e: *Expr, args0: []Expr, expect: Opt[i64], pos: Pos) -> Val {
    cands := cands0
    if self.cx.scope_prelude && !self.cx.p_fn_over.has(name) {
        // library code means the builtin, whatever the program declares under this name
        cands = vec[i64]()
    }
    nrecv := 0
    args := args0
    all: []Expr
    match recv {
        Some(rv) => {
            // the builtin takes the receiver as its first argument
            nrecv = 1
            all = alloc[Expr](len(args0) + 1)
            all[0] = *recv_e
            for i in 0..len(args0) {
                all[i + 1] = args0[i]
            }
            args = all[1..]
        }
        None => {}
    }
    alive := vec[i64]()
    for ci in 0..cands.len {
        d := self.cx.fn_decls[cands[ci]]
        targs_ok := match explicit {
            Some(t) => t.len == d.tparams.len
            None => true
        }
        if targs_ok && d.params.len == len(args) + nrecv {
            if nrecv == 1 && !self.param_accepts(d, &d.params[0].1, unwrap(recv).ty, true, lower_call_as_slice(explicit)) {
                continue
            }
            alive.push(cands[ci])
        }
    }
    memo_mark := self.memo.len
    if alive.len != 0 {
        tys := vec[i64]()
        failed := false
        for i in 0..len(args) {
            a := &args[i]
            if self.is_untyped(a) {
                tys.push(-1)
                continue
            }
            // a single definition that is not generic tells the type its parameter expects
            exp: Opt[i64] = None
            if alive.len == 1 {
                d := self.cx.fn_decls[alive[0]]
                if d.tparams.len == 0 {
                    saved := self.cx.errs.len
                    empty := map[str, i64]()
                    t := self.cx.resolve(&d.params[nrecv + i].1, &empty)
                    self.cx.errs.truncate(saved)
                    if t != T_ERR {
                        exp = Some(t)
                    }
                }
            }
            nerr := self.cx.errs.len
            v := self.expr(a, exp)
            if is_some(exp) && self.cx.errs.len > nerr {
                // the argument was typed for the one declared function: name it
                e := &self.cx.errs[nerr]
                e.msg = fmt(e.msg, " (argument ", i + 1, " of the declared `", lower_call_call_overloaded_sigs(self, alive.items()), "`)")
            }
            v = self.stabilize(v, args[i + 1..])
            self.memo.push((a, v))
            tys.push(v.ty)
            if v.ty == T_ERR {
                failed = true
            }
        }
        if failed {
            self.memo.truncate(memo_mark)
            return val_err()
        }
        keep := vec[i64]()
        for ai in 0..alive.len {
            if self.decl_accepts(self.cx.fn_decls[alive[ai]], explicit, recv, args, tys.items()) {
                keep.push(alive[ai])
            }
        }
        alive = keep
    }
    r: Val
    if alive.len == 1 {
        r = self.call_decl(alive[0], explicit, recv, args, expect, pos, lower_call_no_pre())
    } else if alive.len > 1 {
        r = self.call_overloaded(alive.items(), explicit, recv, args, expect, pos)
    } else {
        bargs := args
        usable := true
        match recv {
            Some(rv) => {
                if is_method_builtin(ast_plain(name)) {
                    self.memo.push((&all[0], rv))
                    bargs = all
                } else {
                    usable = false
                    tn := self.tyname(rv.ty)
                    if cands.len != 0 {
                        s := lower_call_call_overloaded_sigs(self, cands.items())
                        self.err(pos, fmt("no definition of `", name, "` can be called on ", tn, "; candidates: ", s, " (the builtin `", name, "` has no method form: call it as a plain function)"))
                    } else {
                        self.err(pos, fmt("no function `", name, "` to call on ", tn, " (the builtin `", name, "` has no method form: call it as a plain function)"))
                    }
                    lower_call_eval_all(self, args)
                }
            }
            None => {}
        }
        has_targs := match explicit {
            Some(t) => t.len != 0
            None => false
        }
        if usable && has_targs && ast_plain(name) != "sizeof" && ast_plain(name) != "cast" && ast_plain(name) != "mkslice" {
            usable = false
            self.err(pos, fmt("the builtin `", name, "` takes no type arguments, and no declared `", name, "` accepts these"))
            lower_call_eval_all(self, bargs)
        }
        r = val_err()
        if usable {
            saved := self.cx.errs.len
            match self.builtin(ast_plain(name), lower_call_as_slice(explicit), bargs, expect, pos) {
                Some(v) => {
                    r = v
                }
                None => {}
            }
            if r.ty == T_ERR && self.cx.errs.len > saved && cands.len != 0 {
                // the declared functions were tried first: say so
                e := &self.cx.errs[saved]
                s := lower_call_call_overloaded_sigs(self, cands.items())
                e.msg = fmt(e.msg, " (the declared functions do not accept these arguments either: ", s, ")")
            }
        }
    }
    self.memo.truncate(memo_mark)
    return r
}

// ---------- the library's Vec and Map ----------
// the element type of the library's `Vec[T]` (a user struct that is also named Vec is not one)
priv fn vec_elem(self: *Cx, t: i64) -> Opt[i64] {
    match self.types.k(t) {
        Struct(sid) => {
            di, has := self.p_struct_names.get("Vec")
            si := &self.types.structs[sid]
            if has && si.decl == di && si.targs.len == 1 {
                return Some(si.targs[0])
            }
        }
        _ => {}
    }
    return None
}

// the key and value types of the library's `Map[K, V]`
fn map_kv(self: *Cx, t: i64) -> Opt[(i64, i64)] {
    match self.types.k(t) {
        Struct(sid) => {
            di, has := self.p_struct_names.get("Map")
            si := &self.types.structs[sid]
            if has && si.decl == di && si.targs.len == 2 {
                return Some((si.targs[0], si.targs[1]))
            }
        }
        _ => {}
    }
    return None
}

// `len(m)` of a `Map`: its field `len`
fn map_len(self: *Fx, v: Val) -> Opt[Val] {
    if !is_some(self.cx.map_kv(v.ty)) {
        return None
    }
    match self.field_of(v, "len", Pos{file: 0, line: 0, col: 0}) {
        Some(p) => Some(self.rvalue(p))
        None => None
    }
}

// (pointer to the elements, length, element type) of a `Vec` in memory: what indexing,
// slicing and iteration use. The pointer is only loaded when `want_ptr` (NOV otherwise).
fn vec_parts(self: *Fx, v: Val, want_ptr: bool) -> Opt[(i64, i64, i64)] {
    et := match self.cx.vec_elem(v.ty) {
        Some(t) => t
        None => return None
    }
    if !v.mem {
        return None
    }
    sid := match self.cx.types.k(v.ty) {
        Struct(s) => s
        _ => 0
    }
    // struct Vec[T] { buf []T, len i64 }
    self.cx.types.layout_struct(sid)
    off_buf := self.cx.types.structs[sid].offsets[0]
    off_len := self.cx.types.structs[sid].offsets[1]
    p := NOV
    if want_ptr {
        leaves := vec[Leaf]()
        self.cx.types.leaves(self.cx.types.slice(et), 0, &leaves)
        a := self.add_off(v.v, off_buf)
        p = self.load_raw(a, I64, leaves[0].alias)
    }
    a := self.add_off(v.v, off_len)
    l := self.load_raw(a, I64, self.cx.types.field_alias(v.ty, 1, T_I64))
    return Some((p, l, et))
}

// ---------- clone ----------
// Does a value of type `t` own storage outside itself (a slice, and so a str, Vec or Map,
// anywhere inside)? Pointers are not followed: `clone` shares what they point to.
priv fn has_heap(self: *Cx, t: i64, depth: i64) -> bool {
    // a type that contains itself by value is reported by the layout; do not recurse forever
    if depth > 40 {
        return false
    }
    match self.types.k(t) {
        Slice(_) => return true
        Array(e, n) => return n != 0 && self.has_heap(e, depth + 1)
        Struct(sid) => {
            for i in 0..self.types.structs[sid].fields.len {
                if self.has_heap(self.types.structs[sid].fields[i].1, depth + 1) {
                    return true
                }
            }
            return false
        }
        Enum(eid) => {
            for vi in 0..self.types.enums[eid].variants.len {
                for i in 0..self.types.enums[eid].variants[vi].1.len {
                    if self.has_heap(self.types.enums[eid].variants[vi].1[i], depth + 1) {
                        return true
                    }
                }
            }
            return false
        }
        Tuple(ts) => {
            for i in 0..ts.len {
                if self.has_heap(ts[i], depth + 1) {
                    return true
                }
            }
            return false
        }
        _ => {}
    }
    return false
}

// the builtin `clone(x)`
fn clone_builtin(self: *Fx, args: []Expr, expect: Opt[i64], pos: Pos) -> Val {
    if len(args) != 1 {
        self.err(pos, fmt("`clone` takes 1 argument(s), got ", len(args)))
        lower_call_eval_all(self, args)
        return val_err()
    }
    v := self.expr(&args[0], expect)
    if v.ty == T_UNIT {
        self.err(args[0].pos, "`clone` needs a value; this expression has none")
        return val_err()
    }
    match self.cx.types.k(v.ty) {
        // (in a generic function the type may happen to be a pointer: copied as it is)
        Ptr(_) if self.tenv.len == 0 => {
            self.err(pos, "`clone` of a pointer would copy the pointer, not what it points to; write `clone(*p)` for a copy of the value, or assign the pointer itself")
            return val_err()
        }
        _ => {}
    }
    return self.clone_val(v, pos, 0)
}

// a copy of the bytes of `v` in a fresh temporary
priv fn clone_copy(self: *Fx, v: Val) -> Val {
    if !v.mem {
        return v
    }
    t := self.temp(v.ty)
    tv := self.mval(v.ty, t)
    self.store(tv, v)
    return tv
}

// the members `names` of the struct or tuple copy `tv` that own storage are replaced by clones
priv fn clone_fields(s: *Fx, v: Val, tv: Val, names: Vec[str], tys: Vec[i64], pos: Pos, depth: i64) {
    for i in 0..names.len {
        if !s.cx.has_heap(tys[i], 0) {
            continue
        }
        src := match s.field_of(v, names[i], pos) {
            Some(p) => p
            None => continue
        }
        dst := match s.field_of(tv, names[i], pos) {
            Some(p) => p
            None => continue
        }
        c := s.clone_val(src, pos, depth + 1)
        s.store(dst, c)
    }
}

// An independent copy of `v`, allocated from the current arena: slices (and so str, Vec and
// Map) get new storage, recursively; pointers and function values are copied as they are.
priv fn clone_val(self: *Fx, v: Val, pos: Pos, depth: i64) -> Val {
    ty := v.ty
    if ty == T_ERR || ty == T_NEVER || ty == T_UNIT {
        return v
    }
    if self.cx.types.is_scalar(ty) {
        return self.rvalue(v)
    }
    if !v.mem {
        return v
    }
    if depth > 40 || !self.cx.has_heap(ty, 0) {
        // nothing to duplicate
        return self.clone_copy(v)
    }
    match self.cx.types.k(ty) {
        Slice(et) => {
            // plain elements: one allocation and one memory copy
            name := if self.cx.has_heap(et, 0) { "__clone_slice" } else { "__clone_plain" }
            return self.call_rt(name, vec_of([]i64{et}), vec_of([]Val{v}), pos)
        }
        Array(et, n) => {
            t := self.temp(ty)
            sty := self.cx.types.slice(et)
            nv := self.iconst(I64, n)
            d := self.mval(sty, self.temp(sty))
            self.store_slice(d, t, nv)
            s := self.mval(sty, self.temp(sty))
            self.store_slice(s, v.v, nv)
            self.call_rt("__clone_elems", vec_of([]i64{et}), vec_of([]Val{d, s}), pos)
            return self.mval(ty, t)
        }
        Struct(sid) => {
            match self.cx.vec_elem(ty) {
                Some(et) => {
                    // the live elements only: the spare capacity is uninitialised memory
                    name := if self.cx.has_heap(et, 0) { "__clone_vec" } else { "__clone_vec_plain" }
                    return self.call_rt(name, vec_of([]i64{et}), vec_of([]Val{v}), pos)
                }
                None => {}
            }
            match self.cx.map_kv(ty) {
                Some(kv) => {
                    m := self.sval(self.cx.types.ptr_to(ty), v.v)
                    kp := self.sval(T_BOOL, self.iconst(I8, lower_expr_bool_i64(!self.cx.has_heap(kv.0, 0))))
                    vp := self.sval(T_BOOL, self.iconst(I8, lower_expr_bool_i64(!self.cx.has_heap(kv.1, 0))))
                    return self.call_rt("__clone_map", vec_of([]i64{kv.0, kv.1}), vec_of([]Val{m, kp, vp}), pos)
                }
                None => {}
            }
            names := vec[str]()
            tys := vec[i64]()
            for i in 0..self.cx.types.structs[sid].fields.len {
                names.push(self.cx.types.structs[sid].fields[i].0)
                tys.push(self.cx.types.structs[sid].fields[i].1)
            }
            tv := self.clone_copy(v)
            clone_fields(self, v, tv, names, tys, pos, depth)
            return tv
        }
        Tuple(ts) => {
            names := vec[str]()
            tys := vec[i64]()
            for i in 0..ts.len {
                names.push(fmt(i))
                tys.push(ts[i])
            }
            tv := self.clone_copy(v)
            clone_fields(self, v, tv, names, tys, pos, depth)
            return tv
        }
        Enum(eid) => {
            // the same variant; its payload values that own storage are cloned
            tv := self.clone_copy(v)
            nvar := self.cx.types.enums[eid].variants.len
            tag := self.load_raw(v.v, I64, AK_ANY)
            bj := self.new_block()
            for vi in 0..nvar {
                ptys := vec[i64]()
                any := false
                for i in 0..self.cx.types.enums[eid].variants[vi].1.len {
                    pt := self.cx.types.enums[eid].variants[vi].1[i]
                    ptys.push(pt)
                    if self.cx.has_heap(pt, 0) {
                        any = true
                    }
                }
                if !any {
                    continue
                }
                bt := self.new_block()
                bn := self.new_block()
                c := self.iconst(I64, vi)
                eq := self.ins(Eq, I8, vec_of([]i64{tag, c}), 0)
                self.br(eq, bt, bn)
                self.switch_to(bt)
                offs := self.cx.types.variant_offsets(eid, vi)
                for i in 0..ptys.len {
                    if !self.cx.has_heap(ptys[i], 0) {
                        continue
                    }
                    src := self.add_off(v.v, offs[i])
                    pv := self.load_any(src, ptys[i])
                    cv := self.clone_val(pv, pos, depth + 1)
                    fd := self.mval(ptys[i], self.add_off(tv.v, offs[i]))
                    fd.alias = 0
                    self.store_any(fd, cv)
                }
                self.jmp(bj)
                self.switch_to(bn)
            }
            self.jmp(bj)
            self.switch_to(bj)
            return tv
        }
        _ => {}
    }
    return self.clone_copy(v)
}
