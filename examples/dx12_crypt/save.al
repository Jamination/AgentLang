// The best score and the settings, kept in one small INI file in the user's data directory
// (std.asset's data_dir: %APPDATA%/al_crypt on Windows, ~/.local/share/al_crypt on Linux).
// The text conversion is pure, so the scripted run can check the round trip without touching
// the user's files.
use std.asset
use "logic.al"

const SAVE_APP = "al_crypt"
const SAVE_FILE = "crypt.ini"

fn save_text(g: *Game) -> str {
    s := g.settings
    fmt("# Crypt (AL example): best score and settings\nbest = ", g.best, "\n[settings]\nmusic = ", s.music,
        "\nsound = ", s.sound, "\nmouse = ", s.mouse, "\ninvert = ", s.invert, "\n")
}

// Applies saved text to the game; missing or broken values keep what the game has.
fn load_text(g: *Game, text: str) {
    c := config_parse(text)
    s := &g.settings
    g.best = max(c.get_i64("best", g.best), 0)
    s.music = clamp(c.get_i64("settings.music", s.music), 0, VOLUME_STEPS)
    s.sound = clamp(c.get_i64("settings.sound", s.sound), 0, VOLUME_STEPS)
    s.mouse = clamp(c.get_i64("settings.mouse", s.mouse), 1, 10)
    s.invert = c.get_bool("settings.invert", s.invert)
}

// The path of the save file in `dir` ("" : the user's data directory); "" if there is none.
fn save_path(dir: str) -> str {
    if dir != "" {
        make_dir(dir)
        return path_join(dir, SAVE_FILE)
    }
    d, ok := data_dir(SAVE_APP)
    if !ok {
        return ""
    }
    path_join(d, SAVE_FILE)
}

// Reads the save file if there is one. Returns whether one was read.
fn load_save(g: *Game, path: str) -> bool {
    if path == "" {
        return false
    }
    text, ok := read_bytes(path)
    if ok {
        load_text(g, text)
    }
    ok
}

// Writes the save file if something changed since the last call. "" or why it failed.
fn store_save(g: *Game, path: str) -> str {
    if !g.settings_changed && !g.best_changed {
        return ""
    }
    g.settings_changed = false
    g.best_changed = false
    if path == "" {
        return "no data directory for the save file"
    }
    if !write_bytes(path, save_text(g)) {
        return fmt("cannot write ", path, ": ", error_text(io_error()))
    }
    ""
}

test "save text round trip" {
    g := game_new(1)
    g.best = 1234
    g.settings = Settings{music: 2, sound: 9, mouse: 7, invert: true}
    h := game_new(2)
    h.load_text(save_text(&g))
    assert h.best == 1234 && h.settings == g.settings, fmt(h.best, " ", h.settings)
    h.load_text("best = -5\n[settings]\nmouse = 99\nmusic = loud\n")
    assert h.best == 0 && h.settings.mouse == 10 && h.settings.music == 2
}
