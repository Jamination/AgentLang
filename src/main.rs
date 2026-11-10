// alc: the AL compiler driver.
mod ast;
mod ir;
mod lexer;
mod lower;
mod lower_call;
mod lower_expr;
mod lower_fn;
mod lower_vec;
mod parser;
mod elf;
mod opt;
mod types;
mod x86;

use ast::*;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

const PRELUDE: &str = include_str!("prelude.al");

// modules bundled with the compiler: `use std.<name>`
const STD_MODULES: &[(&str, &str)] = &[("libc", include_str!("../std/libc.al"))];

struct Args {
    cmd: String,
    input: String,
    output: Option<String>,
    emit_ir: bool,
    emit_asm: bool,
    unchecked: bool,
    opt: u32,
    rest: Vec<String>,
}

fn usage() -> ! {
    eprintln!(
        "usage: alc <command> <file.al> [options]\n\
         commands:\n  build   compile to a static x86-64 Linux executable\n  run     build and run (arguments after `--` are passed on)\n  test    build and run all `test` blocks\n  check   type-check only\n  sigs    list the declarations of a file (`alc sigs f.al -- std` adds the standard library)\n\
         options:\n  -o <path>     output path (default: input without .al)\n  --unchecked   disable bounds/division checks\n  -O0           disable optimizations\n  --json        print diagnostics as a JSON array on stdout\n  --emit-ir     print optimized IR to stdout\n  --emit-asm    print the selected machine code to stdout"
    );
    std::process::exit(2);
}

fn parse_args() -> Args {
    let av: Vec<String> = std::env::args().skip(1).collect();
    if av.len() < 2 {
        usage();
    }
    let mut a = Args { cmd: av[0].clone(), input: String::new(), output: None, emit_ir: false, emit_asm: false, unchecked: false, opt: 2, rest: Vec::new() };
    let mut i = 1;
    while i < av.len() {
        match av[i].as_str() {
            "-o" => {
                i += 1;
                if i >= av.len() {
                    usage();
                }
                a.output = Some(av[i].clone());
            }
            "--json" => JSON.store(true, std::sync::atomic::Ordering::Relaxed),
            "--emit-ir" => a.emit_ir = true,
            "--emit-asm" => a.emit_asm = true,
            "--unchecked" => a.unchecked = true,
            "-O0" => a.opt = 0,
            "-O1" => a.opt = 1,
            "-O2" => a.opt = 2,
            "--" => {
                a.rest = av[i + 1..].to_vec();
                break;
            }
            s if s.starts_with('-') => {
                eprintln!("unknown option {}", s);
                usage();
            }
            s => {
                if a.input.is_empty() {
                    a.input = s.to_string();
                } else {
                    eprintln!("unexpected argument {}", s);
                    usage();
                }
            }
        }
        i += 1;
    }
    if a.input.is_empty() {
        usage();
    }
    a
}

struct Sources {
    names: Vec<String>,
    decls: Vec<Decl>,
    errs: Vec<Diag>,
    seen: HashSet<PathBuf>,
    std_files: Vec<u16>,
}

impl Sources {
    fn add_text(&mut self, name: &str, text: &str, dir: Option<&Path>) {
        let file = self.names.len() as u16;
        self.names.push(name.to_string());
        let toks = lexer::lex(text, file, &mut self.errs);
        let decls = parser::Parser::new(toks, &mut self.errs).file();
        for d in decls {
            if let Decl::Use(path, pos) = &d {
                if let Some(name) = path.strip_prefix("std:") {
                    match STD_MODULES.iter().find(|m| m.0 == name) {
                        Some(m) => {
                            if self.seen.insert(PathBuf::from(format!("<std/{}.al>", name))) {
                                self.std_files.push(self.names.len() as u16);
                                self.add_text(&format!("<std/{}.al>", name), m.1, None);
                            }
                        }
                        None => {
                            let all: Vec<&str> = STD_MODULES.iter().map(|m| m.0).collect();
                            self.errs.push(Diag { pos: *pos, msg: format!("unknown module `std.{}` (available: {})", name, all.join(", ")) });
                        }
                    }
                    continue;
                }
                let p = match dir {
                    Some(dir) => dir.join(path),
                    None => PathBuf::from(path),
                };
                self.add_file(&p, Some(*pos));
            } else {
                self.decls.push(d);
            }
        }
    }
    fn add_file(&mut self, path: &Path, from: Option<Pos>) {
        let canon = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        if !self.seen.insert(canon) {
            return;
        }
        match std::fs::read_to_string(path) {
            Ok(text) => {
                let dir = path.parent().map(|p| p.to_path_buf());
                self.add_text(&path.to_string_lossy(), &text, dir.as_deref());
            }
            Err(e) => {
                let msg = format!("cannot read `{}`: {}", path.display(), e);
                match from {
                    Some(pos) => self.errs.push(Diag { pos, msg }),
                    None => {
                        eprintln!("error: {}", msg);
                        std::process::exit(1);
                    }
                }
            }
        }
    }
}

static JSON: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn json_str(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

fn report(names: &[String], errs: &mut Vec<Diag>) -> bool {
    if errs.is_empty() {
        return false;
    }
    errs.sort_by_key(|d| (d.pos.file, d.pos.line, d.pos.col));
    if JSON.load(std::sync::atomic::Ordering::Relaxed) {
        // machine-readable diagnostics: one JSON array on stdout
        let mut items: Vec<String> = Vec::new();
        let mut last = String::new();
        for d in errs.iter() {
            let file = names.get(d.pos.file as usize).map(|s| s.as_str()).unwrap_or("?");
            let item = format!("{{\"file\":{},\"line\":{},\"col\":{},\"message\":{}}}", json_str(file), d.pos.line, d.pos.col, json_str(&d.msg));
            if item != last {
                items.push(item.clone());
                last = item;
            }
        }
        println!("[{}]", items.join(","));
        return true;
    }
    let mut last = String::new();
    let mut n = 0;
    for d in errs.iter() {
        let line = format!("{}:{}:{}: error: {}", names.get(d.pos.file as usize).map(|s| s.as_str()).unwrap_or("?"), d.pos.line, d.pos.col, d.msg);
        if line != last {
            eprintln!("{}", line);
            n += 1;
            last = line;
        }
    }
    eprintln!("{} error(s)", n);
    true
}


// `alc sigs`: one line per declaration, for a quick overview of a file
fn print_sigs(names: &[String], decls: &[Decl], from_file: u16) {
    let tp = |t: &Vec<String>| if t.is_empty() { String::new() } else { format!("[{}]", t.join(", ")) };
    for d in decls {
        let (pos, text) = match d {
            Decl::Fn(f) => {
                let ps = f.params.iter().map(|p| format!("{} {}", p.0, type_str(&p.1))).collect::<Vec<_>>().join(", ");
                let r = f.ret.as_ref().map(|r| format!(" {}", type_str(r))).unwrap_or_default();
                (f.pos, format!("fn {}{}({}){}", f.name, tp(&f.tparams), ps, r))
            }
            Decl::Struct(s) => {
                let fs = s.fields.iter().map(|f| format!("{} {}", f.0, type_str(&f.1))).collect::<Vec<_>>().join(", ");
                (s.pos, format!("struct {}{} {{ {} }}", s.name, tp(&s.tparams), fs))
            }
            Decl::Enum(e) => {
                let vs = e
                    .variants
                    .iter()
                    .map(|v| if v.1.is_empty() { v.0.clone() } else { format!("{}({})", v.0, v.1.iter().map(type_str).collect::<Vec<_>>().join(", ")) })
                    .collect::<Vec<_>>()
                    .join(", ");
                (e.pos, format!("enum {}{} {{ {} }}", e.name, tp(&e.tparams), vs))
            }
            Decl::Const(c) => (c.pos, format!("const {}{}", c.name, c.ty.as_ref().map(|t| format!(" {}", type_str(t))).unwrap_or_default())),
            Decl::Global(g) => (g.pos, format!("var {}{}", g.name, g.ty.as_ref().map(|t| format!(" {}", type_str(t))).unwrap_or_default())),
            Decl::Test(t) => (t.pos, format!("test \"{}\"", t.name)),
            Decl::Use(..) => continue,
        };
        if pos.file < from_file {
            continue;
        }
        println!("{}:{}: {}", names.get(pos.file as usize).map(|s| s.as_str()).unwrap_or("?"), pos.line, text);
    }
}

fn real_main() -> i32 {
    let args = parse_args();
    let test_mode = args.cmd == "test";
    if !matches!(args.cmd.as_str(), "build" | "run" | "test" | "check" | "sigs") {
        usage();
    }
    let mut src = Sources { names: Vec::new(), decls: Vec::new(), errs: Vec::new(), seen: HashSet::new(), std_files: Vec::new() };
    src.add_text("<prelude>", PRELUDE, None);
    src.add_file(Path::new(&args.input), None);
    if args.cmd == "sigs" {
        // `alc sigs <file> --` with "std" as input lists the standard library
        if report(&src.names, &mut src.errs) {
            return 1;
        }
        let from = if args.rest.iter().any(|a| a == "std") { 0 } else { 1 };
        let decls: Vec<Decl> = if from == 0 {
            src.decls.iter().filter(|d| match d {
                Decl::Fn(f) => !f.name.starts_with("__"),
                Decl::Global(g) => !g.name.starts_with("__"),
                _ => true,
            }).cloned().collect()
        } else {
            src.decls.clone()
        };
        print_sigs(&src.names, &decls, from);
        return 0;
    }
    // tests become functions; the entry point is synthesized
    let mut tests: Vec<String> = Vec::new();
    let mut main_ret = false;
    let mut has_main = false;
    let mut decls: Vec<Decl> = Vec::new();
    for d in std::mem::take(&mut src.decls) {
        match d {
            Decl::Test(t) => {
                let fname = format!("__test_{}", tests.len());
                tests.push(t.name.clone());
                decls.push(Decl::Fn(FnDecl { name: fname, tparams: vec![], params: vec![], ret: None, body: t.body, pos: t.pos, inline: -1, ext: None }));
            }
            Decl::Fn(f) => {
                if f.name == "main" {
                    has_main = true;
                    main_ret = f.ret.is_some();
                }
                decls.push(Decl::Fn(f));
            }
            d => decls.push(d),
        }
    }
    let mut entry = String::from("fn __entry(sp i64) never {\n __rt_init(sp)\n");
    if test_mode {
        for (i, name) in tests.iter().enumerate() {
            let esc: String = name.chars().map(|c| if c == '"' || c == '\\' { '_' } else { c }).collect();
            entry.push_str(&format!(" __run_test(\"{}\", __test_{})\n", esc, i));
        }
        entry.push_str(" exit(__tests_done())\n}\n");
    } else if !has_main {
        src.errs.push(Diag { pos: Pos { file: 1, line: 1, col: 1 }, msg: "missing `fn main()`".into() });
        entry.push_str(" exit(0)\n}\n");
    } else if main_ret {
        entry.push_str(" exit(main())\n}\n");
    } else {
        entry.push_str(" main()\n exit(0)\n}\n");
    }
    {
        let file = src.names.len() as u16;
        src.names.push("<entry>".into());
        let toks = lexer::lex(&entry, file, &mut src.errs);
        decls.extend(parser::Parser::new(toks, &mut src.errs).file());
    }
    if report(&src.names, &mut src.errs) {
        return 1;
    }
    let mut cx = lower::Cx::new(&decls, src.names.clone(), lower::Opts { checks: !args.unchecked });
    if args.cmd != "check" {
        // bundled modules are only compiled as far as the program reaches into them
        cx.lazy_files = src.std_files.iter().copied().collect();
    }
    lower_fn::lower_all(&mut cx, "__entry", 1);
    if report(&src.names, &mut cx.errs) {
        return 1;
    }
    if args.cmd == "check" {
        return 0;
    }
    let module = cx.module;
    let mut module = module;
    opt::optimize(&mut module, args.opt);
    if args.emit_ir {
        for f in &module.funcs {
            if f.lowered {
                print!("{}", ir::print_func(f, Some(&module)));
            }
        }
    }
    let out = x86::compile(&mut module, args.emit_asm);
    let bytes = match elf::link(&module, &out) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("error: {}", e);
            return 1;
        }
    };
    let out_path = match &args.output {
        Some(p) => p.clone(),
        None => {
            let p = Path::new(&args.input);
            let stem = p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "a.out".into());
            let dir = p.parent().map(|d| d.to_path_buf()).unwrap_or_default();
            let cand = dir.join(&stem);
            if cand == p {
                format!("{}.out", cand.display())
            } else {
                cand.to_string_lossy().to_string()
            }
        }
    };
    let out_path = if out_path.contains('/') { out_path } else { format!("./{}", out_path) };
    if let Err(e) = std::fs::write(&out_path, &bytes) {
        eprintln!("error: cannot write `{}`: {}", out_path, e);
        return 1;
    }
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&out_path, std::fs::Permissions::from_mode(0o755));
    }
    if args.cmd == "run" || args.cmd == "test" {
        let st = std::process::Command::new(&out_path).args(&args.rest).status();
        return match st {
            Ok(s) => s.code().unwrap_or(128 + 11),
            Err(e) => {
                eprintln!("error: cannot run `{}`: {}", out_path, e);
                1
            }
        };
    }
    0
}

fn main() {
    // deep recursion in the frontend and SSA construction: use a big stack
    let h = std::thread::Builder::new().stack_size(1 << 30).spawn(real_main).unwrap();
    let code = h.join().unwrap_or(101);
    std::process::exit(code);
}
