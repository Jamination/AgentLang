// std.input: how mouse_delta and mouse_pos follow fed events, and feed_motion (relative motion,
// as a locked cursor's raw motion) for scripted runs
use std.input

fn show(i: *Input, what: str) {
    print(what, "pos", mouse_pos(i), "delta", mouse_delta(i))
}

fn main() {
    inp: Input
    inp.begin_frame()
    // the first position has no delta: nothing to measure it from
    inp.feed(Event{kind: EventMouseMove, x: 100, y: 50})
    show(&inp, "first position:")
    inp.feed(Event{kind: EventMouseMove, x: 110, y: 45})
    inp.feed(Event{kind: EventMouseDown, key: MOUSE_LEFT, x: 112, y: 45})
    show(&inp, "two more positions:")
    inp.begin_frame()
    show(&inp, "next frame:")
    // relative motion: delta and position move together, fractions and all, without bounds
    inp.feed_motion(-30.5, 0.25)
    inp.feed_motion(-200.0, 0.0)
    show(&inp, "motion:")
    // a position fed afterwards counts from the moved position
    inp.feed(Event{kind: EventMouseMove, x: -110, y: 50})
    show(&inp, "then a position:")
    inp.begin_frame()
    // a fresh Input: motion alone, starting at (0, 0)
    bot: Input
    bot.begin_frame()
    bot.feed_motion(12.0, -3.0)
    show(&bot, "bot:")
}
