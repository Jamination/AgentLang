// File-private declarations (`priv fn`, `priv struct`, `priv enum`, `priv const`, `priv var`).
//
// All top-level names of a program share one namespace. A private declaration `name` of file
// number `k` is taken out of it by renaming: right after the file is parsed, the declaration
// and every identifier of that spelling in the same file get the internal name
// `name` + byte 1 + `k`, which cannot be written in source. The rest of the compiler needs no
// notion of files: other files simply cannot spell the name. Local variables, parameters and
// type parameters of the same spelling are renamed with it, so shadowing works as written.
// Field names, field labels of literals and enum variant names are not renamed.
//
// Where the rest of the compiler knows about internal names:
// - ast_plain / ast_plain_text (ast.al) give the written name; every diagnostic and `alc sigs`
//   line passes through ast_plain_text (main.al); types, functions, globals and C imports get
//   their plain name when they are created (lower.al)
// - a call `f(..)` / `x.f(..)` of a private function also considers the public definitions of
//   the written name (fn_candidates in lower.al; private ones win, call_overloaded in
//   lower_call.al)
// - `x.f(..)` first looks for a field `f` holding a function (call in lower_call.al, field_of
//   in lower_expr.al use the plain name)
//
// The walkers below return a value from a `match` over every variant, which makes the match
// exhaustive: a new AST variant does not compile until it is handled here.

struct PrivCx {
    // written name -> internal name, for every private declaration of the file
    names Map[str, str]
    // the same for private functions only (method-call syntax `x.f(..)`)
    methods Map[str, str]
}

// (name, kind, private, position) of a declaration; kind 0 = declares no name,
// 1 = function, 2 = any other kind
fn priv_decl_info(d *Decl) (str, i64, bool, Pos) {
    return match *d {
        DeclFn(f) => (f.name, 1, f.is_priv, f.pos)
        DeclStruct(s) => (s.name, 2, s.is_priv, s.pos)
        DeclEnum(e) => (e.name, 2, e.is_priv, e.pos)
        DeclConst(c) => (c.name, 2, c.is_priv, c.pos)
        DeclGlobal(g) => (g.name, 2, g.is_priv, g.pos)
        DeclType(t) => (t.name, 2, t.is_priv, t.pos)
        DeclTest(t) => ("", 0, false, t.pos)
        DeclUse(path, pos) => ("", 0, false, pos)
    }
}

// Renames the private declarations of one file (number `file`) and their uses.
fn priv_apply(decls *Vec[Decl], file i64, errs *Vec[Diag]) {
    any := false
    for i in 0..decls.len {
        info := priv_decl_info(&decls[i])
        if info.2 {
            any = true
            break
        }
    }
    if !any {
        return
    }
    r := PrivCx{names: map[str, str](), methods: map[str, str]()}
    // written name -> (private, kind, line) of its first declaration in this file
    seen := map[str, (bool, i64, i64)]()
    for i in 0..decls.len {
        name, kind, is_private, pos := priv_decl_info(&decls[i])
        if kind == 0 {
            continue
        }
        first, known := seen.get(name)
        if !known {
            seen.set(name, (is_private, kind, pos.line))
        } else if first.0 != is_private {
            if kind == 1 && first.1 == 1 {
                errs.push(Diag{pos: pos, msg: fmt("function `", name, "` is defined both with and without `priv` in this file (the other definition is at line ", first.2, "): the definitions of one name in a file are all private or all public; write `priv` in front of every one, or of none")})
            } else {
                errs.push(Diag{pos: pos, msg: fmt("`", name, "` is declared both with and without `priv` in this file (the other declaration is at line ", first.2, "): inside the file the name would be ambiguous; rename one of them")})
            }
        }
        // a builtin type name is rejected as a declaration name anyway (cx_new): renaming it
        // would only hide the type from the rest of the file
        if is_private && !r.names.has(name) && !is_some(lower_builtin_type(name)) {
            r.names.set(name, fmt(name, "\x01", file))
        }
    }
    for i in 0..decls.len {
        name, kind, is_private, pos := priv_decl_info(&decls[i])
        if kind == 1 && r.names.has(name) {
            r.methods.set(name, r.names.get_or(name, name))
        }
    }
    // enum variants are not private: inside this file a private declaration of the same name
    // would hide the variant
    for i in 0..decls.len {
        match decls[i] {
            DeclEnum(e) => {
                for vi in 0..e.variants.len {
                    vn := e.variants[vi].0
                    if r.names.has(vn) {
                        errs.push(Diag{pos: e.pos, msg: fmt("enum variant `", vn, "` conflicts with the `priv` declaration `", vn, "` of this file (variants are never private); rename one of them")})
                    }
                }
            }
            _ => {}
        }
    }
    for i in 0..decls.len {
        decls[i] = priv_rewrite(&r, decls[i])
    }
}

fn priv_name(r *PrivCx, n str) str {
    nn, found := r.names.get(n)
    if found {
        return nn
    }
    return n
}

fn priv_names(r *PrivCx, v *Vec[str]) {
    for i in 0..v.len {
        v[i] = priv_name(r, v[i])
    }
}

// a function, top-level or nested: its name, parameters, types and body
fn priv_fn(r *PrivCx, f *FnDecl) bool {
    f.name = priv_name(r, f.name)
    priv_names(r, &f.tparams)
    for i in 0..f.params.len {
        f.params[i].0 = priv_name(r, f.params[i].0)
        priv_type(r, &f.params[i].1)
    }
    f.ret = priv_opt_type(r, f.ret)
    return priv_block(r, f.body)
}

fn priv_rewrite(r *PrivCx, d Decl) Decl {
    return match d {
        DeclFn(f) => {
            priv_fn(r, &f)
            DeclFn(f)
        }
        DeclStruct(s) => {
            s.name = priv_name(r, s.name)
            priv_names(r, &s.tparams)
            for i in 0..s.fields.len {
                priv_type(r, &s.fields[i].1)
            }
            DeclStruct(s)
        }
        DeclEnum(e) => {
            e.name = priv_name(r, e.name)
            priv_names(r, &e.tparams)
            for i in 0..e.variants.len {
                priv_types(r, &e.variants[i].1)
            }
            DeclEnum(e)
        }
        DeclConst(c) => {
            c.name = priv_name(r, c.name)
            c.ty = priv_opt_type(r, c.ty)
            priv_expr(r, &c.val)
            DeclConst(c)
        }
        DeclGlobal(g) => {
            g.name = priv_name(r, g.name)
            g.ty = priv_opt_type(r, g.ty)
            g.init = priv_opt_expr(r, g.init)
            DeclGlobal(g)
        }
        DeclType(t) => {
            t.name = priv_name(r, t.name)
            priv_type(r, &t.ty)
            DeclType(t)
        }
        DeclTest(t) => {
            priv_block(r, t.body)
            DeclTest(t)
        }
        DeclUse(path, pos) => d
    }
}

fn priv_types(r *PrivCx, ts *Vec[TypeAst]) bool {
    for i in 0..ts.len {
        priv_type(r, &ts[i])
    }
    return true
}

fn priv_type(r *PrivCx, t *TypeAst) bool {
    return match *t {
        TypeAstName(n, args, pos) => {
            priv_types(r, &args)
            nn, found := r.names.get(n)
            if found {
                *t = TypeAstName(nn, args, pos)
            }
            true
        }
        TypeAstPtr(e) => priv_type(r, e)
        TypeAstSlice(e) => priv_type(r, e)
        TypeAstArray(n, e) => {
            priv_expr(r, n)
            priv_type(r, e)
        }
        TypeAstFn(ps, ret) => {
            priv_types(r, &ps)
            match ret {
                Some(rt) => priv_type(r, rt)
                None => true
            }
        }
        TypeAstTuple(ts) => priv_types(r, &ts)
    }
}

fn priv_opt_type(r *PrivCx, o Opt[TypeAst]) Opt[TypeAst] {
    match o {
        Some(t) => {
            var tt TypeAst = t
            priv_type(r, &tt)
            return Some(tt)
        }
        None => {}
    }
    return o
}

fn priv_opt_expr(r *PrivCx, o Opt[Expr]) Opt[Expr] {
    match o {
        Some(e) => {
            var ee Expr = e
            priv_expr(r, &ee)
            return Some(ee)
        }
        None => {}
    }
    return o
}

fn priv_opt_pexpr(r *PrivCx, o Opt[*Expr]) bool {
    match o {
        Some(e) => {
            return priv_expr(r, e)
        }
        None => {}
    }
    return true
}

fn priv_exprs(r *PrivCx, es *Vec[Expr]) bool {
    for i in 0..es.len {
        priv_expr(r, &es[i])
    }
    return true
}

// the callee of a call: `x.f(..)` and `x.f[T](..)` name the function `f` if one is private
// in this file (lowering still prefers a field `f` that holds a function)
fn priv_callee(r *PrivCx, c *Expr) bool {
    match c.k {
        EKField(recv, name) => {
            priv_expr(r, recv)
            mn, found := r.methods.get(name)
            if found {
                c.k = EKField(recv, mn)
            }
            return true
        }
        EKIndex(b, targs) => {
            match b.k {
                EKField(recv, name) => {
                    priv_callee(r, b)
                    return priv_exprs(r, &targs)
                }
                _ => {}
            }
        }
        _ => {}
    }
    return priv_expr(r, c)
}

fn priv_expr(r *PrivCx, e *Expr) bool {
    return match e.k {
        EKInt(v) => true
        EKFloat(v) => true
        EKStr(s) => true
        EKBool(b) => true
        EKNil => true
        EKIdent(n) => {
            nn, found := r.names.get(n)
            if found {
                e.k = EKIdent(nn)
            }
            true
        }
        EKUn(op, x) => priv_expr(r, x)
        EKBin(op, a, b) => {
            priv_expr(r, a)
            priv_expr(r, b)
        }
        EKCall(c, args) => {
            priv_callee(r, c)
            priv_exprs(r, &args)
        }
        EKIndex(b, idx) => {
            priv_expr(r, b)
            priv_exprs(r, &idx)
        }
        EKSlice(b, lo, hi) => {
            priv_expr(r, b)
            priv_opt_pexpr(r, lo)
            priv_opt_pexpr(r, hi)
        }
        // a field name is not a top-level name
        EKField(b, name) => priv_expr(r, b)
        EKLit(te, items) => {
            priv_expr(r, te)
            // field labels stay as written
            for i in 0..items.len {
                priv_expr(r, &items[i].1)
            }
            true
        }
        EKTypeE(t) => {
            var tt TypeAst = t
            priv_type(r, &tt)
            e.k = EKTypeE(tt)
            true
        }
        EKIf(c, a, b) => {
            priv_expr(r, c)
            priv_block(r, a)
            priv_block(r, b)
        }
        EKTuple(es) => priv_exprs(r, &es)
        EKMatch(sc, arms) => {
            priv_expr(r, sc)
            for i in 0..arms.len {
                arm := &arms[i]
                for j in 0..arm.pats.len {
                    priv_pat(r, &arm.pats[j])
                }
                match arm.guard {
                    Some(g) => {
                        priv_expr(r, g)
                    }
                    None => {}
                }
                priv_block(r, arm.body)
            }
            true
        }
    }
}

fn priv_pat(r *PrivCx, p *Pat) bool {
    return match *p {
        PatWild => true
        PatConst(e) => {
            var ee Expr = e
            priv_expr(r, &ee)
            *p = PatConst(ee)
            true
        }
        // the variant name stays (variants are not private); the bindings are local variables
        // (a name inside is a constant, a variant or a binding: renamed like any identifier)
        PatVariant(name, subs, pos, qual) => {
            for i in 0..subs.len {
                priv_pat(r, &subs[i])
            }
            // the qualifier `Enum` of `Enum.Variant(..)` may be a private enum
            match qual {
                Some(q) => {
                    match q.k {
                        EKCall(c, args) => {
                            match c.k {
                                EKField(b, f) => {
                                    priv_expr(r, b)
                                }
                                _ => {}
                            }
                        }
                        EKField(b, f) => {
                            priv_expr(r, b)
                        }
                        _ => {}
                    }
                }
                None => {}
            }
            true
        }
        PatTuple(subs, pos) => {
            for i in 0..subs.len {
                priv_pat(r, &subs[i])
            }
            true
        }
        PatRef(name, pos) => {
            *p = PatRef(priv_name(r, name), pos)
            true
        }
    }
}

// the statements are rewritten in place: a Block copy shares their storage
fn priv_block(r *PrivCx, b Block) bool {
    for i in 0..b.stmts.len {
        priv_stmt(r, &b.stmts[i])
    }
    return true
}

fn priv_stmt(r *PrivCx, s *Stmt) bool {
    return match s.k {
        SKExpr(e) => {
            var ee Expr = e
            priv_expr(r, &ee)
            s.k = SKExpr(ee)
            true
        }
        SKLet(names, e) => {
            priv_names(r, &names)
            var ee Expr = e
            priv_expr(r, &ee)
            s.k = SKLet(names, ee)
            true
        }
        SKMultiAssign(lhs, e) => {
            priv_exprs(r, &lhs)
            var ee Expr = e
            priv_expr(r, &ee)
            s.k = SKMultiAssign(lhs, ee)
            true
        }
        SKVar(name, ty, init) => {
            s.k = SKVar(priv_name(r, name), priv_opt_type(r, ty), priv_opt_expr(r, init))
            true
        }
        SKAssign(a, op, b) => {
            var aa Expr = a
            var bb Expr = b
            priv_expr(r, &aa)
            priv_expr(r, &bb)
            s.k = SKAssign(aa, op, bb)
            true
        }
        SKIf(c, then, els) => {
            var cc Expr = c
            priv_expr(r, &cc)
            priv_block(r, then)
            match els {
                Some(eb) => {
                    priv_block(r, eb)
                }
                None => {}
            }
            s.k = SKIf(cc, then, els)
            true
        }
        SKWhile(c, body) => {
            var cc Expr = c
            priv_expr(r, &cc)
            s.k = SKWhile(cc, body)
            priv_block(r, body)
        }
        SKLoop(body) => priv_block(r, body)
        SKFor(v1, v2, lo, hi, incl, step, body) => {
            var v2n Opt[str] = v2
            match v2 {
                Some(n2) => {
                    v2n = Some(priv_name(r, n2))
                }
                None => {}
            }
            var ll Expr = lo
            priv_expr(r, &ll)
            s.k = SKFor(priv_name(r, v1), v2n, ll, priv_opt_expr(r, hi), incl, priv_opt_expr(r, step), body)
            priv_block(r, body)
        }
        SKReturn(v) => {
            s.k = SKReturn(priv_opt_expr(r, v))
            true
        }
        SKBreak => true
        SKLabeled(label, st) => priv_stmt(r, st)
        SKBreakTo(label) => true
        SKContinueTo(label) => true
        SKContinue => true
        SKAssert(c, msg) => {
            var cc Expr = c
            priv_expr(r, &cc)
            s.k = SKAssert(cc, priv_opt_expr(r, msg))
            true
        }
        SKBlock(b) => priv_block(r, b)
        SKDefer(b) => priv_block(r, b)
        // a nested function is a local name: renamed like the variables of that spelling
        SKFn(d) => priv_fn(r, d)
    }
}
