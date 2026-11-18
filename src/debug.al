// Debug information (`alc build -g`): what the front end and the back end record for it, and
// the tables the linkers write: DWARF (dwarf.al) in the ELF file and in the PE file, and a PDB
// next to a Windows executable (pdb.al).
//
// Lines. The source locations that the stack traces use (SrcLoc in ir.al, Code.lines in
// x86/emit.al) are also the line table of the debug information: every instruction carries the
// location of its statement or expression from lowering through optimisation (the inliner
// rebases them) to instruction selection, and emit_emit records where the location changes.
// So -g adds nothing to the compile but the tables at the end.
//
// Variables. At -O0 with -g (dbg_keep_vars) the variables stay in their frame slots: mem2reg
// leaves the allocas of named variables alone and the slot sharing of isel gives each its own
// slot, so every statement that assigns one has code and the debugger finds the value at a
// fixed offset from the frame (the CFA). An alloca is marked as variable k by the source
// location -(k + 1) (allocas have no location of their own); a binding whose storage is not an
// alloca of its own (a match binding into the matched value, a parameter passed by reference)
// gets an 8-byte slot holding its address (an indirect variable). With optimisation -g does
// not change the code: the allocas of variables are marked but promoted as usual; those that
// stay in memory with a slot of their own (address taken, aggregates) are described.

// -g given
dbg_on: bool
// -g at -O0: variables keep their frame slots (see above)
dbg_keep_vars: bool

struct DbgVar {
    name: str
    ty: i64       // the AL type (Cx.types)
    func: i64     // the function it belongs to
    line: i32     // where it is declared
    end: i32      // the last line of its scope (0: the whole function)
    indirect: bool // its slot holds its address
    param: bool
}

// the variables of all functions, numbered as their allocas are marked
dbg_vars: Vec[DbgVar]
// by function: the line and file of its declaration (0 / -1: unknown)
dbg_fn_line: Vec[i32]
dbg_fn_file: Vec[i32]
// the parameters of the function being lowered are being declared
dbg_in_params: bool
// > 0: the last line of the scope of the variables being declared (a `for` loop's variables and
// a `match` arm's bindings live in the body that follows)
dbg_scope_end: i64
// for the linkers: the type checker's tables (types, files, signatures) and the names of the
// test blocks (function __test_k is test k)
dbg_cx: *Cx
dbg_tests: []str
// the file given on the command line (the name of the compile unit)
dbg_main_file: i64
// Windows: the path of the PDB as the executable names it (absolute), and its bytes (pe_link)
dbg_pdb_path: str
dbg_pdb: Vec[u8]

// the name of function fid as written (as in stack traces: `priv` names plain, nested ones
// `outer.name`, test blocks `test "name"`); a specialised copy has the name of the original
fn dbg_fn_name(m: *Module, fid0: i64) -> str {
    fid := dbg_fn_orig(m, fid0)
    n := ast_plain_text(m.funcs[fid].name)
    if starts_with(n, "__test_") {
        t, ok := parse_i64(n[7..])
        if ok && t >= 0 && t < len(dbg_tests) {
            n = fmt("test \"", dbg_tests[t], "\"")
        }
    }
    return n
}

// the function whose source a compiled function is (a specialised copy: the original)
fn dbg_fn_orig(m: *Module, fid: i64) -> i64 {
    c := m.funcs[fid].copy_of
    return if c >= 0 { c } else { fid }
}

// the name of file k as the program wrote it ("" for none)
fn dbg_file_name(k: i64) -> str {
    if dbg_cx == nil || k < 0 || k >= dbg_cx.file_names.len {
        return ""
    }
    return dbg_cx.file_names[k]
}

// a row of the line table of a compiled function: from code offset `off` on, the line `line`
// of file `file` (inlined code: the line in the function it was inlined from)
struct DbgRow {
    off: i64
    file: i64
    line: i64
    own: bool // a line of the function itself (not of code inlined into it)
    loc: i64  // the source location (Module.locs; 0: none)
    pe: bool  // the row after the prologue (DWARF prologue_end; a debugger's breakpoint on the function)
}

// the rows of the code of compiled function fid0 (consecutive locations of one line are one
// row); the first is at offset 0 (its line covers the prologue)
fn dbg_rows(m: *Module, fid0: i64, code: *Code) -> Vec[DbgRow] {
    rows := vec[DbgRow]()
    fid := dbg_fn_orig(m, fid0)
    lines := &code.lines
    for k in 0..lines.len / 2 {
        o := i64(lines[2 * k])
        l := i64(lines[2 * k + 1])
        if l <= 0 || l >= m.locs.list.len {
            continue
        }
        s := &m.locs.list[l]
        r := DbgRow{off: if rows.is_empty() { 0 } else { o }, file: i64(s.file), line: i64(s.line), own: s.parent == 0 && i64(s.func) == fid, loc: l}
        if !rows.is_empty() {
            last := &rows[rows.len - 1]
            if last.loc == r.loc || last.own && r.own && last.file == r.file && last.line == r.line {
                continue
            }
            if last.off == r.off {
                *last = r
                continue
            }
        }
        rows.push(r)
    }
    if rows.is_empty() && fid < dbg_fn_line.len && dbg_fn_line[fid] > 0 {
        rows.push(DbgRow{off: 0, file: i64(dbg_fn_file[fid]), line: i64(dbg_fn_line[fid]), own: true})
    }
    // a row starts where the prologue ends (the parameters stored): the same line again if
    // the code there has no row of its own (gdb takes the second row of a function for the
    // end of its prologue, newer debuggers the prologue_end flag)
    pe := i64(code.pro_end)
    if pe > 0 && pe < code.bytes.len && !rows.is_empty() {
        k := 0
        while k + 1 < rows.len && rows[k + 1].off <= pe {
            k += 1
        }
        if rows[k].off == pe {
            rows[k].pe = true
        } else {
            r := rows[k]
            r.off = pe
            r.pe = true
            rows.insert(k + 1, r)
        }
    }
    return rows
}

// function fid is being lowered from a declaration at `pos`
fn dbg_function(fid: i64, pos: Pos) {
    if dbg_fn_line.len <= fid {
        dbg_fn_line.resize(fid + 1, i32(0))
        dbg_fn_file.resize(fid + 1, i32(-1))
    }
    dbg_fn_line[fid] = pos.line
    dbg_fn_file[fid] = i32(pos.file)
}

// `name` is bound to the place `addr` (of type ty) in the function being lowered: it becomes a
// variable of the debug information (called by scope_set with -g)
fn dbg_bind(self: *Fx, name: str, ty: i64, addr: i64) {
    if name == "_" || ty <= T_ERR || ty == T_UNIT || ty == T_NEVER || addr < 0 || addr >= self.f.insts.len {
        return
    }
    if self.cx.types.size_of(ty) == 0 {
        return
    }
    line: i32 = 0
    if self.loc > 0 && i64(self.loc) < self.cx.module.locs.list.len {
        line = self.cx.module.locs.list[self.loc].line
    }
    end: i32 = 0
    if dbg_scope_end > 0 {
        end = i32(dbg_scope_end)
    } else if !dbg_in_params && self.blocks.len > 0 {
        end = self.blocks.last().end.line
    }
    k := dbg_vars.len
    v := DbgVar{name: ast_plain_text(name), ty: ty, func: self.fid, line: line, end: end, indirect: false, param: dbg_in_params}
    i := self.f.im(addr)
    if i.op == Alloca && i.cap == 0 {
        i.cap = i32(-(k + 1))
        dbg_vars.push(v)
    } else if dbg_keep_vars {
        p := self.alloca(8, 8)
        self.f.im(p).cap = i32(-(k + 1))
        self.store_raw(p, addr, I64, AK_PTR)
        v.indirect = true
        dbg_vars.push(v)
    }
}

// A scope of variables in a function: the lines first..last, its variables (pairs: variable,
// offset from the CFA) and the scopes inside it. A variable declared in a block is visible from
// its line to the end of the block; the code of a scope is the code of those lines of the
// function itself (dbg_runs), which at -O0 follows the source.
struct DbgScope {
    first: i64
    last: i64
    vars: Vec[i64]
    kids: Vec[i64]
}

// the scopes of the variables of a compiled function: [0] is the function (its parameters and
// the variables of its outermost block), the others nested by their lines
fn dbg_scopes(code: *Code) -> Vec[DbgScope] {
    sc := vec[DbgScope]()
    sc.push(DbgScope{first: 0, last: 0x7FFFFFFF})
    vs := vec[(i64, i64, i64, i64)]() // (first, -last, variable, offset)
    for x in 0..code.dvars.len / 2 {
        k := i64(code.dvars[2 * x])
        off := i64(code.dvars[2 * x + 1])
        v := &dbg_vars[k]
        if v.param || v.end == 0 {
            // (parameters first, in their order)
            sc[0].vars.push(k)
            sc[0].vars.push(off)
        } else {
            vs.push((i64(v.line), -i64(v.end), k, off))
        }
    }
    sort_by(vs.items(), fn(a: (i64, i64, i64, i64), b: (i64, i64, i64, i64)) -> bool { a.0 < b.0 || a.0 == b.0 && (a.1 < b.1 || a.1 == b.1 && a.2 < b.2) })
    stack := vec_one(0)
    for x in vs {
        first := x.0
        last := -x.1
        top := stack.last()
        if sc[top].first != first || sc[top].last != last {
            while stack.len > 1 && !(first >= sc[stack.last()].first && last <= sc[stack.last()].last) {
                stack.pop()
            }
            sc.push(DbgScope{first: first, last: last})
            sc[stack.last()].kids.push(sc.len - 1)
            stack.push(sc.len - 1)
            top = sc.len - 1
        }
        sc[top].vars.push(x.2)
        sc[top].vars.push(x.3)
    }
    return sc
}

// the code of the lines first..last of the function itself, as (start, end) offsets within
// lo..hi (rows: of a function of `size` bytes)
fn dbg_runs(rows: *Vec[DbgRow], size: i64, first: i64, last: i64, lo: i64, hi: i64) -> Vec[(i64, i64)] {
    runs := vec[(i64, i64)]()
    k := 0
    while k < rows.len {
        r := &rows[k]
        if !(r.own && r.line >= first && r.line <= last) {
            k += 1
            continue
        }
        start := r.off
        k += 1
        while k < rows.len && rows[k].own && rows[k].line >= first && rows[k].line <= last {
            k += 1
        }
        end := if k < rows.len { rows[k].off } else { size }
        start = max(start, lo)
        end = min(end, hi)
        if end > start {
            runs.push((start, end))
        }
    }
    return runs
}

// isel: the frame slots of the variables of f (slot_of: by alloca) go to mf.dvars as pairs
// (variable, slot); a slot shared with another alloca (optimised code) is left out
fn dbg_slots(f: *Func, mf: *MFunc, slot_of: *Vec[i32]) {
    for v in f.blocks[0].insts {
        k := dbg_var_of(&f.insts[v])
        sl := slot_of[v]
        if k < 0 || sl < 0 {
            continue
        }
        shared := false
        if !dbg_keep_vars {
            for u in f.blocks[0].insts {
                if u != v && f.insts[u].op == Alloca && slot_of[u] == sl {
                    shared = true
                }
            }
        }
        if !shared {
            mf.dvars.push(k)
            mf.dvars.push(i64(sl))
        }
    }
}

// the variable an alloca is marked with, or -1
fn dbg_var_of(i: *Inst) -> i64 {
    if i.op == Alloca && i.cap < 0 {
        return -i64(i.cap) - 1
    }
    return -1
}

// ---------- where the values are: location lists ----------
//
// A variable whose alloca mem2reg promotes has no place of its own: its values are SSA values,
// which isel puts in virtual registers and the allocator in machine registers or spill slots.
// What -g records for it is bookkeeping that never changes the code (no pass has to keep it,
// nothing in it keeps a value alive), in three parts:
//
// 1. Func.dexp (mem2reg, its first run on the function, opt_first): for every source location
//    of the function and every promoted variable, the SSA value the variable has there (-1:
//    different values at instructions of that location, or none). Later passes keep the table
//    as it is but for value replacements (apply_repl: the replacement is equal) and the
//    renumbering of keep_func; a replaced value that is not equal everywhere (unroll) is
//    forgotten. Instructions made after the recording (dthr) are copies or new code: the
//    locations they belong to are not trusted at all.
// 2. isel (DbgMF): every selected value's last instruction carries the value in MInst.tgt
//    (value + 1; only operations whose `tgt` is otherwise unused, see dbg_taggable), plus the
//    phis' inputs, the parameters' registers at the entry, the dominator tree and the table of
//    1 by location.
// 3. emit_emit (dbg_ranges, on the final code after allocation and peepholes): a forward
//    analysis of which machine register or spill slot holds which value: a tagged instruction
//    puts its value in its destination (and ends every other copy of an older instance of
//    it), copies, spills and reloads move values, every other write ends what the location
//    held, a call ends the registers it clobbers. At the start of a block only what all
//    predecessors agree on and what is defined in a block that strictly dominates it stays (a
//    value of a loop body never survives its back edge: no stale instance), and a location
//    holds a phi when each predecessor ends with the phi's input there. An instruction shows a
//    variable where the location of the instruction expects the value (1) and some place holds
//    it (or it is a constant). Everything else is "optimised out": when in doubt, the range
//    ends.
// The parameters of a function whose parameters are stored in frame slots (all at -O0, those
// in memory when optimising) are found in their argument registers until those stores
// (DBG_HOME): a debugger that stops at the function's first instruction shows them right.

// MInst.tgt of a store of a parameter into its frame slot (see above)
const DBG_HOME = -2
// DbgMF.vblk of the parameters: defined once, before the entry block
const DBG_ENTRY = -2

// kinds of DbgRange
const DL_REG = 1 // in register `val` (0..15, xmm 16..31)
const DL_FB = 2  // in memory at `val` from the CFA
const DL_INT = 3 // the integer `val`
const DL_F32 = 4 // the f32 of bits `val`
const DL_F64 = 5 // the f64 of bits `val`

// Code.dvars offset of a variable described by Code.dranges (none: optimised out)
const DV_RANGES = 0x7FFFFFFF

// what a variable is in the code offsets lo..hi
struct DbgRange {
    var: i32
    lo: i32
    hi: i32
    kind: i32
    val: i64
}

// a variable's value at a source location (Func.dexp, see above)
struct DbgExp {
    loc: i32
    var: i32
    val: i32
}

// what isel hands dbg_ranges (see above)
struct DbgMF {
    on: bool
    seeds: Vec[(i64, i64, i64)] // at the entry: (DL_REG register, or DL_FB stack argument, n, the Param)
    vsize: Vec[u8]              // the size of each IR value in bytes
    vblk: Vec[i32]              // the block of each IR value (NOV: in none)
    dpre: Vec[i32]              // the dominator tree (Cfg.pre, Cfg.post)
    dpost: Vec[i32]
    phis: Map[i64, Vec[(i64, i64, i64)]] // by block: (phi, predecessor, input)
    consts: Map[i64, (i64, i64)]         // the constants among the expected values: (kind, bits)
    exp_at: Map[i32, (i64, i64)]         // by source location: exp[start..end]
    exp: Vec[(i64, i64)]                 // (variable, value)
    vars: Vec[i64]                       // the promoted variables of the function
}

// Values replaced in a way that holds for their uses only (unroll: header phis by their
// first values): the variables are not shown where they had those values.
fn dbg_forget(f: *Func, repl: *Vec[i32]) {
    for e in 0..f.dexp.len {
        x := i64(f.dexp[e].val)
        if x >= 0 && x < repl.len && repl[x] != NOV {
            f.dexp[e].val = -1
        }
    }
}

// can MInst.tgt of this operation carry a value (an operation whose destination is operand a
// and that does not use tgt)?
fn dbg_taggable(op: MOp) -> bool {
    return match op {
        Mov, Movzx, Movsx, Lea, MovSd, Cvtsi2sd, Cvttsd2si, MovqToX, MovqToR, Setcc, Sqrtsd, Cvtf, Popcnt, Tzcnt, Lzcnt, Zero,
            Add, Sub, And, Or, Xor, Imul, Addsd, Subsd, Mulsd, Divsd, Minsd, Maxsd, Unpcklps, Movlo, Xorpd, Andpd, Cmov,
            Shl, Shr, Sar, Rol, Ror, Neg, Not, Bswap => true
        _ => false
    }
}

// the locations of the analysis: registers 0..31, then the frame slots that only plain loads
// and stores reach (never an address taken), then the incoming stack arguments
priv struct Flow {
    mf: *MFunc
    nl: i64
    slot_ix: Vec[i64]         // by frame slot: its location, or -1
    arg0: i64                 // the location of stack argument 0
    place: Vec[(i64, i64)]    // by location: (DL_REG, register) or (DL_FB, offset from the CFA)
    du: Vec[i64]
}

priv fn fl_new(mf: *MFunc, slot_off: []i32, above: i64) -> Flow {
    ns := mf.slots.len
    plain := vec_fill(ns, true)
    nargs := 0
    for s in mf.dbg.seeds {
        if s.0 == DL_FB {
            nargs = max(nargs, s.1 + 1)
        }
    }
    fn look(o: *Opnd, lea: bool, plain: *Vec[bool], nargs: *i64) {
        match o {
            M(&m) => {
                if m.kind == MK_SLOT && m.id >= 0 && i64(m.id) < plain.len {
                    if lea || m.base != NOREG || m.idx != NOREG || m.disp != 0 {
                        plain[i64(m.id)] = false
                    }
                } else if m.kind == MK_INARG && m.id >= 0 {
                    *nargs = max(*nargs, i64(m.id) + 2)
                }
            }
            _ => {}
        }
    }
    for b in 0..mf.blocks.len {
        for i in mf.blocks[b].insts {
            look(&i.a, false, &plain, &nargs)
            look(&i.b, i.op == Lea, &plain, &nargs)
        }
    }
    fl := Flow{mf: mf, slot_ix: vec_fill(ns, -1), du: vec_fill(DU_MAX, 0)}
    for r in 0..32 {
        fl.place.push((DL_REG, r))
    }
    for s in 0..ns {
        if plain[s] && s < len(slot_off) {
            fl.slot_ix[s] = fl.place.len
            fl.place.push((DL_FB, i64(slot_off[s]) - above))
        }
    }
    fl.arg0 = fl.place.len
    for a in 0..nargs {
        fl.place.push((DL_FB, 8 * a))
    }
    fl.nl = fl.place.len
    return fl
}

// the location an operand names (a register, a plain slot or stack argument), or -1
priv fn fl_loc(fl: *Flow, o: *Opnd) -> i64 {
    match o {
        R(r) => return if r >= 0 && r < 32 { r } else { -1 }
        M(&m) => {
            if m.base != NOREG || m.idx != NOREG || m.disp != 0 || m.id < 0 {
                return -1
            }
            if m.kind == MK_SLOT && i64(m.id) < fl.slot_ix.len {
                return fl.slot_ix[i64(m.id)]
            }
            if m.kind == MK_INARG && fl.arg0 + i64(m.id) < fl.nl {
                return fl.arg0 + i64(m.id)
            }
            return -1
        }
        _ => return -1
    }
}

// the location of the memory an operand writes to (any part of a slot or stack argument), or -1
priv fn fl_mem(fl: *Flow, o: *Opnd) -> i64 {
    match o {
        M(&m) => {
            if m.kind == MK_SLOT && m.id >= 0 && i64(m.id) < fl.slot_ix.len {
                return fl.slot_ix[i64(m.id)]
            }
            if m.kind == MK_INARG && m.id >= 0 && fl.arg0 + i64(m.id) < fl.nl {
                return fl.arg0 + i64(m.id)
            }
            return -1
        }
        _ => return -1
    }
}

priv fn fl_size(fl: *Flow, v: i64) -> i64 {
    return if v < fl.mf.dbg.vsize.len { i64(fl.mf.dbg.vsize[v]) } else { 64 }
}

// the state after instruction i (st: the value each location holds, -1 none)
priv fn fl_step(fl: *Flow, i: *MInst, st: []i32) {
    gl := -1
    gv := -1
    if i.tgt > 0 && dbg_taggable(i.op) {
        // a new instance of the value: older copies of it are stale (not of a constant or a
        // parameter: DBG_ENTRY)
        gv = i64(i.tgt) - 1
        vb := if gv < fl.mf.dbg.vblk.len { i64(fl.mf.dbg.vblk[gv]) } else { -1 }
        if vb != DBG_ENTRY {
            for x in 0..fl.nl {
                if i64(st[x]) == gv {
                    st[x] = -1
                }
            }
        }
        gl = fl_loc(fl, &i.a)
    } else if i.op == Mov || i.op == MovSd {
        // copies, spills and reloads
        d := fl_loc(fl, &i.a)
        s := fl_loc(fl, &i.b)
        if d >= 0 && s >= 0 && (d < 32 || s < 32) {
            v := i64(st[s])
            if v >= 0 && fl_size(fl, v) <= i64(i.sz) {
                gl = d
                gv = v
            }
        }
    }
    mir_decode(fl.mf, i, fl.du.items(), 0)
    h := fl.du[0]
    for j in 1..1 + (h & 255) {
        r := fl.du[j]
        if r >= 0 && r < 32 {
            st[r] = -1
        }
    }
    if h & (DU_CALL << 16) != 0 {
        for r in CALL_CLOBBER {
            st[r] = -1
        }
    }
    match i.op {
        Cmp, Test, Ucomisd, Push, Call, CallInd, Jmp, Jcc, Ret => {}
        _ => {
            w := fl_mem(fl, &i.a)
            if w >= 0 {
                st[w] = -1
            }
        }
    }
    if gl >= 0 {
        st[gl] = i32(gv)
    }
}

// a dominates b strictly (blocks of the dominator tree of DbgMF; DBG_ENTRY: before the entry
// block, the parameters' place)
priv fn fl_sdom(d: *DbgMF, a: i64, b: i64) -> bool {
    if a == DBG_ENTRY {
        return true
    }
    if a < 0 || b < 0 || a >= d.dpre.len || b >= d.dpre.len || a == b {
        return false
    }
    return d.dpre[a] <= d.dpre[b] && d.dpost[b] <= d.dpost[a]
}

// the ranges of the code of a function (mf after allocation and emit's peepholes, in the
// order `layout`; at[j]: the offset of the j-th instruction that is no jump, a `ret` at its
// epilogue; pro: the offset after the prologue; size: the code's) where its variables are
// found, and the end of its prologue (after the parameters' DBG_HOME stores). Adds the
// variables described by ranges to dvars (pairs variable, offset from the CFA).
fn dbg_ranges(mf: *MFunc, layout: []i64, at: []i64, slot_off: []i32, above: i64, pro: i64, size: i64, dvars: *Vec[i32]) -> (Vec[DbgRange], i64) {
    out := vec[DbgRange]()
    fl := fl_new(mf, slot_off, above)
    nl := fl.nl
    nb := mf.blocks.len
    // the end offset of the j-th instruction's range
    fn end_of(at: []i64, j: i64, size: i64) -> i64 {
        return if j + 1 < len(at) { at[j + 1] } else { size }
    }
    // a range of variable k (merged with its last one when it continues it)
    fn add(out: *Vec[DbgRange], last: *Map[i64, i64], k: i64, lo: i64, hi: i64, kind: i64, val: i64) {
        if hi <= lo {
            return
        }
        li, found := last.get(k)
        if found {
            r := &out[li]
            if i64(r.hi) == lo && i64(r.kind) == kind && r.val == val {
                r.hi = i32(hi)
                return
            }
        }
        last.set(k, out.len)
        out.push(DbgRange{var: i32(k), lo: i32(lo), hi: i32(hi), kind: i32(kind), val: val})
    }
    last := map[i64, i64]()
    entry := if len(layout) > 0 { layout[0] } else { 0 }
    seed := vec_fill(nl, i32(-1))
    for s in mf.dbg.seeds {
        l := if s.0 == DL_REG { s.1 } else { fl.arg0 + s.1 }
        if l >= 0 && l < nl {
            seed[l] = i32(s.2)
        }
    }
    // 1. the parameters stored in frame slots: in the entry block (straight-line code from
    // the seeds) until their stores, then in the slots
    pro_end := pro
    {
        homes := map[i64, (i64, i64)]() // slot -> (position of its store, the stored register)
        nhome := map[i64, i64]()
        st := clone(seed)
        // (positions: j counts the instructions that are no jumps, as `at` does; the states
        // before them are kept up to the last store)
        j := 0
        states := vec[Vec[i32]]()
        nlast := 0
        if len(layout) > 0 {
            cnt := 0
            for i in mf.blocks[entry].insts {
                if i.op != Jmp && i.op != Jcc {
                    cnt += 1
                    if i.tgt == DBG_HOME {
                        nlast = cnt
                    }
                }
            }
            for i in mf.blocks[entry].insts {
                if i.op == Jmp || i.op == Jcc {
                    continue
                }
                if j >= nlast {
                    break
                }
                states.push(clone(st))
                if i.tgt == DBG_HOME {
                    match &i.a {
                        M(&m) if m.kind == MK_SLOT => {
                            nh, _ := nhome.get(i64(m.id))
                            nhome.set(i64(m.id), nh + 1)
                            r := match &i.b {
                                R(x) => x
                                _ => -1
                            }
                            if m.disp == 0 && m.base == NOREG && m.idx == NOREG {
                                homes.set(i64(m.id), (j, r))
                            }
                            if j < len(at) {
                                pro_end = end_of(at, j, size)
                            }
                        }
                        _ => {}
                    }
                }
                fl_step(&fl, &i, st.items())
                j += 1
            }
        }
        for x in 0..mf.dvars.len / 2 {
            k := mf.dvars[2 * x]
            sl := mf.dvars[2 * x + 1]
            v := &dbg_vars[k]
            if !v.param {
                continue
            }
            n, _ := nhome.get(sl)
            hj, found := homes.get(sl)
            if n == 0 {
                continue
            }
            cfa := i64(slot_off[sl]) - above
            if found && n == 1 && hj.1 >= 0 && hj.1 < 32 && hj.0 < states.len {
                // the parameter's value: what the stored register holds before the store
                p := i64(states[hj.0][hj.1])
                if p >= 0 {
                    for l in 0..32 {
                        if seed[l] == i32(p) {
                            add(&out, &last, k, 0, pro, DL_REG, l)
                            break
                        }
                    }
                    for y in 0..=hj.0 {
                        if y >= len(at) {
                            break
                        }
                        for l in 0..nl {
                            if states[y][l] == i32(p) {
                                add(&out, &last, k, at[y], end_of(at, y, size), fl.place[l].0, fl.place[l].1)
                                break
                            }
                        }
                    }
                }
            }
            // then in its slot (a parameter stored in parts: from its last part on)
            lo := size
            j2 := 0
            for i in mf.blocks[entry].insts {
                if i.op == Jmp || i.op == Jcc {
                    continue
                }
                if i.tgt == DBG_HOME && j2 < len(at) {
                    match &i.a {
                        M(&m) if m.kind == MK_SLOT && i64(m.id) == sl => lo = end_of(at, j2, size)
                        _ => {}
                    }
                }
                j2 += 1
            }
            add(&out, &last, k, lo, size, DL_FB, cfa)
            for y in 0..dvars.len / 2 {
                if i64(dvars[2 * y]) == k && dvars[2 * y + 1] != DV_RANGES {
                    dvars[2 * y + 1] = DV_RANGES
                }
            }
        }
    }
    if mf.dbg.exp.is_empty() {
        return (out, pro_end)
    }
    dump := false
    {
        dv, dset := env_get("ALC_DBGLOC")
        dump = dset && dv == mf.name
    }
    if dump {
        eput(fmt("dbg_ranges ", mf.name, ": seeds ", mf.dbg.seeds.items(), " exp ", mf.dbg.exp.items(), "\n"))
        for l in mf.dbg.exp_at.keys() {
            se, _ := mf.dbg.exp_at.get(l)
            eput(fmt("  loc ", l, " -> ", se, "\n"))
        }
        eput(mir_print_mfunc(mf))
    }
    // 2. the promoted variables: the analysis over the blocks
    for k in mf.dbg.vars {
        dvars.push(i32(k))
        dvars.push(DV_RANGES)
    }
    succs := vec_fill(nb, vec[i64]())
    preds := vec_fill(nb, vec[i64]())
    for b in 0..nb {
        succs[b] = mf.blocks[b].succs
    }
    // reverse postorder from the entry
    rpo := vec[i64]()
    {
        seen := vec_fill(nb, false)
        stack := vec_of([](i64, i64){(entry, 0)})
        seen[entry] = true
        post := vec[i64]()
        while !stack.is_empty() {
            top := stack.len - 1
            b, i := stack[top]
            if i < succs[b].len {
                stack[top].1 = i + 1
                s := succs[b][i]
                if s >= 0 && s < nb && !seen[s] {
                    seen[s] = true
                    stack.push((s, 0))
                }
            } else {
                post.push(b)
                stack.pop()
            }
        }
        for x in post.len - 1..=0 by -1 {
            rpo.push(post[x])
        }
        for b in rpo {
            for s in succs[b] {
                if s >= 0 && s < nb {
                    preds[s].push(b)
                }
            }
        }
    }
    TOP := i32(-2)
    ins := vec_fill(nb, vec[i32]())
    outs := vec_fill(nb, vec[i32]())
    for b in rpo {
        outs[b] = vec_fill(nl, TOP)
    }
    d := &mf.dbg
    // the state at the start of block b from the ends of its predecessors
    fn entry_state(d: *DbgMF, b: i64, entry: i64, preds: *Vec[Vec[i64]], outs: *Vec[Vec[i32]], seed: *Vec[i32], nl: i64) -> Vec[i32] {
        TOP := i32(-2)
        st := vec_fill(nl, TOP)
        if b == entry {
            copy(st.items(), seed.items())
        }
        for p in preds[b] {
            o := &outs[p]
            if o.len == 0 {
                continue
            }
            for x in 0..nl {
                if o[x] == TOP {
                    continue
                }
                if st[x] == TOP {
                    st[x] = o[x]
                } else if st[x] != o[x] {
                    st[x] = -1
                }
            }
        }
        for x in 0..nl {
            v := i64(st[x])
            if v >= 0 && !(v < d.vblk.len && fl_sdom(d, i64(d.vblk[v]), b)) {
                st[x] = -1
            }
        }
        // the phis of b: where every predecessor ends with the phi's input
        ph, has := d.phis.get(b)
        if has && b != entry {
            k := 0
            while k < ph.len {
                p := ph[k].0
                e := k
                while e < ph.len && ph[e].0 == p {
                    e += 1
                }
                for x in 0..nl {
                    if st[x] >= 0 && i64(st[x]) != p {
                        // (a location already known to hold another value keeps it)
                        continue
                    }
                    ok := true
                    any := false
                    for q in preds[b] {
                        o := &outs[q]
                        if o.len == 0 || o[x] == TOP {
                            continue
                        }
                        inp := -1
                        for y in k..e {
                            if ph[y].1 == q {
                                inp = ph[y].2
                            }
                        }
                        if inp < 0 || i64(o[x]) != inp {
                            ok = false
                            break
                        }
                        any = true
                    }
                    if ok && any {
                        st[x] = i32(p)
                    }
                }
                k = e
            }
        }
        for x in 0..nl {
            if st[x] == TOP {
                st[x] = -1
            }
        }
        return st
    }
    changed := true
    rounds := 0
    while changed && rounds < 50 {
        changed = false
        rounds += 1
        for b in rpo {
            st := entry_state(d, b, entry, &preds, &outs, &seed, nl)
            ins[b] = clone(st)
            for i in mf.blocks[b].insts {
                fl_step(&fl, &i, st.items())
            }
            if st.items() != outs[b].items() {
                outs[b] = st
                changed = true
            }
        }
    }
    if changed {
        // (no fixed point: nothing is described)
        return (out, pro_end)
    }
    // the ranges, instruction by instruction (the instructions before the first one with a
    // source location, the parameters' copies, have the location of that one: the line
    // table's first row covers them)
    chosen := map[i64, i64]() // variable -> the location it was last shown in
    first_loc: i32 = 0
    for b in layout {
        for i in mf.blocks[b].insts {
            if first_loc == 0 && i.loc != 0 && i.op != Jmp && i.op != Jcc {
                first_loc = i.loc
            }
        }
    }
    leading := true
    j := 0
    for b in layout {
        if b < 0 || b >= nb || ins[b].len == 0 {
            continue
        }
        st := clone(ins[b])
        for i in mf.blocks[b].insts {
            if i.op == Jmp || i.op == Jcc {
                continue
            }
            if j >= len(at) {
                break
            }
            if dump {
                s := vec[str]()
                for x in 0..nl {
                    if st[x] >= 0 {
                        s.push(fmt(x, "=", st[x]))
                    }
                }
                eput(fmt("  [", j, "] b", b, " loc ", i.loc, " tgt ", i.tgt, " ", i.op, ": ", join(s.items(), " "), "\n"))
            }
            if i.loc != 0 || b != entry {
                leading = false
            }
            if i.op != Ret {
                se, has := d.exp_at.get(if leading { first_loc } else { i.loc })
                if has {
                    lo0 := at[j]
                    hi := end_of(at, j, size)
                    for e in se.0..se.1 {
                        k, v := d.exp[e]
                        c, is_c := d.consts.get(v)
                        if is_c {
                            add(&out, &last, k, lo0, hi, c.0, c.1)
                            continue
                        }
                        l := -1
                        pl, had := chosen.get(k)
                        if had && st[pl] == i32(v) {
                            l = pl
                        } else {
                            for x in 0..nl {
                                if st[x] == i32(v) {
                                    l = x
                                    break
                                }
                            }
                        }
                        if l >= 0 {
                            chosen.set(k, l)
                            // (at the first instruction: also in the prologue, which keeps the
                            // registers the parameters arrive in)
                            lo := if j == 0 && b == entry && l < 32 && seed[l] == i32(v) && len(at) > 0 && at[0] == pro { 0 } else { lo0 }
                            add(&out, &last, k, lo, hi, fl.place[l].0, fl.place[l].1)
                        }
                    }
                }
            }
            fl_step(&fl, &i, st.items())
            j += 1
        }
    }
    return (out, pro_end)
}
