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
use "opt/spec.al"
use "opt/tre.al"
use "opt/unroll.al"
use "x86/mir.al"
use "x86/isel.al"
use "x86/regalloc.al"
use "x86/emit.al"
use "x86/mod.al"
use "elf.al"
use "pe.al"
use "backtrace.al"
use "priv.al"
use "lower_mem.al"
use "when.al"

priv const PRELUDE = embed("prelude.al")
// the OS layer of the run-time library, compiled right after the prelude (see the top of
// prelude.al)
priv const PRELUDE_LINUX = embed("prelude_linux.al")
priv const PRELUDE_WINDOWS = embed("prelude_windows.al")

// bundled modules that only exist for Linux: what a program built for Windows can use instead
priv const LINUX_ONLY = [_](str, str){
    ("libc", "declare the functions of a Windows library with `extern \"x.dll\" fn`"),
    ("x11", ""),
    ("wayland", ""),
    ("alsa", ""),
    ("vk", ""),
    ("shaderc", ""),
}

// the operating system the executable is built for (`--target linux|windows`); the default
// is the one the compiler runs on (parse_args). Read by the back end (calling convention,
// frames), the linker (ELF or PE) and wherever the run-time library is chosen.
enum TargetOs { TargetLinux, TargetWindows }

target_os: TargetOs
// `--gui` (Windows only): the PE gets the GUI subsystem instead of the console one (pe_link)
pe_gui: bool

// modules bundled with the compiler: `use std.<name>`
// (during development, ALC_STD_DIR=<dir> reads `<dir>/<name>.al` instead of the built-in copy).
// A module with parts that differ per OS keeps them in `<name>_linux` / `<name>_windows`
// modules, which it includes with `when TARGET_OS == ... { use std.<name>_... }`.
priv const STD_MODULES = [_](str, str){
    ("math", embed("../std/math.al")),
    ("rand", embed("../std/rand.al")),
    ("time", embed("../std/time.al")),
    ("mem", embed("../std/mem.al")),
    ("libc", embed("../std/libc.al")),
    ("asset", embed("../std/asset.al")),
    ("os", embed("../std/os.al")),
    ("image", embed("../std/image.al")),
    ("x11", embed("../std/x11.al")),
    ("wayland", embed("../std/wayland.al")),
    ("alsa", embed("../std/alsa.al")),
    ("window", embed("../std/window.al")),
    ("window_linux", embed("../std/window_linux.al")),
    ("window_windows", embed("../std/window_windows.al")),
    ("input", embed("../std/input.al")),
    ("input_linux", embed("../std/input_linux.al")),
    ("input_windows", embed("../std/input_windows.al")),
    ("audio", embed("../std/audio.al")),
    ("audio_linux", embed("../std/audio_linux.al")),
    ("audio_windows", embed("../std/audio_windows.al")),
    ("vk", embed("../std/vk.al")),
    ("shaderc", embed("../std/shaderc.al")),
    ("dx12", embed("../std/dx12.al")),
    ("dx12_util", embed("../std/dx12_util.al")),
    ("metal", embed("../std/metal.al")),
}

// modules that are loaded into every program
priv const CORE_MODULES = [4]str{"math", "rand", "time", "mem"}

// ---------- paths ----------
// Paths are taken as written: components are separated by `/` (on Windows also `\`), and the
// compiler joins them with `/`. host_root (src/base.al) is the length of a root ("/"; on
// Windows also "C:\", "C:", "\\server\share\"); path_join, path_trim and path_parent are there
// too (lowering resolves `embed` paths with them).

// the components of a path as far as comparing paths goes: the root is a component, empty
// components and "." are dropped, except a "." at the start of a relative path
priv fn path_comps(p: str) -> Vec[str] {
    out := vec[str]()
    root := host_root(p)
    if root > 0 {
        out.push(p[..root])
    }
    first := true
    start := root
    for i in root..len(p) + 1 {
        if i < len(p) && !host_sep(p[i]) {
            continue
        }
        c := p[start..i]
        start = i + 1
        if len(c) == 0 {
            continue
        }
        if c == "." && !(first && root == 0) {
            first = false
            continue
        }
        first = false
        out.push(c)
    }
    return out
}

// the last component, unless the path ends in ".." or has none
priv fn path_file_name(p: str) -> Opt[str] {
    t := path_trim(p)
    root := host_root(t)
    k := len(t)
    while k > root && !host_sep(t[k - 1]) {
        k -= 1
    }
    name := t[k..]
    if len(name) == 0 || name == ".." || name == "." {
        return None
    }
    return Some(name)
}

// the file name without its last extension
priv fn path_file_stem(p: str) -> Opt[str] {
    name := match path_file_name(p) {
        Some(n) => n
        None => return None
    }
    k := rfind(name, ".")
    if k <= 0 {
        // no dot, or only a leading one
        return Some(name)
    }
    return Some(name[..k])
}

// the path has a separator
priv fn has_sep(p: str) -> bool {
    for c in p {
        if host_sep(c) {
            return true
        }
    }
    return false
}

// both paths name the same existing file (also through links)
priv fn same_file(a: str, b: str) -> bool {
    ia, oka := file_id(a)
    ib, okb := file_id(b)
    return oka && okb && ia == ib
}

// the content of a file: (text, error); the error text is empty on success
priv fn read_to_string(path: str) -> (str, str) {
    text, ok := read_file(path)
    if !ok {
        return ("", os_error(io_error()))
    }
    return (text, "")
}

priv fn std_text(name: str) -> Opt[str] {
    for m in STD_MODULES {
        if m.0 != name {
            continue
        }
        dir, have_dir := env_get("ALC_STD_DIR")
        if have_dir {
            t, err := read_to_string(path_join(dir, fmt(name, ".al")))
            if len(err) == 0 {
                return Some(t)
            }
        }
        return Some(m.1)
    }
    return None
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
    // -D NAME=VALUE: (name, value, `=VALUE` given)
    defs: Vec[(str, str, bool)]
    // `alc check --all-targets`: once per target
    all_targets: bool
    target_set: bool
}

// an error of the driver itself (no position): with --json the same array as diagnostics,
// with line and col 0
priv fn driver_error(file: str, msg: str) {
    if json {
        print(fmt("[{\"file\":", json_str(file), ",\"line\":0,\"col\":0,\"message\":", json_str(msg), "}]"))
    } else {
        eput(fmt("error: ", msg, "\n"))
    }
}

// `why` (empty: the command line is incomplete) and the usage; exit status 2
priv fn usage(why: str) -> never {
    if json {
        driver_error("", if len(why) == 0 { "usage: alc <command> <file.al> [options]" } else { why })
        exit(2)
    }
    if len(why) != 0 {
        eput(fmt(why, "\n"))
    }
    eput(concat("usage: alc <command> <file.al> [options]\n",
        concat("commands:\n  build   compile to a static x86-64 executable (Linux ELF, or Windows PE with --target windows)\n  run     build and run (arguments after `--` are passed on)\n  test    build and run all `test` blocks\n  check   type-check only\n  sigs    list the declarations of a file (`alc sigs f.al -- std` adds the standard library)\n",
        "options:\n  -o <path>     output path (default: input without .al; with .exe for windows)\n  --target <os> linux or windows (default: the system alc runs on)\n  --all-targets check: type-check once for every target\n  -D NAME=VALUE set the program's constant NAME (-D NAME: a bool constant set to true)\n  --gui         windows: a GUI program (no console window of its own)\n  --unchecked   disable bounds/division checks\n  -O0           disable optimizations\n  --json        print diagnostics as a JSON array on stdout\n  --emit-ir     print optimized IR to stdout\n  --emit-asm    print the selected machine code to stdout\n")))
    exit(2)
}

// `-D NAME=VALUE` / `-D NAME` (the text after -D)
priv fn parse_define(a: *Args, s: str) {
    eq := find(s, "=")
    name := if eq < 0 { s } else { s[..eq] }
    ok := len(name) > 0 && !is_digit(name[0])
    for c in name {
        if !is_alnum(c) && c != '_' {
            ok = false
        }
    }
    if !ok {
        usage(fmt("-D needs the name of a constant: -D NAME=VALUE, not -D ", s))
    }
    for d in a.defs {
        if d.0 == name {
            usage(fmt("-D ", name, " is given twice"))
        }
    }
    a.defs.push((name, if eq < 0 { "" } else { s[eq + 1..] }, eq >= 0))
}

priv fn parse_args() -> Args {
    all := args()
    av := vec[str]()
    for i in 1..len(all) {
        av.push(all[i])
    }
    // --json first: it also decides how errors in the command line are written
    for k, s in av {
        if s == "--" {
            break
        }
        if s == "--json" && !(k > 0 && av[k - 1] == "-o") {
            json = true
        }
    }
    if av.len < 2 {
        usage("")
    }
    // the default target is the system the compiler runs on
    if TARGET_OS == Windows {
        target_os = TargetWindows
    }
    a := Args{cmd: av[0], opt: 2}
    i := 1
    while i < av.len {
        s := av[i]
        match s {
            "-o" => {
                i += 1
                if i >= av.len {
                    usage("-o needs a path")
                }
                a.output = Some(av[i])
            }
            "--target" => {
                i += 1
                if i >= av.len {
                    usage("--target needs an operating system: linux or windows")
                }
                a.target_set = true
                match av[i] {
                    "linux" => target_os = TargetLinux
                    "windows" => target_os = TargetWindows
                    _ => usage(fmt("unknown target ", av[i], " (linux or windows)"))
                }
            }
            "--json" => json = true
            "--gui" => pe_gui = true
            "--emit-ir" => a.emit_ir = true
            "--emit-asm" => a.emit_asm = true
            "--unchecked" => a.unchecked = true
            "-O0" => a.opt = 0
            "-D" => {
                i += 1
                if i >= av.len {
                    usage("-D needs a constant: -D NAME=VALUE")
                }
                a.parse_define(av[i])
            }
            _ if starts_with(s, "-D") => a.parse_define(s[2..])
            "--all-targets" => a.all_targets = true
            "-O1" => a.opt = 1
            "-O2" => a.opt = 2
            "--" => {
                a.rest = vec_of(av[i + 1..av.len])
                break
            }
            _ if starts_with(s, "-") => usage(fmt("unknown option ", s))
            _ if len(a.input) == 0 => a.input = s
            _ => usage(fmt("unexpected argument ", s))
        }
        i += 1
    }
    if len(a.input) == 0 {
        usage("")
    }
    if pe_gui && target_os != TargetWindows {
        usage("--gui is for Windows executables: add --target windows")
    }
    if a.all_targets && (a.cmd != "check" || a.target_set) {
        usage("--all-targets is an option of `alc check`, which then checks every target (without --target)")
    }
    return a
}

// what a file contributes, in order: declarations, the files it includes first, and (in
// files of the program) `when`s that wait to be decided (see src/when.al)
priv enum Item {
    D(Decl),
    Inc(i64),
    Wait(WhenDecl),
}

priv struct SrcFile {
    items: Vec[Item]
    dir: Opt[str]
    // a file of the library (prelude, OS layer, bundled module): its `when`s are decided as
    // soon as it is parsed, with the library's constants
    lib: bool
    // its declarations outside `when` (what conditions can use: when_register)
    top: Vec[Decl]
    // it has the keyword `when` / an item `Wait`
    has_when: bool
    waiting: bool
}

priv struct Sources {
    names: Vec[str]
    files: Vec[SrcFile]
    decls: Vec[Decl]
    errs: Vec[Diag]
    seen: Map[str, bool]
    std_files: Vec[i64]
    wc: WhenCx
    // the files whose declarations the `when` conditions know (when_register): 0..registered
    registered: i64
    // the `when`s of the program decided while files were still being loaded: (the `when`,
    // file, branch), checked again at the end
    decided: Vec[(WhenDecl, i64, i64)]
    // the names of the `test` blocks: the function `__test_k` is test k (see program)
    tests: Vec[str]
}

// file `file` gets the declarations in `decls` (a file, or the taken branch of one of its
// `when`s), in order: `use` includes a file, a `when` of the library is decided at once
priv fn process(self: *Sources, file: i64, decls: *Vec[Decl], out: *Vec[Item]) {
    for di in 0..decls.len {
        d := decls[di]
        match d {
            Use(path, pos) => self.use_file(file, path, pos, out)
            When(wd) => {
                if self.files[file].lib {
                    self.register_all()
                    k := when_decide(&self.wc, &wd, file, true, true, &self.errs)
                    if k >= 0 {
                        self.process(file, &wd.arms[k].decls, out)
                    }
                } else {
                    out.push(Wait(wd))
                    self.files[file].waiting = true
                }
            }
            _ => out.push(D(d))
        }
    }
}

// the declarations of every file loaded so far become known to `when` conditions
priv fn register_all(self: *Sources) {
    while self.registered < self.files.len {
        f := self.registered
        when_register(&self.wc, &self.files[f].top, f, self.files[f].lib)
        self.registered += 1
    }
}

// a source file, of the library (`lib`) or of the program; its index
priv fn add_text(self: *Sources, name: str, text: str, dir: Opt[str], lib: bool) -> i64 {
    file := self.names.len
    self.names.push(name)
    toks := lexer_lex(text, file, &self.errs)
    has_when := false
    for t in toks {
        if t.t == Kw(KW_WHEN) {
            has_when = true
            break
        }
    }
    p := parser_new(toks, &self.errs)
    decls := p.file()
    self.files.push(SrcFile{items: vec[Item](), dir: dir, lib: lib, top: decls, has_when: has_when, waiting: false})
    items := vec[Item]()
    self.process(file, &decls, &items)
    self.files[file].items = items
    return file
}

// `use path` in file `file`: a file included for the first time becomes the item Inc
priv fn use_file(self: *Sources, file: i64, path: str, pos: Pos, out: *Vec[Item]) {
    dir := self.files[file].dir
    if starts_with(path, "std:") {
        mname := path[4..]
        // (once, where the program asks for it: not again for the modules it uses)
        if target_os == TargetWindows && is_some(dir) {
            for lo in LINUX_ONLY {
                if lo.0 == mname {
                    more := if len(lo.1) == 0 { "" } else { fmt("; ", lo.1) }
                    self.errs.push(Diag{pos: pos, msg: fmt("module `std.", mname, "` is not available for --target windows (it uses Linux system interfaces)", more)})
                }
            }
        }
        match std_text(mname) {
            Some(mtext) => {
                key := fmt("<std/", mname, ".al>")
                if !self.seen.has(key) {
                    self.seen.set(key, true)
                    self.std_files.push(self.names.len)
                    out.push(Inc(self.add_text(key, mtext, None, true)))
                }
            }
            None => {
                all := vec[str]()
                for m in STD_MODULES {
                    all.push(m.0)
                }
                self.errs.push(Diag{pos: pos, msg: fmt("unknown module `std.", mname, "` (available: ", join(all.items(), ", "), ")")})
            }
        }
        return
    }
    fp := match dir {
        Some(dr) => path_join(dr, path)
        None => path
    }
    k := self.add_file(fp, Some(pos))
    if k >= 0 {
        out.push(Inc(k))
    }
}

// a file of the program; its index, or -1 if it was included before or cannot be read
priv fn add_file(self: *Sources, path: str, from: Opt[Pos]) -> i64 {
    // a file is recognised by its identity, also through symbolic and hard links; one that
    // does not exist by its path (reading it fails below)
    key, exists := file_id(path)
    if !exists {
        key = concat("path:", path)
    }
    if self.seen.has(key) {
        return -1
    }
    self.seen.set(key, true)
    text, err := read_to_string(path)
    if len(err) == 0 && find(text, "\x00") >= 0 {
        // an executable or other binary file: one error instead of one per byte
        err = "not a source file (it contains NUL bytes)"
    }
    if len(err) == 0 {
        return self.add_text(path, text, path_parent(path), false)
    }
    msg := fmt("cannot read `", path, "`: ", err)
    match from {
        Some(pos) => self.errs.push(Diag{pos: pos, msg: msg})
        None => {
            driver_error(path, msg)
            exit(1)
        }
    }
    return -1
}

// Decides the `when`s of the program's files: in rounds, as long as a round decides one (a
// taken branch may include files with more of them); then the ones whose names are still
// unknown are errors. Each decision is checked again with all files loaded.
priv fn settle(self: *Sources) {
    final_pass := false
    loop {
        progress := false
        for f in 0..self.files.len {
            if !self.files[f].waiting {
                continue
            }
            self.files[f].waiting = false
            self.register_all()
            out := vec[Item]()
            for it in self.files[f].items {
                match it {
                    Wait(wd) => {
                        k := when_decide(&self.wc, &wd, f, false, final_pass, &self.errs)
                        if k == -2 {
                            out.push(it)
                            self.files[f].waiting = true
                            continue
                        }
                        progress = true
                        if !final_pass {
                            self.decided.push((wd, f, k))
                        }
                        if k >= 0 {
                            self.process(f, &wd.arms[k].decls, &out)
                        }
                    }
                    _ => out.push(it)
                }
            }
            self.files[f].items = out
        }
        if progress {
            final_pass = false
        } else if final_pass {
            break
        } else {
            final_pass = true
        }
    }
    if self.decided.is_empty() {
        return
    }
    // all files are loaded: the same decisions again, from scratch
    self.register_all()
    when_forget(&self.wc)
    for x in self.decided {
        scratch := vec[Diag]()
        wd := x.0
        if when_decide(&self.wc, &wd, x.1, false, true, &scratch) != x.2 {
            self.errs.push(Diag{pos: wd.pos, msg: "this `when` was decided before all files were included, and a file included later changes a constant of its condition (a constant of the program that hides one of the library): give that constant another name"})
        }
    }
}

// After loading: the `when`s in function bodies are decided, -D values are given to the
// program's constants, private names are renamed (priv.al), and the declarations of all
// files are put in order, each included file where it is first included.
priv fn finish(self: *Sources) {
    self.settle()
    if self.wc.defs.len != 0 {
        self.register_all()
    }
    included := vec_fill(self.files.len, false)
    for f in 0..self.files.len {
        decls := vec[Decl]()
        for it in self.files[f].items {
            match it {
                D(d) => decls.push(d)
                Inc(k) => {
                    included[k] = true
                }
                Wait(_) => {}
            }
        }
        lib := self.files[f].lib
        if self.files[f].has_when {
            self.register_all()
            when_stmts(&self.wc, &decls, f, lib, &self.errs)
        }
        if !lib {
            when_apply_defs(&self.wc, &decls, f, &self.errs)
        }
        priv_apply(&decls, f, &self.errs)
        k := 0
        items := self.files[f].items
        for i in 0..items.len {
            match items[i] {
                D(_) => {
                    items[i] = D(decls[k])
                    k += 1
                }
                _ => {}
            }
        }
    }
    when_unused_defs(&self.wc, &self.errs)
    for f in 0..self.files.len {
        if !included[f] {
            self.flatten(f)
        }
    }
}

priv fn flatten(self: *Sources, f: i64) {
    for it in self.files[f].items {
        match it {
            D(d) => self.decls.push(d)
            Inc(k) => self.flatten(k)
            Wait(_) => {}
        }
    }
}

priv json: bool

priv fn json_str(s: str) -> str {
    o := vec[u8]()
    o.push('"')
    for c in s {
        match c {
            '"' => o.extend("\\\"")
            '\\' => o.extend("\\\\")
            '\n' => o.extend("\\n")
            _ if c < 0x20 => o.extend(concat("\\u", hex(u64(c), 4)))
            _ => o.push(c)
        }
    }
    o.push('"')
    return o.items()
}

priv fn report(names: *Vec[str], errs: *Vec[Diag]) -> bool {
    if errs.is_empty() {
        return false
    }
    // sorted by (file, line, col)
    sort_by(errs.items(), fn(a: Diag, b: Diag) -> bool {
        if a.pos.file != b.pos.file {
            return a.pos.file < b.pos.file
        }
        if a.pos.line != b.pos.line {
            return a.pos.line < b.pos.line
        }
        a.pos.col < b.pos.col
    })
    // an error in the generated entry (the last file) follows from one in the program (a
    // second declaration named `main`)
    while errs.len > 1 && file_name(names, errs.last().pos.file) == "<entry>" && file_name(names, errs[0].pos.file) != "<entry>" {
        errs.pop()
    }
    if json {
        // machine-readable diagnostics: one JSON array on stdout
        items := vec[str]()
        last := ""
        for d in errs {
            file := if d.pos.file < 0 { "" } else { file_name(names, d.pos.file) }
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
        // (file -1: the command line)
        line := if d.pos.file < 0 { fmt("error: ", ast_plain_text(d.msg)) } else { fmt(file_name(names, d.pos.file), ":", d.pos.line, ":", d.pos.col, ": error: ", ast_plain_text(d.msg)) }
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

// `extern "lib" ` in front of the signature of a C function or variable
priv fn sigs_extern(ext: Opt[str]) -> str {
    return match ext {
        Some(lib) => fmt("extern \"", lib, "\" ")
        None => ""
    }
}

// `alc sigs`: one line per declaration, for a quick overview of a file
priv fn print_sigs(names: *Vec[str], decls: []Decl, from_file: i64) {
    for d in decls {
        pos, text := match d {
            Fn(f) => (f.pos, fmt(sigs_priv(f.name), sigs_extern(f.ext), ast_sig_str(&f)))
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
            Global(g) => {
                sig := match g.ty {
                    Some(ty) => fmt(sigs_priv(g.name), sigs_extern(g.ext), g.name, ": ", ast_type_str(&ty))
                    None => fmt(sigs_priv(g.name), g.name, " := ...")
                }
                (g.pos, sig)
            }
            Test(t) => (t.pos, fmt("test \"", t.name, "\""))
            Use(_, _), When(_) => continue
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
        Global(g) => !starts_with(g.name, "__")
        _ => true
    }
}

// The files of the program for the target in `target_os`: the run-time library, the core
// modules, the input file and what they include; `when`s decided (finish). The index of the
// first file of the program is the second result.
priv fn load(ar: *Args) -> (Sources, i64) {
    src := Sources{}
    for d in ar.defs {
        when_define(&src.wc, d.0, d.1, d.2)
    }
    // the run-time library: the prelude and the OS layer of the target. ALC_PRELUDE=<file>
    // (development) reads the prelude from that file instead of the copy inside the compiler,
    // and the layer from prelude_linux.al / prelude_windows.al next to it; without one there
    // the file is the whole library (ALC_PRELUDE=src/prelude.al tests the sources as they are).
    // The layer declares TARGET_OS, which `when` conditions use.
    prelude := PRELUDE
    layer_name, layer := if target_os == TargetWindows { ("prelude_windows.al", PRELUDE_WINDOWS) } else { ("prelude_linux.al", PRELUDE_LINUX) }
    pre_path, pre_set := env_get("ALC_PRELUDE")
    if pre_set {
        t, err := read_to_string(pre_path)
        if len(err) != 0 {
            driver_error(pre_path, fmt("cannot read `", pre_path, "`: ", err))
            exit(1)
        }
        prelude = t
        lpath := match path_parent(pre_path) {
            Some(d) => path_join(d, layer_name)
            None => layer_name
        }
        // (a file without a layer next to it is the whole run-time library)
        lt, lerr := read_to_string(lpath)
        layer = if len(lerr) == 0 { lt } else { "" }
    }
    src.add_text("<prelude>", prelude, None, true)
    src.add_text(fmt("<", layer_name[..len(layer_name) - 3], ">"), layer, None, true)
    // the core library is part of the language: always present, no `use` needed
    for name in CORE_MODULES {
        text := std_text(name).or("")
        src.seen.set(fmt("<std/", name, ".al>"), true)
        src.add_text(fmt("<std/", name, ".al>"), text, None, true)
    }
    n_prelude := src.names.len
    src.add_file(ar.input, None)
    src.finish()
    return (src, n_prelude)
}

// The declarations to compile: tests become functions, and the entry point `__entry` is
// generated (in the file "<entry>")
priv fn program(src: *Sources, n_prelude: i64, test_mode: bool) -> Vec[Decl] {
    tests := vec[str]()
    main_ret := false
    has_main := false
    has_c := false
    has_bt_c := false
    decls := vec[Decl]()
    taken := src.decls
    src.decls = vec[Decl]()
    for d in taken {
        match d {
            Test(t) => {
                fname := fmt("__test_", tests.len)
                tests.push(t.name)
                decls.push(Fn(FnDecl{name: fname, body: t.body, pos: t.pos, inl: -1}))
            }
            Fn(f) => {
                if f.name == "main" {
                    has_main = true
                    // `exit(main())` / `main()` in the entry: anything else would be reported
                    // there, in generated code
                    rt := match f.ret {
                        Some(t) => ast_type_str(&t)
                        None => ""
                    }
                    main_ret = rt == "i64"
                    if !test_mode && (!f.params.is_empty() || !f.tparams.is_empty() || !(rt == "" || rt == "i64" || rt == "never") || is_some(f.ext)) {
                        note := if f.params.is_empty() { "" } else { ": the command line is `args()`" }
                        src.errs.push(Diag{pos: f.pos, msg: fmt("`main` is declared `fn main()` or `fn main() -> i64` (the exit status), not `", ast_sig_str(&f), "`", note)})
                    }
                }
                has_c = has_c || is_some(f.ext)
                has_bt_c = has_bt_c || f.name == "__bt_c_init"
                decls.push(Fn(f))
            }
            _ => {
                decls.push(d)
            }
        }
    }
    entry := vec[str]()
    entry.push("fn __entry(sp: i64) -> never {\n __rt_init(sp)\n")
    if has_c && has_bt_c {
        // (stack traces through C code: only a program that declares C functions has them; a
        // run-time library of ALC_PRELUDE may lack them)
        entry.push(" __bt_c_init()\n")
    }
    if test_mode {
        for i, name in tests {
            // as a string literal of the entry source: every byte that cannot stand there as it is
            // becomes a \x escape
            esc := vec[u8]()
            for c in name {
                if c == '"' || c == '\\' || c < 0x20 || c == 0x7F {
                    esc.extend(concat("\\x", hex(u64(c), 2)))
                } else {
                    esc.push(c)
                }
            }
            entry.push(fmt(" __run_test(\"", esc.items(), "\", __test_", i, ")\n"))
        }
        entry.push(" exit(__tests_done())\n}\n")
    } else if !has_main {
        // (after a syntax error main may just not have been parsed)
        if src.errs.is_empty() {
            src.errs.push(Diag{pos: Pos{file: n_prelude, line: 1, col: 1}, msg: "missing `fn main() { ... }`, the function where the program starts"})
        }
        entry.push(" exit(0)\n}\n")
    } else if main_ret {
        entry.push(" exit(main())\n}\n")
    } else {
        entry.push(" main()\n exit(0)\n}\n")
    }
    file := src.names.len
    src.names.push("<entry>")
    toks := lexer_lex(join(entry.items(), ""), file, &src.errs)
    p := parser_new(toks, &src.errs)
    more := p.file()
    decls.extend(more.items())
    src.tests = tests
    return decls
}

// type checking and lowering to IR
priv fn typecheck(ar: *Args, src: *Sources, decls: *Vec[Decl], n_prelude: i64) -> Cx {
    // the files of the library: the core library (`load`) and the bundled modules
    lib_files := vec[u8]()
    for i in 0..src.files.len {
        lib_files.push(if i < n_prelude { LIB_CORE } else if src.files[i].lib { LIB_MODULE } else { u8(0) })
    }
    cx := cx_new(decls.items(), clone(src.names), Opts{checks: !ar.unchecked}, lib_files)
    if ar.cmd != "check" {
        // bundled modules are only compiled as far as the program reaches into them
        for f in src.std_files {
            cx.lazy_files.set(f, true)
        }
    }
    lower_fn_lower_all(&cx, "__entry", n_prelude)
    return cx
}

// `alc check --all-targets`: the program is loaded and checked once per target (each sees
// the branches of its `when`s). An error that only some targets report names them.
priv fn check_all(ar: *Args) -> i64 {
    names := vec[str]()
    // a diagnostic (its file an index into `names`) and the targets that report it (bits)
    found := map[Diag, i64]()
    targets := []TargetOs{TargetLinux, TargetWindows}
    for t, target in targets {
        target_os = target
        src, n_prelude := load(ar)
        decls := program(&src, n_prelude, false)
        errs := src.errs
        if errs.is_empty() {
            cx := typecheck(ar, &src, &decls, n_prelude)
            errs = cx.errs
        }
        for d in errs {
            // the targets load different files: the same file has the same name
            f := -1
            if d.pos.file >= 0 {
                fname := file_name(&src.names, d.pos.file)
                f = index_of(names.items(), fname)
                if f < 0 {
                    f = names.len
                    names.push(fname)
                }
            }
            nd := Diag{pos: Pos{file: f, line: d.pos.line, col: d.pos.col}, msg: ast_plain_text(d.msg)}
            found.set(nd, found.get_or(nd, 0) | 1 << t)
        }
    }
    errs := vec[Diag]()
    for d in found.keys() {
        bits := found.get_or(d, 0)
        if bits != (1 << targets.len) - 1 {
            which := vec[str]()
            for t, target in targets {
                if bits & (1 << t) != 0 {
                    which.push(if target == TargetLinux { "--target linux" } else { "--target windows" })
                }
            }
            d.msg = fmt(d.msg, " (", join(which.items(), ", "), ")")
        }
        errs.push(d)
    }
    if report(&names, &errs) {
        return 1
    }
    return 0
}

priv fn real_main() -> i64 {
    ar := parse_args()
    test_mode := ar.cmd == "test"
    if !(ar.cmd == "build" || ar.cmd == "run" || ar.cmd == "test" || ar.cmd == "check" || ar.cmd == "sigs") {
        usage(fmt("unknown command ", ar.cmd))
    }
    if ar.all_targets {
        return check_all(&ar)
    }
    src, n_prelude := load(&ar)
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
                _, _, is_private, pos := priv_decl_info(&src.decls[x])
                lib_private := is_private && src.files[pos.file].lib
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
    decls := program(&src, n_prelude, test_mode)
    if report(&src.names, &src.errs) {
        return 1
    }
    mem("parsed")
    cx := typecheck(&ar, &src, &decls, n_prelude)
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
            opt_finish(&module, fi)
        }
        for fi in 0..module.funcs.len {
            if module.funcs[fi].lowered {
                put(ir_print_func(&module.funcs[fi], Some(&module)))
            }
        }
    }
    out := x86_compile(&module, ar.emit_asm)
    if opt_enabled("backtrace") {
        bt_attach(&module, &out, &cx, src.tests.items())
    }
    mem("compiled")
    bytes, link_err := if target_os == TargetWindows { pe_link(&module, &out) } else { elf_link(&module, &out) }
    if len(link_err) != 0 {
        driver_error(ar.input, link_err)
        return 1
    }
    out_path := match ar.output {
        Some(op) => op
        None => {
            stem := path_file_stem(ar.input).or("a.out")
            dir := path_parent(ar.input).or("")
            cand := path_join(dir, stem)
            // the test runner gets its own name: `alc test` must not replace the program
            if target_os == TargetWindows {
                if test_mode { fmt(cand, ".test.exe") } else { fmt(cand, ".exe") }
            } else if test_mode {
                fmt(cand, ".test")
            } else if path_comps(cand).items() == path_comps(ar.input).items() {
                fmt(cand, ".out")
            } else {
                cand
            }
        }
    }
    if host_root(out_path) == 0 && !has_sep(out_path) {
        out_path = fmt("./", out_path)
    }
    // the executable must not replace a source file of the program (`-o main.al`)
    for name in src.names {
        if same_file(name, out_path) {
            driver_error(out_path, fmt("the output `", out_path, "` is the source file `", name, "`: choose another path with -o"))
            return 1
        }
    }
    if !write_file(out_path, bytes) {
        // (io_error(): why it failed)
        errno := io_error()
        if errno == 0 {
            errno = 5
        }
        driver_error(out_path, fmt("cannot write `", out_path, "`: ", os_error(errno)))
        return 1
    }
    make_executable(out_path)
    if ar.cmd == "run" || ar.cmd == "test" {
        if target_os == TargetWindows && TARGET_OS != Windows {
            return run_windows(out_path, ar.rest.items())
        }
        if target_os == TargetLinux && TARGET_OS == Windows {
            driver_error(out_path, fmt("built `", out_path, "`, a Linux executable, which cannot run on Windows"))
            return 1
        }
        code := run_program(out_path, ar.rest.items())
        if code < 0 {
            driver_error(out_path, fmt("cannot run `", out_path, "`: ", os_error(11)))
            return 1
        }
        return code
    }
    return 0
}

// `alc run` / `alc test` of a Windows executable on Linux: under Wine if ALC_WINE=1 (with
// WINEPREFIX set; no window can open: DISPLAY and WAYLAND_DISPLAY are removed), else it is
// only built
priv fn run_windows(exe: str, argv: []str) -> i64 {
    w, wset := env_get("ALC_WINE")
    if !wset || w != "1" {
        driver_error(exe, fmt("built `", exe, "`, a Windows executable, which cannot run here (ALC_WINE=1 runs it under Wine)"))
        return 1
    }
    _, pset := env_get("WINEPREFIX")
    if !pset {
        driver_error(exe, "ALC_WINE=1 needs WINEPREFIX: the Wine prefix to run the program in")
        return 1
    }
    wine := ""
    path, has_path := env_get("PATH")
    if has_path {
        for d in split(path, ':') {
            cand := path_join(if len(d) == 0 { "." } else { d }, "wine")
            _, ok := file_id(cand)
            if ok {
                wine = cand
                break
            }
        }
    }
    if len(wine) == 0 {
        driver_error(exe, "ALC_WINE=1: `wine` is not on the PATH")
        return 1
    }
    wargs := vec_one(exe)
    wargs.extend(argv)
    drop := []str{"DISPLAY", "WAYLAND_DISPLAY", "WINEDEBUG", "WINEDLLOVERRIDES"}
    add := []str{"WINEDEBUG=-all", "WINEDLLOVERRIDES=mscoree=;mshtml="}
    code := run_program_env(wine, wargs.items(), drop, add)
    if code < 0 {
        driver_error(exe, fmt("cannot run `", wine, "`: ", os_error(11)))
        return 1
    }
    return code
}

fn main() -> i64 {
    // deep recursion in the frontend and SSA construction: use a big stack
    return with_stack(1 << 30, start)
}

priv fn start() -> i64 {
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
