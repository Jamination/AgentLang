// data_dir / config_dir: the per-user directory of an application, created on the way. The
// program runs itself ("child") in prepared environments with directories under tmp/, so the
// user's real directories are never touched: on Linux through `env -i`, on Windows (Wine)
// through `cmd /c set ...`, which also checks the prefix's own %APPDATA%.
use std.os

const APP = "al_user_dirs_test"

// the child: one line per call, "path ok exists"
fn child() {
    for app in args()[2..] {
        a := if app == "-" { "" } else { app }
        d, dok := data_dir(a)
        c, cok := config_dir(a)
        print(d, dok, is_dir(d))
        print(c, cok, is_dir(c))
    }
    _, ok := data_dir(APP)
    if !ok {
        print("io_error:", error_text(io_error()))
    }
}

struct Case { name: str, env: []str, apps: []str, want: []str }

fn line(path: str, ok: bool) -> str {
    fmt(path, " ", ok, " ", ok)
}

when TARGET_OS == Windows {
    fn run_child(self_path: str, env: []str, apps: []str) -> str {
        cmd := ""
        for e in env {
            cmd = fmt(cmd, "set ", e, "&&")
        }
        cmd = fmt(cmd, self_path, " child ", join(apps, " "))
        out, _ := run_capture([]str{"cmd", "/c", cmd})
        replace(out, "\r\n", "\n")
    }

    fn cases(root: str) -> []Case {
        appdata, _ := env_get("APPDATA")
        ad := path_join(root, "appdata")
        prof := path_join(root, "profile")
        roaming := path_join(prof, "AppData/Roaming")
        file := path_join(root, "file")
        []Case{
            Case{"own environment", []str{}, []str{APP}, []str{line(path_join(appdata, APP), true), line(path_join(appdata, APP), true)}},
            Case{"variables", []str{fmt("APPDATA=", ad)}, []str{APP}, []str{line(path_join(ad, APP), true), line(path_join(ad, APP), true)}},
            Case{"nested and empty names", []str{fmt("APPDATA=", ad)}, []str{"studio/game", "-"}, []str{line(path_join(ad, "studio/game"), true), line(path_join(ad, "studio/game"), true), line(ad, true), line(ad, true)}},
            Case{"fallback", []str{"APPDATA=", fmt("USERPROFILE=", prof)}, []str{APP}, []str{line(path_join(roaming, APP), true), line(path_join(roaming, APP), true)}},
            Case{"nothing set", []str{"APPDATA=", "USERPROFILE="}, []str{APP}, []str{" false false", " false false", "io_error: no such file or directory"}},
            Case{"cannot be created", []str{fmt("APPDATA=", file)}, []str{APP}, []str{line(path_join(file, APP), false), line(path_join(file, APP), false), "io_error: no such file or directory"}},
        }
    }

    fn cleanup(root: str) {
        appdata, _ := env_get("APPDATA")
        remove_dir(path_join(appdata, APP))
        run([]str{"cmd", "/c", fmt("rmdir /s /q ", replace(root, "/", "\\"))})
    }
} else {
    fn run_child(self_path: str, env: []str, apps: []str) -> str {
        argv := vec_of([]str{"env"})
        if len(env) == 0 || env[0] != "-" {
            argv.push("-i")
        }
        for e in env {
            if e != "-" {
                argv.push(e)
            }
        }
        argv.extend([]str{self_path, "child"})
        argv.extend(apps)
        out, _ := run_capture(argv.items())
        out
    }

    fn cases(root: str) -> []Case {
        xd := path_join(root, "xdg-data")
        xc := path_join(root, "xdg-config")
        home := path_join(root, "home")
        file := path_join(root, "file")
        []Case{
            // "-": the inherited environment with only the XDG variables changed
            Case{"own environment", []str{"-", fmt("XDG_DATA_HOME=", xd), fmt("XDG_CONFIG_HOME=", xc)}, []str{APP}, []str{line(path_join(xd, APP), true), line(path_join(xc, APP), true)}},
            Case{"variables", []str{fmt("XDG_DATA_HOME=", xd), fmt("XDG_CONFIG_HOME=", xc), fmt("HOME=", home)}, []str{APP}, []str{line(path_join(xd, APP), true), line(path_join(xc, APP), true)}},
            Case{"nested and empty names", []str{fmt("XDG_DATA_HOME=", xd), fmt("XDG_CONFIG_HOME=", xc)}, []str{"studio/game", "-"}, []str{line(path_join(xd, "studio/game"), true), line(path_join(xc, "studio/game"), true), line(xd, true), line(xc, true)}},
            Case{"fallback", []str{fmt("HOME=", home), "XDG_DATA_HOME=rel/data", "XDG_CONFIG_HOME="}, []str{APP}, []str{line(path_join(home, fmt(".local/share/", APP)), true), line(path_join(home, fmt(".config/", APP)), true)}},
            Case{"nothing set", []str{}, []str{APP}, []str{" false false", " false false", "io_error: no such file or directory"}},
            Case{"cannot be created", []str{fmt("HOME=", file)}, []str{APP}, []str{line(path_join(file, fmt(".local/share/", APP)), false), line(path_join(file, fmt(".config/", APP)), false), "io_error: not a directory"}},
        }
    }

    fn cleanup(root: str) {
        run([]str{"rm", "-rf", root})
    }
}

fn main() {
    a := args()
    if len(a) > 1 && a[1] == "child" {
        child()
        return
    }
    root := path_join(current_dir(), "tmp/al_user_dirs")
    make_dir(root)
    write_bytes(path_join(root, "file"), "not a directory")
    for c in cases(root) {
        got := run_child(a[0], c.env, c.apps)
        want := fmt(join(c.want, "\n"), "\n")
        print(c.name, got == want)
        if got != want {
            print("  want:", want)
            print("  got: ", got)
        }
    }
    cleanup(root)
}
