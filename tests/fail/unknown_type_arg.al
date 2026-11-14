// an unknown name as a type argument is reported as an unknown type
fn main() {
    print(sizeof[Missing]())
}
