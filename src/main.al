// alc: the AL compiler driver.
use "base.al"
use "ast.al"
use "lexer.al"
use "parser.al"
use "types.al"
use "ir.al"
use "lower.al"
use "lower_fn.al"
use "lower_expr.al"
use "lower_call.al"
use "lower_vec.al"
use "lower_nested.al"
use "lint.al"
use "lower_match.al"
use "opt/alias.al"
use "opt/bce.al"
use "opt/checkmerge.al"
use "opt/cleanup.al"
use "opt/gvn.al"
use "opt/inline.al"
use "opt/licm.al"
use "opt/loadelim.al"
use "opt/mem2reg.al"
use "opt/mod.al"
use "opt/simplify.al"
use "opt/tre.al"
use "opt/unroll.al"
use "x86/mir.al"
use "x86/isel.al"
use "x86/regalloc.al"
use "x86/emit.al"
use "x86/mod.al"
use "elf.al"
use "priv.al"
use "lower_mem.al"

priv const PRELUDE = embed("prelude.al")

// modules bundled with the compiler: `use std.<name>`
// (during development, ALC_STD_DIR=<dir> reads `<dir>/<name>.al` instead of the built-in copy)
priv const STD_MODULES = [15](str, str){
    ("math", embed("../std/math.al")),
    ("rand", embed("../std/rand.al")),
    ("time", embed("../std/time.al")),
    ("mem", embed("../std/mem.al")),
    ("libc", embed("../std/libc.al")),
    ("asset", embed("../std/asset.al")),
    ("image", embed("../std/image.al")),
    ("x11", embed("../std/x11.al")),
    ("alsa", embed("../std/alsa.al")),
    ("window", embed("../std/window.al")),
    ("input", embed("../std/input.al")),
    ("audio", embed("../std/audio.al")),
    ("vk", embed("../std/vk.al")),
    ("dx12", embed("../std/dx12.al")),
    ("metal", embed("../std/metal.al")),
}

// modules that are loaded into every program
priv const CORE_MODULES = [4]str{"math", "rand", "time", "mem"}

// ---------- paths ----------
// `p` seen from `dir` (an absolute `p` stays as it is)
priv fn path_join(dir: str, p: str) -> str {
    if starts_with(p, "/") || len(dir) == 0 {
        return p
    }
    if ends_with(dir, "/") {
        return concat(dir, p)
    }
    return fmt(dir, "/", p)
}

// the components of a path as far as comparing paths goes: a leading "/" is a component,
// empty components and "." are dropped, except a "." at the start of a relative path
priv fn path_comps(p: str) -> Vec[str] {
    out := vec[str]()
    if starts_with(p, "/") {
        out.push("/")
    }
    first := true
    for c in split(p, '/') {
        if len(c) == 0 {
            continue
        }
        if c == "." && !(first && !starts_with(p, "/")) {
            first = false
            continue
        }
        first = false
        out.push(c)
    }
    return out
}

// the path without trailing separators and trailing "." components
priv fn path_trim(p: str) -> str {
    n := len(p)
    loop {
        if n > 1 && p[n - 1] == '/' {
            n -= 1
        } else if n >= 2 && p[n - 1] == '.' && p[n - 2] == '/' {
            n -= 1
        } else {
            break
        }
    }
    return p[..n]
}

// the last component, unless the path ends in ".." or has none
priv fn path_file_name(p: str) -> Opt[str] {
    t := path_trim(p)
    k := len(t)
    while k > 0 && t[k - 1] != '/' {
        k -= 1
    }
    name := t[k..]
    if len(name) == 0 || name == ".." || name == "." {
        return None
    }
    return Some(name)
}

// the path without its last component
priv fn path_parent(p: str) -> Opt[str] {
    t := path_trim(p)
    if len(t) == 0 || t == "/" {
        return None
    }
    k := len(t)
    while k > 0 && t[k - 1] != '/' {
        k -= 1
    }
    // separators between the parent and the last component do not belong to the parent
    while k > 1 && t[k - 1] == '/' {
        k -= 1
    }
    return Some(t[..k])
}

// the file name without its last extension
priv fn path_file_stem(p: str) -> Opt[str] {
    name := match path_file_name(p) {
        Some(n) => n
        None => return None
    }
    k := len(name) - 1
    while k > 0 && name[k] != '.' {
        k -= 1
    }
    if k <= 0 {
        // no dot, or only a leading one
        return Some(name)
    }
    return Some(name[..k])
}

// the canonical form of a path, as far as the driver needs it (to recognise a file that is included
// twice): the absolute path with "." and ".." resolved textually; symbolic links are kept
priv fn canonical(path: str) -> str {
    full := path
    if !starts_with(path, "/") {
        buf := alloc[u8](4096)
        n := syscall(79, ptr(buf), 4096)
        if n > 0 {
            // the length includes the terminating NUL
            full = fmt(buf[..n - 1], "/", path)
        }
    }
    parts := vec[str]()
    for c in split(full, '/') {
        if len(c) == 0 || c == "." {
            continue
        }
        if c == ".." {
            if parts.len > 0 {
                parts.pop()
            }
            continue
        }
        parts.push(c)
    }
    return concat("/", join(parts.items(), "/"))
}

// the text for an errno, as in diagnostics: "No such file or directory (os error 2)"
priv fn os_error(errno: i64) -> str {
    text := match errno {
        1 => "Operation not permitted"
        2 => "No such file or directory"
        5 => "Input/output error"
        11 => "Resource temporarily unavailable"
        12 => "Cannot allocate memory"
        13 => "Permission denied"
        17 => "File exists"
        20 => "Not a directory"
        21 => "Is a directory"
        23 => "Too many open files in system"
        24 => "Too many open files"
        26 => "Text file busy"
        27 => "File too large"
        28 => "No space left on device"
        30 => "Read-only file system"
        36 => "File name too long"
        40 => "Too many levels of symbolic links"
        _ => fmt("Unknown error ", errno)
    }
    return fmt(text, " (os error ", errno, ")")
}

// the content of a file: (text, error); the error text is empty on success
priv fn read_to_string(path: str) -> (str, str) {
    // read_file does not say why it failed: look at the file first
    fd := syscall(2, cstr(path), 0, 0)
    if fd < 0 {
        return ("", os_error(-fd))
    }
    probe: [1]u8
    r := syscall(0, fd, ptr(probe), 0)
    syscall(3, fd)
    if r < 0 && r != -4 {
        return ("", os_error(-r))
    }
    text, ok := read_file(path)
    if !ok {
        return ("", os_error(5))
    }
    return (text, "")
}

priv fn std_text(name: str) -> Opt[str] {
    mi := -1
    for i in 0..STD_MODULES.len {
        if STD_MODULES[i].0 == name {
            mi = i
            break
        }
    }
    if mi < 0 {
        return None
    }
    dir, have_dir := env_get("ALC_STD_DIR")
    if have_dir {
        t, err := read_to_string(path_join(dir, fmt(name, ".al")))
        if len(err) == 0 {
            return Some(t)
        }
    }
    return Some(STD_MODULES[mi].1)
}

priv struct Args {
    cmd: str
    input: str
    output: Opt[str]
    emit_ir: bool
    emit_asm: bool
    unchecked: bool
    opt: i64
    rest: Vec[str]
}

priv fn usage() -> never {
    eput(concat("usage: alc <command> <file.al> [options]\n",
        concat("commands:\n  build   compile to a static x86-64 Linux executable\n  run     build and run (arguments after `--` are passed on)\n  test    build and run all `test` blocks\n  check   type-check only\n  sigs    list the declarations of a file (`alc sigs f.al -- std` adds the standard library)\n",
        "options:\n  -o <path>     output path (default: input without .al)\n  --unchecked   disable bounds/division checks\n  -O0           disable optimizations\n  --json        print diagnostics as a JSON array on stdout\n  --emit-ir     print optimized IR to stdout\n  --emit-asm    print the selected machine code to stdout\n")))
    exit(2)
}

priv fn parse_args() -> Args {
    all := args()
    av := vec[str]()
    for i in 1..len(all) {
        av.push(all[i])
    }
    if av.len < 2 {
        usage()
    }
    a := Args{cmd: av[0], input: "", output: None, emit_ir: false, emit_asm: false, unchecked: false, opt: 2, rest: vec[str]()}
    i := 1
    while i < av.len {
        s := av[i]
        if s == "-o" {
            i += 1
            if i >= av.len {
                usage()
            }
            a.output = Some(av[i])
        } else if s == "--json" {
            json = true
        } else if s == "--emit-ir" {
            a.emit_ir = true
        } else if s == "--emit-asm" {
            a.emit_asm = true
        } else if s == "--unchecked" {
            a.unchecked = true
        } else if s == "-O0" {
            a.opt = 0
        } else if s == "-O1" {
            a.opt = 1
        } else if s == "-O2" {
            a.opt = 2
        } else if s == "--" {
            a.rest = vec_of(av[i + 1..av.len])
            break
        } else if starts_with(s, "-") {
            eput(fmt("unknown option ", s, "\n"))
            usage()
        } else {
            if len(a.input) == 0 {
                a.input = s
            } else {
                eput(fmt("unexpected argument ", s, "\n"))
                usage()
            }
        }
        i += 1
    }
    if len(a.input) == 0 {
        usage()
    }
    return a
}

priv struct Sources {
    names: Vec[str]
    decls: Vec[Decl]
    errs: Vec[Diag]
    seen: Map[str, bool]
    std_files: Vec[i64]
}

priv fn add_text(self: *Sources, name: str, text: str, dir: Opt[str]) {
    file := self.names.len
    self.names.push(name)
    toks := lexer_lex(text, file, &self.errs)
    p := parser_new(toks, &self.errs)
    decls := p.file()
    priv_apply(&decls, file, &self.errs)
    for di in 0..decls.len {
        d := decls[di]
        match d {
            Use(path, pos) => {
                if starts_with(path, "std:") {
                    mname := path[4..]
                    match std_text(mname) {
                        Some(mtext) => {
                            key := fmt("<std/", mname, ".al>")
                            if !self.seen.has(key) {
                                self.seen.set(key, true)
                                self.std_files.push(self.names.len)
                                self.add_text(fmt("<std/", mname, ".al>"), mtext, None)
                            }
                        }
                        None => {
                            all := vec[str]()
                            for mi in 0..STD_MODULES.len {
                                all.push(STD_MODULES[mi].0)
                            }
                            self.errs.push(Diag{pos: pos, msg: fmt("unknown module `std.", mname, "` (available: ", join(all.items(), ", "), ")")})
                        }
                    }
                    continue
                }
                fp := match dir {
                    Some(dr) => path_join(dr, path)
                    None => path
                }
                self.add_file(fp, Some(pos))
            }
            _ => {
                self.decls.push(d)
            }
        }
    }
}

priv fn add_file(self: *Sources, path: str, from: Opt[Pos]) {
    // canonicalize fails for a file that does not exist: the path is then used as it is
    canon := path
    if syscall(21, cstr(path), 0) == 0 {
        canon = canonical(path)
    }
    if self.seen.has(canon) {
        return
    }
    self.seen.set(canon, true)
    text, err := read_to_string(path)
    if len(err) == 0 {
        self.add_text(path, text, path_parent(path))
    } else {
        msg := fmt("cannot read `", path, "`: ", err)
        match from {
            Some(pos) => self.errs.push(Diag{pos: pos, msg: msg})
            None => {
                eput(fmt("error: ", msg, "\n"))
                exit(1)
            }
        }
    }
}

priv json: bool

priv fn json_str(s: str) -> str {
    o := vec[u8]()
    o.push('"')
    for c in s {
        if c == '"' {
            o.extend("\\\"")
        } else if c == '\\' {
            o.extend("\\\\")
        } else if c == '\n' {
            o.extend("\\n")
        } else if c < 0x20 {
            o.extend(concat("\\u", pad_left(hex(u64(c)), 4, '0')))
        } else {
            o.push(c)
        }
    }
    o.push('"')
    return o.items()
}

// sort key (file, line, col)
priv fn report_less(a: Diag, b: Diag) -> bool {
    if a.pos.file != b.pos.file {
        return a.pos.file < b.pos.file
    }
    if a.pos.line != b.pos.line {
        return a.pos.line < b.pos.line
    }
    return a.pos.col < b.pos.col
}

// names.get(file) or "?"
priv fn file_name(names: *Vec[str], file: i64) -> str {
    if file >= 0 && file < names.len {
        return names[file]
    }
    return "?"
}

priv fn report(names: *Vec[str], errs: *Vec[Diag]) -> bool {
    if errs.is_empty() {
        return false
    }
    sort_by(errs.items(), report_less)
    if json {
        // machine-readable diagnostics: one JSON array on stdout
        items := vec[str]()
        last := ""
        for d in errs {
            file := file_name(names, d.pos.file)
            item := fmt("{\"file\":", json_str(file), ",\"line\":", d.pos.line, ",\"col\":", d.pos.col, ",\"message\":", json_str(ast_plain_text(d.msg)), "}")
            if item != last {
                items.push(item)
                last = item
            }
        }
        print(fmt("[", join(items.items(), ","), "]"))
        return true
    }
    last := ""
    n := 0
    for d in errs {
        line := fmt(file_name(names, d.pos.file), ":", d.pos.line, ":", d.pos.col, ": error: ", ast_plain_text(d.msg))
        if line != last {
            eput(fmt(line, "\n"))
            n += 1
            last = line
        }
    }
    eput(fmt(n, " error(s)\n"))
    return true
}

// "priv " in front of the signature of a private declaration
priv fn sigs_priv(name: str) -> str {
    if ast_is_private(name) {
        return "priv "
    }
    return ""
}

// `alc sigs`: one line per declaration, for a quick overview of a file
priv fn print_sigs(names: *Vec[str], decls: []Decl, from_file: i64) {
    for d in decls {
        pos, text := match d {
            Fn(f) => (f.pos, fmt(sigs_priv(f.name), ast_sig_str(&f)))
            Struct(s) => (s.pos, fmt(sigs_priv(s.name), ast_struct_str(&s)))
            Enum(e) => (e.pos, fmt(sigs_priv(e.name), ast_enum_str(&e)))
            // (the value of a constant or a global is not shown: `...`)
            Const(c) => {
                sig := match c.ty {
                    Some(ty) => fmt(sigs_priv(c.name), "const ", c.name, ": ", ast_type_str(&ty), " = ...")
                    None => fmt(sigs_priv(c.name), "const ", c.name, " = ...")
                }
                (c.pos, sig)
            }
            Glob(g) => {
                sig := match g.ty {
                    Some(ty) => fmt(sigs_priv(g.name), g.name, ": ", ast_type_str(&ty))
                    None => fmt(sigs_priv(g.name), g.name, " := ...")
                }
                (g.pos, sig)
            }
            Test(t) => (t.pos, fmt("test \"", t.name, "\""))
            Use(_, _) => continue
        }
        if pos.file < from_file {
            continue
        }
        print(fmt(file_name(names, pos.file), ":", pos.line, ": ", ast_plain_text(text)))
    }
}

// is a declaration shown by `alc sigs <file> -- std`?
priv fn sigs_visible(d: *Decl) -> bool {
    match *d {
        Fn(f) => !starts_with(f.name, "__")
        Glob(g) => !starts_with(g.name, "__")
        _ => true
    }
}

priv fn real_main() -> i64 {
    ar := parse_args()
    test_mode := ar.cmd == "test"
    if !(ar.cmd == "build" || ar.cmd == "run" || ar.cmd == "test" || ar.cmd == "check" || ar.cmd == "sigs") {
        usage()
    }
    src := Sources{names: vec[str](), decls: vec[Decl](), errs: vec[Diag](), seen: map[str, bool](), std_files: vec[i64]()}
    src.add_text("<prelude>", PRELUDE, None)
    // the core library is part of the language: always present, no `use` needed
    for name in CORE_MODULES {
        text := match std_text(name) {
            Some(t) => t
            None => ""
        }
        src.seen.set(fmt("<std/", name, ".al>"), true)
        src.add_text(fmt("<std/", name, ".al>"), text, None)
    }
    n_prelude := src.names.len
    src.add_file(ar.input, None)
    if ar.cmd == "sigs" {
        // `alc sigs <file> --` with "std" as input lists the standard library
        if report(&src.names, &src.errs) {
            return 1
        }
        from := if contains(&ar.rest, "std") { 0 } else { n_prelude }
        sdecls := vec[Decl]()
        if from == 0 {
            for x in 0..src.decls.len {
                // private declarations of the library cannot be used from outside
                info := priv_decl_info(&src.decls[x])
                lib_private := info.2 && (info.3.file < n_prelude || contains(&src.std_files, info.3.file))
                if sigs_visible(&src.decls[x]) && !lib_private {
                    sdecls.push(src.decls[x])
                }
            }
        } else {
            sdecls = src.decls
        }
        print_sigs(&src.names, sdecls.items(), from)
        return 0
    }
    // tests become functions; the entry point is synthesized
    tests := vec[str]()
    main_ret := false
    has_main := false
    decls := vec[Decl]()
    taken := src.decls
    src.decls = vec[Decl]()
    for x in 0..taken.len {
        d := taken[x]
        match d {
            Test(t) => {
                fname := fmt("__test_", tests.len)
                tests.push(t.name)
                decls.push(Fn(FnDecl{name: fname, tparams: vec[str](), params: vec[(str, TypeAst)](), ret: None, body: t.body, pos: t.pos, inl: -1, ext: None}))
            }
            Fn(f) => {
                if f.name == "main" {
                    has_main = true
                    main_ret = is_some(f.ret)
                }
                decls.push(Fn(f))
            }
            _ => {
                decls.push(d)
            }
        }
    }
    entry := vec[str]()
    entry.push("fn __entry(sp: i64) -> never {\n __rt_init(sp)\n")
    if test_mode {
        for i in 0..tests.len {
            name := tests[i]
            esc := alloc[u8](len(name))
            for k, c in name {
                esc[k] = if c == '"' || c == '\\' { '_' } else { c }
            }
            entry.push(fmt(" __run_test(\"", esc, "\", __test_", i, ")\n"))
        }
        entry.push(" exit(__tests_done())\n}\n")
    } else if !has_main {
        src.errs.push(Diag{pos: Pos{file: n_prelude, line: 1, col: 1}, msg: "missing `fn main() { ... }`, the function where the program starts"})
        entry.push(" exit(0)\n}\n")
    } else if main_ret {
        entry.push(" exit(main())\n}\n")
    } else {
        entry.push(" main()\n exit(0)\n}\n")
    }
    {
        file := src.names.len
        src.names.push("<entry>")
        toks := lexer_lex(join(entry.items(), ""), file, &src.errs)
        p := parser_new(toks, &src.errs)
        more := p.file()
        decls.extend(more.items())
    }
    if report(&src.names, &src.errs) {
        return 1
    }
    mem("parsed")
    cx := cx_new(decls.items(), clone(src.names), Opts{checks: !ar.unchecked}, n_prelude)
    if ar.cmd != "check" {
        // bundled modules are only compiled as far as the program reaches into them
        for f in src.std_files {
            cx.lazy_files.set(f, true)
        }
    }
    lower_fn_lower_all(&cx, "__entry", n_prelude)
    if report(&src.names, &cx.errs) {
        return 1
    }
    if ar.cmd == "check" {
        return 0
    }
    module := cx.module
    mem("lowered")
    opt_optimize(&module, ar.opt)
    mem("optimized")
    if ar.emit_ir {
        for fi in 0..module.funcs.len {
            if module.funcs[fi].lowered {
                put(ir_print_func(&module.funcs[fi], Some(&module)))
            }
        }
    }
    out := x86_compile(&module, ar.emit_asm)
    mem("compiled")
    bytes, link_err := elf_link(&module, &out)
    if len(link_err) != 0 {
        eput(fmt("error: ", link_err, "\n"))
        return 1
    }
    out_path := match ar.output {
        Some(op) => op
        None => {
            stem := match path_file_stem(ar.input) {
                Some(s) => s
                None => "a.out"
            }
            dir := match path_parent(ar.input) {
                Some(dr) => dr
                None => ""
            }
            cand := path_join(dir, stem)
            if path_comps(cand).items() == path_comps(ar.input).items() { fmt(cand, ".out") } else { cand }
        }
    }
    if find(out_path, "/") < 0 {
        out_path = fmt("./", out_path)
    }
    if !write_file(out_path, bytes) {
        // write_file does not say why it failed: ask again
        errno := 5
        fd := syscall(2, cstr(out_path), 577, 420)
        if fd < 0 {
            errno = -fd
        } else {
            syscall(3, fd)
        }
        eput(fmt("error: cannot write `", out_path, "`: ", os_error(errno), "\n"))
        return 1
    }
    make_executable(out_path)
    if ar.cmd == "run" || ar.cmd == "test" {
        code := run_program(out_path, ar.rest.items())
        if code < 0 {
            eput(fmt("error: cannot run `", out_path, "`: ", os_error(11), "\n"))
            return 1
        }
        return code
    }
    return 0
}

fn main() -> i64 {
    // deep recursion in the frontend and SSA construction: use a big stack
    ensure_stack(1 << 30)
    t0 = clock_ns()
    return real_main()
}

priv t0: i64

// ALC_DEBUG=mem: memory in use and time since the start after each phase, and the largest
// size of the work heap
priv fn mem(phase: str) {
    v, found := env_get("ALC_DEBUG")
    if found && v == "mem" {
        eput(fmt("[mem] ", phase, ": ", mem_used() >> 20, " MB, work heap peak ", work_peak() >> 20, " MB, ", (clock_ns() - t0) / 1000000, " ms\n"))
    }
}
