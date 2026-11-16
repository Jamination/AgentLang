// `extern LIB`: LIB must be a str constant
const COUNT = 3
extern NO_SUCH_LIB fn f() -> i32
extern COUNT fn g() -> i32

fn main() {
    print(f(), g())
}
