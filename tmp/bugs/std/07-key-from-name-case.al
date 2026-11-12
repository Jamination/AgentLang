// key_from_name ignores "letter case" by comparing c | 0x20 for every byte, which also maps
// the control characters 0x10-0x19 onto the digits.
// expected: 0 0 0   actual (before the fix): 28 (KEY_1) 91 (KEY_KP_7) 70 (KEY_F10)
use std.input
fn main() {
    print(key_from_name("\x11"), key_from_name("Kp\x17"), key_from_name("f\x11\x10"))
}
