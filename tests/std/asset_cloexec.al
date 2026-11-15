// read_bytes and list_dir open with O_CLOEXEC, so their descriptors never reach a program started
// meanwhile. A child reports the flags of the descriptor that read_bytes has open on a FIFO.
use std.os

fn main() {
    fifo := fmt("/tmp/al_cloexec_", process_id())
    syscall(133, cstr(fifo), 0o10600, 0)          // mknod(fifo, S_IFIFO | 0600)
    defer { remove_file(fifo) }
    // (the child's open of the FIFO can return before read_bytes' own open has put its
    // descriptor into /proc: the child looks again, for up to 5 s, until it is there)
    script := `exec 9>"$1"; n=0; while [ $n -lt 500 ]; do for f in /proc/$PPID/fd/*; do if [ "$(readlink $f)" = "$1" ]; then grep flags /proc/$PPID/fdinfo/${f##*/} >&9; exit 0; fi; done; n=$((n+1)); sleep 0.01; done`
    p, ok := spawn([]str{"sh", "-c", script, "sh", fifo})
    text, ok2 := read_bytes(fifo)
    wait(p)
    v, _ := parse_i64(trim(trim(text)[6..]), 8)
    print(ok, ok2, v & 0o2000000 != 0)
}
