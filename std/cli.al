// std.cli: lightweight command-line flag, option and positional argument parser. `use std.cli`.
// Supports `--flag`, `-f`, `--no-flag`, `--opt val`, `--opt=val`, `-o val`, `-abc` combined
// short flags, `--` positional separator, `-h` / `--help`, and formatted help generation.

priv enum OptKind { CliBool, CliStr, CliI64 }

priv struct CliSpec {
    long: str
    short: str
    kind: OptKind
    def_str: str
    def_i64: i64
    help: str
}

// Command-line parser specification and parsed result.
struct Cli {
    prog: str
    desc: str
    specs: Vec[CliSpec]
    flags: Map[str, bool]
    strs: Map[str, str]
    ints: Map[str, i64]
    positionals: Vec[str]
    err: str
    help_requested: bool
}

// Creates a new CLI parser with program name `prog` and summary `desc`.
fn cli_new(prog: str, desc: str) -> Cli {
    return Cli{
        prog: prog,
        desc: desc,
        specs: vec[CliSpec](),
        flags: map[str, bool](),
        strs: map[str, str](),
        ints: map[str, i64](),
        positionals: vec[str](),
    }
}

// Registers a boolean flag (`--long` / `-short`, default false).
fn add_flag(c: *Cli, long: str, short: str, help: str) {
    c.specs.push(CliSpec{long: long, short: short, kind: CliBool, help: help})
    c.flags.set(long, false)
}

// Registers a string option (`--long <val>` / `-short <val>`).
fn add_str(c: *Cli, long: str, short: str, default: str, help: str) {
    c.specs.push(CliSpec{long: long, short: short, kind: CliStr, def_str: default, help: help})
    c.strs.set(long, default)
}

// Registers an integer option (`--long <n>` / `-short <n>`).
fn add_i64(c: *Cli, long: str, short: str, default: i64, help: str) {
    c.specs.push(CliSpec{long: long, short: short, kind: CliI64, def_i64: default, help: help})
    c.ints.set(long, default)
}

priv fn find_long(c: *Cli, name: str) -> i64 {
    for i in 0..c.specs.len {
        if c.specs[i].long == name {
            return i
        }
    }
    return -1
}

priv fn find_short(c: *Cli, name: str) -> i64 {
    for i in 0..c.specs.len {
        if len(c.specs[i].short) > 0 && c.specs[i].short == name {
            return i
        }
    }
    return -1
}

priv fn set_opt_val(c: *Cli, idx: i64, raw: str, display: str) -> bool {
    sp := &c.specs[idx]
    match sp.kind {
        CliStr => {
            c.strs.set(sp.long, raw)
            return true
        }
        CliI64 => {
            n, ok := parse_i64(raw, 0)
            if !ok {
                c.err = fmt("option ", display, " expects an integer, got `", raw, "`")
                return false
            }
            c.ints.set(sp.long, n)
            return true
        }
        CliBool => {
            c.err = fmt("flag ", display, " does not take a value")
            return false
        }
    }
}

// Parses `argv` (typically `args()[1..]`). Returns true on success (including `-h` / `--help`,
// which sets `c.help_requested = true`); false on error (with reason in `c.err`).
fn parse(c: *Cli, argv: []str) -> bool {
    c.err = ""
    c.help_requested = false
    c.positionals.clear()
    for sp in c.specs {
        match sp.kind {
            CliBool => c.flags.set(sp.long, false)
            CliStr => c.strs.set(sp.long, sp.def_str)
            CliI64 => c.ints.set(sp.long, sp.def_i64)
        }
    }
    i := 0
    only_pos := false
    while i < len(argv) {
        a := argv[i]
        if only_pos {
            c.positionals.push(a)
            i += 1
            continue
        }
        if a == "--" {
            only_pos = true
            i += 1
            continue
        }
        if a == "--help" || a == "-h" {
            c.help_requested = true
            i += 1
            continue
        }
        if starts_with(a, "--") && len(a) > 2 {
            body := a[2..]
            eq := find(body, "=")
            name := if eq >= 0 { body[..eq] } else { body }
            idx := find_long(c, name)
            if idx < 0 && eq < 0 && starts_with(name, "no-") {
                nidx := find_long(c, name[3..])
                if nidx >= 0 && c.specs[nidx].kind == CliBool {
                    c.flags.set(c.specs[nidx].long, false)
                    i += 1
                    continue
                }
            }
            if idx < 0 {
                c.err = fmt("unknown option `--", name, "`")
                return false
            }
            if c.specs[idx].kind == CliBool {
                if eq >= 0 {
                    v := body[eq + 1..]
                    if v == "true" || v == "1" {
                        c.flags.set(name, true)
                    } else if v == "false" || v == "0" {
                        c.flags.set(name, false)
                    } else {
                        c.err = fmt("flag `--", name, "` expects true/false, got `", v, "`")
                        return false
                    }
                } else {
                    c.flags.set(name, true)
                }
                i += 1
                continue
            }
            val := ""
            if eq >= 0 {
                val = body[eq + 1..]
            } else {
                i += 1
                if i >= len(argv) {
                    c.err = fmt("option `--", name, "` requires a value")
                    return false
                }
                val = argv[i]
            }
            if !set_opt_val(c, idx, val, fmt("`--", name, "`")) {
                return false
            }
            i += 1
            continue
        }
        if starts_with(a, "-") && len(a) > 1 {
            // Short flag(s): -v, -abc, or -o value
            j := 1
            while j < len(a) {
                ch := a[j..j + 1]
                if ch == "h" {
                    c.help_requested = true
                    j += 1
                    continue
                }
                idx := find_short(c, ch)
                if idx < 0 {
                    c.err = fmt("unknown option `-", ch, "`")
                    return false
                }
                if c.specs[idx].kind == CliBool {
                    c.flags.set(c.specs[idx].long, true)
                    j += 1
                    continue
                }
                val := ""
                if j + 1 < len(a) {
                    val = a[j + 1..]
                } else {
                    i += 1
                    if i >= len(argv) {
                        c.err = fmt("option `-", ch, "` requires a value")
                        return false
                    }
                    val = argv[i]
                }
                if !set_opt_val(c, idx, val, fmt("`-", ch, "`")) {
                    return false
                }
                break
            }
            i += 1
            continue
        }
        c.positionals.push(a)
        i += 1
    }
    return true
}

// Returns the value of a registered boolean flag.
fn flag(c: *Cli, name: str) -> bool {
    return c.flags.get_or(name, false)
}

// Returns the value of a registered string option.
fn opt_str(c: *Cli, name: str) -> str {
    return c.strs.get_or(name, "")
}

// Returns the value of a registered integer option.
fn opt_i64(c: *Cli, name: str) -> i64 {
    return c.ints.get_or(name, 0)
}

// Returns the positional arguments collected during `parse`.
fn pos(c: *Cli) -> []str {
    return c.positionals.items()
}

// Formats a human-readable usage and options help message.
fn help_text(c: *Cli) -> str {
    out := vec[u8]()
    out.extend(fmt("usage: ", c.prog, " [options] [args...]\n"))
    if len(c.desc) > 0 {
        out.extend(fmt(c.desc, "\n"))
    }
    out.extend("\noptions:\n")
    for sp in c.specs {
        lhs := if len(sp.short) > 0 { fmt("  -", sp.short, ", --", sp.long) } else { fmt("      --", sp.long) }
        lhs = match sp.kind {
            CliBool => lhs
            CliStr => concat(lhs, " <str>")
            CliI64 => concat(lhs, " <int>")
        }
        out.extend(pad_right(lhs, 26, ' '))
        out.extend(sp.help)
        match sp.kind {
            CliStr if len(sp.def_str) > 0 => out.extend(fmt(" (default: ", sp.def_str, ")"))
            CliI64 => out.extend(fmt(" (default: ", sp.def_i64, ")"))
            _ => {}
        }
        out.push('\n')
    }
    out.extend("  -h, --help              show this help message\n")
    return out.items()
}
