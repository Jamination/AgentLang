use "../../examples/starter/game.al"
fn moved(key: i64) -> vec2 {
    g := game_new(1)
    inp: Input
    start := g.ents.get(g.player).pos
    inp.begin_frame()
    inp.feed(Event{kind: EventKeyDown, key: key})
    for i in 0..30 {
        update(&g, &inp, 1.0 / f32(HZ))
        inp.begin_frame()
    }
    g.ents.get(g.player).pos - start
}
test "directions" {
    assert moved(KEY_UP).y < 0.0 && moved(KEY_DOWN).y > 0.0 && moved(KEY_LEFT).x < 0.0 && moved(KEY_RIGHT).x > 0.0
    assert moved(KEY_W).y < 0.0 && moved(KEY_S).y > 0.0
}
