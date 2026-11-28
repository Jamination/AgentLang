#!/usr/bin/env bash
# End-to-end test for `alc lsp` (LSP 3.17 JSON-RPC over stdio).
set -euo pipefail

ALC="$1"
TMP="$2"
WORK="$TMP/lsp_work"
rm -rf "$WORK"
mkdir -p "$WORK"

# --help exits 0
"$ALC" lsp --help | grep -q "usage: alc lsp"

python3 - "$ALC" "$WORK" <<'PY'
import json
import os
import subprocess
import sys

alc, work = sys.argv[1], sys.argv[2]

helper_path = os.path.join(work, "helper.al")
main_path = os.path.join(work, "main.al")
with open(helper_path, "w") as f:
    f.write("""// A 2D point in space.
struct Point {
    x: i64
    y: i64
}

// Color choices.
enum Color {
    Red,
    Green,
    Blue,
}

// Adds two points together.
fn add_points(a: Point, b: Point) -> Point {
    return Point{x: a.x + b.x, y: a.y + b.y}
}

// Scales a point by k.
fn scale(p: Point, k: i64) -> Point {
    return Point{x: p.x * k, y: p.y * k}
}
""")

main_src = """use "helper.al"

// Computes a sample result.
fn compute(n: i64) -> i64 {
    unused_val := 99
    p := Point{x: n, y: 2}
    q := p.scale(3)
    c := Color.Green
    _ := c
    r := add_points(p, q)
    return r.x + r.y
}

fn main() {
    print(compute(5))
}
"""
with open(main_path, "w") as f:
    f.write(main_src)

def to_uri(p):
    return "file://" + os.path.abspath(p)

helper_uri = to_uri(helper_path)
main_uri = to_uri(main_path)

proc = subprocess.Popen(
    [alc, "lsp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)

def send(obj):
    raw = json.dumps(obj).encode("utf-8")
    hdr = f"Content-Length: {len(raw)}\r\n\r\n".encode("ascii")
    proc.stdin.write(hdr + raw)
    proc.stdin.flush()

def recv():
    clen = None
    while True:
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError("EOF from alc lsp")
        s = line.decode("ascii").strip()
        if s == "":
            if clen is not None:
                break
            continue
        if s.lower().startswith("content-length:"):
            clen = int(s.split(":", 1)[1].strip())
    body = proc.stdout.read(clen)
    return json.loads(body.decode("utf-8"))

def request(req_id, method, params):
    send({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
    while True:
        msg = recv()
        if msg.get("id") == req_id:
            return msg

# 1. initialize
res = request(1, "initialize", {"rootUri": to_uri(work), "capabilities": {}})
assert "result" in res, res
caps = res["result"]["capabilities"]
assert caps["hoverProvider"] is True
assert caps["definitionProvider"] is True
assert caps["referencesProvider"] is True
assert caps["documentSymbolProvider"] is True
assert caps["documentFormattingProvider"] is True
assert res["result"]["serverInfo"]["name"] == "alc"
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

# 2. didOpen -> expect publishDiagnostics with unused variable warning (severity 2)
send({
    "jsonrpc": "2.0",
    "method": "textDocument/didOpen",
    "params": {"textDocument": {"uri": main_uri, "languageId": "al", "version": 1, "text": main_src}},
})
diag_msg = recv()
assert diag_msg["method"] == "textDocument/publishDiagnostics", diag_msg
diags = diag_msg["params"]["diagnostics"]
assert any(d["severity"] == 2 and "unused_val" in d["message"] for d in diags), diags
assert not any(d["severity"] == 1 for d in diags), diags

# 3. documentSymbol on helper.al
send({
    "jsonrpc": "2.0",
    "method": "textDocument/didOpen",
    "params": {"textDocument": {"uri": helper_uri, "languageId": "al", "version": 1, "text": open(helper_path).read()}},
})
hdiag = recv()
assert hdiag["params"]["diagnostics"] == [], hdiag

sym_res = request(2, "textDocument/documentSymbol", {"textDocument": {"uri": helper_uri}})
syms = sym_res["result"]
sym_names = [s["name"] for s in syms]
assert "Point" in sym_names and "Color" in sym_names and "add_points" in sym_names and "scale" in sym_names, syms
pt_sym = [s for s in syms if s["name"] == "Point"][0]
assert [c["name"] for c in pt_sym["children"]] == ["x", "y"], pt_sym

# 4. hover on `add_points` call (line 9, col 10) -> signature + doc comment
hov = request(3, "textDocument/hover", {"textDocument": {"uri": main_uri}, "position": {"line": 9, "character": 12}})
assert hov["result"] is not None, hov
hov_md = hov["result"]["contents"]["value"]
assert "fn add_points(a: Point, b: Point) -> Point" in hov_md, hov_md
assert "Adds two points together." in hov_md, hov_md

# 5. hover on local variable `q` (line 9, col 24) -> type Point
hov_q = request(4, "textDocument/hover", {"textDocument": {"uri": main_uri}, "position": {"line": 9, "character": 24}})
assert hov_q["result"] is not None, hov_q
assert "Point" in hov_q["result"]["contents"]["value"], hov_q

# 6. hover on method call `p.scale(3)` (line 6, col 12) -> signature + doc comment
hov_m = request(5, "textDocument/hover", {"textDocument": {"uri": main_uri}, "position": {"line": 6, "character": 12}})
assert hov_m["result"] is not None, hov_m
assert "fn scale(p: Point, k: i64) -> Point" in hov_m["result"]["contents"]["value"], hov_m

# 7. go-to-definition on `add_points` -> helper.al
def_res = request(6, "textDocument/definition", {"textDocument": {"uri": main_uri}, "position": {"line": 9, "character": 12}})
assert def_res["result"] is not None, def_res
assert def_res["result"]["uri"] == helper_uri, def_res

# 8. go-to-definition on `use "helper.al"` (line 0, col 6) -> helper.al line 0
def_use = request(7, "textDocument/definition", {"textDocument": {"uri": main_uri}, "position": {"line": 0, "character": 6}})
assert def_use["result"] is not None and def_use["result"]["uri"] == helper_uri, def_use

# 9. go-to-definition on local `p` at line 9 col 21 -> line 5 in main.al
def_p = request(8, "textDocument/definition", {"textDocument": {"uri": main_uri}, "position": {"line": 9, "character": 21}})
assert def_p["result"] is not None, def_p
assert def_p["result"]["uri"] == main_uri and def_p["result"]["range"]["start"]["line"] == 5, def_p

# 10. references to `p` (line 9, col 21) -> declaration + uses in main.al
ref_res = request(9, "textDocument/references", {
    "textDocument": {"uri": main_uri},
    "position": {"line": 9, "character": 21},
    "context": {"includeDeclaration": True},
})
refs = ref_res["result"]
assert len(refs) >= 3, refs

# 11. dot completion on `p.` (with trailing dot!) -> fields x, y and UFCS method scale
comp_src = main_src.replace("    return r.x + r.y", "    _ := p.\n    return r.x + r.y")
send({
    "jsonrpc": "2.0",
    "method": "textDocument/didChange",
    "params": {"textDocument": {"uri": main_uri, "version": 2}, "contentChanges": [{"text": comp_src}]},
})
_ = recv()  # diagnostics for trailing dot
comp_dot = request(10, "textDocument/completion", {"textDocument": {"uri": main_uri}, "position": {"line": 10, "character": 11}})
labels = {it["label"] for it in comp_dot["result"]}
assert {"x", "y", "scale"}.issubset(labels), labels

# 12. enum dot completion on `Color.`
enum_src = main_src.replace("    return r.x + r.y", "    _ := Color.\n    return r.x + r.y")
send({
    "jsonrpc": "2.0",
    "method": "textDocument/didChange",
    "params": {"textDocument": {"uri": main_uri, "version": 3}, "contentChanges": [{"text": enum_src}]},
})
_ = recv()
comp_enum = request(11, "textDocument/completion", {"textDocument": {"uri": main_uri}, "position": {"line": 10, "character": 15}})
elabels = {it["label"] for it in comp_enum["result"]}
assert {"Red", "Green", "Blue"}.issubset(elabels), elabels

# 13. `use std.` module completion
std_src = "use std.cr\n" + main_src
send({
    "jsonrpc": "2.0",
    "method": "textDocument/didChange",
    "params": {"textDocument": {"uri": main_uri, "version": 4}, "contentChanges": [{"text": std_src}]},
})
_ = recv()
comp_std = request(12, "textDocument/completion", {"textDocument": {"uri": main_uri}, "position": {"line": 0, "character": 10}})
slabels = [it["label"] for it in comp_std["result"]]
assert "crypto" in slabels, slabels

# 14. signatureHelp inside `add_points(p, ` -> activeParameter == 1
send({
    "jsonrpc": "2.0",
    "method": "textDocument/didChange",
    "params": {"textDocument": {"uri": main_uri, "version": 5}, "contentChanges": [{"text": main_src}]},
})
_ = recv()
sig_res = request(13, "textDocument/signatureHelp", {"textDocument": {"uri": main_uri}, "position": {"line": 9, "character": 24}})
assert sig_res["result"] is not None, sig_res
assert sig_res["result"]["activeParameter"] == 1, sig_res
assert "add_points" in sig_res["result"]["signatures"][0]["label"], sig_res

# 15. formatting on unformatted code
unfmt = "fn main(){\nprint(  1+2 )\n}\n"
send({
    "jsonrpc": "2.0",
    "method": "textDocument/didChange",
    "params": {"textDocument": {"uri": main_uri, "version": 6}, "contentChanges": [{"text": unfmt}]},
})
_ = recv()
fmt_res = request(14, "textDocument/formatting", {"textDocument": {"uri": main_uri}, "options": {"tabSize": 4, "insertSpaces": True}})
edits = fmt_res["result"]
assert len(edits) == 1 and edits[0]["newText"] == "fn main() {\n    print(1 + 2)\n}\n", edits

# 16. Repeated edits + multi-file overlay stress check (verifies Region reclamation & stability)
for v in range(7, 27):
    send({
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {"textDocument": {"uri": main_uri, "version": v}, "contentChanges": [{"text": f"fn main() {{\n    print({v})\n}}\n"}]},
    })
    dm = recv()
    assert dm["params"]["diagnostics"] == [], dm

# 17. didClose clears diagnostics
send({"jsonrpc": "2.0", "method": "textDocument/didClose", "params": {"textDocument": {"uri": main_uri}}})
close_dm = recv()
assert close_dm["params"]["diagnostics"] == [], close_dm

# 18. unknown method returns -32601
unk = request(15, "workspace/nonexistent", {})
assert unk["error"]["code"] == -32601, unk

# 19. shutdown + exit -> exit code 0
sd = request(16, "shutdown", {})
assert sd["result"] is None, sd
send({"jsonrpc": "2.0", "method": "exit", "params": {}})
rc = proc.wait(timeout=10)
stderr_out = proc.stderr.read().decode("utf-8", errors="replace")
assert rc == 0, f"expected exit 0, got {rc}, stderr={stderr_out}"
print("lsp_e2e_ok")
PY

# One-shot CLI semantic queries (`alc query`)
"$ALC" query --help | grep -q "usage: alc query"
"$ALC" query hover "$WORK/main.al:10:13" | grep -q "fn add_points(a: Point, b: Point) -> Point"
"$ALC" query def "$WORK/main.al:10:13" | grep -q "helper.al"
"$ALC" query refs "$WORK/main.al:10:22" | grep -q "main.al"
"$ALC" query symbols "$WORK/helper.al" | grep -q '"name":"Point"'
"$ALC" query complete "$WORK/main.al:7:12" | grep -q '"label":"scale"'
echo "query_e2e_ok"

