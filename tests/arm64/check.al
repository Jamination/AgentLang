// A structural check of the executables of --target linux-arm64 (no machine here runs them).
//
//   alc run tests/arm64/check.al -- [-v] [path/to/alc] [file.al | dir]...
//
// builds every program (`fn main`) of the files and directories given (default: tests/run,
// tests/std and examples) with `--target linux-arm64`, by default and with -O0, and checks the
// executable as a file:
//
// - the ELF header, the program headers (two PT_LOAD segments of 64 KiB alignment, PT_TLS,
//   PT_GNU_STACK), the entry point at the start of .text;
// - every word of the code decodes (by the tables of this file, written from the Arm
//   architecture reference, not from the compiler's encoder) as an instruction of the set the
//   back end emits; x18 (the platform register) is never touched;
// - every branch stays inside its function, every BL goes to the start of a function, every
//   ADRP / ADD pair addresses a byte of the image;
// - the stack pointer: along every path of a function its offset from the entry is the same
//   at each instruction (whichever path reaches it), it is 0 at RET, a multiple of 16 at each
//   call, it moves by multiples of 16 only, and nothing is stored below it;
// - registers: no instruction reads a register that is not written on every path from the
//   entry (arguments x0-x7 / v0-v7, the preserved x19-x28, d8-d15, x29, x30 count as written
//   at the entry; a call leaves x0-x3 / v0-v3 and destroys x0-x17 and v0-v31; a system call
//   writes x0). This catches register allocation and spill bugs that leave a value
//   unwritten.
// - a dynamically linked executable (C functions): PT_PHDR, PT_INTERP (/lib/ld-linux-aarch64.so.1)
//   and PT_DYNAMIC inside the segments; the dynamic section (DT_NEEDED names in .dynstr, the
//   tables inside the read-only segment, DT_SYMENT / DT_RELAENT 24, BIND_NOW, DT_DEBUG); every
//   dynamic symbol undefined, global, a function or an object, named; the SysV hash table's
//   chain count equal to the number of symbols; every relocation an R_AARCH64_GLOB_DAT of a
//   symbol, at a distinct 8-byte aligned import slot in the writable segment; every ADRP + LDR
//   loads one of these slots, and every slot is loaded somewhere;
// - the C calls (a BLR of a register loaded from an import slot), for programs whose source
//   declares the C function (`extern`, parsed here with its struct types): the argument
//   registers that the classification of tests/arm64/aapcs.al (an independent implementation of
//   the Arm procedure call standard) assigns, and x8 for a result in memory, are written on
//   every path to the call (a register that still holds an argument of the calling function
//   counts: it may be passed on). (Whether the right values are in them is what tests/sys/c_abi
//   checks, against C compiled by clang, under the emulator.)
//
// Output: a line per problem, then `arm64 check: N executables, F functions, W instructions,
// P problems` (and the number of C calls checked); the exit status is 0 without problems.
use std.os
use "aapcs.al"

priv struct Ins {
    ok: bool
    du_g: u64   // general registers written (bit 31: sp)
    du_f: u64   // SIMD registers written
    us_g: u64   // read
    us_f: u64
    kind: u8    // K_*
    target: i64 // branch target, as a word distance
    sp_set: i64 // K_SPADD: the change of sp; K_SPFROM: (unused)
    adrp: i64   // K_ADRP: the page distance; K_ADD12: the immediate
    rd: i64
    rn: i64
    neg_sp_store: bool
}

priv const K_PLAIN: u8 = 0
priv const K_B: u8 = 1      // unconditional branch
priv const K_BCOND: u8 = 2  // conditional branch (B.cond, CBZ, CBNZ)
priv const K_BL: u8 = 3
priv const K_BLR: u8 = 4
priv const K_RET: u8 = 5
priv const K_BR: u8 = 6
priv const K_BRK: u8 = 7
priv const K_SVC: u8 = 8
priv const K_SPADD: u8 = 9   // sp = sp + sp_set
priv const K_SPFROM: u8 = 10 // sp = rn (+ 0): `mov sp, xN`
priv const K_FPFROMSP: u8 = 11 // x29 = sp
priv const K_ADRP: u8 = 12
priv const K_ADD12: u8 = 13 // add rd, rn, #imm (the low part after an ADRP)

priv const SP_BIT: u64 = 1 << 31

priv fn g(r: i64, sp: bool) -> u64 {
    if r == 31 {
        return if sp { SP_BIT } else { 0 }
    }
    return u64(1) << u64(r)
}

priv fn f(r: i64) -> u64 {
    return u64(1) << u64(r)
}

priv fn sx(v: i64, bits: i64) -> i64 {
    return (v << (64 - bits)) >> (64 - bits)
}

// decodes one word
priv fn decode(w0: u32) -> Ins {
    w := i64(w0)
    rd := w & 31
    rn := (w >> 5) & 31
    rm := (w >> 16) & 31
    r := Ins{ok: true, rd: rd, rn: rn}
    // ADD / SUB (immediate)
    if (w >> 24) & 0x1F == 0x11 {
        s := (w >> 29) & 1
        r.du_g = g(rd, s == 0)
        r.us_g = g(rn, true)
        imm := ((w >> 10) & 0xFFF) << (if (w >> 22) & 1 == 1 { 12 } else { 0 })
        if (w >> 22) & 2 != 0 {
            r.ok = false
        }
        sub := (w >> 30) & 1 == 1
        if rd == 31 && s == 0 {
            if rn == 31 {
                r.kind = K_SPADD
                r.sp_set = if sub { -imm } else { imm }
            } else if imm == 0 {
                r.kind = K_SPFROM
            } else {
                r.ok = false // sp set from another register plus an offset: never emitted
            }
        } else if rn == 31 && rd == 29 && imm == 0 && !sub {
            r.kind = K_FPFROMSP
        } else if s == 0 && !sub && (w >> 22) & 1 == 0 {
            r.kind = K_ADD12
            r.adrp = imm
        }
        return r
    }
    // ADD / SUB (shifted register)
    if w & 0x1F200000 == 0x0B000000 {
        r.du_g = g(rd, false)
        r.us_g = g(rn, false) | g(rm, false)
        if (w >> 22) & 3 == 3 {
            r.ok = false
        }
        return r
    }
    // ADD / SUB (extended register)
    if w & 0x1FE00000 == 0x0B200000 {
        s := (w >> 29) & 1
        r.du_g = g(rd, s == 0)
        r.us_g = g(rn, true) | g(rm, false)
        if rd == 31 && s == 0 {
            r.ok = false // (sp changed by a register: the checks below would not follow it)
        }
        return r
    }
    // logical (shifted register)
    if w & 0x1F000000 == 0x0A000000 {
        r.du_g = g(rd, false)
        r.us_g = g(rn, false) | g(rm, false)
        return r
    }
    // logical (immediate)
    if w & 0x1F800000 == 0x12000000 {
        opc := (w >> 29) & 3
        r.du_g = g(rd, opc != 3)
        r.us_g = g(rn, false)
        if (w >> 31) == 0 && (w >> 22) & 1 == 1 {
            r.ok = false
        }
        return r
    }
    // move wide
    if w & 0x1F800000 == 0x12800000 {
        opc := (w >> 29) & 3
        r.du_g = g(rd, false)
        if opc == 1 || ((w >> 31) == 0 && (w >> 22) & 1 == 1) {
            r.ok = false
        }
        if opc == 3 {
            r.us_g = g(rd, false)
        }
        return r
    }
    // bitfield
    if w & 0x1F800000 == 0x13000000 {
        opc := (w >> 29) & 3
        r.du_g = g(rd, false)
        r.us_g = g(rn, false)
        if opc == 1 {
            r.us_g |= g(rd, false)
        }
        if opc == 3 || (w >> 31) != (w >> 22) & 1 {
            r.ok = false
        }
        return r
    }
    // EXTR
    if w & 0x1FA00000 == 0x13800000 {
        if (w >> 31) != (w >> 22) & 1 {
            r.ok = false
        }
        r.du_g = g(rd, false)
        r.us_g = g(rn, false) | g(rm, false)
        return r
    }
    // data processing, two sources: UDIV, SDIV, LSLV, LSRV, ASRV, RORV
    if w & 0x7FE00000 == 0x1AC00000 {
        op := (w >> 10) & 0x3F
        r.du_g = g(rd, false)
        r.us_g = g(rn, false) | g(rm, false)
        r.ok = op == 2 || op == 3 || (op >= 8 && op <= 11)
        return r
    }
    // data processing, one source: RBIT, REV16, REV32 / REV, REV, CLZ
    if w & 0x7FFF0000 == 0x5AC00000 {
        op := (w >> 10) & 0x3F
        r.du_g = g(rd, false)
        r.us_g = g(rn, false)
        r.ok = op <= 4 && !(op == 3 && (w >> 31) == 0)
        return r
    }
    // data processing, three sources: MADD, MSUB, SMADDL, SMULH, UMADDL, UMULH
    if w & 0x7F000000 == 0x1B000000 {
        ra := (w >> 10) & 31
        r.du_g = g(rd, false)
        r.us_g = g(rn, false) | g(rm, false) | g(ra, false)
        op := (w >> 21) & 7
        if (w >> 31) == 0 && op != 0 {
            r.ok = false
        }
        return r
    }
    // conditional select
    if w & 0x1FE00000 == 0x1A800000 {
        r.du_g = g(rd, false)
        r.us_g = g(rn, false) | g(rm, false)
        if (w >> 10) & 2 != 0 {
            r.ok = false
        }
        return r
    }
    // loads and stores (single register)
    if w & 0x3B000000 == 0x39000000 || w & 0x3B200C00 == 0x38200800 || w & 0x3B200C00 == 0x38000000 || w & 0x3B200C00 == 0x38000400 {
        v := (w >> 26) & 1 == 1
        opc := (w >> 22) & 3
        size := (w >> 30) & 3
        load := if v { opc == 1 || opc == 3 } else { opc != 0 }
        if v && opc >= 2 && size != 0 {
            r.ok = false
        }
        if !v && size == 3 && opc == 3 {
            r.ok = false
        }
        r.us_g = g(rn, true)
        if load {
            if v {
                r.du_f = f(rd)
            } else {
                r.du_g = g(rd, false)
            }
        } else if v {
            r.us_f = f(rd)
        } else {
            r.us_g |= g(rd, false)
        }
        if w & 0x3B200C00 == 0x38200800 {
            r.us_g |= g(rm, false)
            if (w >> 13) & 7 != 3 {
                r.ok = false
            }
        }
        if w & 0x3B200C00 == 0x38000400 {
            r.du_g |= g(rn, true)
            if rn == 31 {
                r.ok = false
            }
        }
        if w & 0x3B200C00 == 0x38000000 && rn == 31 && sx((w >> 12) & 0x1FF, 9) < 0 {
            r.neg_sp_store = true
        }
        return r
    }
    // load / store pair
    if w & 0x3A000000 == 0x28000000 {
        v := (w >> 26) & 1 == 1
        opc := (w >> 30) & 3
        mode := (w >> 23) & 3
        load := (w >> 22) & 1 == 1
        rt2 := (w >> 10) & 31
        off := sx((w >> 15) & 0x7F, 7) * 8
        if (v && opc != 1) || (!v && opc != 2) || mode == 0 {
            r.ok = false
        }
        r.us_g = g(rn, true)
        if load {
            if v {
                r.du_f = f(rd) | f(rt2)
            } else {
                r.du_g = g(rd, false) | g(rt2, false)
            }
        } else if v {
            r.us_f = f(rd) | f(rt2)
        } else {
            r.us_g |= g(rd, false) | g(rt2, false)
        }
        if mode != 2 {
            if rn != 31 {
                r.ok = false
            } else {
                r.kind = K_SPADD
                r.sp_set = off
            }
        } else if rn == 31 && off < 0 {
            r.neg_sp_store = true
        }
        return r
    }
    if w & 0x7C000000 == 0x14000000 {
        r.kind = if (w >> 31) == 1 { K_BL } else { K_B }
        r.target = sx(w & 0x3FFFFFF, 26)
        return r
    }
    if w & 0xFF000010 == 0x54000000 {
        r.kind = K_BCOND
        r.target = sx((w >> 5) & 0x7FFFF, 19)
        if w & 15 >= 14 {
            r.ok = false
        }
        return r
    }
    if w & 0x7E000000 == 0x34000000 {
        r.kind = K_BCOND
        r.target = sx((w >> 5) & 0x7FFFF, 19)
        r.us_g = g(rd, false)
        return r
    }
    match w & 0xFFFFFC1F {
        0xD61F0000 => {
            r.kind = K_BR
            r.us_g = g(rn, false)
            return r
        }
        0xD63F0000 => {
            r.kind = K_BLR
            r.us_g = g(rn, false)
            return r
        }
        0xD65F0000 => {
            r.kind = K_RET
            r.us_g = g(rn, false)
            return r
        }
        _ => {}
    }
    if w & 0xFFE0001F == 0xD4000001 {
        r.kind = K_SVC
        r.us_g = g(8, false)
        r.du_g = g(0, false)
        return r
    }
    if w & 0xFFE0001F == 0xD4200000 {
        r.kind = K_BRK
        return r
    }
    if w & 0xFFFFFFE0 == 0xD53BD040 {
        r.du_g = g(rd, false)
        return r
    }
    if w & 0xFFFFFFE0 == 0xD51BD040 {
        r.us_g = g(rd, false)
        return r
    }
    if w == 0xD5033BBF {
        return r
    }
    // ADR / ADRP
    if w & 0x1F000000 == 0x10000000 {
        r.du_g = g(rd, false)
        if (w >> 31) == 1 {
            r.kind = K_ADRP
            r.adrp = sx(((w >> 5) & 0x7FFFF) << 2 | (w >> 29) & 3, 21)
        }
        return r
    }
    // exclusive and acquire / release
    if w & 0x3FFFFC00 == 0x085FFC00 || w & 0x3FFFFC00 == 0x08DFFC00 {
        r.du_g = g(rd, false)
        r.us_g = g(rn, true)
        return r
    }
    if w & 0x3FE0FC00 == 0x0800FC00 {
        r.du_g = g(rm, false)
        r.us_g = g(rn, true) | g(rd, false)
        if rm == rd || rm == rn {
            r.ok = false // (the status register must differ from the others)
        }
        return r
    }
    if w & 0x3FFFFC00 == 0x089FFC00 {
        r.us_g = g(rn, true) | g(rd, false)
        return r
    }
    // scalar floating point
    ftype := (w >> 22) & 3
    if w & 0xFF200C00 == 0x1E200800 {
        r.du_f = f(rd)
        r.us_f = f(rn) | f(rm)
        r.ok = ftype < 2 && (w >> 12) & 15 <= 5
        return r
    }
    if w & 0xFF207C00 == 0x1E204000 {
        op := (w >> 15) & 0x3F
        r.du_f = f(rd)
        r.us_f = f(rn)
        r.ok = ftype < 2 && op <= 5 && !(op == 4 && ftype == 0) && !(op == 5 && ftype == 1)
        return r
    }
    if w & 0xFF20FC1F == 0x1E202000 {
        r.us_f = f(rn) | f(rm)
        r.ok = ftype < 2
        return r
    }
    if w & 0xFF200C00 == 0x1E200C00 {
        r.du_f = f(rd)
        r.us_f = f(rn) | f(rm)
        r.ok = ftype < 2
        return r
    }
    // conversions between general and floating-point registers
    if w & 0x7F20FC00 == 0x1E200000 {
        sf := w >> 31
        k := (w >> 16) & 31 // rmode:opcode
        if ftype >= 2 {
            r.ok = false
            return r
        }
        if k == 2 || k == 7 {
            // SCVTF, FMOV to the floating-point register
            r.du_f = f(rd)
            r.us_g = g(rn, false)
            r.ok = k == 2 || sf == ftype
        } else if k == 0x18 || k == 6 {
            // FCVTZS, FMOV to the general register
            r.du_g = g(rd, false)
            r.us_f = f(rn)
            r.ok = k == 0x18 || sf == ftype
        } else {
            r.ok = false
        }
        return r
    }
    // SIMD: the forms the back end emits
    match w & 0xFFE0FC00 {
        0x4E20D400, 0x4EA0D400, 0x6E20DC00, 0x6E20FC00, 0x4E20F400, 0x4EA0F400, 0x6EA0E400, 0x4EA01C00 => {
            r.du_f = f(rd)
            r.us_f = f(rn) | f(rm)
            return r
        }
        0x6E601C00 => {
            // BSL reads its destination
            r.du_f = f(rd)
            r.us_f = f(rd) | f(rn) | f(rm)
            return r
        }
        _ => {}
    }
    match w & 0xFFFFFC00 {
        0x4EA0F800, 0x6EA0F800, 0x6EA1F800, 0x0E205800, 0x0E31B800 => {
            r.du_f = f(rd)
            r.us_f = f(rn)
            return r
        }
        _ => {}
    }
    if w & 0xFFE0FC00 == 0x4E000400 || w & 0xFFE0FC00 == 0x5E000400 || w & 0xFFE08400 == 0x6E000400 {
        r.du_f = f(rd)
        r.us_f = f(rn)
        if w & 0xFFE08400 == 0x6E000400 {
            r.us_f |= f(rd)
        }
        // single lanes (imm5 = xx100)
        r.ok = (w >> 16) & 7 == 4
        return r
    }
    if w & 0xFFFFFFE0 == 0x6F00E400 {
        r.du_f = f(rd)
        return r
    }
    r.ok = false
    return r
}

priv struct Prob {
    list: Vec[str]
}

priv fn u32_at(b: str, at: i64) -> i64 {
    return i64(b[at]) | i64(b[at + 1]) << 8 | i64(b[at + 2]) << 16 | i64(b[at + 3]) << 24
}

priv fn u16_at(b: str, at: i64) -> i64 {
    return i64(b[at]) | i64(b[at + 1]) << 8
}

priv fn u64_at(b: str, at: i64) -> i64 {
    return u32_at(b, at) | u32_at(b, at + 4) << 32
}

priv struct Func {
    name: str
    addr: i64
    size: i64
}

priv struct Seg {
    vaddr: i64
    memsz: i64
}

// registers that count as written at the entry of a function
priv const ENTRY_G: u64 = 0xFF | 0x1FF80000 | (1 << 29) | (1 << 30) | (1 << 31)
priv const ENTRY_F: u64 = 0xFFFF
// a call destroys x0-x17 and every SIMD register, and writes x0-x3, v0-v3 and x30
priv const CALL_KILL_G: u64 = 0x3FFFF
priv const CALL_SET_G: u64 = 0xF | (1 << 30)
priv const CALL_SET_F: u64 = 0xF

priv struct Totals {
    files: i64
    funcs: i64
    words: i64
    ccalls: i64
}

// a C function as the program's source declares it: the C types of its named parameters, how
// many there are, its result
priv struct Sig {
    args: Vec[CT]
    nfixed: i64
    ret: Opt[CT]
}

// what check_func needs to know about the C side of an executable
priv struct CSide {
    slots: Map[i64, str]      // import slot address -> symbol
    loaded: Map[i64, bool]    // the slots some ADRP + LDR loads
    sigs: Map[str, Sig]       // the declarations of the source (empty: an executable given as is)
}

// the C type of an AL type written in a declaration, if it has one here
priv fn c_type(t0: str, structs: *Map[str, str], depth: i64) -> Opt[CT] {
    t := trim(t0)
    if depth > 8 || len(t) == 0 {
        return None
    }
    match t {
        "i8", "u8", "bool" => return Some(CT.Int(1, t == "i8"))
        "i16", "u16" => return Some(CT.Int(2, t == "i16"))
        "i32", "u32" => return Some(CT.Int(4, t == "i32"))
        "i64", "u64" => return Some(CT.Int(8, t == "i64"))
        "f32" => return Some(CT.Flt(4))
        "f64" => return Some(CT.Flt(8))
        _ => {}
    }
    if t[0] == '*' || starts_with(t, "fn(") {
        return Some(CT.Int(8, false))
    }
    if t[0] == '[' {
        e := index_of(t, ']')
        n, ok := parse_i64(t[1..max(e, 1)])
        if e < 0 || !ok {
            return None
        }
        return match c_type(t[e + 1..], structs, depth + 1) {
            Some(et) => Some(CT.Arr(vec_of([]CT{et}), n))
            None => None
        }
    }
    body, has := structs.get(t)
    if !has {
        return None
    }
    fs := vec[CT]()
    for f in split_top(body) {
        colon := index_of(f, ':')
        if colon < 0 {
            continue
        }
        match c_type(f[colon + 1..], structs, depth + 1) {
            Some(ft) => fs.push(ft)
            None => return None
        }
    }
    return Some(CT.Rec(fs))
}

// s split at the commas outside parentheses and brackets
priv fn split_top(s: str) -> Vec[str] {
    out := vec[str]()
    depth := 0
    start := 0
    for k in 0..len(s) {
        c := s[k]
        if c == '(' || c == '[' {
            depth += 1
        } else if c == ')' || c == ']' {
            depth -= 1
        } else if (c == ',' || c == '\n') && depth == 0 {
            if len(trim(s[start..k])) > 0 {
                out.push(trim(s[start..k]))
            }
            start = k + 1
        }
    }
    if len(trim(s[start..])) > 0 {
        out.push(trim(s[start..]))
    }
    return out
}

// the C functions the source declares (`extern LIB fn name(params) -> T`, over several lines if
// need be), with the structs of the same file (`struct Name { a: T, b: T }` or one field a line)
priv fn c_sigs(src: str) -> Map[str, Sig] {
    out := map[str, Sig]()
    text, ok := read_file(src)
    if !ok {
        return out
    }
    structs := map[str, str]()
    p := 0
    loop {
        s := find(text, "struct ", p)
        if s < 0 {
            break
        }
        p = s + 7
        if s > 0 && text[s - 1] != '\n' && text[s - 1] != ' ' {
            continue
        }
        o := find(text, "{", p)
        c := find(text, "}", p)
        if o < 0 || c < o {
            continue
        }
        structs.set(trim(text[p..o]), text[o + 1..c])
    }
    p = 0
    loop {
        s := find(text, "extern ", p)
        if s < 0 {
            break
        }
        p = s + 7
        f := find(text, " fn ", p)
        nl := find(text, "\n", p)
        if f < 0 || (nl >= 0 && f > nl) {
            continue
        }
        o := find(text, "(", f)
        if o < 0 {
            continue
        }
        name := trim(text[f + 4..o])
        depth := 0
        c := o
        while c < len(text) {
            if text[c] == '(' {
                depth += 1
            } else if text[c] == ')' {
                depth -= 1
                if depth == 0 {
                    break
                }
            }
            c += 1
        }
        if c >= len(text) {
            break
        }
        sig := Sig{nfixed: 0}
        good := true
        for prm in split_top(text[o + 1..c]) {
            if prm == "..." {
                continue
            }
            colon := index_of(prm, ':')
            t: Opt[CT] = if colon < 0 { None } else { c_type(prm[colon + 1..], &structs, 0) }
            match t {
                Some(ct) => sig.args.push(ct)
                None => good = false
            }
        }
        sig.nfixed = sig.args.len
        e := find(text, "\n", c)
        rest := trim(text[c + 1..if e < 0 { len(text) } else { e }])
        if starts_with(rest, "->") {
            match c_type(rest[2..], &structs, 0) {
                Some(rt) => sig.ret = Some(rt)
                None => good = false
            }
        }
        if good {
            out.set(name, sig)
        }
    }
    return out
}

// checks one executable; problems go to p
priv fn check_elf(name: str, b: str, p: *Vec[str], t: *Totals, sigs: Map[str, Sig]) {
    fn bad(p: *Vec[str], name: str, msg: str) {
        p.push(fmt(name, ": ", msg))
    }
    if len(b) < 64 || b[..4] != "\x7FELF" || b[4] != 2 || b[5] != 1 {
        bad(p, name, "not a little-endian ELF64 file")
        return
    }
    if u16_at(b, 16) != 2 || u16_at(b, 18) != 183 {
        bad(p, name, fmt("e_type ", u16_at(b, 16), " e_machine ", u16_at(b, 18), ": expected an executable for AArch64 (2, 183)"))
        return
    }
    entry := u64_at(b, 24)
    phoff := u64_at(b, 32)
    shoff := u64_at(b, 40)
    phnum := u16_at(b, 56)
    shnum := u16_at(b, 60)
    // program headers
    segs := vec[Seg]()
    nload := 0
    has_tls := false
    has_stack := false
    dyn_va := 0
    dyn_size := 0
    interp := ""
    has_phdr := false
    for k in 0..phnum {
        h := phoff + 56 * k
        ty := u32_at(b, h)
        off := u64_at(b, h + 8)
        va := u64_at(b, h + 16)
        fsz := u64_at(b, h + 32)
        msz := u64_at(b, h + 40)
        al := u64_at(b, h + 48)
        if ty == 6 {
            has_phdr = k == 0 && off == phoff && fsz == 56 * phnum
        } else if ty == 3 {
            if off + fsz <= len(b) && fsz > 0 {
                interp = b[off..off + fsz - 1]
            }
        } else if ty == 2 {
            dyn_va = va
            dyn_size = fsz
        } else if ty == 1 {
            nload += 1
            if al != 0x10000 || off % al != va % al || off + fsz > len(b) || fsz > msz {
                bad(p, name, fmt("PT_LOAD ", k, ": offset ", off, ", address ", va, ", alignment ", al, ", sizes ", fsz, "/", msz))
            }
            segs.push(Seg{vaddr: va, memsz: msz})
        } else if ty == 7 {
            has_tls = true
            if fsz != 0 || u64_at(b, h + 48) != 16 {
                bad(p, name, "PT_TLS: the thread block has file data or is not aligned to 16")
            }
        } else if ty == 0x6474e551 {
            has_stack = true
            if u32_at(b, h + 4) & 1 != 0 {
                bad(p, name, "PT_GNU_STACK asks for an executable stack")
            }
        }
    }
    if nload != 2 || !has_tls || !has_stack {
        bad(p, name, "expected two PT_LOAD segments, PT_TLS and PT_GNU_STACK")
    }
    cs := CSide{sigs: sigs}
    dynamic := dyn_va != 0
    if dynamic {
        if !has_phdr || interp != "/lib/ld-linux-aarch64.so.1" || phnum != 7 {
            bad(p, name, fmt("a dynamic executable needs PT_PHDR first, PT_INTERP /lib/ld-linux-aarch64.so.1 (", interp, ") and 7 program headers"))
        }
        check_dynamic(name, b, &segs, dyn_va, dyn_size, &cs, p)
    } else if interp != "" || has_phdr {
        bad(p, name, "PT_INTERP or PT_PHDR without PT_DYNAMIC")
    }
    // sections: .text and .symtab / .strtab
    text_off := -1
    text_addr := 0
    text_size := 0
    sym_off := -1
    sym_size := 0
    str_off := 0
    for k in 0..shnum {
        h := shoff + 64 * k
        ty := u32_at(b, h + 4)
        if ty == 1 && u64_at(b, h + 8) == 6 {
            text_addr = u64_at(b, h + 16)
            text_off = u64_at(b, h + 24)
            text_size = u64_at(b, h + 32)
        }
        if ty == 2 {
            sym_off = u64_at(b, h + 24)
            sym_size = u64_at(b, h + 32)
            link := u32_at(b, h + 40)
            str_off = u64_at(b, shoff + 64 * link + 24)
        }
    }
    if text_off < 0 || sym_off < 0 {
        bad(p, name, "no .text or no .symtab")
        return
    }
    if entry != text_addr {
        bad(p, name, "the entry point is not the start of .text")
    }
    funcs := vec[Func]()
    for k in 1..sym_size / 24 {
        s := sym_off + 24 * k
        no := u32_at(b, s)
        e := str_off + no
        while b[e] != 0 {
            e += 1
        }
        funcs.push(Func{name: b[str_off + no..e], addr: u64_at(b, s + 8), size: u64_at(b, s + 16)})
    }
    starts := map[i64, bool]()
    for fn_ in funcs {
        starts.set(fn_.addr, true)
    }
    in_image := fn(segs: *Vec[Seg], a: i64) -> bool {
        for s in segs {
            if a >= s.vaddr && a < s.vaddr + max(s.memsz, 1) {
                return true
            }
        }
        return false
    }
    t.files += 1
    // the entry stub: up to the first function
    first := text_addr + text_size
    for fn_ in funcs {
        first = min(first, fn_.addr)
    }
    // (the stub of a dynamic program leaves the thread pointer to the loader: 3 words)
    stub := vec[Func]()
    stub.push(Func{name: "<entry>", addr: text_addr, size: if dynamic { 12 } else { 28 }})
    for fn_ in stub.items() {
        check_func(name, b, text_off, text_addr, fn_, &starts, &segs, in_image, p, t, true, &cs)
    }
    for fn_ in funcs {
        check_func(name, b, text_off, text_addr, fn_, &starts, &segs, in_image, p, t, false, &cs)
    }
    for a in cs.slots.keys() {
        if !cs.loaded.has(a) {
            bad(p, name, fmt("the import slot of `", cs.slots.get_or(a, ""), "` at ", hex(u64(a), 8), " is loaded nowhere"))
        }
    }
}

// the dynamic section at dyn_va (dyn_size bytes) and the tables it names; the import slots go
// to cs.slots
priv fn check_dynamic(name: str, b: str, segs: *Vec[Seg], dyn_va: i64, dyn_size: i64, cs: *CSide, p: *Vec[str]) {
    fn bad(p: *Vec[str], name: str, msg: str) {
        p.push(fmt(name, ": ", msg))
    }
    if segs.len != 2 {
        return
    }
    ro := segs[0]
    rw := segs[1]
    // file offsets
    fn file_off(segs: *Vec[Seg], a: i64) -> i64 {
        // (both segments lie at their file offset + the base address)
        return a - segs[0].vaddr
    }
    in_ro := fn(ro: Seg, a: i64, n: i64) -> bool { a >= ro.vaddr && a + n <= ro.vaddr + ro.memsz }
    if dyn_va < rw.vaddr || dyn_va + dyn_size > rw.vaddr + rw.memsz || dyn_size % 16 != 0 {
        bad(p, name, "PT_DYNAMIC is not inside the writable segment")
        return
    }
    d := file_off(segs, dyn_va)
    tags := map[i64, i64]()
    needed := vec[i64]()
    k := 0
    ended := false
    while 16 * k < dyn_size {
        tg := u64_at(b, d + 16 * k)
        v := u64_at(b, d + 16 * k + 8)
        k += 1
        if tg == 0 {
            ended = true
            break
        }
        if tg == 1 {
            needed.push(v)
        } else if tags.has(tg) {
            bad(p, name, fmt("dynamic tag ", tg, " twice"))
        } else {
            tags.set(tg, v)
        }
    }
    if !ended {
        bad(p, name, "the dynamic section does not end with DT_NULL")
    }
    for tg in []i64{4, 5, 6, 10, 11, 7, 8, 9, 30, 21} {
        if !tags.has(tg) {
            bad(p, name, fmt("dynamic tag ", tg, " missing"))
            return
        }
    }
    strtab := tags.get_or(5, 0)
    strsz := tags.get_or(10, 0)
    symtab := tags.get_or(6, 0)
    hash := tags.get_or(4, 0)
    rela := tags.get_or(7, 0)
    relasz := tags.get_or(8, 0)
    if tags.get_or(11, 0) != 24 || tags.get_or(9, 0) != 24 || tags.get_or(30, 0) & 8 == 0 || tags.has(22) {
        bad(p, name, "DT_SYMENT / DT_RELAENT not 24, no BIND_NOW, or DT_TEXTREL")
    }
    if !in_ro(ro, strtab, strsz) || !in_ro(ro, symtab, 24) || !in_ro(ro, hash, 8) || !in_ro(ro, rela, relasz) || relasz % 24 != 0 {
        bad(p, name, "a table of the dynamic section is not inside the read-only segment")
        return
    }
    st := file_off(segs, strtab)
    cstr_at := fn(b: str, at: i64, end: i64) -> str {
        e := at
        while e < end && b[e] != 0 {
            e += 1
        }
        return b[at..e]
    }
    if needed.is_empty() {
        bad(p, name, "no DT_NEEDED")
    }
    for n in needed {
        if n <= 0 || n >= strsz || len(cstr_at(b, st + n, st + strsz)) == 0 {
            bad(p, name, fmt("DT_NEEDED ", n, " is not a name in .dynstr"))
        }
    }
    // the SysV hash table: nbucket, nchain (= the number of symbols)
    ho := file_off(segs, hash)
    nsym := u32_at(b, ho + 4)
    if u32_at(b, ho) < 1 || !in_ro(ro, hash, 8 + 4 * (u32_at(b, ho) + nsym)) || !in_ro(ro, symtab, 24 * nsym) {
        bad(p, name, "the hash table's sizes do not fit")
        return
    }
    sy := file_off(segs, symtab)
    for j in 0..24 {
        if b[sy + j] != 0 {
            bad(p, name, "dynamic symbol 0 is not null")
            break
        }
    }
    names := vec[str]()
    names.push("")
    for s in 1..nsym {
        e := sy + 24 * s
        info := i64(b[e + 4])
        nm := if u32_at(b, e) < strsz { cstr_at(b, st + u32_at(b, e), st + strsz) } else { "" }
        if len(nm) == 0 || info >> 4 != 1 || (info & 15 != 1 && info & 15 != 2) || u16_at(b, e + 6) != 0 || u64_at(b, e + 8) != 0 {
            bad(p, name, fmt("dynamic symbol ", s, " (", nm, ") is not an undefined global function or object"))
        }
        names.push(nm)
    }
    ra := file_off(segs, rela)
    for r in 0..relasz / 24 {
        off := u64_at(b, ra + 24 * r)
        info := u64_at(b, ra + 24 * r + 8)
        add := u64_at(b, ra + 24 * r + 16)
        sym := info >> 32
        if info & 0xFFFFFFFF != 1025 || sym < 1 || sym >= nsym || add != 0 {
            bad(p, name, fmt("relocation ", r, ": type ", info & 0xFFFFFFFF, ", symbol ", sym, ", addend ", add, " (expected R_AARCH64_GLOB_DAT of a symbol)"))
            continue
        }
        if off % 8 != 0 || off < rw.vaddr || off + 8 > rw.vaddr + rw.memsz || cs.slots.has(off) {
            bad(p, name, fmt("relocation ", r, ": the import slot ", hex(u64(off), 8), " is misaligned, outside the writable segment or used twice"))
            continue
        }
        cs.slots.set(off, names[sym])
    }
    if cs.slots.len != nsym - 1 {
        bad(p, name, "not every dynamic symbol has its relocation")
    }
}

priv fn check_func(name: str, b: str, text_off: i64, text_addr: i64, fn_: Func, starts: *Map[i64, bool], segs: *Vec[Seg],
        in_image: fn(*Vec[Seg], i64) -> bool, p: *Vec[str], t: *Totals, stub: bool, cs: *CSide) {
    n := fn_.size / 4
    if n == 0 {
        return
    }
    t.funcs += 1
    t.words += n
    base := text_off + (fn_.addr - text_addr)
    ins := vec[Ins]()
    for k in 0..n {
        ins.push(decode(u32(u32_at(b, base + 4 * k))))
    }
    where := fn(name: str, fn_: Func, k: i64) -> str {
        return fmt(name, ": ", fn_.name, "+", 4 * k)
    }
    errs := 0
    say := fn(p: *Vec[str], errs: *i64, s: str) {
        if *errs < 5 {
            p.push(s)
        }
        *errs += 1
    }
    w := vec[i64]()
    for k in 0..n {
        w.push(u32_at(b, base + 4 * k))
    }
    // decoding, branches, addresses
    for k in 0..n {
        i := &ins[k]
        if !i.ok {
            say(p, &errs, fmt(where(name, fn_, k), ": word ", hex(u64(w[k]), 8), " is not an instruction of the back end's set"))
            continue
        }
        if (i.du_g | i.us_g) & (1 << 18) != 0 {
            say(p, &errs, fmt(where(name, fn_, k), ": uses x18"))
        }
        if i.neg_sp_store {
            say(p, &errs, fmt(where(name, fn_, k), ": an access below sp"))
        }
        match i.kind {
            K_B, K_BCOND => {
                tk := k + i.target
                if tk < 0 || tk >= n {
                    say(p, &errs, fmt(where(name, fn_, k), ": a branch out of the function"))
                }
            }
            K_BL => {
                ta := fn_.addr + 4 * k + 4 * i.target
                if !starts.has(ta) {
                    say(p, &errs, fmt(where(name, fn_, k), ": BL to ", hex(u64(ta), 8), ", not the start of a function"))
                }
            }
            K_ADRP => {
                // the ADD of the pair follows (or a load that uses the register)
                if k + 1 < n && ins[k + 1].kind == K_ADD12 && ins[k + 1].rn == i.rd {
                    pc := fn_.addr + 4 * k
                    a := ((pc >> 12) + i.adrp) << 12 | ins[k + 1].adrp
                    if !in_image(segs, a) {
                        say(p, &errs, fmt(where(name, fn_, k), ": ADRP / ADD address ", hex(u64(a), 8), " outside the image"))
                    }
                } else if k + 1 < n && w[k + 1] & 0xFFC00000 == 0xF9400000 && (w[k + 1] >> 5) & 31 == i.rd {
                    // ADRP + LDR (8 bytes, unsigned offset): the load of an import slot
                    pc := fn_.addr + 4 * k
                    a := ((pc >> 12) + i.adrp) << 12 | ((w[k + 1] >> 10) & 0xFFF) * 8
                    if !cs.slots.has(a) {
                        say(p, &errs, fmt(where(name, fn_, k), ": ADRP / LDR of ", hex(u64(a), 8), ", which is no import slot"))
                    }
                    cs.loaded.set(a, true)
                } else {
                    say(p, &errs, fmt(where(name, fn_, k), ": ADRP without its ADD"))
                }
            }
            K_SPADD => {
                if i.sp_set % 16 != 0 {
                    say(p, &errs, fmt(where(name, fn_, k), ": sp moved by ", i.sp_set))
                }
            }
            _ => {}
        }
    }
    if errs > 0 {
        return
    }
    // dataflow over the instructions: registers written on every path, and the offset of sp
    // (and x29) from the entry; unknown: -1 << 40
    unk := -(1 << 40)
    in_g := vec_fill(n, ~u64(0))
    in_f := vec_fill(n, ~u64(0))
    in_sp := vec_fill(n, unk)
    in_fp := vec_fill(n, unk)
    seen := vec_fill(n, false)
    in_g[0] = if stub { 1 << 31 } else { ENTRY_G }
    in_f[0] = if stub { 0 } else { ENTRY_F }
    in_sp[0] = 0
    in_fp[0] = unk
    seen[0] = true
    work := vec_of([]i64{0})
    queued := vec_fill(n, false)
    queued[0] = true
    sp_conflict := false
    while !work.is_empty() {
        k := work.pop()
        queued[k] = false
        i := &ins[k]
        gs := in_g[k]
        fs := in_f[k]
        sp := in_sp[k]
        fp := in_fp[k]
        // the effect
        gs |= i.du_g
        fs |= i.du_f
        match i.kind {
            K_SPADD => sp = sp + i.sp_set
            K_SPFROM => sp = if i.rn == 29 { fp } else { unk }
            K_FPFROMSP => fp = sp
            K_BL, K_BLR => {
                gs = (gs & ~CALL_KILL_G) | CALL_SET_G
                fs = CALL_SET_F
            }
            _ => {}
        }
        if i.du_g & (1 << 29) != 0 && i.kind != K_FPFROMSP && i.kind != K_SPADD {
            fp = unk
        }
        // the successors
        succ := vec[i64]()
        match i.kind {
            K_B => succ.push(k + i.target)
            K_BCOND => {
                succ.push(k + i.target)
                succ.push(k + 1)
            }
            K_RET, K_BR, K_BRK => {}
            _ => succ.push(k + 1)
        }
        for s in succ {
            if s < 0 || s >= n {
                continue
            }
            ng := in_g[s] & gs
            nf := in_f[s] & fs
            changed := !seen[s] || ng != in_g[s] || nf != in_f[s]
            if !seen[s] {
                in_sp[s] = sp
                in_fp[s] = fp
            } else if in_sp[s] != sp || in_fp[s] != fp {
                if !sp_conflict {
                    sp_conflict = true
                    say(p, &errs, fmt(where(name, fn_, s), ": the stack pointer (or x29) differs between the paths that reach here"))
                }
            }
            seen[s] = true
            in_g[s] = ng
            in_f[s] = nf
            if changed && !queued[s] {
                queued[s] = true
                work.push(s)
            }
        }
    }
    for k in 0..n {
        if !seen[k] {
            continue
        }
        i := &ins[k]
        mg := i.us_g & ~in_g[k]
        mf := i.us_f & ~in_f[k]
        if mg != 0 || mf != 0 {
            r := if mg != 0 { fmt("x", ctz(mg)) } else { fmt("v", ctz(mf)) }
            say(p, &errs, fmt(where(name, fn_, k), ": reads ", r, ", which not every path writes"))
        }
        if (i.kind == K_BL || i.kind == K_BLR) && in_sp[k] % 16 != 0 {
            say(p, &errs, fmt(where(name, fn_, k), ": a call with sp at entry ", in_sp[k], " (not a multiple of 16)"))
        }
        if i.kind == K_BLR && cs.sigs.len > 0 {
            // a C call: the register was loaded from an import slot (ADRP + LDR, perhaps
            // copied with a MOV) by the instructions before it
            r := i.rn
            sym := ""
            j := k - 1
            while j >= max(k - 40, 1) && len(sym) == 0 {
                x := &ins[j]
                if x.du_g & (u64(1) << u64(r)) != 0 {
                    if w[j] & 0xFFC00000 == 0xF9400000 && ins[j - 1].kind == K_ADRP && ins[j - 1].rd == r {
                        a := (((fn_.addr + 4 * (j - 1)) >> 12) + ins[j - 1].adrp) << 12 | ((w[j] >> 10) & 0xFFF) * 8
                        sym = cs.slots.get_or(a, "?")
                    } else if w[j] & 0xFFE0FFE0 == 0xAA0003E0 {
                        r = (w[j] >> 16) & 31 // mov xd, xm
                    } else {
                        break
                    }
                }
                j -= 1
            }
            sig, known := cs.sigs.get(sym)
            if known {
                t.ccalls += 1
                ret := sig.ret
                locs, rl := aapcs64(sig.args.items(), sig.nfixed, ret, false)
                ng, nf := loc_regs(locs.items(), rl)
                mg := ng & ~in_g[k]
                mf := nf & ~in_f[k]
                if mg != 0 || mf != 0 {
                    say(p, &errs, fmt(where(name, fn_, k), ": the C call of `", sym, "` (", loc_text(locs.items(), rl), ") does not write ",
                        if mg != 0 { fmt("x", ctz(mg)) } else { fmt("v", ctz(mf)) }, " on every path"))
                }
            }
        }
        if i.kind == K_RET && in_sp[k] != 0 {
            say(p, &errs, fmt(where(name, fn_, k), ": RET with sp at entry ", in_sp[k]))
        }
        if i.kind == K_RET && !stub && i.rn != 30 {
            say(p, &errs, fmt(where(name, fn_, k), ": RET to a register other than x30"))
        }
    }
}

priv fn skip_list() -> Map[str, bool] {
    out := map[str, bool]()
    text, ok := read_file("tests/arm64.skip")
    if !ok {
        return out
    }
    for l in lines(text) {
        if len(l) == 0 || l[0] == '#' {
            continue
        }
        sp := index_of(l, ' ')
        out.set(if sp < 0 { l } else { l[..sp] }, true)
    }
    return out
}

fn main() -> i64 {
    a := args()[1..]
    verbose := false
    if len(a) > 0 && a[0] == "-v" {
        verbose = true
        a = a[1..]
    }
    alc := if TARGET_OS == Windows { "build/alc.exe" } else { "./build/alc" }
    if len(a) > 0 && (ends_with(a[0], "alc") || ends_with(a[0], "alc.exe")) {
        alc = a[0]
        a = a[1..]
    }
    inputs := vec_of(a)
    if inputs.is_empty() {
        inputs = vec_of([]str{"tests/run", "tests/std", "tests/sys", "examples"})
    }
    skip := skip_list()
    files := vec[str]()
    for x in inputs {
        if !is_dir(x) {
            files.push(x)
            continue
        }
        names := list_dir(x)
        sort(names)
        for nm in names {
            if !ends_with(nm, ".al") {
                continue
            }
            dir_name := x
            k := len(x)
            while k > 0 && x[k - 1] != '/' {
                k -= 1
            }
            key := fmt(x[k..], "/", nm[..len(nm) - 3])
            if skip.has(key) {
                continue
            }
            src := path_join(x, nm)
            text, _ := read_file(src)
            if find(text, "fn main") < 0 {
                continue
            }
            files.push(src)
        }
    }
    tmp := path_join(if TARGET_OS == Windows { env_get("TEMP").0 } else { "/tmp" }, fmt("a64check.", process_id()))
    make_dir(tmp)
    probs := vec[str]()
    t := Totals{}
    built := 0
    for src in files {
        if !ends_with(src, ".al") {
            // an executable to check as it is
            bytes, ok := read_file(src)
            if ok {
                check_elf(src, bytes, &probs, &t, map[str, Sig]())
            }
            continue
        }
        sigs := c_sigs(src)
        for mode in []str{"", "-O0"} {
            out := path_join(tmp, "prog")
            cmd := vec_of([]str{alc, "build", "--target", "linux-arm64", src, "-o", out})
            if mode != "" {
                cmd.push(mode)
            }
            // (programs that do not build for this target are the conformance suite's matter)
            if run_capture_all(cmd.items()).1 != 0 {
                continue
            }
            built += 1
            bytes, ok := read_file(out)
            if !ok {
                continue
            }
            before := probs.len
            check_elf(fmt(src, if mode == "" { "" } else { " -O0" }), bytes, &probs, &t, sigs)
            if verbose && probs.len == before {
                print(fmt("ok   ", src, " ", mode))
            }
        }
    }
    remove_file(path_join(tmp, "prog"))
    remove_dir(tmp)
    for s in probs {
        print(s)
    }
    print(fmt("arm64 check: ", t.files, " executables, ", t.funcs, " functions, ", t.words, " instructions, ", t.ccalls, " C calls, ", probs.len, " problems"))
    return if probs.is_empty() { 0 } else { 1 }
}
