// assert in a private function called with method syntax; a struct method-style function
struct Account { id: i64, balance: i64 }

priv fn check(a: *Account) {
    assert a.balance >= 0, fmt("account ", a.id, " is overdrawn")
}

fn withdraw(self: *Account, amount: i64) {
    self.balance -= amount
    self.check()
}

fn main() {
    acct := Account{id: 7, balance: 10}
    acct.withdraw(4)
    print(acct.balance)
    acct.withdraw(9)
}
