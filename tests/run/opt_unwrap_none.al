// unwrap of None stops the program
main :: () {
    o: Opt[i64] = Some(1)
    print(o.unwrap())
    o = None
    print(o.unwrap())
    print("not reached")
}
