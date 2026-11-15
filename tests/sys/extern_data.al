// `extern "lib" name: T`: C variables of the C library (Linux: glibc, Windows: msvcrt.dll),
// read and written through their import slots
use std.os

when TARGET_OS == Windows {
    // FILE of msvcrt.dll: 48 bytes; _iob holds stdin, stdout, stderr
    struct CFile { words: [6]i64 }
    extern "msvcrt.dll" _environ: **u8
    extern "msvcrt.dll" _iob: [3]CFile
    extern "msvcrt.dll" _fmode: i32
    extern "msvcrt.dll" _sys_nerr: i32
    extern "msvcrt.dll" fn _fileno(f: *u8) -> i32
    extern "msvcrt.dll" fn _setmode(fd: i32, mode: i32) -> i32
    extern "msvcrt.dll" fn fputs(s: *u8, f: *u8) -> i32
    extern "msvcrt.dll" fn fflush(f: *u8) -> i32
    extern "msvcrt.dll" fn getenv(name: *u8) -> *u8
    extern "msvcrt.dll" fn fopen(path: *u8, mode: *u8) -> *u8
    extern "msvcrt.dll" fn fclose(f: *u8) -> i32
    extern "msvcrt.dll" fn _putenv(setting: *u8) -> i32

    const O_TEXT: i32 = 0x4000
    const O_BINARY: i32 = 0x8000
    const NOT_SET = "USERPROFILE"

    fn out() -> *u8 { cast[*u8](&_iob[1]) }
    fn err() -> *u8 { cast[*u8](&_iob[2]) }
    fn fd_of(f: *u8) -> i32 { _fileno(f) }
    fn env() -> ***u8 { &_environ }

    fn int_value() -> i32 { _fmode }

    // the size of a file that fopen(path, "w") and fputs("a\n") write
    fn written(path: str) -> i64 {
        f := fopen(cstr(path), ptr("w"))
        if f == nil {
            return -1
        }
        fputs(ptr("a\n"), f)
        fclose(f)
        n := file_size(path)
        remove_file(path)
        return n
    }

    fn entries() -> i64 {
        n := 0
        while _environ[n] != nil { n += 1 }
        return n
    }

    fn ints() -> *i32 {
        // (the stream writes "\n" as it is)
        _setmode(1, O_BINARY)
        print("initial values:", _fmode == 0 || _fmode == O_TEXT, _sys_nerr > 40 && _sys_nerr < 200)
        // _fmode: how fopen opens a file whose mode has neither "t" nor "b": a binary file
        // gets "\n" as it is, a text file "\r\n"
        make_dir("tmp")
        path := fmt("tmp/extern_data_", process_id())
        _fmode = O_BINARY
        binary := written(path)
        _fmode = O_TEXT
        print("written here, read by the library:", binary == 2, written(path) == 3)
        // _putenv puts a new variable into the array that _environ points to
        n := entries()
        _putenv(ptr("AL_EXTERN_DATA=1"))
        print("written by the library, read here:", entries() == n + 1 && from_cstr(_environ[n]) == "AL_EXTERN_DATA=1")
        return &_fmode
    }
} else {
    extern "libc.so.6" environ: **u8
    extern "libc.so.6" stdout: *u8
    extern "libc.so.6" stderr: *u8
    extern "libc.so.6" optind: i32
    extern "libc.so.6" opterr: i32
    extern "libc.so.6" fn fileno(f: *u8) -> i32
    extern "libc.so.6" fn fputs(s: *u8, f: *u8) -> i32
    extern "libc.so.6" fn fflush(f: *u8) -> i32
    extern "libc.so.6" fn getenv(name: *u8) -> *u8
    extern "libc.so.6" fn getopt(argc: i32, argv: **u8, optstring: *u8) -> i32

    const NOT_SET = "HOME"

    struct Opts { argc: i32, argv: [4]*u8 }

    fn out() -> *u8 { stdout }
    fn err() -> *u8 { stderr }
    fn fd_of(f: *u8) -> i32 { fileno(f) }
    fn env() -> ***u8 { &environ }
    fn int_value() -> i32 { optind }

    // getopt's variables: it starts at optind and does not print when opterr is 0
    fn ints() -> *i32 {
        print("initial values:", optind == 1, opterr == 1)
        opterr = 0
        o := Opts{4, [4]*u8{ptr("prog"), ptr("-a"), ptr("-x"), ptr("-b")}}
        optind = 2
        print("written here, read by the library:", getopt(o.argc, &o.argv[0], ptr("ab")) == '?', optind == 3)
        print("written by the library, read here:", getopt(o.argc, &o.argv[0], ptr("ab")) == 'b' && optind == 4 && getopt(o.argc, &o.argv[0], ptr("ab")) == -1 && optind == 4)
        return &optind
    }
}

// a pointer to a C variable is an ordinary pointer
fn bump(p: *i32) { *p += 1 }

fn main() {
    environ := env()
    n := 0
    while (*environ)[n] != nil { n += 1 }
    print("environment entries:", n > 0, "stdout:", fd_of(out()), "stderr:", fd_of(err()))
    p := ints()
    saved_int := *p
    *p = 10
    bump(p)
    print("through pointers:", int_value(), *p)
    *p = saved_int
    // a new environment for getenv
    vars := [3]*u8{ptr("AL_A=1"), ptr("AL_B=two"), nil}
    saved := *environ
    *environ = &vars[0]
    print("getenv:", from_cstr(getenv(ptr("AL_B"))), getenv(ptr(NOT_SET)) == nil)
    *environ = saved
    print("restored:", getenv(ptr(NOT_SET)) != nil)
    flush()
    fputs(ptr("written through stdout\n"), out())
    fflush(out())
}
