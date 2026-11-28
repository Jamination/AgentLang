// alc: the AL compiler driver.
use "base.al"
use "diagcode.al"
use "ast.al"
use "lexer.al"
use "parser.al"
use "types.al"
use "ir.al"
use "lower.al"
use "lower_fn.al"
use "lower_expr.al"
use "lower_call.al"
use "lower_ccall.al"
use "lower_vec.al"
use "lower_nested.al"
use "lint.al"
use "lower_match.al"
use "opt/alias.al"
use "opt/bce.al"
use "opt/checkmerge.al"
use "opt/cleanup.al"
use "opt/gvn.al"
use "opt/idiom.al"
use "opt/vec.al"
use "opt/inline.al"
use "opt/licm.al"
use "opt/loop.al"
use "opt/lsr.al"
use "opt/loadelim.al"
use "opt/mem2reg.al"
use "opt/mod.al"
use "opt/simplify.al"
use "opt/spec.al"
use "opt/switch.al"
use "opt/tre.al"
use "opt/unroll.al"
use "spread.al"
use "regalloc.al"
use "x86/mir.al"
use "x86/isel.al"
use "x86/regalloc.al"
use "x86/emit.al"
use "x86/mod.al"
use "arm64/enc.al"
use "arm64/mir.al"
use "arm64/isel.al"
use "arm64/regalloc.al"
use "arm64/emit.al"
use "arm64/mod.al"
use "arm64/backtrace.al"
use "elf_arm64.al"
use "macho.al"
use "elf.al"
use "pe.al"
use "backtrace.al"
use "debug.al"
use "dwarf.al"
use "pdb.al"
use "priv.al"
use "lower_mem.al"
use "when.al"
use "fmt.al"
use "lsp.al"

// the compiler's version, "MAJOR.MINOR.PATCH": `alc --version`. Changed only on a release,
// to the version of the topmost released section of CHANGELOG.md (verify.sh checks it).
priv const VERSION = "0.5.0"

priv const PRELUDE = embed("prelude.al")
// the OS layer of the run-time library, compiled right after the prelude (see the top of
// prelude.al)
priv const PRELUDE_LINUX = embed("prelude_linux.al")
priv const PRELUDE_WINDOWS = embed("prelude_windows.al")
priv const PRELUDE_LINUX_ARM64 = embed("prelude_linux_arm64.al")
priv const PRELUDE_MACOS = embed("prelude_macos.al")

// bundled modules that only exist for Linux: what a program built for Windows can use instead
priv const LINUX_ONLY = [_](str, str){
    ("x11", ""),
    ("wayland", ""),
    ("alsa", ""),
}

// the operating system the executable is built for (`--target linux|windows`); the default
// is the one the compiler runs on (parse_args). Read by the back end (calling convention,
// frames), the linker (ELF or PE) and wherever the run-time library is chosen.
enum TargetOs { TargetLinux, TargetWindows, TargetMacOS }

target_os: TargetOs
// the processor (`--target linux-arm64`: AArch64, src/arm64 and src/elf_arm64.al)
enum TargetArch { ArchX86_64, ArchArm64 }

target_arch: TargetArch
// `--gui` (Windows only): the PE gets the GUI subsystem instead of the console one (pe_link)
pe_gui: bool
// `--icon file.ico` (Windows only): the bytes of the file, checked (ico_error); and
// `--version-info NAME=VALUE`: the pairs in the order given (see rsrc.al)
pe_icon: str
pe_version: Vec[(str, str)]

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
    ("font", embed("../std/font.al")),
    ("image_jpeg", embed("../std/image_jpeg.al")),
    ("x11", embed("../std/x11.al")),
    ("wayland", embed("../std/wayland.al")),
    ("alsa", embed("../std/alsa.al")),
    ("window", embed("../std/window.al")),
    ("window_linux", embed("../std/window_linux.al")),
    ("window_wayland", embed("../std/window_wayland.al")),
    ("window_windows", embed("../std/window_windows.al")),
    ("input", embed("../std/input.al")),
    ("input_linux", embed("../std/input_linux.al")),
    ("input_windows", embed("../std/input_windows.al")),
    ("audio", embed("../std/audio.al")),
    ("audio_linux", embed("../std/audio_linux.al")),
    ("audio_windows", embed("../std/audio_windows.al")),
    ("audio_vorbis", embed("../std/audio_vorbis.al")),
    ("vk", embed("../std/vk.al")),
    ("shaderc", embed("../std/shaderc.al")),
    ("dx12", embed("../std/dx12.al")),
    ("metal", embed("../std/metal.al")),
    ("net", embed("../std/net.al")),
    ("net_linux", embed("../std/net_linux.al")),
    ("net_windows", embed("../std/net_windows.al")),
    ("crypto", embed("../std/crypto.al")),
    ("cli", embed("../std/cli.al")),
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

// the module `name` is read from ALC_STD_DIR (std_text)
priv fn std_from_dir(name: str) -> bool {
    dir, have_dir := env_get("ALC_STD_DIR")
    return have_dir && file_id(path_join(dir, fmt(name, ".al"))).1
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
    warn: bool
    deny_warnings: bool
    sigs_std: bool
    sigs_pub: bool
    filter: str
}

priv deny_warnings: bool

priv fn usage_text() -> str {
    return concat("usage: alc <command> <file.al> [options]\n       alc --version [--json]\n       alc --help\n",
        concat("commands:\n  build   compile to a static x86-64 executable (Linux ELF, or Windows PE with --target windows)\n  run     build and run (arguments after `--` are passed on)\n  test    build and run all `test` blocks (`--filter <pat>`, `--json`)\n  check   type-check only (`main` need not exist: one file of a program can be checked alone)\n  sigs    list the declarations of a file (`--std`, `--pub`, `--filter <pat>`, `--json`)\n  fmt     rewrite files in the canonical layout (`alc fmt --check` lists those that would change)\n  lsp     run the Language Server Protocol (LSP) server over stdio\n  query   one-shot JSON semantic queries (`hover`, `def`, `refs`, `complete`, `symbols`)\n  capabilities  describe the language and compiler as one JSON object (keywords, types,\n          modules, limits, defined behaviour, diagnostic codes)\n  explain print what a diagnostic code means: `alc explain E0401`\n  version print the compiler's version and default target (also --version)\n  help    print this help message (also --help, -h)\n",
            "options:\n  -o <path>       output path (default: input without .al; with .exe for windows)\n  --target <os>   linux or windows (default: the system alc runs on); linux-arm64 (experimental:\n                  AArch64, see docs/ARM64_TEST.md); macos (experimental:\n                  arm64, never run: see docs/MACOS_TEST.md)\n  --all-targets   check: type-check once for every target\n  -D NAME=VALUE   set the program's constant NAME (-D NAME: a bool constant set to true)\n  -W, --warn      enable compiler warnings (unused locals, unreachable code, self-assignment)\n  --deny-warnings treat warnings as errors (implies -W)\n  --std           sigs: include the standard library (same as `-- std`)\n  --pub           sigs: omit `priv` declarations\n  --filter <pat>  sigs / test: only declarations or tests whose name contains <pat>\n  --gui           windows: a GUI program (no console window of its own)\n  --icon <ico>    windows: the icon of the executable (an .ico file)\n  --version-info NAME=VALUE\n                  windows: version information (FileDescription, ProductName, CompanyName,\n                  FileVersion, LegalCopyright, ...), once per name\n  --unchecked     disable bounds/division checks\n  -O0, -O1, -O2   optimization level (default: -O2; -O0 disables optimizations)\n  -g              debug information for debuggers and profilers (DWARF; Windows: also a .pdb)\n  --json          print diagnostics, sigs, test results or version as JSON on stdout\n  --emit-ir       print optimized IR to stdout\n  --emit-asm      print the selected machine code to stdout\n  --version       print the compiler's version and default target\n  -h, --help      print this help message\n"))
}

// `"a","b"`: the elements of a JSON array of strings
priv fn json_strs(xs: []str) -> str {
    o := vec[str]()
    for x in xs {
        o.push(json_str(x))
    }
    return join(o.items(), ",")
}

priv fn json_kinds(kinds: []DiagKind, sev: str, o: *Vec[str]) {
    for k in kinds {
        o.push(fmt("{\"code\":", json_str(k.code), ",\"name\":", json_str(k.name), ",\"severity\":", json_str(sev), ",\"summary\":", json_str(k.what), "}"))
    }
}

// What a C programmer would have to look up, and AL's answer: (question, answer). Printed by
// `alc capabilities`; docs/SEMANTICS.md is the same table with examples.
priv fn defined_behaviour() -> [](str, str) {
    return [](str, str){
        ("signed integer overflow", "wraps around (two's complement); `sat_add` / `sat_sub` saturate"),
        ("unsigned integer overflow", "wraps around"),
        ("integer division", "truncates toward zero; `%` has the sign of the left operand"),
        ("integer division or remainder by zero", "panic with file:line, exit status 1 (undefined with --unchecked)"),
        ("MIN / -1", "yields MIN"),
        ("shift count not less than the bit width", "the count is taken modulo the bit width"),
        ("right shift of a negative number", "arithmetic for signed types, logical for unsigned"),
        ("index or slice bound out of range", "panic with file:line, exit status 1 (undefined with --unchecked)"),
        ("nil dereference, stack overflow", "panic: memory fault, exit status 1"),
        ("uninitialized variable or memory", "cannot be read: every variable and every allocation starts zeroed"),
        ("order of evaluation", "operands and arguments left to right, each once; `&&` and `||` short-circuit"),
        ("implicit conversions", "none between types; an integer literal is accepted where a float is expected"),
        ("integer to narrower integer", "keeps the low bits"),
        ("integer to wider integer", "the source type decides: signed sign-extends, unsigned zero-extends"),
        ("float to integer", "truncates toward zero; NaN and values beyond i64 give 0x8000000000000000"),
        ("char signedness", "there is no char type: a character literal and a byte of a str are u8"),
        ("size of int", "there is no int: i8 to i64 and u8 to u64 have the same size on every target; an untyped integer literal is i64, a float literal f32"),
        ("use of released memory", "not detected in a normal run; `ALC_CHECK_MEMORY=1` makes it a panic"),
        ("data race", "undefined"),
        ("missing return", "compile error"),
        ("non-exhaustive match", "compile error when the match is used as a value, warning (-W) as a statement"),
    }
}

// `alc capabilities`: the compiler described as one JSON object, from the tables it works with
priv fn capabilities_json() -> str {
    os_name := if target_os == TargetWindows { "windows" } else if target_os == TargetMacOS { "macos" } else { "linux" }
    arch_name := if target_arch == ArchArm64 { "arm64" } else { "x86-64" }
    types := vec[str]()
    for t in []str{"i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64", "bool", "str", "vec2", "vec3", "vec4", "quat", "mat4", "never"} {
        if is_some(lower_builtin_type(t)) {
            types.push(t)
        }
    }
    mods := vec[str]()
    for m in STD_MODULES {
        note := ""
        linux_only := false
        for lo in LINUX_ONLY {
            if lo.0 == m.0 {
                linux_only = true
                note = lo.1
            }
        }
        mods.push(fmt("{\"name\":", json_str(m.0), ",\"linux_only\":", linux_only, if len(note) == 0 { "" } else { fmt(",\"note\":", json_str(note)) }, "}"))
    }
    sem := vec[str]()
    for q in defined_behaviour() {
        sem.push(fmt("{\"question\":", json_str(q.0), ",\"answer\":", json_str(q.1), "}"))
    }
    kinds := vec[str]()
    json_kinds(diag_errors(), "error", &kinds)
    json_kinds(diag_warnings(), "warning", &kinds)
    o := vec[str]()
    o.push(fmt("\"language\":\"AL\",\"version\":", json_str(VERSION)))
    o.push(fmt("\"host\":{\"os\":", json_str(os_name), ",\"arch\":", json_str(arch_name), "}"))
    o.push("\"source\":{\"extension\":\".al\",\"encoding\":\"UTF-8\",\"entry\":\"fn main() or fn main() -> i64\",\"comment\":\"//\",\"statement_end\":\"end of line\"}")
    o.push("\"targets\":[{\"name\":\"linux\",\"arch\":\"x86-64\",\"status\":\"supported\"},{\"name\":\"windows\",\"arch\":\"x86-64\",\"status\":\"supported\"},{\"name\":\"linux-arm64\",\"arch\":\"arm64\",\"status\":\"experimental\"},{\"name\":\"macos\",\"arch\":\"arm64\",\"status\":\"experimental, never run\"}]")
    o.push(fmt("\"commands\":[", json_strs([]str{"build", "run", "test", "check", "sigs", "fmt", "lsp", "query", "capabilities", "explain", "version", "help"}), "]"))
    o.push(fmt("\"keywords\":[", json_strs(lexer_keywords()), "]"))
    o.push(fmt("\"builtin_types\":[", json_strs(types.items()), "]"))
    o.push("\"library\":\"alc sigs --std --json --pub <file.al> lists every function of the run-time library and of the modules the file uses\"")
    o.push(fmt("\"std_modules\":[", join(mods.items(), ","), "]"))
    o.push(fmt("\"limits\":{\"nesting\":", parser_nest_max(), "}"))
    o.push("\"exit_status\":{\"0\":\"success\",\"1\":\"diagnostics were reported; for a built program: a panic or failed assert\",\"2\":\"mistake in the command line\"}")
    o.push("\"diagnostic_format\":{\"command\":\"alc check --json -W <file.al>\",\"output\":\"one JSON array on standard output\",\"fields\":{\"file\":\"path as given\",\"line\":\"from 1; 0: no position\",\"col\":\"from 1, in bytes\",\"message\":\"the whole message\",\"severity\":\"error or warning\",\"code\":\"the kind of mistake, one of diagnostics[].code\",\"end_line\":\"line of the end of the token at the position\",\"end_col\":\"column after its last character\",\"fix\":\"what the message says to do; absent if it gives no advice\"}}")
    o.push(fmt("\"semantics\":[", join(sem.items(), ","), "]"))
    o.push(fmt("\"diagnostics\":[", join(kinds.items(), ","), "]"))
    return fmt("{", join(o.items(), ","), "}")
}

// `alc explain <code>`: what a diagnostic code means
priv fn explain(code: str) -> never {
    match diag_kind(code) {
        Some(k) => {
            if json {
                print(fmt("{\"code\":", json_str(k.code), ",\"name\":", json_str(k.name), ",\"summary\":", json_str(k.what), "}"))
            } else {
                print(fmt(k.code, " ", k.name, "\n", k.what))
            }
            exit(0)
        }
        None => usage(if len(code) == 0 { "explain needs a diagnostic code: alc explain E0401" } else { fmt("unknown diagnostic code ", code, " (`alc capabilities` lists them)") })
    }
}

// an error of the driver itself (no position): with --json the same array as diagnostics,
// with line and col 0
priv fn driver_error(file: str, msg: str) {
    if json {
        print(fmt("[{\"file\":", json_str(file), ",\"line\":0,\"col\":0,\"message\":", json_str(msg), ",\"severity\":\"error\",\"code\":", json_str(DIAG_DRIVER), ",\"end_line\":0,\"end_col\":0}]"))
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
    eput(usage_text())
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
    k := 0
    while k < av.len {
        s := av[k]
        if s == "--" {
            break
        }
        if s == "-o" || s == "--target" || s == "--icon" || s == "--version-info" || s == "-D" || s == "--filter" {
            k += 2
            continue
        }
        if s == "--json" {
            json = true
        }
        k += 1
    }
    // the default target is the system the compiler runs on
    if TARGET_OS == Windows {
        target_os = TargetWindows
    }
    if HOST_ARM64 {
        target_arch = ArchArm64
    }
    if av.len >= 1 && (av[0] == "--help" || av[0] == "-h" || av[0] == "help") {
        put(usage_text())
        exit(0)
    }
    if av.len >= 1 && (av[0] == "--version" || av[0] == "version") {
        os_name := if target_os == TargetWindows { "windows" } else if target_os == TargetMacOS { "macos" } else { "linux" }
        arch_name := if target_arch == ArchArm64 { "arm64" } else { "x86-64" }
        if json {
            print(fmt("{\"version\":", json_str(VERSION), ",\"target_os\":", json_str(os_name), ",\"target_arch\":", json_str(arch_name), "}"))
        } else {
            print(fmt("alc ", VERSION, "\ndefault target: ", os_name, " ", arch_name))
        }
        exit(0)
    }
    if av.len >= 1 && av[0] == "capabilities" {
        print(capabilities_json())
        exit(0)
    }
    if av.len >= 1 && av[0] == "explain" {
        explain(if av.len >= 2 && av[1] != "--json" { av[1] } else if av.len >= 3 { av[2] } else { "" })
    }
    if av.len < 2 {
        usage("")
    }
    a := Args{cmd: av[0], opt: 2}
    icon := "" // the path of --icon
    i := 1
    while i < av.len {
        s := av[i]
        match s {
            "-h", "--help" => {
                put(usage_text())
                exit(0)
            }
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
                    usage("--target needs an operating system: linux, windows, linux-arm64 or macos")
                }
                a.target_set = true
                match av[i] {
                    "linux" => {
                        target_os = TargetLinux
                        target_arch = ArchX86_64
                    }
                    "windows" => {
                        target_os = TargetWindows
                        target_arch = ArchX86_64
                    }
                    "macos" => {
                        target_os = TargetMacOS
                        target_arch = ArchArm64
                    }
                    "linux-arm64" => {
                        target_os = TargetLinux
                        target_arch = ArchArm64
                    }
                    _ => usage(fmt("unknown target ", av[i], " (linux, windows, linux-arm64 or macos)"))
                }
            }
            "--json" => json = true
            "--gui" => pe_gui = true
            "--icon", "--version-info" => {
                i += 1
                if i >= av.len {
                    usage(if s == "--icon" { "--icon needs an icon file: --icon app.ico" } else { "--version-info needs NAME=VALUE: --version-info FileVersion=1.2.0" })
                }
                err := if s == "--icon" { "" } else { version_info_add(av[i]) }
                if len(err) != 0 {
                    usage(err)
                }
                if s == "--icon" {
                    icon = av[i]
                }
            }
            "--emit-ir" => a.emit_ir = true
            "--emit-asm" => a.emit_asm = true
            "--unchecked" => a.unchecked = true
            "-O0" => a.opt = 0
            "-g" => dbg_on = true
            "-D" => {
                i += 1
                if i >= av.len {
                    usage("-D needs a constant: -D NAME=VALUE")
                }
                a.parse_define(av[i])
            }
            _ if starts_with(s, "-D") => a.parse_define(s[2..])
            "--all-targets" => a.all_targets = true
            "-W", "--warn" => a.warn = true
            "--deny-warnings" => {
                a.warn = true
                a.deny_warnings = true
                deny_warnings = true
            }
            "--std" => a.sigs_std = true
            "--pub" => a.sigs_pub = true
            "--filter" => {
                i += 1
                if i >= av.len {
                    usage("--filter needs a pattern: --filter <substring>")
                }
                a.filter = av[i]
            }
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
    if dbg_on && target_arch == ArchArm64 {
        usage(fmt("-g: debug information is not written for --target ", if target_os == TargetMacOS { "macos" } else { "linux-arm64" }, " yet (only x86-64: DWARF on Linux, PDB on Windows)"))
    }
    if (pe_gui || len(icon) != 0 || !pe_version.is_empty()) && target_os != TargetWindows {
        usage(fmt(if pe_gui { "--gui" } else if len(icon) != 0 { "--icon" } else { "--version-info" }, " is for Windows executables: add --target windows"))
    }
    if len(icon) != 0 {
        err := ""
        pe_icon, err = read_to_string(icon)
        if len(err) != 0 || len(ico_error(pe_icon)) != 0 {
            driver_error(icon, if len(err) != 0 { fmt("cannot read `", icon, "`: ", err) } else { fmt("`", icon, "` ", ico_error(pe_icon)) })
            exit(1)
        }
    }
    if a.all_targets && (a.cmd != "check" || a.target_set) {
        usage("--all-targets is an option of `alc check`, which then checks every target (without --target)")
    }
    if (a.sigs_std || a.sigs_pub) && a.cmd != "sigs" {
        usage(fmt(if a.sigs_std { "--std" } else { "--pub" }, " is an option of `alc sigs`"))
    }
    if len(a.filter) != 0 && a.cmd != "sigs" && a.cmd != "test" {
        usage("--filter is an option of `alc sigs` and `alc test`")
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

struct Sources {
    names: Vec[str]
    files: Vec[SrcFile]
    decls: Vec[Decl]
    errs: Vec[Diag]
    seen: Map[str, bool]
    // the bundled modules the program includes, except those read from ALC_STD_DIR; the
    // first file of the core modules (after the run-time library)
    std_files: Vec[i64]
    n_core: i64
    wc: WhenCx
    // the files whose declarations the `when` conditions know (when_register): 0..registered
    registered: i64
    // the `when`s of the program decided while files were still being loaded: (the `when`,
    // file, branch), checked again at the end
    decided: Vec[(WhenDecl, i64, i64)]
    // the names of the `test` blocks: the function `__test_k` is test k (see program)
    tests: Vec[str]
    // optional in-memory file overlays for `alc lsp` (normalized path -> source text)
    overlays: *Map[str, str]
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
    if dbg_on {
        // (-g: the PDB's checksums of the source files)
        dbg_texts.resize(file + 1, "")
        dbg_texts[file] = text
    }
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
        if (target_os == TargetWindows || target_os == TargetMacOS) && is_some(dir) {
            for lo in LINUX_ONLY {
                if lo.0 == mname {
                    more := if len(lo.1) == 0 { "" } else { fmt("; ", lo.1) }
                    self.errs.push(Diag{pos: pos, msg: fmt("module `std.", mname, "` is not available for --target ", if target_os == TargetMacOS { "macos" } else { "windows" }, " (it uses Linux system interfaces)", more)})
                }
            }
        }
        match std_text(mname) {
            Some(mtext) => {
                key := fmt("<std/", mname, ".al>")
                if !self.seen.has(key) {
                    self.seen.set(key, true)
                    if !std_from_dir(mname) {
                        self.std_files.push(self.names.len)
                    }
                    out.push(Inc(self.add_text(key, mtext, None, true)))
                }
            }
            None => {
                all := vec[str]()
                for m in STD_MODULES {
                    all.push(m.0)
                }
                self.errs.push(Diag{pos: pos, msg: fmt("unknown module `std.", mname, "` (available: ", join(all.items(), ", "), ")", did_you_mean_hint(mname, all.items()))})
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
    // in-memory overlay (alc lsp) takes precedence over disk
    if self.overlays != nil {
        norm := lsp_norm_path(path)
        otext, has_ov := self.overlays.get(norm)
        if !has_ov {
            otext, has_ov = self.overlays.get(path)
        }
        if has_ov {
            okey := concat("ov:", norm)
            if self.seen.has(okey) {
                return -1
            }
            self.seen.set(okey, true)
            return self.add_text(path, otext, path_parent(path), false)
        }
    }
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
            if self.overlays != nil {
                self.errs.push(Diag{pos: Pos{file: -1, line: 1, col: 1}, msg: msg})
            } else {
                driver_error(path, msg)
                exit(1)
            }
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
    n_err := 0
    n_warn := 0
    if json {
        // machine-readable diagnostics: one JSON array on stdout
        items := vec[str]()
        last := ""
        texts := map[i64, str]()
        for d in errs {
            file := if d.pos.file < 0 { "" } else { file_name(names, d.pos.file) }
            sev := if d.warn { "warning" } else { "error" }
            msg := ast_plain_text(d.msg)
            // the end of the token at the position (in the file as it is on disk; a file that
            // is not one, like the generated entry, gives an empty range)
            end_col := i64(d.pos.col)
            if d.pos.file >= 0 && d.pos.line > 0 {
                if !texts.has(d.pos.file) {
                    text, _ := read_file(file)
                    texts.set(d.pos.file, text)
                }
                text, _ := texts.get(d.pos.file)
                end_col = diag_token_end(diag_line_text(text, i64(d.pos.line)), i64(d.pos.col))
            }
            fix := diag_fix(msg)
            fix_json := if len(fix) == 0 { "" } else { fmt(",\"fix\":", json_str(fix)) }
            item := fmt("{\"file\":", json_str(file), ",\"line\":", d.pos.line, ",\"col\":", d.pos.col, ",\"message\":", json_str(msg), ",\"severity\":", json_str(sev), ",\"code\":", json_str(diag_code(msg, d.warn)), ",\"end_line\":", d.pos.line, ",\"end_col\":", end_col, fix_json, "}")
            if item != last {
                items.push(item)
                last = item
                if d.warn {
                    n_warn += 1
                } else {
                    n_err += 1
                }
            }
        }
        print(fmt("[", join(items.items(), ","), "]"))
        return n_err > 0 || (deny_warnings && n_warn > 0)
    }
    last := ""
    for d in errs {
        // (file -1: the command line)
        sev := if d.warn { "warning" } else { "error" }
        line := if d.pos.file < 0 { fmt(sev, ": ", ast_plain_text(d.msg)) } else { fmt(file_name(names, d.pos.file), ":", d.pos.line, ":", d.pos.col, ": ", sev, ": ", ast_plain_text(d.msg)) }
        if line != last {
            eput(fmt(line, "\n"))
            if d.warn {
                n_warn += 1
            } else {
                n_err += 1
            }
            last = line
        }
    }
    if n_err > 0 && n_warn > 0 {
        eput(fmt(n_err, " error(s), ", n_warn, " warning(s)\n"))
    } else if n_err > 0 {
        eput(fmt(n_err, " error(s)\n"))
    } else if n_warn > 0 {
        eput(fmt(n_warn, " warning(s)\n"))
    }
    return n_err > 0 || (deny_warnings && n_warn > 0)
}

// "priv " in front of the signature of a private declaration
priv fn sigs_priv(name: str) -> str {
    if ast_is_private(name) {
        return "priv "
    }
    return ""
}

// `extern "lib" ` in front of the signature of a C function or variable
priv fn sigs_extern(ext: Opt[str], named: bool) -> str {
    return match ext {
        Some(lib) => if named { fmt("extern ", lib, " ") } else { fmt("extern \"", lib, "\" ") }
        None => ""
    }
}

// the text of the file named `name` in `alc sigs` / `alc lsp` (its comments are not kept): a bundled
// module, the run-time library (as `load` reads it), a file of the program; "" if unknown
fn sigs_text(name: str) -> str {
    if starts_with(name, "<std/") {
        return std_text(name[5..len(name) - 4]).or("")
    }
    if !starts_with(name, "<prelude") {
        if starts_with(name, "<") {
            return ""
        }
        t, err := read_to_string(name)
        return if len(err) == 0 { t } else { "" }
    }
    file := fmt(name[1..len(name) - 1], ".al")
    pre_path, pre_set := env_get("ALC_PRELUDE")
    if pre_set {
        p := if file == "prelude.al" { pre_path } else { path_join(path_parent(pre_path).or("."), file) }
        t, err := read_to_string(p)
        return if len(err) == 0 { t } else { "" }
    }
    return match file {
        "prelude.al" => PRELUDE
        "prelude_linux.al" => PRELUDE_LINUX
        "prelude_windows.al" => PRELUDE_WINDOWS
        "prelude_linux_arm64.al" => PRELUDE_LINUX_ARM64
        "prelude_macos.al" => PRELUDE_MACOS
        _ => ""
    }
}

// the first line of the comment that leads the declaration on `line` (the comment lines right
// above it, after a heading such as `// ---- paths ----`), else the comment after it on its
// line; "" if neither
fn sigs_doc(cl: *Map[i64, str], line: i64) -> str {
    top := line
    while cl.has(top - 1) {
        top -= 1
    }
    for l in top..line {
        c := trim(trim_left(cl.get_or(l, ""), "/"))
        if len(c) > 0 && !(starts_with(c, "---") || starts_with(c, "===")) {
            return c
        }
    }
    return trim(trim_left(cl.get_or(-line, ""), "/"))
}

// `alc sigs`: one line per declaration, for a quick overview of a file; the first line of its
// leading comment follows after `  // ` (or a JSON array with `--json`)
priv fn print_sigs(names: *Vec[str], decls: []Decl, from_file: i64, pub_only: bool, filter: str) {
    // the comments of the files seen so far
    comments := map[i64, Map[i64, str]]()
    jitems := vec[str]()
    for d in decls {
        pos, kind, raw_name, text := match d {
            Fn(f) => (f.pos, "fn", f.name, fmt(sigs_priv(f.name), sigs_extern(f.ext, f.ext_const), ast_sig_str(&f)))
            Struct(s) => (s.pos, "struct", s.name, fmt(sigs_priv(s.name), ast_struct_str(&s)))
            Enum(e) => (e.pos, "enum", e.name, fmt(sigs_priv(e.name), ast_enum_str(&e)))
            // (the value of a constant or a global is not shown: `...`)
            Const(c) => {
                sig := match c.ty {
                    Some(ty) => fmt(sigs_priv(c.name), "const ", c.name, ": ", ast_type_str(&ty), " = ...")
                    None => fmt(sigs_priv(c.name), "const ", c.name, " = ...")
                }
                (c.pos, "const", c.name, sig)
            }
            Global(g) => {
                sig := match g.ty {
                    Some(ty) => fmt(sigs_priv(g.name), sigs_extern(g.ext, g.ext_const), g.name, ": ", ast_type_str(&ty))
                    None => fmt(sigs_priv(g.name), g.name, " := ...")
                }
                (g.pos, "global", g.name, sig)
            }
            Test(t) => (t.pos, "test", t.name, fmt("test \"", t.name, "\""))
            Use(_, _), When(_) => continue
        }
        if pos.file < from_file {
            continue
        }
        is_p := ast_is_private(raw_name)
        if pub_only && is_p {
            continue
        }
        plain_name := ast_plain(raw_name)
        if len(filter) != 0 && find(plain_name, filter) < 0 {
            continue
        }
        if !comments.has(pos.file) {
            comments.set(pos.file, comment_lines(sigs_text(file_name(names, pos.file))))
        }
        cl := comments.get_or(pos.file, map[i64, str]())
        doc := sigs_doc(&cl, i64(pos.line))
        fname := file_name(names, pos.file)
        sig_plain := ast_plain_text(text)
        if json {
            jitems.push(fmt("{\"file\":", json_str(fname), ",\"line\":", pos.line, ",\"kind\":", json_str(kind), ",\"name\":", json_str(plain_name), ",\"priv\":", if is_p { "true" } else { "false" }, ",\"sig\":", json_str(sig_plain), ",\"doc\":", json_str(doc), "}"))
        } else {
            print(fmt(fname, ":", pos.line, ": ", sig_plain, if len(doc) == 0 { "" } else { concat("  // ", doc) }))
        }
    }
    if json {
        print(fmt("[", join(jitems.items(), ","), "]"))
    }
}

// is a declaration shown by `alc sigs <file> --std` / `-- std`?
priv fn sigs_visible(d: *Decl) -> bool {
    match *d {
        Fn(f) => !starts_with(f.name, "__")
        Global(g) => !starts_with(g.name, "__")
        Struct(s) => !starts_with(s.name, "__")
        Enum(e) => !starts_with(e.name, "__")
        Const(c) => !starts_with(c.name, "__")
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
    if target_arch == ArchArm64 {
        layer_name, layer = if target_os == TargetMacOS { ("prelude_macos.al", PRELUDE_MACOS) } else { ("prelude_linux_arm64.al", PRELUDE_LINUX_ARM64) }
    }
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
    src.n_core = src.names.len
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
// generated (in the file "<entry>"). `need_main`: a program without `main` is an error (not
// for `alc test` and `alc check`, which write no program that starts at `main`).
priv fn program(src: *Sources, n_prelude: i64, test_mode: bool, need_main: bool) -> Vec[Decl] {
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
    if has_c {
        // an OS layer with `__os_c_thread_create` / `__os_c_thread_join` (src/prelude_linux_arm64.al):
        // a program that declares C functions makes its threads with those (the C library's),
        // which call the layer's own as `__os_clone_thread_*`; other programs never see them
        has_twin := false
        for d in decls {
            match d {
                Fn(f) if f.name == "__os_c_thread_create" => has_twin = true
                _ => {}
            }
        }
        if has_twin {
            for i in 0..decls.len {
                match decls[i] {
                    Fn(&f) => {
                        for w in []str{"create", "join"} {
                            if f.name == fmt("__os_thread_", w) {
                                f.name = fmt("__os_clone_thread_", w)
                            } else if f.name == fmt("__os_c_thread_", w) {
                                f.name = fmt("__os_thread_", w)
                            }
                        }
                    }
                    _ => {}
                }
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
        if need_main && src.errs.is_empty() {
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
    cx := cx_new(decls.items(), clone(src.names), Opts{checks: !ar.unchecked, warn: ar.warn}, lib_files)
    // `alc check` type-checks every function of the program and of the bundled modules it
    // includes, the core modules (n_core..n_prelude) too. `alc build` / `run` / `test` compile
    // the bundled modules only as far as the program reaches into them: checking the rest
    // would cost every build of a program that uses std.window 40-70% more time
    // (at -O0; 2-4 times at -O), for errors that tests/check/std_targets.al rule out. A
    // module read from ALC_STD_DIR (one being written) is checked in full by every command.
    from := n_prelude
    if ar.cmd == "check" {
        from = src.n_core
    } else {
        for f in src.std_files {
            cx.lazy_files.set(f, true)
        }
    }
    lower_fn_lower_all(&cx, "__entry", from)
    return cx
}

// `alc check --all-targets`: the program is loaded and checked once per target (each sees
// the branches of its `when`s). An error that only some targets report names them.
priv fn check_all(ar: *Args) -> i64 {
    names := vec[str]()
    // a diagnostic (its file an index into `names`) and the targets that report it (bits)
    found := map[Diag, i64]()
    saved_os := target_os
    saved_arch := target_arch
    targets := []TargetOs{TargetLinux, TargetWindows}
    for t, target in targets {
        target_os = target
        target_arch = ArchX86_64
        src, n_prelude := load(ar)
        decls := program(&src, n_prelude, false, false)
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
            nd := Diag{pos: Pos{file: f, line: d.pos.line, col: d.pos.col}, msg: ast_plain_text(d.msg), warn: d.warn}
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
    target_os = saved_os
    target_arch = saved_arch
    if report(&names, &errs) {
        return 1
    }
    if json && errs.is_empty() {
        print("[]")
    }
    return 0
}

// Helpers used by `alc lsp` (src/lsp.al)
fn lsp_version() -> str {
    return VERSION
}

fn lsp_std_modules() -> Vec[str] {
    out := vec[str]()
    for m in STD_MODULES {
        n := m.0
        if ends_with(n, "_linux") || ends_with(n, "_windows") || ends_with(n, "_wayland") || ends_with(n, "_jpeg") || ends_with(n, "_vorbis") {
            continue
        }
        out.push(n)
    }
    return out
}

// Loads and type-checks `path` using in-memory `overlays` for `alc lsp` (with Opts.lsp = true
// and Opts.warn = true). Returns (sources, n_prelude, cx, typechecked).
fn lsp_analyze(path: str, overlays: *Map[str, str]) -> (Sources, i64, Cx, bool) {
    src := Sources{overlays: overlays}
    prelude := PRELUDE
    layer_name, layer := if target_os == TargetWindows { ("prelude_windows.al", PRELUDE_WINDOWS) } else { ("prelude_linux.al", PRELUDE_LINUX) }
    if target_arch == ArchArm64 {
        layer_name, layer = if target_os == TargetMacOS { ("prelude_macos.al", PRELUDE_MACOS) } else { ("prelude_linux_arm64.al", PRELUDE_LINUX_ARM64) }
    }
    src.add_text("<prelude>", prelude, None, true)
    src.add_text(fmt("<", layer_name[..len(layer_name) - 3], ">"), layer, None, true)
    src.n_core = src.names.len
    for name in CORE_MODULES {
        text := std_text(name).or("")
        src.seen.set(fmt("<std/", name, ".al>"), true)
        src.add_text(fmt("<std/", name, ".al>"), text, None, true)
    }
    n_prelude := src.names.len
    src.add_file(path, None)
    src.finish()
    decls := program(&src, n_prelude, false, false)
    if !src.errs.is_empty() {
        empty_cx := Cx{}
        return (src, n_prelude, empty_cx, false)
    }
    lib_files := vec[u8]()
    for i in 0..src.files.len {
        lib_files.push(if i < n_prelude { LIB_CORE } else if src.files[i].lib { LIB_MODULE } else { u8(0) })
    }
    cx := cx_new(decls.items(), clone(src.names), Opts{checks: false, warn: true, lsp: true}, lib_files)
    for f in src.std_files {
        cx.lazy_files.set(f, true)
    }
    lower_fn_lower_all(&cx, "__entry", n_prelude)
    return (src, n_prelude, cx, true)
}

priv fn real_main() -> i64 {
    if len(args()) >= 2 && args()[1] == "fmt" {
        json = contains(args()[2..], "--json")
        return fmt_main(args()[2..], report)
    }
    if len(args()) >= 2 && args()[1] == "lsp" {
        if TARGET_OS == Windows {
            target_os = TargetWindows
        }
        if HOST_ARM64 {
            target_arch = ArchArm64
        }
        return lsp_main(args()[2..])
    }
    if len(args()) >= 2 && args()[1] == "query" {
        if TARGET_OS == Windows {
            target_os = TargetWindows
        }
        if HOST_ARM64 {
            target_arch = ArchArm64
        }
        return lsp_query_main(args()[2..])
    }
    ar := parse_args()
    dbg_keep_vars = dbg_on && ar.opt == 0
    test_mode := ar.cmd == "test"
    if !(ar.cmd == "build" || ar.cmd == "run" || ar.cmd == "test" || ar.cmd == "check" || ar.cmd == "sigs") {
        usage(fmt("unknown command ", ar.cmd))
    }
    if ar.all_targets {
        return check_all(&ar)
    }
    src, n_prelude := load(&ar)
    if ar.cmd == "sigs" {
        // `alc sigs <file> --std` (or `-- std`) lists the standard library
        if report(&src.names, &src.errs) {
            return 1
        }
        from := if ar.sigs_std || contains(&ar.rest, "std") { 0 } else { n_prelude }
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
        print_sigs(&src.names, sdecls.items(), from, ar.sigs_pub, ar.filter)
        return 0
    }
    decls := program(&src, n_prelude, test_mode, ar.cmd == "build" || ar.cmd == "run")
    if report(&src.names, &src.errs) {
        return 1
    }
    mem("parsed")
    cx := typecheck(&ar, &src, &decls, n_prelude)
    if report(&src.names, &cx.errs) {
        return 1
    }
    if ar.cmd == "check" {
        if json && cx.errs.is_empty() {
            print("[]")
        }
        return 0
    }
    module := cx.module
    mem("lowered")
    opt_optimize(&module, ar.opt)
    mem("optimized")
    if ar.emit_ir {
        for fi in 0..module.funcs.len {
            opt_finish(&module, fi, work_main())
        }
        for fi in 0..module.funcs.len {
            if module.funcs[fi].lowered {
                put(ir_print_func(&module.funcs[fi], Some(&module)))
            }
        }
    }
    // the back end (arm64: src/arm64); the linker runs below, once the output path is known
    aout: A64Output
    out: Output
    if target_arch == ArchArm64 {
        aout = a64_compile(&module, ar.emit_asm)
        for fi in aout.code_files {
            fname := file_name(&src.names, fi)
            if starts_with(fname, "<std/") {
                stxt := std_text(fname[5..len(fname) - 4]).or("")
                if find(stxt, "syscall(") >= 0 && find(stxt, "TARGET_ARCH") < 0 {
                    mname := fname[5..len(fname) - 4]
                    if ends_with(mname, "_linux") {
                        mname = mname[..len(mname) - 6]
                    }
                    driver_error(ar.input, fmt("module `std.", mname, "` makes Linux system calls by their x86-64 numbers: it is not available for --target ", if target_os == TargetMacOS { "macos" } else { "linux-arm64" }, " yet"))
                    return 1
                }
            }
        }
        if opt_enabled("backtrace") {
            a64_bt_attach(&module, &aout, &cx, src.tests.items())
        }
    } else {
        out = x86_compile(&module, ar.emit_asm)
        if opt_enabled("backtrace") {
            bt_attach(&module, &out, &cx, src.tests.items())
        }
    }
    mem("compiled")
    if dbg_on {
        dbg_cx = &cx
        dbg_tests = src.tests.items()
        dbg_main_file = n_prelude
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
    if dbg_on && target_os == TargetWindows {
        // the PDB next to the executable: prog.exe -> prog.pdb (its absolute path goes into the
        // executable)
        stem := if ends_with(to_lower(out_path), ".exe") { out_path[..len(out_path) - 4] } else { out_path }
        dbg_pdb_path = fmt(stem, ".pdb")
        if host_root(dbg_pdb_path) == 0 {
            rel := if starts_with(dbg_pdb_path, "./") || starts_with(dbg_pdb_path, ".\\") { dbg_pdb_path[2..] } else { dbg_pdb_path }
            cwd := __os_current_dir()
            if len(cwd) != 0 {
                dbg_pdb_path = fmt(cwd, if TARGET_OS == Windows { "\\" } else { "/" }, rel)
            }
        }
        if TARGET_OS == Windows {
            dbg_pdb_path = replace(dbg_pdb_path, "/", "\\")
        }
    }
    bytes, link_err := if target_os == TargetMacOS { macho_link(&module, &aout, path_file_name(out_path).or("a.out")) } else if target_arch == ArchArm64 { elf_arm64_link(&module, &aout) } else if target_os == TargetWindows { pe_link(&module, &out) } else { elf_link(&module, &out) }
    if len(link_err) != 0 {
        driver_error(ar.input, link_err)
        return 1
    }
    if !dbg_pdb.is_empty() && !write_file(dbg_pdb_path, dbg_pdb.items()) {
        driver_error(dbg_pdb_path, fmt("cannot write `", dbg_pdb_path, "`: ", os_error(io_error())))
        return 1
    }
    // (a busy executable cannot be written but can be replaced: Linux keeps the file of a
    // process that has ended mapped while it tears down its memory, which takes a moment after
    // a program with threads)
    if !write_file(out_path, bytes) && !(io_error() == 26 && unlink_file(out_path) && write_file(out_path, bytes)) {
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
        extra_env := vec[str]()
        if test_mode {
            if len(ar.filter) != 0 {
                extra_env.push(concat("ALC_TEST_FILTER=", ar.filter))
            }
            if json {
                extra_env.push("ALC_TEST_JSON=1")
            }
        }
        if target_os == TargetWindows && TARGET_OS != Windows {
            return run_windows(out_path, ar.rest.items(), extra_env.items())
        }
        if target_os == TargetMacOS {
            driver_error(out_path, fmt("built `", out_path, "`, a macOS executable, which cannot run here"))
            return 1
        }
        if target_os == TargetLinux && TARGET_OS == Windows {
            driver_error(out_path, fmt("built `", out_path, "`, a Linux executable, which cannot run on Windows"))
            return 1
        }
        if (target_arch == ArchArm64) != HOST_ARM64 {
            // (HOST_ARM64: the compiler built for linux-arm64 runs there)
            driver_error(out_path, fmt("built `", out_path, "`, an ", if target_arch == ArchArm64 { "arm64" } else { "x86-64" }, " executable, which cannot run on this processor"))
            return 1
        }
        code := if extra_env.is_empty() { run_program(out_path, ar.rest.items()) } else { run_program_env(out_path, ar.rest.items(), nil, extra_env.items()) }
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
priv fn run_windows(exe: str, argv: []str, extra_env: []str) -> i64 {
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
    add := vec_of([]str{"WINEDEBUG=-all", "WINEDLLOVERRIDES=mscoree=;mshtml="})
    add.extend(extra_env)
    code := run_program_env(wine, wargs.items(), drop, add.items())
    if code < 0 {
        driver_error(exe, fmt("cannot run `", wine, "`: ", os_error(11)))
        return 1
    }
    return code
}

fn main() -> i64 {
    // deep recursion in the front end (it follows the nesting): use a big stack
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
        eput(fmt("[mem] ", phase, ": ", (mem_used() + spread_thread_mem()) >> 20, " MB, work heap peak ", work_peak(work_main()) >> 20, " MB, ", (clock_ns() - t0) / 1000000, " ms\n"))
    }
}
