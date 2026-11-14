// a panic on a thread that a C library created names the thread and ends the process
use std.os

when TARGET_OS == Windows {
    extern "thread_ccb_panic.dll" fn call_from_thread(f: fn(i32), x: i32)
} else {
    extern "libthread_ccb_panic.so" fn call_from_thread(f: fn(i32), x: i32)
}

fn callback(x: i32) {
    s := fmt("value ", x)
    assert x < 5, s
}

fn main() {
    call_from_thread(callback, 9)
    print("not reached")
}
