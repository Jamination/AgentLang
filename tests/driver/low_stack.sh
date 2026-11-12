# with a stack limit the compiler cannot raise, deep nesting is an error, never a crash
set -u
ALC=$1; D=$2; cd "$D" || exit 1
python3 -c "
n = 1500
print('fn f(x: i64) -> i64 { x }')
print('fn main() {\n' + '{' * n + '\n' + '}' * n + '\n}')
print('fn g() {\n x := ' + '(' * n + '1' + ')' * n + '\n}')
x = '1'
for k in range(8): x = '(' + x + ')' + '.f()' * 200
print('fn h() {\n x := ' + x + '\n}')" > deep.al || exit 1
printf 'fn main() {\n    print((1 + 2) * 3)\n}\n' > ok.al
for st in 2048 8192; do
  ( ulimit -s $st && "$ALC" check deep.al ) 2>err; code=$?
  [[ $code == 1 ]] || { echo "FAIL: stack $st: status $code"; head -3 err; exit 1; }
  [[ $(grep -c "nesting is too deep" err) == 3 ]] || { echo "FAIL: stack $st"; head -3 err; exit 1; }
  ( ulimit -s $st && "$ALC" run ok.al ) >out || { echo "FAIL: ok.al with stack $st"; exit 1; }
done
exit 0
