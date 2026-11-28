-- Tests of editors/nvim, run by run.sh: nvim --headless -u NONE -l run.lua <repo root> <alc> <scratch dir>
local root, alc, tmp = arg[1], arg[2], arg[3]
vim.opt.rtp:prepend(root .. "/editors/nvim")
vim.cmd("filetype plugin indent on")
vim.cmd("syntax on")
require("al").setup({ alc = alc })
-- ftdetect/ is not sourced after startup under -u NONE
vim.cmd("runtime! ftdetect/al.lua")
local failed = false
local function fail(msg)
  failed = true
  print("FAIL " .. msg)
end

-- 1. Syntax: the group at the first occurrence of a piece of text
local syn = tmp .. "/syn.al"
vim.fn.writefile({
  "fn main() { // hi TODO",
  "    c := '\\n'",
  '    s := `raw \\ "x`',
  "    x := a / b -> 0x1F @lbl",
  "    // alc fmt: off",
  '    t := "a // b"',
  "    p := Point{x: 1}",
  "}",
}, syn)
vim.cmd("edit " .. syn)
for _, t in ipairs({
  { 1, "//", "alComment" }, { 1, "TODO", "alTodo" }, { 1, "main", "alFuncDecl" }, { 1, "fn", "alKeyword" },
  { 2, "'", "alChar" }, { 3, "raw", "alRawString" }, { 3, '"x', "alRawString" },
  { 4, "/", "alOperator" }, { 4, "->", "alOperator" }, { 4, "0x", "alNumber" }, { 4, "@", "alLabel" },
  { 5, "//", "alFmtDirective" }, { 6, "//", "alString" }, { 7, "Point", "alCamelType" },
}) do
  local col = vim.fn.getline(t[1]):find(t[2], 1, true)
  local got = vim.fn.synIDattr(vim.fn.synID(t[1], col, 1), "name")
  if got ~= t[3] then
    fail(string.format("syntax: line %d `%s` is %s, expected %s", t[1], t[2], got, t[3]))
  end
end
vim.cmd("bwipeout!")

-- 2. Indentation: alc fmt laid out src/ and std/, so no line may move. The one layout that
-- is not reproduced: the patterns of a match arm wrapped after a comma (2 lines, src/debug.al)
local allowed, lines, bad = 2, 0, 0
for _, dir in ipairs({ "src", "std" }) do
  for _, f in ipairs(vim.fn.glob(root .. "/" .. dir .. "/*.al", false, true)) do
    vim.cmd("silent edit " .. vim.fn.fnameescape(f))
    for l = 1, vim.fn.line("$") do
      if vim.fn.getline(l):match("%S") then
        lines = lines + 1
        local want, got = vim.fn.indent(l), _G.al_indent_expr(l)
        if got ~= -1 and got ~= want then
          bad = bad + 1
          print(string.format("%s:%d: indented to %d, alc fmt has %d", f, l, got, want))
        end
      end
    end
    vim.cmd("silent bwipeout!")
  end
end
print(string.format("indent: %d lines, %d differ from alc fmt (%d allowed)", lines, bad, allowed))
if bad > allowed then
  fail("indent")
end

-- 3. LSP, :AlFmt and :AlCheck
local main = tmp .. "/main.al"
vim.fn.writefile({
  "fn add(a: i64, b: i64) -> i64 {", "return a+b", "}", "",
  "fn main() {", "    print(add(1, 2), undefined_thing)", "}",
}, main)
vim.cmd("edit " .. main)
if vim.bo.filetype ~= "al" or vim.bo.indentexpr == "" or not vim.bo.makeprg:find("check") then
  fail("filetype: ft=" .. vim.bo.filetype .. " indentexpr=" .. vim.bo.indentexpr .. " makeprg=" .. vim.bo.makeprg)
end
if not vim.wait(10000, function() return #vim.lsp.get_clients({ bufnr = 0, name = "alc" }) > 0 end) then
  fail("lsp: alc lsp did not attach")
else
  local client = vim.lsp.get_clients({ bufnr = 0, name = "alc" })[1]
  vim.wait(5000, function() return #vim.diagnostic.get(0) > 0 end)
  local d = vim.diagnostic.get(0)[1]
  if not d or not d.message:find("undefined_thing", 1, true) then
    fail("lsp: no diagnostic for the unknown identifier")
  end
  local pos = { textDocument = { uri = vim.uri_from_bufnr(0) }, position = { line = 5, character = 11 } }
  local hover = vim.inspect((client:request_sync("textDocument/hover", pos, 5000, 0) or {}).result)
  if not hover:find("fn add(a: i64, b: i64) -> i64", 1, true) then
    fail("lsp: hover is " .. hover)
  end
  local def = (client:request_sync("textDocument/definition", pos, 5000, 0) or {}).result
  if not def or (def.range or def[1].range).start.line ~= 0 then
    fail("lsp: definition is " .. vim.inspect(def))
  end
end
vim.cmd("AlFmt")
if vim.fn.getline(2) ~= "    return a + b" then
  fail(":AlFmt left `" .. vim.fn.getline(2) .. "`")
end
vim.cmd("AlCheck")
local qf = vim.fn.getqflist()
if #qf ~= 1 or qf[1].lnum ~= 6 then
  fail(":AlCheck quickfix is " .. vim.inspect(qf))
end
print("syntax, lsp, fmt and check: " .. (failed and "FAILED" or "ok"))
vim.cmd(failed and "cquit!" or "qall!")
