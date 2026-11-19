// Crypt's HUD and menus, drawn with the batcher of ui.al in a virtual space HUD_H units high
// (as wide as the window's aspect ratio makes it): the title screen, the play HUD with its map,
// the pause menu and the end screens. Dark translucent panels with thin gold rules, text in a
// TrueType font over shadows, glows added behind what should shine. It reads the game and never
// changes it. (The scripted test checks pixels of some of these elements: see PROBES in
// front.al. It checks shapes that do not depend on the font found on the machine.)
use "logic.al"
use "ui.al"

const HUD_H = 270                  // the HUD is drawn in a virtual space 270 units high

const WHITE: u32 = 0xFFFFFFFF
const GREY = rgb8(170, 170, 170)
const SILVER = rgb8(176, 176, 176)
const MENU_TEXT = rgb8(235, 232, 225)
const PALE = rgb8(214, 204, 186)
const YELLOW = rgb8(255, 224, 64)
const GOLD = rgb8(196, 150, 72)
const RED = rgb8(232, 40, 40)
const GREEN = rgb8(96, 232, 120)
const MAP_WALL = rgb8(112, 118, 140)

// A colour with its alpha replaced (0..1).
priv fn with_alpha(c: u32, a: f32) -> u32 { (c & 0x00FFFFFF) | (u32(clamp(a, 0.0, 1.0) * 255.0) << 24) }

priv fn clock_text(seconds: f32) -> str {
    t := i64(seconds)
    fmt(t / 60, ":", fmti(t % 60, 2, '0'))
}

// A dark panel with a faint lighter top and a thin gold frame with a small diamond at each corner.
priv fn panel(u: *Ui, x: f32, y: f32, w: f32, h: f32) {
    u.ui_rect(x, y, w, h, rgba8(12, 10, 12, 215))
    u.ui_fade(x, y, w, h * 0.5, rgba8(90, 70, 50, 40))
    frame(u, x, y, w, h, with_alpha(GOLD, 0.8))
}

priv fn frame(u: *Ui, x: f32, y: f32, w: f32, h: f32, c: u32) {
    u.ui_rect(x, y, w, 1.0, c)
    u.ui_rect(x, y + h - 1.0, w, 1.0, c)
    u.ui_rect(x, y + 1.0, 1.0, h - 2.0, c)
    u.ui_rect(x + w - 1.0, y + 1.0, 1.0, h - 2.0, c)
    for k in 0..4 {
        cx := if k % 2 == 0 { x } else { x + w }
        cy := if k < 2 { y } else { y + h }
        diamond(u, cx, cy, 3.0, c)
    }
}

priv fn diamond(u: *Ui, x: f32, y: f32, r: f32, c: u32) {
    u.ui_sprite(x - r, y - r, 2.0 * r, 2.0 * r, f32(ICON_DIAMOND), f32(ICON_Y), 32.0, 32.0, c)
}

// A gold rule fading out at both ends with a diamond in the middle.
priv fn rule(u: *Ui, cx: f32, y: f32, half: f32) {
    steps := 12
    for k in 0..steps {
        t := (f32(k) + 0.5) / f32(steps)
        a := 0.85 * (1.0 - t)
        u.ui_rect(cx + half * f32(k) / f32(steps), y, half / f32(steps), 1.0, with_alpha(GOLD, a))
        u.ui_rect(cx - half * f32(k + 1) / f32(steps), y, half / f32(steps), 1.0, with_alpha(GOLD, a))
    }
    diamond(u, cx, y + 0.5, 3.0, GOLD)
}

// A soft round glow added to the picture, centred on (x, y).
priv fn glow(u: *Ui, x: f32, y: f32, rx: f32, ry: f32, c: u32) {
    u.ui_glow(x - rx, y - ry, 2.0 * rx, 2.0 * ry, f32(ICON_DISK), f32(ICON_Y), 64.0, 64.0, c)
}

fn draw_hud(u: *Ui, g: *Game, w: f32, note: str) {
    h := f32(HUD_H)
    cx := w / 2.0
    t := f32(g.time)
    pulse := 0.6 + 0.4 * sin(t * 4.0)
    match g.mode {
        Title => draw_title(u, g, w)
        Playing, Paused => {
            draw_status(u, g, w)
            if g.mode == Paused {
                draw_menu(u, g, w)
            }
        }
        Won, Lost => {
            draw_status(u, g, w)
            u.ui_rect(0.0, 0.0, w, h, 0x99000000)
            won := g.mode == Won
            text := if won { "YOU ESCAPED" } else { "CAUGHT" }
            col := if won { GREEN } else { RED }
            glow(u, cx, 84.0, 150.0, 40.0, if won { rgba8(40, 160, 70, 255) } else { rgba8(170, 20, 10, 255) })
            // a banner: the verdict between two bars of its colour
            u.ui_rect(cx - 140.0, 65.0, 280.0, 4.0, col)
            u.ui_rect(cx - 140.0, 96.0, 280.0, 4.0, col)
            diamond(u, cx - 140.0, 67.0, 5.0, col)
            diamond(u, cx + 140.0, 67.0, 5.0, col)
            diamond(u, cx - 140.0, 98.0, 5.0, col)
            diamond(u, cx + 140.0, 98.0, 5.0, col)
            u.ui_text_centered(cx, 73.0, TEXT_XL, text, col)
            u.ui_text_centered(cx, 118.0, TEXT_M, fmt("Score ", g.score), WHITE)
            u.ui_text_centered(cx, 145.0, TEXT_S, if g.score >= g.best && g.score > 0 { "New best!" } else { fmt("Best ", g.best) }, YELLOW)
            if g.end_time > 1.0 {
                u.ui_text_centered(cx, 180.0, TEXT_S, "Press Enter or A", with_alpha(WHITE, pulse))
            }
        }
    }
    if note != "" {
        u.ui_text_shadow(4.0, h - 10.0, TEXT_S, note, rgb8(255, 192, 96))
    }
}

// The title: the world turning slowly behind dark bands, the gilded name with a warm glow, the
// one-line story, a pulsing prompt and the controls on a panel.
priv fn draw_title(u: *Ui, g: *Game, w: f32) {
    h := f32(HUD_H)
    cx := w / 2.0
    t := f32(g.time)
    u.ui_rect(0.0, 0.0, w, h, 0x40000000)
    u.ui_fade(0.0, 0.0, w, 130.0, 0xD0000000)
    u.ui_fade_up(0.0, 150.0, w, 120.0, 0xE0000000)
    // the name: glow, then the letters
    lw: f32 = 220.0
    lh := lw * f32(LOGO_H) / f32(LOGO_W)
    lx := floor(cx - lw / 2.0)
    ly: f32 = 45.0
    flicker := 0.85 + 0.1 * sin(t * 7.3) * sin(t * 3.1)
    glow(u, cx, ly + lh / 2.0, lw * 0.9, lh * 1.4, with_alpha(rgb8(150, 60, 10), flicker))
    pad := 16.0 * lw / f32(LOGO_W)
    u.ui_glow(lx - pad, ly - pad, lw + 2.0 * pad, lh + 2.0 * pad, f32(GLOW_X), f32(GLOW_Y), f32(LOGO_W + 32), f32(LOGO_H + 32),
        with_alpha(rgb8(255, 150, 40), 0.55 * flicker))
    mg := f32(LOGO_M) * lw / f32(LOGO_W)
    u.ui_sprite(lx - mg, ly - mg, lw + 2.0 * mg, lh + 2.0 * mg, f32(LOGO_X - LOGO_M), f32(LOGO_Y - LOGO_M), f32(LOGO_W + 2 * LOGO_M),
        f32(LOGO_H + 2 * LOGO_M), WHITE)
    rule(u, cx, 103.0, 120.0)
    u.ui_text_centered(cx, 110.0, TEXT_S, "Take every gem, then find the exit. The wraiths hunt by sight.", PALE)
    a := 0.55 + 0.45 * sin(t * 3.5)
    u.ui_text_centered(cx, 140.0, TEXT_M, "Press Enter or A", with_alpha(WHITE, a))
    if g.best > 0 {
        u.ui_text_centered(cx, 170.0, TEXT_S, fmt("Best ", g.best), YELLOW)
    }
    // the controls on a panel with a silver frame
    pw: f32 = 360.0
    u.ui_rect(cx - pw / 2.0, 196.0, pw, 39.0, rgba8(10, 8, 10, 180))
    frame(u, cx - pw / 2.0, 196.0, pw, 39.0, SILVER)
    u.ui_text_centered(cx, 201.0, TEXT_S, "Move  WASD / left stick       Look  mouse / right stick", GREY)
    u.ui_text_centered(cx, 212.0, TEXT_S, "Lantern flash  F / right click / X  (stuns wraiths)", GREY)
    u.ui_text_centered(cx, 223.0, TEXT_S, "Pause  Esc / Start      Fullscreen  F11      Quit  Esc", GREY)
}

// The play HUD: gems, life, time, the lantern's charge, a crosshair, the map.
priv fn draw_status(u: *Ui, g: *Game, w: f32) {
    h := f32(HUD_H)
    t := f32(g.time)
    // the corners darken softly behind the numbers
    u.ui_sprite(-90.0, -60.0, 300.0, 150.0, f32(ICON_DISK), f32(ICON_Y), 64.0, 64.0, 0xA0000000)
    u.ui_sprite(w - 110.0, -45.0, 200.0, 90.0, f32(ICON_DISK), f32(ICON_Y), 64.0, 64.0, 0xA0000000)
    if g.hurt > 0.0 {
        u.ui_rect(0.0, 0.0, w, h, with_alpha(rgb8(160, 0, 0), clamp(g.hurt / 1.5, 0.0, 1.0) * 0.25))
    }
    // crosshair: a small cross over a dark shadow (not behind the menu)
    if g.mode == Playing {
        u.ui_rect(w / 2.0 - 4.0, h / 2.0 + 1.0, 9.0, 1.0, 0x60000000)
        u.ui_rect(w / 2.0 + 1.0, h / 2.0 - 4.0, 1.0, 9.0, 0x60000000)
        u.ui_rect(w / 2.0 - 4.0, h / 2.0, 9.0, 1.0, 0xE0FFFFFF)
        u.ui_rect(w / 2.0, h / 2.0 - 4.0, 1.0, 9.0, 0xE0FFFFFF)
    }

    // the gems: an icon and the count
    glow(u, 17.0, 16.0, 15.0, 13.0, rgba8(90, 70, 0, 255))
    u.ui_sprite(6.0, 6.0, 22.0, 20.0, f32(ICON_GEM), f32(ICON_Y), 32.0, 32.0, YELLOW)
    u.ui_text_shadow(33.0, 9.0, TEXT_M, fmt(g.got, " / ", g.n_gems), YELLOW)
    for k in 0..MAX_HP {
        x := 8.0 + f32(k) * 14.0
        if k < g.hp {
            glow(u, x + 5.5, 33.0, 9.0, 8.0, rgba8(120, 10, 10, 255))
            u.ui_sprite(x - 0.5, 27.5, 12.0, 11.0, f32(ICON_HEART), f32(ICON_Y), 32.0, 32.0, RED)
        } else {
            u.ui_sprite(x - 0.5, 27.5, 12.0, 11.0, f32(ICON_HEART), f32(ICON_Y), 32.0, 32.0, 0x90302830)
        }
    }
    clock := clock_text(g.run_time)
    u.ui_text_shadow(w - 8.0 - u.ui_text_width(TEXT_M, clock), 9.0, TEXT_M, clock, WHITE)

    // the lantern: a flame and a bar, full (and glowing) when it can flash again
    charge := 1.0 - g.flash_wait / FLASH_WAIT
    ready := charge >= 1.0
    u.ui_sprite(7.0, 41.0, 8.0, 10.0, f32(ICON_FLAME), f32(ICON_Y), 32.0, 32.0, if ready { rgb8(255, 190, 80) } else { GREY })
    u.ui_rect(18.0, 44.0, 42.0, 5.0, 0xA0000000)
    u.ui_rect(19.0, 45.0, 40.0 * charge, 3.0, if ready { YELLOW } else { rgb8(150, 120, 80) })
    if ready {
        glow(u, 39.0, 46.5, 28.0, 6.0, with_alpha(rgb8(120, 80, 10), 0.5 + 0.3 * sin(t * 3.0)))
    }
    if exit_open(g) && g.mode == Playing {
        a := 0.75 + 0.25 * sin(t * 3.0)
        glow(u, w / 2.0, 33.5, 60.0, 10.0, with_alpha(rgb8(20, 110, 40), a))
        u.ui_text_centered(w / 2.0, 29.0, TEXT_S, "The exit is open", with_alpha(GREEN, a))
    }
    draw_map(u, g, w)
}

// The map, bottom right, 3 units a cell: the walls, the gems left, the exit, and the player as
// an arrow with a faint cone of view.
priv fn draw_map(u: *Ui, g: *Game, w: f32) {
    h := f32(HUD_H)
    t := f32(g.time)
    k: f32 = 3.0
    x0 := w - 8.0 - k * f32(MAP_W)
    y0 := h - 8.0 - k * f32(MAP_H)
    mw := k * f32(MAP_W)
    mh := k * f32(MAP_H)
    u.ui_rect(x0 - 3.0, y0 - 3.0, mw + 6.0, mh + 6.0, rgba8(10, 10, 14, 225))
    frame(u, x0 - 3.0, y0 - 3.0, mw + 6.0, mh + 6.0, with_alpha(GOLD, 0.7))
    for r in 0..MAP_H {
        for c in 0..MAP_W {
            if is_wall(c, r) {
                u.ui_rect(x0 + f32(c) * k, y0 + f32(r) * k, k, k, MAP_WALL)
                if !is_wall(c, r + 1) {
                    u.ui_rect(x0 + f32(c) * k, y0 + f32(r) * k + k - 0.75, k, 0.75, rgb8(64, 66, 82))
                }
            }
        }
    }
    for i in 0..g.n_gems {
        if !g.gems[i].taken {
            p := g.gems[i].pos / CELL * k
            diamond(u, x0 + p.x, y0 + p.y, 1.8, YELLOW)
        }
    }
    e := g.exit / CELL * k
    if exit_open(g) {
        glow(u, x0 + e.x, y0 + e.y, 6.0, 6.0, with_alpha(rgb8(30, 160, 60), 0.6 + 0.3 * sin(t * 4.0)))
        diamond(u, x0 + e.x, y0 + e.y, 2.5, GREEN)
    } else {
        diamond(u, x0 + e.x, y0 + e.y, 2.2, rgb8(120, 40, 40))
    }
    // the player: a cone of view, then an arrow pointing along the view
    p := g.pos / CELL * k + vec2(x0, y0)
    f := forward_of(g.yaw)
    r := right_of(g.yaw)
    c0 := p + f * 9.0 - r * 6.0
    c1 := p + f * 9.0 + r * 6.0
    u.ui_quad4(p, p, c0, c1, f32(ICON_DISK + 32), f32(ICON_Y + 32), 1.0, 1.0, rgba8(255, 200, 120, 50), false)
    tip := p + f * 2.6
    l := p - f * 1.6 - r * 1.7
    rr := p - f * 1.6 + r * 1.7
    back := p - f * 0.8
    u.ui_quad4(tip, tip, l, back, f32(WHITE_X + 8), f32(WHITE_Y + 8), 8.0, 8.0, WHITE, false)
    u.ui_quad4(tip, tip, back, rr, f32(WHITE_X + 8), f32(WHITE_Y + 8), 8.0, 8.0, WHITE, false)
}

priv fn draw_menu(u: *Ui, g: *Game, w: f32) {
    u.ui_rect(0.0, 0.0, w, f32(HUD_H), 0x80000000)
    cx := w / 2.0
    panel(u, cx - 180.0, 26.0, 360.0, 204.0)
    u.ui_text_centered(cx, 40.0, TEXT_L, "PAUSED", WHITE)
    rule(u, cx, 70.0, 100.0)
    labels := [MENU_ITEMS]str{"Resume", "Music", "Sound", "Mouse speed", "Invert look", "Fullscreen", "Quit to title"}
    left := cx - 90.0
    for i, label in labels {
        y := 84.0 + f32(i) * 16.0
        selected := i == g.menu
        color := if selected { YELLOW } else { MENU_TEXT }
        if selected {
            // the chosen line: a faint band, a bar at its left end and a line under it
            u.ui_rect(left - 16.0, y - 4.0, 196.0, 15.0, rgba8(255, 200, 80, 34))
            u.ui_rect(left - 16.0, y - 4.0, 2.0, 15.0, YELLOW)
            u.ui_rect(left - 16.0, y + 11.0, 196.0, 2.0, YELLOW)
            diamond(u, left - 9.0, y + 3.5, 2.5, YELLOW)
        }
        u.ui_text_shadow(left, y, TEXT_S, label, color)
        level := match i { MENU_MUSIC => g.settings.music; MENU_SOUND => g.settings.sound; MENU_MOUSE => g.settings.mouse; _ => -1 }
        if level >= 0 {
            for k in 0..VOLUME_STEPS {
                on := k < level
                u.ui_rect(left + 100.0 + f32(k) * 7.0, y, 5.0, 7.0, if on { color } else { rgba8(70, 64, 60, 255) })
                if on {
                    u.ui_rect(left + 100.0 + f32(k) * 7.0, y, 5.0, 2.0, 0x50FFFFFF)
                }
            }
        }
        if i == MENU_INVERT {
            u.ui_text_shadow(left + 100.0, y, TEXT_S, if g.settings.invert { "On" } else { "Off" }, color)
        }
    }
    u.ui_text_centered(cx, 210.0, TEXT_S, "Up / Down choose    Left / Right change    Esc / B back", GREY)
}
