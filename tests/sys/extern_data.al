// `extern "lib" name: T`: C variables of libc, read and written through their import slots
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

struct Opts { argc: i32, argv: [4]*u8 }

// a pointer to a C variable is an ordinary pointer
fn bump(p: *i32) { *p += 1 }

fn main() {
    n := 0
    while environ[n] != nil { n += 1 }
    print("environment entries:", n > 0, "stdout:", fileno(stdout), "stderr:", fileno(stderr))
    print("optind:", optind, "opterr:", opterr)
    // written here, read by libc: getopt starts at optind and does not print when opterr is 0
    opterr = 0
    o := Opts{4, [4]*u8{ptr("prog"), ptr("-a"), ptr("-x"), ptr("-b")}}
    optind = 2
    print("unknown -x:", getopt(o.argc, &o.argv[0], ptr("ab")) == '?', "optind:", optind)
    // written by libc, read here
    print("-b:", getopt(o.argc, &o.argv[0], ptr("ab")) == 'b', "optind:", optind)
    print("end:", getopt(o.argc, &o.argv[0], ptr("ab")), "optind:", optind)
    p := &optind
    *p = 10
    bump(&optind)
    print("through pointers:", optind, *p)
    // a new environment for getenv
    vars := [3]*u8{ptr("AL_A=1"), ptr("AL_B=two"), nil}
    saved := environ
    environ = &vars[0]
    print("getenv:", from_cstr(getenv(ptr("AL_B"))), getenv(ptr("HOME")) == nil)
    environ = saved
    flush()
    fputs(ptr("written through stdout\n"), stdout)
    fflush(stdout)
}
