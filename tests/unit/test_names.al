// test names with characters that cannot stand in a string literal as they are
test "line\nbreak" { assert 1 == 1 }
test "quote \" and backslash \\" { assert 2 == 2 }
test "tab\there\x01" { assert 3 == 3 }
