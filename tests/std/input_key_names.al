// key_from_name folds the case of letters only: control characters 0x10-0x19 OR 0x20 are the
// digits, so "\x11" used to be KEY_1 and "Kp\x17" KEY_KP_7
use std.input

fn main() {
    print(key_from_name("\x11"), key_from_name("Kp\x17"), key_from_name("f\x11\x10"), key_from_name("\x01"))
    print(key_from_name("1") == KEY_1, key_from_name("kp7") == KEY_KP_7, key_from_name("F10") == KEY_F10, key_from_name("lshift") == KEY_LSHIFT, key_from_name("SPACE") == KEY_SPACE)
    n := 0
    for k in 0..KEY_COUNT {
        if key_from_name(key_name(k)) == k && key_from_name(to_lower(key_name(k))) == k && key_from_name(to_upper(key_name(k))) == k { n += 1 }
    }
    print(n, KEY_COUNT)
}
