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
        r := DbgRow{off: if rows.is_empty() { 0 } else { o }, file: i64(s.file), line: i64(s.line), own: s.parent == 0 && i64(s.func) == fid}
        if !rows.is_empty() {
            last := &rows[rows.len - 1]
            if last.file == r.file && last.line == r.line {
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
