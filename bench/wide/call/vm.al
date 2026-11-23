// bytecode interpreter: enum instructions with payloads, a match dispatch loop

enum Ins {
    Push(i64)
    Load(i64)
    Store(i64)
    Inc(i64)
    Add
    Sub
    Mul
    And
    Or
    Xor
    Shl
    Shr
    Lt
    Eq
    Dup
    Swap
    Over
    Pop
    Jmp(i64)
    Jz(i64)
    Jnz(i64)
    Halt
}

fn run(code: []Ins) -> i64 {
    stack: [64]i64
    locals: [8]i64
    sp := 0
    pc := 0
    loop {
        ins := code[pc]
        pc += 1
        match ins {
            Push(v) => { stack[sp] = v; sp += 1 }
            Load(k) => { stack[sp] = locals[k]; sp += 1 }
            Store(k) => { sp -= 1; locals[k] = stack[sp] }
            Inc(k) => { locals[k] += 1 }
            Add => { sp -= 1; stack[sp - 1] += stack[sp] }
            Sub => { sp -= 1; stack[sp - 1] -= stack[sp] }
            Mul => { sp -= 1; stack[sp - 1] *= stack[sp] }
            And => { sp -= 1; stack[sp - 1] &= stack[sp] }
            Or => { sp -= 1; stack[sp - 1] |= stack[sp] }
            Xor => { sp -= 1; stack[sp - 1] ^= stack[sp] }
            Shl => { sp -= 1; stack[sp - 1] <<= stack[sp] }
            Shr => { sp -= 1; stack[sp - 1] >>= stack[sp] }
            Lt => { sp -= 1; stack[sp - 1] = if stack[sp - 1] < stack[sp] { 1 } else { 0 } }
            Eq => { sp -= 1; stack[sp - 1] = if stack[sp - 1] == stack[sp] { 1 } else { 0 } }
            Dup => { stack[sp] = stack[sp - 1]; sp += 1 }
            Swap => {
                t := stack[sp - 1]
                stack[sp - 1] = stack[sp - 2]
                stack[sp - 2] = t
            }
            Over => { stack[sp] = stack[sp - 2]; sp += 1 }
            Pop => { sp -= 1 }
            Jmp(t) => { pc = t }
            Jz(t) => {
                sp -= 1
                if stack[sp] == 0 { pc = t }
            }
            Jnz(t) => {
                sp -= 1
                if stack[sp] != 0 { pc = t }
            }
            Halt => { return stack[sp - 1] }
        }
    }
}

fn main() {
    n := 2000 + len(args())
    m := 1500
    code := []Ins{
        Push(0), Store(0), Push(0), Store(2),
        Load(0), Push(n), Lt, Jz(41),                       // 4: outer loop
        Push(0), Store(1),
        Load(1), Push(m), Lt, Jz(39),                       // 10: inner loop
        Load(2), Push(31), Mul,
        Load(0), Load(1), Xor, Dup, Push(3), Shl, Or, Add,
        Dup, Push(13), Shr, Swap, Xor,
        Load(1), Push(1), And, Jz(36), Push(7), Sub,
        Store(2), Inc(1), Jmp(10),                          // 36
        Inc(0), Jmp(4),                                     // 39
        Load(2), Halt,                                      // 41
    }
    total := 0
    for r in 0..3 {
        code[1] = Store(0)
        total = total * 7 + run(code)
    }
    put(total, "\n")
}
