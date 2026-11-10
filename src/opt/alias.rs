// Simple alias analysis: identified objects (allocas, globals), constant offsets, type-based classes.
use crate::ir::*;
use crate::types::may_alias_class;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Base {
    Alloca(V),
    Global(i64),
    Unknown(V),
}

#[derive(Clone, Copy, Debug)]
pub struct Addr {
    pub base: Base,
    pub off: Option<i64>,
}

pub fn decompose(f: &Func, addr: V) -> Addr {
    let mut v = addr;
    let mut off: Option<i64> = Some(0);
    let mut depth = 0;
    loop {
        let i = &f.insts[v as usize];
        match i.op {
            Op::Alloca => return Addr { base: Base::Alloca(v), off },
            Op::GAddr => return Addr { base: Base::Global(i.k), off },
            Op::Add if depth < 32 => {
                depth += 1;
                let (a, b) = (i.args[0], i.args[1]);
                if let Some(k) = f.is_const(b) {
                    off = off.map(|o| o.wrapping_add(k));
                    v = a;
                    continue;
                }
                if let Some(k) = f.is_const(a) {
                    off = off.map(|o| o.wrapping_add(k));
                    v = b;
                    continue;
                }
                // variable index: look for an identified object on either side
                let da = decompose_obj(f, a, depth);
                if let Some(base) = da {
                    return Addr { base, off: None };
                }
                let db = decompose_obj(f, b, depth);
                if let Some(base) = db {
                    return Addr { base, off: None };
                }
                return Addr { base: Base::Unknown(v), off };
            }
            _ => return Addr { base: Base::Unknown(v), off },
        }
    }
}

fn decompose_obj(f: &Func, v: V, depth: u32) -> Option<Base> {
    if depth > 32 {
        return None;
    }
    let i = &f.insts[v as usize];
    match i.op {
        Op::Alloca => Some(Base::Alloca(v)),
        Op::GAddr => Some(Base::Global(i.k)),
        Op::Add => decompose_obj(f, i.args[0], depth + 1).or_else(|| decompose_obj(f, i.args[1], depth + 1)),
        _ => None,
    }
}

// allocas whose address may be observed by something other than direct loads/stores
pub fn escaped_allocas(f: &Func) -> Vec<bool> {
    let n = f.insts.len();
    let mut esc = vec![false; n];
    // derived[v] = alloca this pointer value is derived from
    let mut derived: Vec<V> = vec![NOV; n];
    for &v in &f.blocks[0].insts {
        if f.insts[v as usize].op == Op::Alloca {
            derived[v as usize] = v;
        }
    }
    let rpo = f.rpo();
    let mut changed = true;
    while changed {
        changed = false;
        for &b in &rpo {
            for &v in &f.blocks[b as usize].insts {
                let i = &f.insts[v as usize];
                match i.op {
                    Op::Add => {
                        for &a in &i.args {
                            let d = derived[a as usize];
                            if d != NOV && derived[v as usize] != d {
                                if derived[v as usize] != NOV {
                                    // derived from two allocas: treat both as escaped
                                    esc[d as usize] = true;
                                    esc[derived[v as usize] as usize] = true;
                                } else {
                                    derived[v as usize] = d;
                                    changed = true;
                                }
                            }
                        }
                    }
                    Op::Load => {}
                    Op::Store => {
                        let d = derived[i.args[1] as usize];
                        if d != NOV && !esc[d as usize] {
                            esc[d as usize] = true;
                            changed = true;
                        }
                    }
                    _ => {
                        for &a in &i.args {
                            let d = derived[a as usize];
                            if d != NOV && !esc[d as usize] {
                                esc[d as usize] = true;
                                changed = true;
                            }
                        }
                    }
                }
            }
            for u in f.term_uses(b) {
                let d = derived[u as usize];
                if d != NOV && !esc[d as usize] {
                    esc[d as usize] = true;
                    changed = true;
                }
            }
        }
    }
    esc
}

pub struct MemRef {
    pub addr: Addr,
    pub size: i64,
    pub class: u32,
    pub ptr: V, // the address value itself
}

pub fn memref(f: &Func, v: V) -> MemRef {
    let i = &f.insts[v as usize];
    MemRef { addr: decompose(f, i.args[0]), size: i.ty.size() as i64, class: i.aux, ptr: i.args[0] }
}

pub fn may_alias(a: &MemRef, b: &MemRef, esc: &[bool]) -> bool {
    match (a.addr.base, b.addr.base) {
        (Base::Alloca(x), Base::Alloca(y)) if x != y => return false,
        (Base::Global(x), Base::Global(y)) if x != y => return false,
        (Base::Alloca(_), Base::Global(_)) | (Base::Global(_), Base::Alloca(_)) => return false,
        (Base::Alloca(x), Base::Unknown(_)) | (Base::Unknown(_), Base::Alloca(x)) => {
            if !esc[x as usize] {
                return false;
            }
        }
        _ => {}
    }
    if a.ptr == b.ptr && a.ptr != NOV {
        return true;
    }
    if a.addr.base == b.addr.base {
        if let (Some(oa), Some(ob)) = (a.addr.off, b.addr.off) {
            return oa < ob + b.size && ob < oa + a.size;
        }
    }
    may_alias_class(a.class, b.class)
}

pub fn must_alias(a: &MemRef, b: &MemRef) -> bool {
    if a.size != b.size {
        return false;
    }
    (a.ptr == b.ptr && a.ptr != NOV) || (a.addr.base == b.addr.base && a.addr.off.is_some() && a.addr.off == b.addr.off)
}
