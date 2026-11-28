# Diagnostic codes, `alc capabilities` and `alc explain`:
# - every diagnostic of tests/fail keeps the code recorded in tests/fail/CODES.txt (a message
#   that is reworded and loses its code fails here; after a deliberate change:
#   UPDATE=1 bash tests/driver/diag_codes.sh build/alc /tmp/x)
# - the codes of `alc capabilities` are unique and are exactly those of docs/DIAGNOSTICS.md
# - every question of its `semantics` is in docs/SEMANTICS.md
set -u
ALC=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); D=$2
REPO=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$D"
fail() { echo "FAIL: $*"; exit 1; }
cd "$REPO" || exit 1
"$ALC" capabilities >"$D/cap.json" 2>"$D/err" || fail "capabilities: status"
[[ -s "$D/err" ]] && fail "capabilities: stderr"
python3 - "$D/cap.json" docs/DIAGNOSTICS.md docs/SEMANTICS.md <<'PY' || fail "capabilities"
import json, re, sys
cap = json.load(open(sys.argv[1]))
codes = [d["code"] for d in cap["diagnostics"]]
bad = 0
if len(codes) != len(set(codes)):
    print("a diagnostic code is listed twice"); bad = 1
doc = set(re.findall(r"^### ([EW]\d{4}) ", open(sys.argv[2]).read(), re.M))
for c in sorted(set(codes) - doc):
    print("not in docs/DIAGNOSTICS.md:", c); bad = 1
for c in sorted(doc - set(codes)):
    print("in docs/DIAGNOSTICS.md, not a code:", c); bad = 1
sem = open(sys.argv[3]).read().lower()
for q in cap["semantics"]:
    if q["question"].lower() not in sem:
        print("not in docs/SEMANTICS.md:", q["question"]); bad = 1
for k in ("keywords", "builtin_types", "std_modules", "targets", "commands"):
    if not cap[k]:
        print("empty:", k); bad = 1
sys.exit(bad)
PY
for f in tests/fail/*.al; do
  flags=; [[ -f ${f%.al}.flags ]] && flags=$(cat "${f%.al}.flags")
  # shellcheck disable=SC2086
  "$ALC" check --target linux --json -W $flags "$f" 2>/dev/null; echo
done >"$D/diag.jsonl"
python3 - "$D/diag.jsonl" >"$D/codes.txt" <<'PY' || fail "tests/fail: not JSON"
import json, os, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    for d in json.loads(line):
        for k in ("code", "end_line", "end_col"):
            assert k in d, k
        assert d["end_line"] == d["line"] and d["end_col"] >= d["col"], d
        print(os.path.basename(d["file"]), f'{d["line"]}:{d["col"]}', d["code"])
PY
if [[ ${UPDATE:-} == 1 ]]; then
  cp "$D/codes.txt" tests/fail/CODES.txt
fi
diff -u tests/fail/CODES.txt "$D/codes.txt" >"$D/codes.diff" || { head -20 "$D/codes.diff"; fail "codes of tests/fail changed"; }
n=$(grep -c ' [EW]0000$' "$D/codes.txt"); [[ $n == 0 ]] || fail "$n diagnostic(s) of tests/fail have no code of their own"
# the fields of one diagnostic
cd "$D" || exit 1
printf 'fn main() {\n    count := 3\n    print(coutn)\n}\n' >t.al
"$ALC" check --json -W t.al >out 2>err; [[ $? == 1 ]] || fail "check: status"
grep -q '"line":3,"col":11,"message":"unknown identifier `coutn` (did you mean `count`?)","severity":"error","code":"E0301","end_line":3,"end_col":16,"fix":"write `count`"}' out || fail "fields: $(cat out)"
grep -q '"code":"W0001"' out || fail "warning code"
"$ALC" check nosuch.al --json >out 2>err; grep -q '"code":"E1002","end_line":0,"end_col":0}' out || fail "driver code"
# explain
"$ALC" explain e0301 >out 2>err || fail "explain: status"
grep -q '^E0301 unknown-identifier$' <(head -1 out) || fail "explain: $(cat out)"
"$ALC" explain --json E0301 >out 2>err || fail "explain --json: status"
grep -q '^{"code":"E0301","name":"unknown-identifier","summary":' out || fail "explain --json"
"$ALC" explain E9999 2>err; [[ $? == 2 ]] || fail "explain unknown: status"
"$ALC" explain 2>err; [[ $? == 2 ]] || fail "explain without a code: status"
exit 0
