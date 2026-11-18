// Color(i) with a number that is no variant's stops the program with a message that names
// the enum and the line
enum Color { Red, Green, Blue }

fn pick(i: i64) -> Color { Color(i) }

fn main() {
    print(pick(2))
    print(pick(3))
}
