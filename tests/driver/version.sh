# `alc --version` / `alc version`: the version on the first line, the default target on the
# second, status 0; the usage lists the option
set -u
ALC=$1; D=$2; cd "$D" || exit 1
fail() { echo "FAIL: $*"; exit 1; }
for a in --version version; do
  "$ALC" $a >out 2>err || fail "$a: status"
  grep -qE '^alc [0-9]+\.[0-9]+\.[0-9]+$' <(head -1 out) || fail "$a: first line: $(head -1 out)"
  grep -qE '^default target: (linux|windows) x86-64$' <(sed -n 2p out) || fail "$a: second line"
  [[ $(wc -l <out) == 2 && ! -s err ]] || fail "$a: extra output"
done
"$ALC" 2>err; [[ $? == 2 ]] || fail "usage: status"
grep -q -- '--version' err || fail "usage does not list --version"
exit 0
