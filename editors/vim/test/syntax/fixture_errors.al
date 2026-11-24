// Fixture for run.vim: text the lexer rejects (alc check reports errors here).
const A = "bad escape \q in a string"
const B = "short hex \x4 escape"
const BAD_BIN = 0b102
const BAD_HEX = 0xG1
const EMPTY_HEX = 0x
const UPPER_PREFIX = 0X1F
const C = "unterminated
const after_unterminated = 1
const TWO_BYTES = 'ab'
const NOT_FLOAT = 1.
const D = `open raw string
fn not_code() {} // to the end of the file
