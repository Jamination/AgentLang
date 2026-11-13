// platform code chosen with `when`: a function of the system on each target (the other one is
// not type-checked, so the Windows import and the Linux system call never meet), and the
// target constants in ordinary code
when TARGET_OS == Windows {
    extern "kernel32.dll" fn GetCurrentProcessId() -> u32
    fn pid() -> i64 { i64(GetCurrentProcessId()) }
    const PATH_SEP = '\\'
} else {
    fn pid() -> i64 { syscall(39) }
    const PATH_SEP = '/'
}

const ON_WINDOWS = TARGET_OS == Os.Windows

fn main() {
    print(pid() > 0, TARGET_OS == Linux || TARGET_OS == Windows, ON_WINDOWS == (TARGET_OS != Linux))
    match TARGET_OS {
        Linux => print(PATH_SEP == '/')
        Windows => print(PATH_SEP == '\\')
    }
    if TARGET_OS == Windows {
        print(fmt(TARGET_OS) == "Windows")
    } else {
        print(fmt(TARGET_OS) == "Linux")
    }
}
