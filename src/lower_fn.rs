// Per-function lowering: statements, places, control flow. Type checking is fused with IR generation.
use crate::ast::*;
use crate::ir::*;
use crate::lower::*;
use crate::types::*;
use std::collections::HashMap;

#[derive(Clone, Copy, Debug)]
pub struct Val {
    pub ty: Ty,
    pub v: V,
    pub mem: bool,
    pub alias: u32,
    // for a place that is one f32 lane of a vector in memory: (lane, vector IR type)
    pub lane: Option<(u8, T)>,
}

impl Val {
    pub fn unit() -> Val {
        Val { ty: T_UNIT, v: NOV, mem: false, alias: 0, lane: None }
    }
    pub fn err() -> Val {
        Val { ty: T_ERR, v: NOV, mem: false, alias: 0, lane: None }
    }
    pub fn never() -> Val {
        Val { ty: T_NEVER, v: NOV, mem: false, alias: 0, lane: None }
    }
}

pub struct Scope<'a> {
    pub vars: HashMap<String, (Ty, V)>,
    pub defers: Vec<&'a Block>,
}

pub struct LoopCtx {
    pub brk: B,
    pub cont: B,
    pub scope_depth: usize,
}

pub struct Fx<'c, 'a> {
    pub cx: &'c mut Cx<'a>,
    pub f: Func,
    pub cur: B,
    pub dead: bool,
    pub scopes: Vec<Scope<'a>>,
    pub loops: Vec<LoopCtx>,
    pub tenv: HashMap<String, Ty>,
    pub ret_ty: Ty,
    pub sret: Option<V>,
    pub allocas: Vec<V>,
    pub traps: HashMap<(u8, u32), B>,
}

pub fn lower_all(cx: &mut Cx, entry: &str, check_from_file: u16) {
    match cx.fn_names.get(entry) {
        Some(&di) => {
            cx.entry_file = cx.fn_decls[di].pos.file;
            let fid = cx.inst_fn(di, vec![]);
            cx.module.entry = fid;
        }
        None => {
            cx.err(Pos::default(), format!("missing entry function `{}`", entry));
            return;
        }
    }
    let mut checked_all = false;
    loop {
        while let Some((fid, di, targs)) = cx.work.pop() {
            lower_fn(cx, fid, di, targs);
        }
        if checked_all {
            break;
        }
        checked_all = true;
        // type-check every non-generic user function, even if unreachable
        for di in 0..cx.fn_decls.len() {
            let d = cx.fn_decls[di];
            let eager = d.pos.file >= check_from_file && !cx.lazy_files.contains(&d.pos.file);
            if d.tparams.is_empty() && eager && cx.fn_over.get(d.name.as_str()).map(|l| l.contains(&di)).unwrap_or(false) && cx.fn_names.contains_key(d.name.as_str()) {
                cx.inst_fn(di, vec![]);
            }
        }
        // and force evaluation of user constants / globals
        let lazy = cx.lazy_files.clone();
        let cnames: Vec<&str> = cx.const_decls.iter().filter(|(_, d)| d.pos.file >= check_from_file && !lazy.contains(&d.pos.file)).map(|(n, _)| *n).collect();
        for n in cnames {
            cx.const_named(n);
        }
        let gnames: Vec<&str> = cx.global_decls.iter().filter(|(_, d)| d.pos.file >= check_from_file && !lazy.contains(&d.pos.file)).map(|(n, _)| *n).collect();
        for n in gnames {
            cx.global(n);
        }
    }
    // exposed scalar fields lose their private alias class
    if !cx.exposed.is_empty() {
        let exposed = cx.exposed.clone();
        for f in cx.module.funcs.iter_mut() {
            for i in f.insts.iter_mut() {
                if matches!(i.op, Op::Load | Op::Store) && i.aux >> 4 != 0 && exposed.contains(&(i.aux >> 4)) {
                    i.aux &= 15;
                }
            }
        }
    }
}

fn lower_fn(cx: &mut Cx, fid: u32, di: usize, targs: Vec<Ty>) {
    let d = cx.fn_decls[di];
    cx.scope_prelude = cx.internal_file(d.pos.file);
    let (ptys, rty) = cx.fn_sigs[fid as usize].clone();
    let f = std::mem::replace(&mut cx.module.funcs[fid as usize], Func::new(""));
    let mut tenv = HashMap::new();
    for (n, t) in d.tparams.iter().zip(targs.iter()) {
        tenv.insert(n.clone(), *t);
    }
    let mut fx = Fx {
        cx,
        f,
        cur: 0,
        dead: false,
        scopes: vec![Scope { vars: HashMap::new(), defers: Vec::new() }],
        loops: Vec::new(),
        tenv,
        ret_ty: rty,
        sret: None,
        allocas: Vec::new(),
        traps: HashMap::new(),
    };
    fx.cur = fx.f.new_block();
    let mut pi = 0i64;
    if let RetAbi::SRet = fx.cx.abi_ret(rty) {
        let p = fx.ins(Op::Param, T::I64, vec![], pi);
        pi += 1;
        fx.sret = Some(p);
    }
    for (i, (pname, _)) in d.params.iter().enumerate() {
        let pt = ptys[i];
        match fx.cx.abi_param(pt) {
            ParamAbi::Scalar(t) => {
                let p = fx.ins(Op::Param, t, vec![], pi);
                pi += 1;
                let addr = fx.declare(pname, pt, d.pos);
                let (_, ak) = fx.cx.types.scalar_ir(pt);
                fx.store_raw(addr, p, t, ak);
            }
            ParamAbi::Flat(leaves) => {
                let addr = fx.declare(pname, pt, d.pos);
                for l in leaves {
                    let p = fx.ins(Op::Param, l.t, vec![], pi);
                    pi += 1;
                    let a = fx.add_off(addr, l.off as i64);
                    fx.store_raw(a, p, l.t, l.alias);
                }
            }
            ParamAbi::ByRef => {
                let p = fx.ins(Op::Param, T::I64, vec![], pi);
                pi += 1;
                if fx.scopes[0].vars.insert(pname.clone(), (pt, p)).is_some() {
                    fx.cx.err(d.pos, format!("duplicate parameter `{}`", pname));
                }
            }
        }
    }
    let want = rty != T_UNIT && rty != T_NEVER;
    let v = fx.block_value(&d.body, want, if want { Some(rty) } else { None });
    if !fx.dead {
        if rty == T_NEVER {
            fx.terminate(Term::Trap);
        } else if rty == T_UNIT {
            fx.terminate(Term::Ret(vec![]));
        } else if v.ty == T_UNIT {
            fx.cx.err(d.body.end, format!("function `{}` must return a value of type {}", d.name, fx.cx.types.name(rty)));
            fx.terminate(Term::Trap);
        } else {
            let v = fx.coerce(v, rty, d.body.end);
            fx.do_return(Some(v));
        }
    }
    // finalize: allocas at the top of the entry block
    let mut entry = fx.allocas.clone();
    entry.extend(fx.f.blocks[0].insts.iter().copied());
    fx.f.blocks[0].insts = entry;
    for b in fx.f.blocks.iter_mut() {
        if b.term == Term::None {
            b.term = Term::Trap;
        }
    }
    let mut f = fx.f;
    f.lowered = true;
    cx.flush_layout_errors(d.pos);
    cx.module.funcs[fid as usize] = f;
}

impl<'c, 'a> Fx<'c, 'a> {
    // ---------- builder primitives ----------
    pub fn ins(&mut self, op: Op, ty: T, args: Vec<V>, k: i64) -> V {
        self.f.push(self.cur, op, ty, args, k)
    }
    pub fn iconst(&mut self, ty: T, k: i64) -> V {
        self.ins(Op::Const, ty, vec![], canon(ty, k))
    }
    pub fn new_block(&mut self) -> B {
        self.f.new_block()
    }
    pub fn switch_to(&mut self, b: B) {
        self.cur = b;
        self.dead = false;
    }
    pub fn terminate(&mut self, t: Term) {
        self.f.blocks[self.cur as usize].term = t;
        self.cur = self.f.new_block();
        self.dead = true;
    }
    pub fn jmp(&mut self, b: B) {
        let d = self.dead;
        self.f.blocks[self.cur as usize].term = Term::Jmp(b);
        self.cur = self.f.new_block();
        self.dead = d;
    }
    pub fn br(&mut self, c: V, t: B, e: B) {
        self.f.blocks[self.cur as usize].term = Term::Br(c, t, e);
        self.cur = self.f.new_block();
    }
    pub fn err(&mut self, pos: Pos, msg: String) {
        self.cx.err(pos, msg);
    }
    pub fn tyname(&self, t: Ty) -> String {
        self.cx.types.name(t)
    }
    pub fn alloca(&mut self, size: u32, align: u32) -> V {
        let v = self.f.mk(Op::Alloca, T::I64, vec![], size.max(1) as i64);
        self.f.im(v).aux = align.max(1);
        self.allocas.push(v);
        v
    }
    pub fn temp(&mut self, ty: Ty) -> V {
        let s = self.cx.types.size_of(ty);
        let a = self.cx.types.align_of(ty);
        self.alloca(s, a)
    }
    pub fn add_off(&mut self, addr: V, off: i64) -> V {
        if off == 0 {
            return addr;
        }
        let c = self.iconst(T::I64, off);
        self.ins(Op::Add, T::I64, vec![addr, c], 0)
    }
    pub fn load_raw(&mut self, addr: V, t: T, alias: u32) -> V {
        let v = self.ins(Op::Load, t, vec![addr], 0);
        self.f.im(v).aux = alias;
        v
    }
    pub fn store_raw(&mut self, addr: V, val: V, t: T, alias: u32) {
        let v = self.ins(Op::Store, t, vec![addr, val], 0);
        self.f.im(v).aux = alias;
    }
    pub fn sval(&self, ty: Ty, v: V) -> Val {
        Val { ty, v, mem: false, alias: 0, lane: None }
    }
    // a memory value; alias class is the generic class of scalar types
    pub fn mval(&self, ty: Ty, addr: V) -> Val {
        let alias = if self.cx.types.is_scalar(ty) { self.cx.types.scalar_ir(ty).1 } else { 0 };
        Val { ty, v: addr, mem: true, alias, lane: None }
    }
    pub fn irt(&self, ty: Ty) -> T {
        self.cx.types.scalar_ir(ty).0
    }
    // scalar SSA value of a Val
    pub fn scalar(&mut self, v: Val) -> V {
        if v.ty == T_ERR || v.ty == T_NEVER || v.ty == T_UNIT {
            return self.iconst(T::I64, 0);
        }
        if v.mem {
            if let Some((k, vt)) = v.lane {
                // one f32 lane of a vector in memory
                let x = self.load_raw(v.v, vt, v.alias);
                return self.ins(Op::VExt, T::F32, vec![x], k as i64);
            }
            let t = self.irt(v.ty);
            self.load_raw(v.v, t, v.alias)
        } else {
            v.v
        }
    }
    // store `src` into the place `dst`
    pub fn store(&mut self, dst: Val, src: Val) {
        if dst.ty == T_ERR || src.ty == T_ERR || src.ty == T_NEVER || dst.ty == T_UNIT {
            return;
        }
        if self.cx.types.is_scalar(dst.ty) {
            let v = self.scalar(src);
            if let Some((k, vt)) = dst.lane {
                let old = self.load_raw(dst.v, vt, dst.alias);
                let new = self.ins(Op::VIns, vt, vec![old, v], k as i64);
                self.store_raw(dst.v, new, vt, dst.alias);
                return;
            }
            let t = self.irt(dst.ty);
            self.store_raw(dst.v, v, t, dst.alias);
            return;
        }
        if !src.mem {
            return;
        }
        if src.v == dst.v {
            return;
        }
        let n = self.cx.types.leaf_count(dst.ty);
        if n <= 16 {
            let mut leaves = Vec::new();
            self.cx.types.leaves(dst.ty, 0, &mut leaves);
            let mut vals = Vec::new();
            for l in &leaves {
                let a = self.add_off(src.v, l.off as i64);
                vals.push(self.load_raw(a, l.t, l.alias));
            }
            for (l, v) in leaves.iter().zip(vals) {
                let a = self.add_off(dst.v, l.off as i64);
                self.store_raw(a, v, l.t, l.alias);
            }
        } else {
            let sz = self.cx.types.size_of(dst.ty);
            let c = self.iconst(T::I64, sz as i64);
            self.ins(Op::MemCpy, T::Void, vec![dst.v, src.v, c], 0);
        }
    }
    pub fn zero(&mut self, dst: Val) {
        if dst.ty == T_ERR {
            return;
        }
        let n = self.cx.types.leaf_count(dst.ty);
        if n <= 32 {
            let mut leaves = Vec::new();
            self.cx.types.leaves(dst.ty, 0, &mut leaves);
            for l in &leaves {
                let a = self.add_off(dst.v, l.off as i64);
                let z = if l.t.is_fp() { self.ins(Op::FConst, l.t, vec![], 0) } else { self.iconst(l.t, 0) };
                self.store_raw(a, z, l.t, l.alias);
            }
        } else {
            let sz = self.cx.types.size_of(dst.ty);
            let c = self.iconst(T::I64, sz as i64);
            let z = self.iconst(T::I8, 0);
            self.ins(Op::MemSet, T::Void, vec![dst.v, z, c], 0);
        }
    }
    pub fn coerce(&mut self, v: Val, to: Ty, pos: Pos) -> Val {
        if v.ty == to {
            return v;
        }
        if v.ty == T_ERR || to == T_ERR {
            return Val::err();
        }
        if v.ty == T_NEVER {
            return Val::never();
        }
        let (a, b) = (self.tyname(to), self.tyname(v.ty));
        self.err(pos, format!("type mismatch: expected {}, found {}", a, b));
        Val::err()
    }

    // ---------- scopes ----------
    pub fn push_scope(&mut self) {
        self.scopes.push(Scope { vars: HashMap::new(), defers: Vec::new() });
    }
    pub fn pop_scope(&mut self) {
        if !self.dead {
            let defers = self.scopes.last().unwrap().defers.clone();
            for d in defers.iter().rev() {
                self.block(d);
            }
        }
        self.scopes.pop();
    }
    fn run_defers_down_to(&mut self, depth: usize) {
        // emit defers of scopes [depth..] innermost first, without popping
        let mut all: Vec<&'a Block> = Vec::new();
        for s in self.scopes[depth..].iter().rev() {
            for d in s.defers.iter().rev() {
                all.push(d);
            }
        }
        if all.is_empty() {
            return;
        }
        // defers must not see themselves again: temporarily hide them
        let saved: Vec<Vec<&'a Block>> = self.scopes.iter_mut().map(|s| std::mem::take(&mut s.defers)).collect();
        for d in all {
            self.block(d);
        }
        for (s, d) in self.scopes.iter_mut().zip(saved) {
            s.defers = d;
        }
    }
    pub fn lookup(&self, name: &str) -> Option<(Ty, V)> {
        for s in self.scopes.iter().rev() {
            if let Some(&x) = s.vars.get(name) {
                return Some(x);
            }
        }
        None
    }
    pub fn declare(&mut self, name: &str, ty: Ty, pos: Pos) -> V {
        let addr = self.temp(ty);
        if name == "_" {
            return addr;
        }
        if self.scopes.last().unwrap().vars.contains_key(name) {
            self.err(pos, format!("`{}` is already declared in this scope (use `=` to assign)", name));
        }
        self.scopes.last_mut().unwrap().vars.insert(name.to_string(), (ty, addr));
        addr
    }

    // ---------- blocks / statements ----------
    pub fn block(&mut self, b: &'a Block) {
        self.push_scope();
        for s in &b.stmts {
            self.stmt(s);
        }
        self.pop_scope();
    }

    pub fn block_value(&mut self, b: &'a Block, want: bool, expect: Option<Ty>) -> Val {
        if !want {
            self.block(b);
            return Val::unit();
        }
        self.push_scope();
        let n = b.stmts.len();
        let mut v = Val::unit();
        for (i, s) in b.stmts.iter().enumerate() {
            if i + 1 < n {
                self.stmt(s);
                continue;
            }
            match &s.k {
                SK::Expr(e) => v = self.expr(e, expect),
                SK::If(c, t, Some(e)) => v = self.if_value(c, t, e, true, expect),
                _ => self.stmt(s),
            }
        }
        if self.dead {
            v = Val::never();
        } else if v.mem && !self.scopes.last().unwrap().defers.is_empty() {
            let t = self.temp(v.ty);
            let tv = self.mval(v.ty, t);
            self.store(tv, v);
            v = tv;
        } else if v.mem && self.cx.types.is_scalar(v.ty) {
            let s = self.scalar(v);
            v = self.sval(v.ty, s);
        }
        self.pop_scope();
        v
    }

    pub fn stmt(&mut self, s: &'a Stmt) {
        match &s.k {
            SK::Expr(e) => {
                match &e.k {
                    EK::Match(sc, arms) => {
                        self.match_expr(sc, arms, false, None, e.pos);
                    }
                    EK::Int(_) | EK::Float(_) | EK::Str(_) | EK::Bool(_) | EK::Ident(_) | EK::Bin(..) => {
                        self.expr(e, None);
                        if !matches!(&e.k, EK::Bin(BinOp::LAnd | BinOp::LOr, ..)) {
                            self.err(e.pos, "expression statement has no effect (did you mean `=` or `:=`?)".into());
                        }
                    }
                    _ => {
                        self.expr(e, None);
                    }
                }
            }
            SK::Let(names, e) => {
                let v = self.expr(e, None);
                if names.len() == 1 {
                    if v.ty == T_UNIT || v.ty == T_NEVER {
                        self.err(s.pos, format!("cannot bind `{}` to an expression without a value", names[0]));
                        return;
                    }
                    let addr = self.declare(&names[0], v.ty, s.pos);
                    let dst = self.mval(v.ty, addr);
                    self.store(dst, v);
                } else {
                    let tys = match self.cx.types.k(v.ty).clone() {
                        TyK::Tuple(tys) if tys.len() == names.len() => tys,
                        TyK::Err => return,
                        _ => {
                            let tn = self.tyname(v.ty);
                            self.err(s.pos, format!("cannot destructure {} into {} names", tn, names.len()));
                            return;
                        }
                    };
                    let offs = self.cx.types.tuple_offsets(&tys);
                    for (i, n) in names.iter().enumerate() {
                        let src_a = self.add_off(v.v, offs[i] as i64);
                        let mut src = self.mval(tys[i], src_a);
                        if self.cx.types.is_scalar(tys[i]) {
                            src.alias = self.cx.types.field_alias(v.ty, i as u32, tys[i]);
                        }
                        let addr = self.declare(n, tys[i], s.pos);
                        let dst = self.mval(tys[i], addr);
                        self.store(dst, src);
                    }
                }
            }
            SK::MultiAssign(lhs, e) => {
                let v = self.expr(e, None);
                let tys = match self.cx.types.k(v.ty).clone() {
                    TyK::Tuple(tys) if tys.len() == lhs.len() => tys,
                    TyK::Err => return,
                    _ => {
                        let tn = self.tyname(v.ty);
                        self.err(s.pos, format!("cannot destructure {} into {} places", tn, lhs.len()));
                        return;
                    }
                };
                // copy first: the right side may alias the destinations
                let t = self.temp(v.ty);
                let tv = self.mval(v.ty, t);
                self.store(tv, v);
                for (i, l) in lhs.iter().enumerate() {
                    let src = match self.field_of(tv, &i.to_string(), s.pos) {
                        Some(p) => p,
                        None => return,
                    };
                    if let Some(dst) = self.place(l) {
                        let sv = self.coerce(src, dst.ty, l.pos);
                        self.store(dst, sv);
                    }
                }
                let _ = tys;
            }
            SK::Var(name, ty, init) => {
                let t = ty.as_ref().map(|t| {
                    let env = self.tenv.clone();
                    self.cx.resolve(t, &env)
                });
                match (t, init) {
                    (Some(t), None) => {
                        let addr = self.declare(name, t, s.pos);
                        let dst = self.mval(t, addr);
                        self.zero(dst);
                    }
                    (t, Some(e)) => {
                        let v = self.expr(e, t);
                        let v = match t {
                            Some(t) => self.coerce(v, t, e.pos),
                            None => v,
                        };
                        if v.ty == T_UNIT || v.ty == T_NEVER {
                            self.err(s.pos, format!("cannot bind `{}` to an expression without a value", name));
                            return;
                        }
                        let addr = self.declare(name, v.ty, s.pos);
                        let dst = self.mval(v.ty, addr);
                        self.store(dst, v);
                    }
                    (None, None) => {
                        self.err(s.pos, "`var` needs a type or an initializer".into());
                    }
                }
            }
            SK::Assign(lhs, op, rhs) => {
                if let EK::Ident(n) = &lhs.k {
                    if n == "_" {
                        self.expr(rhs, None);
                        return;
                    }
                }
                let dst = match self.place(lhs) {
                    Some(d) => d,
                    None => {
                        self.expr(rhs, None);
                        return;
                    }
                };
                match op {
                    None => {
                        let v = self.expr(rhs, Some(dst.ty));
                        let v = self.coerce(v, dst.ty, rhs.pos);
                        self.store(dst, v);
                    }
                    Some(op) => {
                        let cur = self.scalar(dst);
                        let l = self.sval(dst.ty, cur);
                        let r = if matches!(op, BinOp::Shl | BinOp::Shr) { self.expr(rhs, None) } else { self.expr(rhs, Some(dst.ty)) };
                        let v = self.binary_vals(*op, l, r, s.pos);
                        let v = self.coerce(v, dst.ty, rhs.pos);
                        self.store(dst, v);
                    }
                }
            }
            SK::If(c, t, e) => match e {
                Some(e) => {
                    self.if_value(c, t, e, false, None);
                }
                None => {
                    let bt = self.new_block();
                    let bj = self.new_block();
                    self.cond_br(c, bt, bj);
                    self.switch_to(bt);
                    self.block(t);
                    self.jmp(bj);
                    self.switch_to(bj);
                }
            },
            SK::While(c, body) => {
                let bb = self.new_block();
                let bc = self.new_block();
                let bx = self.new_block();
                self.cond_br(c, bb, bx);
                self.switch_to(bb);
                self.loops.push(LoopCtx { brk: bx, cont: bc, scope_depth: self.scopes.len() });
                self.block(body);
                self.loops.pop();
                self.jmp(bc);
                self.switch_to(bc);
                self.cond_br(c, bb, bx);
                self.switch_to(bx);
            }
            SK::Loop(body) => {
                let bb = self.new_block();
                let bx = self.new_block();
                self.jmp(bb);
                self.switch_to(bb);
                self.loops.push(LoopCtx { brk: bx, cont: bb, scope_depth: self.scopes.len() });
                self.block(body);
                self.loops.pop();
                self.jmp(bb);
                self.switch_to(bx);
                // reachable only through `break`
                let reach = self.f.blocks.iter().any(|b| match &b.term {
                    Term::Jmp(t) => *t == bx,
                    Term::Br(_, t, e) => *t == bx || *e == bx,
                    _ => false,
                });
                self.dead = !reach;
            }
            SK::For { var, var2, lo, hi, incl, step, body } => {
                self.for_stmt(var, var2.as_deref(), lo, hi.as_ref(), *incl, step.as_ref(), body, s.pos);
            }
            SK::Return(e) => {
                let v = match e {
                    Some(e) => {
                        let rt = self.ret_ty;
                        let v = self.expr(e, Some(rt));
                        if rt == T_UNIT || rt == T_NEVER {
                            if v.ty != T_UNIT && v.ty != T_ERR && v.ty != T_NEVER {
                                self.err(e.pos, "this function does not return a value".into());
                            }
                            None
                        } else {
                            Some(self.coerce(v, rt, e.pos))
                        }
                    }
                    None => {
                        if self.ret_ty != T_UNIT && self.ret_ty != T_NEVER {
                            let tn = self.tyname(self.ret_ty);
                            self.err(s.pos, format!("`return` needs a value of type {}", tn));
                        }
                        None
                    }
                };
                if !self.dead {
                    self.do_return(v);
                }
            }
            SK::Break | SK::Continue => {
                let (target, depth) = match self.loops.last() {
                    Some(l) => (if matches!(s.k, SK::Break) { l.brk } else { l.cont }, l.scope_depth),
                    None => {
                        self.err(s.pos, "`break`/`continue` outside of a loop".into());
                        return;
                    }
                };
                self.run_defers_down_to(depth);
                self.f.blocks[self.cur as usize].term = Term::Jmp(target);
                self.cur = self.f.new_block();
                self.dead = true;
            }
            SK::Assert(c, msg) => {
                let ok = self.new_block();
                let fail = self.new_block();
                self.cond_br(c, ok, fail);
                self.switch_to(fail);
                let loc = self.loc_str(s.pos);
                let m = match msg {
                    Some(m) => {
                        let v = self.expr(m, Some(T_STR));
                        self.coerce(v, T_STR, m.pos)
                    }
                    None => self.str_val(b"assertion failed"),
                };
                self.call_rt("__assert_fail", vec![], vec![loc, m], s.pos);
                if !self.dead {
                    self.terminate(Term::Trap);
                }
                self.switch_to(ok);
            }
            SK::Block(b) => self.block(b),
            SK::Defer(b) => {
                self.scopes.last_mut().unwrap().defers.push(b);
            }
        }
    }

    pub fn do_return(&mut self, v: Option<Val>) {
        let mut rets: Vec<V> = Vec::new();
        if let Some(v) = v {
            if v.ty != T_ERR {
                match self.cx.abi_ret(self.ret_ty) {
                    RetAbi::None => {}
                    RetAbi::Scalar(_) => rets.push(self.scalar(v)),
                    RetAbi::Flat(leaves) => {
                        for l in leaves {
                            let a = self.add_off(v.v, l.off as i64);
                            rets.push(self.load_raw(a, l.t, l.alias));
                        }
                    }
                    RetAbi::SRet => {
                        let dst = self.mval(self.ret_ty, self.sret.unwrap());
                        self.store(dst, v);
                    }
                }
            } else {
                self.run_defers_down_to(0);
                self.terminate(Term::Trap);
                return;
            }
        }
        self.run_defers_down_to(0);
        self.terminate(Term::Ret(rets));
    }

    pub fn if_value(&mut self, c: &'a Expr, t: &'a Block, e: &'a Block, want: bool, expect: Option<Ty>) -> Val {
        let bt = self.new_block();
        let be = self.new_block();
        let bj = self.new_block();
        self.cond_br(c, bt, be);
        self.switch_to(bt);
        let v1 = self.block_value(t, want, expect);
        let d1 = self.dead;
        let mut slot: Option<Val> = None;
        if want && !d1 && v1.ty != T_UNIT && v1.ty != T_ERR {
            let a = self.temp(v1.ty);
            let sv = self.mval(v1.ty, a);
            self.store(sv, v1);
            slot = Some(sv);
        }
        self.jmp(bj);
        self.switch_to(be);
        let exp2 = match slot {
            Some(s) => Some(s.ty),
            None => expect,
        };
        let v2 = self.block_value(e, want, exp2);
        let d2 = self.dead;
        let mut res = Val::unit();
        if want {
            match slot {
                Some(sv) => {
                    if !d2 {
                        let v2c = self.coerce(v2, sv.ty, e.end);
                        self.store(sv, v2c);
                    }
                    res = sv;
                }
                None => {
                    if !d2 && v2.ty != T_UNIT && v2.ty != T_ERR {
                        if d1 {
                            let a = self.temp(v2.ty);
                            let sv = self.mval(v2.ty, a);
                            self.store(sv, v2);
                            res = sv;
                        } else if v1.ty == T_UNIT {
                            let tn = self.tyname(v2.ty);
                            self.err(e.end, format!("`if` branches have different types: () and {}", tn));
                        }
                    } else if v1.ty == T_ERR || v2.ty == T_ERR {
                        res = Val::err();
                    }
                }
            }
        }
        self.jmp(bj);
        self.switch_to(bj);
        self.dead = d1 && d2;
        if self.dead {
            return Val::never();
        }
        res
    }

    #[allow(clippy::too_many_arguments)]
    fn for_stmt(&mut self, var: &'a str, var2: Option<&'a str>, lo: &'a Expr, hi: Option<&'a Expr>, incl: bool, step: Option<&'a Expr>, body: &'a Block, pos: Pos) {
        let bb = self.new_block();
        let bc = self.new_block();
        let bx = self.new_block();
        self.push_scope();
        match hi {
            Some(hi) => {
                if var2.is_some() {
                    self.err(pos, "range `for` takes a single loop variable".into());
                }
                let (lv, hv) = if self.is_untyped(lo) && !self.is_untyped(hi) {
                    let h = self.expr(hi, None);
                    let l = self.expr(lo, Some(h.ty));
                    (l, h)
                } else {
                    let l = self.expr(lo, None);
                    let h = self.expr(hi, Some(l.ty));
                    (l, h)
                };
                let ty = lv.ty;
                if !self.cx.types.is_int(ty) {
                    if ty != T_ERR {
                        let tn = self.tyname(ty);
                        self.err(lo.pos, format!("range bounds must be integers, found {}", tn));
                    }
                    self.pop_scope();
                    return;
                }
                let hv = self.coerce(hv, ty, hi.pos);
                let it = self.irt(ty);
                let mut step_dyn: Option<V> = None;
                let stepk = match step {
                    Some(se) => match self.cx.const_eval(se) {
                        Some(CV::Int(k)) if k != 0 => k,
                        Some(_) => {
                            self.err(se.pos, "`by` step must be a non-zero integer".into());
                            1
                        }
                        None => {
                            // runtime step: must be positive
                            let sv = self.expr(se, Some(ty));
                            let sv = self.coerce(sv, ty, se.pos);
                            let s = self.scalar(sv);
                            if self.cx.opts.checks {
                                let z = self.iconst(it, 0);
                                let ok = self.ins(if self.cx.types.is_signed(ty) { Op::Sgt } else { Op::Ne }, T::I8, vec![s, z], 0);
                                self.check(ok, 2, se.pos);
                            }
                            step_dyn = Some(s);
                            1
                        }
                    },
                    None => 1,
                };
                let signed = self.cx.types.is_signed(ty);
                let cmp = match (stepk > 0, incl, signed) {
                    (true, false, true) => Op::Slt,
                    (true, true, true) => Op::Sle,
                    (false, false, true) => Op::Sgt,
                    (false, true, true) => Op::Sge,
                    (true, false, false) => Op::Ult,
                    (true, true, false) => Op::Ule,
                    (false, false, false) => Op::Ugt,
                    (false, true, false) => Op::Uge,
                };
                let lo_s = self.scalar(lv);
                let end = self.scalar(hv);
                let addr = self.declare(var, ty, pos);
                let iv = self.mval(ty, addr);
                self.store_raw(addr, lo_s, it, iv.alias);
                let c = self.ins(cmp, T::I8, vec![lo_s, end], 0);
                self.br(c, bb, bx);
                self.switch_to(bb);
                self.loops.push(LoopCtx { brk: bx, cont: bc, scope_depth: self.scopes.len() });
                self.block(body);
                self.loops.pop();
                self.jmp(bc);
                self.switch_to(bc);
                let cur = self.load_raw(addr, it, iv.alias);
                let st = match step_dyn {
                    Some(s) => s,
                    None => self.iconst(it, stepk),
                };
                let next = self.ins(Op::Add, it, vec![cur, st], 0);
                self.store_raw(addr, next, it, iv.alias);
                let c = self.ins(cmp, T::I8, vec![next, end], 0);
                self.br(c, bb, bx);
            }
            None => {
                if step.is_some() {
                    self.err(pos, "`by` is only valid with a range".into());
                }
                let cv = self.expr(lo, None);
                let (ptr, len, et) = match self.cx.types.k(cv.ty).clone() {
                    TyK::Slice(et) => {
                        let (p, l) = self.slice_parts(cv);
                        (p, l, et)
                    }
                    TyK::Array(et, n) => {
                        let l = self.iconst(T::I64, n as i64);
                        (cv.v, l, et)
                    }
                    TyK::Err => {
                        self.pop_scope();
                        return;
                    }
                    _ => {
                        let tn = self.tyname(cv.ty);
                        self.err(lo.pos, format!("cannot iterate over {}", tn));
                        self.pop_scope();
                        return;
                    }
                };
                let (iname, ename) = match var2 {
                    Some(v2) => (var, Some(v2)),
                    None => ("_", Some(var)),
                };
                let iaddr = self.declare(iname, T_I64, pos);
                let zero = self.iconst(T::I64, 0);
                self.store_raw(iaddr, zero, T::I64, AK_I64);
                let c = self.ins(Op::Slt, T::I8, vec![zero, len], 0);
                self.br(c, bb, bx);
                self.switch_to(bb);
                self.push_scope();
                if let Some(en) = ename {
                    let i = self.load_raw(iaddr, T::I64, AK_I64);
                    let es = self.cx.types.size_of(et);
                    let esz = self.iconst(T::I64, es as i64);
                    let off = self.ins(Op::Mul, T::I64, vec![i, esz], 0);
                    let ea = self.ins(Op::Add, T::I64, vec![ptr, off], 0);
                    let src = self.mval(et, ea);
                    let eaddr = self.declare(en, et, pos);
                    let dst = self.mval(et, eaddr);
                    self.store(dst, src);
                }
                self.loops.push(LoopCtx { brk: bx, cont: bc, scope_depth: self.scopes.len() });
                self.block(body);
                self.loops.pop();
                self.pop_scope();
                self.jmp(bc);
                self.switch_to(bc);
                let cur = self.load_raw(iaddr, T::I64, AK_I64);
                let one = self.iconst(T::I64, 1);
                let next = self.ins(Op::Add, T::I64, vec![cur, one], 0);
                self.store_raw(iaddr, next, T::I64, AK_I64);
                let c = self.ins(Op::Slt, T::I8, vec![next, len], 0);
                self.br(c, bb, bx);
            }
        }
        self.switch_to(bx);
        self.pop_scope();
    }

    // ---------- conditions ----------
    pub fn cond_br(&mut self, e: &'a Expr, t: B, f: B) {
        match &e.k {
            EK::Bin(BinOp::LAnd, a, b) => {
                let mid = self.new_block();
                self.cond_br(a, mid, f);
                self.switch_to(mid);
                self.cond_br(b, t, f);
            }
            EK::Bin(BinOp::LOr, a, b) => {
                let mid = self.new_block();
                self.cond_br(a, t, mid);
                self.switch_to(mid);
                self.cond_br(b, t, f);
            }
            EK::Un(UnOp::Not, a) => self.cond_br(a, f, t),
            _ => {
                let v = self.expr(e, Some(T_BOOL));
                let v = self.coerce(v, T_BOOL, e.pos);
                let c = self.scalar(v);
                let d = self.dead;
                self.br(c, t, f);
                self.dead = d;
            }
        }
    }

    // ---------- runtime failure blocks ----------
    pub fn loc_str(&mut self, pos: Pos) -> Val {
        let s = format!("{}:{}", self.cx.file_names.get(pos.file as usize).cloned().unwrap_or_default(), pos.line);
        self.str_val(s.as_bytes())
    }

    pub fn str_val(&mut self, s: &[u8]) -> Val {
        let g = self.cx.string_global(s);
        let t = self.temp(T_STR);
        let p = self.ins(Op::GAddr, T::I64, vec![], g as i64);
        let n = self.iconst(T::I64, s.len() as i64);
        let v = self.mval(T_STR, t);
        self.store_slice(v, p, n);
        v
    }

    pub fn store_slice(&mut self, dst: Val, ptr: V, len: V) {
        let mut leaves = Vec::new();
        self.cx.types.leaves(dst.ty, 0, &mut leaves);
        self.store_raw(dst.v, ptr, T::I64, leaves[0].alias);
        let a = self.add_off(dst.v, 8);
        self.store_raw(a, len, T::I64, leaves[1].alias);
    }

    pub fn slice_parts(&mut self, s: Val) -> (V, V) {
        let mut leaves = Vec::new();
        self.cx.types.leaves(s.ty, 0, &mut leaves);
        let p = self.load_raw(s.v, T::I64, leaves[0].alias);
        let a = self.add_off(s.v, 8);
        let l = self.load_raw(a, T::I64, leaves[1].alias);
        (p, l)
    }

    // kind: 0 = bounds, 1 = division by zero
    pub fn trap_block(&mut self, kind: u8, pos: Pos) -> B {
        if let Some(&b) = self.traps.get(&(kind, pos.line)) {
            return b;
        }
        let (save_cur, save_dead) = (self.cur, self.dead);
        let b = self.new_block();
        self.switch_to(b);
        let loc = self.loc_str(pos);
        let name = match kind {
            0 => "__bounds_fail",
            1 => "__div_fail",
            _ => "__step_fail",
        };
        self.call_rt(name, vec![], vec![loc], pos);
        if !self.dead {
            self.terminate(Term::Trap);
        }
        self.cur = save_cur;
        self.dead = save_dead;
        self.traps.insert((kind, pos.line), b);
        b
    }

    pub fn check(&mut self, cond: V, kind: u8, pos: Pos) {
        let tb = self.trap_block(kind, pos);
        let ok = self.new_block();
        let d = self.dead;
        self.br(cond, ok, tb);
        self.switch_to(ok);
        self.dead = d;
    }
}

