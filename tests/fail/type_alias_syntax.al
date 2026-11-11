// a type alias cannot be generic; `type` after `::` needs a type on the same line
H[T] :: type Vec[T]
I :: type
J :: type = i64
main :: () {
    // `type` is an ordinary identifier everywhere else
    type := 3
    print(type)
}
