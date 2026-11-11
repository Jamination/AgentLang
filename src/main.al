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

// `embed` is only accepted inside a function: PRELUDE and STD_MODULES are globals that
// main_load_embedded fills once, first thing in main.
PRELUDE: str

// modules bundled with the compiler: `use std.<name>`
// (during development, ALC_STD_DIR=<dir> reads `<dir>/<name>.al` instead of the built-in copy)
STD_MODULES: Vec[(str, str)]

fn main_load_embedded() {
    PRELUDE = embed("prelude.al")
    STD_MODULES = vec[(str, str)]()
    STD_MODULES.push(("math", embed("../std/math.al")))
    STD_MODULES.push(("rand", embed("../std/rand.al")))
    STD_MODULES.push(("time", embed("../std/time.al")))
    STD_MODULES.push(("mem", embed("../std/mem.al")))
    STD_MODULES.push(("libc", embed("../std/libc.al")))
    STD_MODULES.push(("asset", embed("../std/asset.al")))
    STD_MODULES.push(("image", embed("../std/image.al")))
    STD_MODULES.push(("x11", embed("../std/x11.al")))
    STD_MODULES.push(("alsa", embed("../std/alsa.al")))
    STD_MODULES.push(("window", embed("../std/window.al")))
    STD_MODULES.push(("input", embed("../std/input.al")))
    STD_MODULES.push(("audio", embed("../std/audio.al")))
    STD_MODULES.push(("vk", embed("../std/vk.al")))
    STD_MODULES.push(("dx12", embed("../std/dx12.al")))
    STD_MODULES.push(("metal", embed("../std/metal.al")))
}

// modules that are loaded into every program
CORE_MODULES := [4]str{"math", "rand", "time", "mem"}

// ---------- paths (std::path in the Rust source) ----------
// Path::join
fn main_path_join(dir: str, p: str) -> str {
    if starts_with(p, "/") || len(dir) == 0 {
        return p
    }
    if ends_with(dir, "/") {
        return concat(dir, p)
    }
    return fmt(dir, "/", p)
}

// the components of a path as Rust's Path compares them: a leading "/" is a component,
// empty components and "." are dropped, except a "." at the start of a relative path
fn main_path_comps(p: str) -> Vec[str] {
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
fn main_path_trim(p: str) -> str {
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

// Path::file_name: the last component, unless the path ends in ".." or has none
fn main_path_file_name(p: str) -> Opt[str] {
    t := main_path_trim(p)
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

// Path::parent: the path without its last component
fn main_path_parent(p: str) -> Opt[str] {
    t := main_path_trim(p)
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

// Path::file_stem: the file name without its last extension
fn main_path_file_stem(p: str) -> Opt[str] {
    match main_path_file_name(p) {
        Some(name) => {
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
        None => {}
    }
    return None
}

// std::fs::canonicalize, as far as the driver needs it (to recognise a file that is included
// twice): the absolute path with "." and ".." resolved textually; symbolic links are kept
fn main_canonical(path: str) -> str {
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

// the text of std::io::Error for an errno
fn main_os_error(errno: i64) -> str {
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

// std::fs::read_to_string: (text, error); the error text is empty on success
fn main_read_to_string(path: str) -> (str, str) {
    // read_file does not say why it failed: look at the file first
    fd := syscall(2, cstr(path), 0, 0)
    if fd < 0 {
        return ("", main_os_error(-fd))
    }
    probe: [1]u8
    r := syscall(0, fd, ptr(probe), 0)
    syscall(3, fd)
    if r < 0 && r != -4 {
        return ("", main_os_error(-r))
    }
    text, ok := read_file(path)
    if !ok {
        return ("", main_os_error(5))
    }
    return (text, "")
}

fn main_std_text(name: str) -> Opt[str] {
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
        t, err := main_read_to_string(main_path_join(dir, fmt(name, ".al")))
        if len(err) == 0 {
            return Some(t)
        }
    }
    return Some(STD_MODULES[mi].1)
}

struct Args {
    cmd: str
    input: str
    output: Opt[str]
    emit_ir: bool
    emit_asm: bool
    unchecked: bool
    opt: i64
    rest: Vec[str]
}

fn main_usage() -> never {
    eprint(concat("usage: alc <command> <file.al> [options]\n",
        concat("commands:\n  build   compile to a static x86-64 Linux executable\n  run     build and run (arguments after `--` are passed on)\n  test    build and run all `test` blocks\n  check   type-check only\n  sigs    list the declarations of a file (`alc sigs f.al -- std` adds the standard library)\n",
        "options:\n  -o <path>     output path (default: input without .al)\n  --unchecked   disable bounds/division checks\n  -O0           disable optimizations\n  --json        print diagnostics as a JSON array on stdout\n  --emit-ir     print optimized IR to stdout\n  --emit-asm    print the selected machine code to stdout\n")))
    exit(2)
}

fn main_parse_args() -> Args {
    all := args()
    av := vec[str]()
    for i in 1..len(all) {
        av.push(all[i])
    }
    if av.len < 2 {
        main_usage()
    }
    a := Args{cmd: av[0], input: "", output: None, emit_ir: false, emit_asm: false, unchecked: false, opt: 2, rest: vec[str]()}
    i := 1
    while i < av.len {
        s := av[i]
        if s == "-o" {
            i += 1
            if i >= av.len {
                main_usage()
            }
            a.output = Some(av[i])
        } else if s == "--json" {
            main_json = true
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
            eprint(fmt("unknown option ", s, "\n"))
            main_usage()
        } else {
            if len(a.input) == 0 {
                a.input = s
            } else {
                eprint(fmt("unexpected argument ", s, "\n"))
                main_usage()
            }
        }
        i += 1
    }
    if len(a.input) == 0 {
        main_usage()
    }
    return a
}

struct Sources {
    names: Vec[str]
    decls: Vec[Decl]
    errs: Vec[Diag]
    seen: Map[str, bool]
    std_files: Vec[i64]
}

fn add_text(self: *Sources, name: str, text: str, dir: Opt[str]) {
    file := self.names.len
    self.names.push(name)
    toks := lexer_lex(text, file, &self.errs)
    p := parser_new(toks, &self.errs)
    decls := p.file()
    priv_apply(&decls, file, &self.errs)
    for di in 0..decls.len {
        d := decls[di]
        match d {
            DeclUse(path, pos) => {
                if starts_with(path, "std:") {
                    mname := path[4..]
                    match main_std_text(mname) {
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
                    Some(dr) => main_path_join(dr, path)
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

fn add_file(self: *Sources, path: str, from: Opt[Pos]) {
    // canonicalize fails for a file that does not exist: the path is then used as it is
    canon := path
    if syscall(21, cstr(path), 0) == 0 {
        canon = main_canonical(path)
    }
    if self.seen.has(canon) {
        return
    }
    self.seen.set(canon, true)
    text, err := main_read_to_string(path)
    if len(err) == 0 {
        self.add_text(path, text, main_path_parent(path))
    } else {
        msg := fmt("cannot read `", path, "`: ", err)
        match from {
            Some(pos) => self.errs.push(Diag{pos: pos, msg: msg})
            None => {
                eprint(fmt("error: ", msg, "\n"))
                exit(1)
            }
        }
    }
}

main_json: bool

fn main_json_str(s: str) -> str {
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
fn main_report_less(a: Diag, b: Diag) -> bool {
    if a.pos.file != b.pos.file {
        return a.pos.file < b.pos.file
    }
    if a.pos.line != b.pos.line {
        return a.pos.line < b.pos.line
    }
    return a.pos.col < b.pos.col
}

// names.get(file) or "?"
fn main_file_name(names: *Vec[str], file: i64) -> str {
    if file >= 0 && file < names.len {
        return names[file]
    }
    return "?"
}

fn main_report(names: *Vec[str], errs: *Vec[Diag]) -> bool {
    if errs.is_empty() {
        return false
    }
    sort_by(errs.items(), main_report_less)
    if main_json {
        // machine-readable diagnostics: one JSON array on stdout
        items := vec[str]()
        last := ""
        for d in errs.items() {
            file := main_file_name(names, d.pos.file)
            item := fmt("{\"file\":", main_json_str(file), ",\"line\":", d.pos.line, ",\"col\":", d.pos.col, ",\"message\":", main_json_str(ast_plain_text(d.msg)), "}")
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
    for d in errs.items() {
        line := fmt(main_file_name(names, d.pos.file), ":", d.pos.line, ":", d.pos.col, ": error: ", ast_plain_text(d.msg))
        if line != last {
            eprint(fmt(line, "\n"))
            n += 1
            last = line
        }
    }
    eprint(fmt(n, " error(s)\n"))
    return true
}

// "priv " in front of the signature of a private declaration
fn main_sigs_priv(name: str) -> str {
    if ast_is_private(name) {
        return "priv "
    }
    return ""
}

// `alc sigs`: one line per declaration, for a quick overview of a file
fn main_print_sigs(names: *Vec[str], decls: []Decl, from_file: i64) {
    for d in decls {
        pos: Pos
        text := ""
        match d {
            DeclFn(f) => {
                pos = f.pos
                text = fmt(main_sigs_priv(f.name), ast_sig_str(&f))
            }
            DeclStruct(s) => {
                pos = s.pos
                text = fmt(main_sigs_priv(s.name), ast_struct_str(&s))
            }
            DeclEnum(e) => {
                pos = e.pos
                text = fmt(main_sigs_priv(e.name), ast_enum_str(&e))
            }
            // (the value of a constant or a global is not shown: `...`)
            DeclConst(c) => {
                pos = c.pos
                text = match c.ty {
                    Some(ty) => fmt(main_sigs_priv(c.name), "const ", c.name, ": ", ast_type_str(&ty), " = ...")
                    None => fmt(main_sigs_priv(c.name), "const ", c.name, " = ...")
                }
            }
            DeclGlobal(g) => {
                pos = g.pos
                text = match g.ty {
                    Some(ty) => fmt(main_sigs_priv(g.name), g.name, ": ", ast_type_str(&ty))
                    None => fmt(main_sigs_priv(g.name), g.name, " := ...")
                }
            }
            DeclTest(t) => {
                pos = t.pos
                text = fmt("test \"", t.name, "\"")
            }
            DeclUse(path, upos) => {
                continue
            }
            DeclType(t) => {
                pos = t.pos
                text = fmt(main_sigs_priv(t.name), "type ", t.name, " = ", ast_type_str(&t.ty))
            }
        }
        if pos.file < from_file {
            continue
        }
        print(fmt(main_file_name(names, pos.file), ":", pos.line, ": ", ast_plain_text(text)))
    }
}

// is a declaration shown by `alc sigs <file> -- std`?
fn main_sigs_visible(d: *Decl) -> bool {
    match *d {
        DeclFn(f) => {
            return !starts_with(f.name, "__")
        }
        DeclGlobal(g) => {
            return !starts_with(g.name, "__")
        }
        _ => {}
    }
    return true
}

fn main_real_main() -> i64 {
    ar := main_parse_args()
    test_mode := ar.cmd == "test"
    if !(ar.cmd == "build" || ar.cmd == "run" || ar.cmd == "test" || ar.cmd == "check" || ar.cmd == "sigs") {
        main_usage()
    }
    src := Sources{names: vec[str](), decls: vec[Decl](), errs: vec[Diag](), seen: map[str, bool](), std_files: vec[i64]()}
    src.add_text("<prelude>", PRELUDE, None)
    // the core library is part of the language: always present, no `use` needed
    for name in CORE_MODULES {
        text := match main_std_text(name) {
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
        if main_report(&src.names, &src.errs) {
            return 1
        }
        from := if contains(&ar.rest, "std") { 0 } else { n_prelude }
        sdecls := vec[Decl]()
        if from == 0 {
            for x in 0..src.decls.len {
                // private declarations of the library cannot be used from outside
                info := priv_decl_info(&src.decls[x])
                lib_private := info.2 && (info.3.file < n_prelude || contains(&src.std_files, info.3.file))
                if main_sigs_visible(&src.decls[x]) && !lib_private {
                    sdecls.push(src.decls[x])
                }
            }
        } else {
            sdecls = clone(src.decls)
        }
        main_print_sigs(&src.names, sdecls.items(), from)
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
            DeclTest(t) => {
                fname := fmt("__test_", tests.len)
                tests.push(t.name)
                decls.push(DeclFn(FnDecl{name: fname, tparams: vec[str](), params: vec[(str, TypeAst)](), ret: None, body: t.body, pos: t.pos, inl: -1, ext: None}))
            }
            DeclFn(f) => {
                if f.name == "main" {
                    has_main = true
                    main_ret = is_some(f.ret)
                }
                decls.push(DeclFn(f))
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
    if main_report(&src.names, &src.errs) {
        return 1
    }
    main_mem("parsed")
    cx := cx_new(decls.items(), clone(src.names), Opts{checks: !ar.unchecked}, n_prelude)
    if ar.cmd != "check" {
        // bundled modules are only compiled as far as the program reaches into them
        for f in src.std_files.items() {
            cx.lazy_files.set(f, true)
        }
    }
    lower_fn_lower_all(&cx, "__entry", n_prelude)
    if main_report(&src.names, &cx.errs) {
        return 1
    }
    if ar.cmd == "check" {
        return 0
    }
    module := cx.module
    main_mem("lowered")
    opt_optimize(&module, ar.opt)
    main_mem("optimized")
    if ar.emit_ir {
        for fi in 0..module.funcs.len {
            if module.funcs[fi].lowered {
                put(ir_print_func(&module.funcs[fi], Some(&module)))
            }
        }
    }
    out := x86_compile(&module, ar.emit_asm)
    main_mem("compiled")
    bytes, link_err := elf_link(&module, &out)
    if len(link_err) != 0 {
        eprint(fmt("error: ", link_err, "\n"))
        return 1
    }
    out_path := ""
    match ar.output {
        Some(op) => {
            out_path = op
        }
        None => {
            stem := match main_path_file_stem(ar.input) {
                Some(s) => s
                None => "a.out"
            }
            dir := match main_path_parent(ar.input) {
                Some(dr) => dr
                None => ""
            }
            cand := main_path_join(dir, stem)
            if main_path_comps(cand).items() == main_path_comps(ar.input).items() {
                out_path = fmt(cand, ".out")
            } else {
                out_path = cand
            }
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
        eprint(fmt("error: cannot write `", out_path, "`: ", main_os_error(errno), "\n"))
        return 1
    }
    make_executable(out_path)
    if ar.cmd == "run" || ar.cmd == "test" {
        code := run_program(out_path, ar.rest.items())
        if code < 0 {
            eprint(fmt("error: cannot run `", out_path, "`: ", main_os_error(11), "\n"))
            return 1
        }
        return code
    }
    return 0
}

fn main() -> i64 {
    // deep recursion in the frontend and SSA construction: use a big stack
    ensure_stack(1 << 30)
    main_t0 = clock_ns()
    main_load_embedded()
    return main_real_main()
}

main_t0: i64

// ALC_DEBUG=mem: memory in use and time since the start after each phase, and the largest
// size of the work heap
fn main_mem(phase: str) {
    v, found := env_get("ALC_DEBUG")
    if found && v == "mem" {
        eprint(fmt("[mem] ", phase, ": ", mem_used() >> 20, " MB, work heap peak ", work_peak() >> 20, " MB, ", (clock_ns() - main_t0) / 1000000, " ms\n"))
    }
}
