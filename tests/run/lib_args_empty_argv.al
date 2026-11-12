// A program started with an empty argv (execve with argv = {NULL}): Linux (since 5.18) passes
// argc 1 with an empty argv[0], older kernels argc 0; args() is then [""] or [], nothing else.
fn main() {
    a := args()
    _, child := env_get("AL_EMPTY_ARGV")
    if child {
        print("child:", len(a) == 0 || (len(a) == 1 && a[0] == ""))
        return
    }
    flush()
    pid := syscall(57)
    if pid == 0 {
        argv := [1]i64{0}
        envp := [2]i64{cast[i64](ptr("AL_EMPTY_ARGV=1")), 0}
        syscall(59, cstr(a[0]), ptr(argv), ptr(envp))   // execve
        exit(99)
    }
    status: i32
    syscall(61, pid, &status, 0, 0)
    print("parent:", len(a) >= 1, (status >> 8) & 255)
}
