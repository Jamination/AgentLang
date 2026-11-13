// a `when` decided with the library's TARGET_ARCH includes a file whose own TARGET_ARCH would
// have decided it otherwise: the order of loading must not change the program
when TARGET_ARCH == X86_64 {
    use "lib/when_shadow.al"
}
fn main() {}
