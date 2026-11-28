-- Indentation for AgentLang (AL), following the layout of `alc fmt`:
--   * a line inside brackets is one level deeper than the statement that holds the innermost
--     open bracket (so `f(T{` opens a single level), and a closing bracket lines up with it
--   * a line after one that ends in a binary operator is one level deeper again
--   * the text of a multi-line raw string, and a comment aligned under the trailing comment
--     of the line above, stay where they are
if vim.b.did_indent then
  return
end
vim.b.did_indent = true

local OPEN = { ["{"] = true, ["("] = true, ["["] = true }
local CLOSE = { ["}"] = true, [")"] = true, ["]"] = true }

-- The code of a line: string and character literals become `""`, the comment is cut off.
-- in_raw: the line starts inside a raw string. Returns the code, whether the line ends
-- inside a raw string, and the byte index of its comment (nil without one).
local function strip(line, in_raw)
  local out = {}
  local i, n = 1, #line
  local quote = in_raw and "`" or nil
  local comment = nil
  while i <= n do
    local c = line:sub(i, i)
    if quote then
      if c == "\\" and quote ~= "`" then
        i = i + 1
      elseif c == quote then
        quote = nil
        out[#out + 1] = '""'
      end
    elseif c == "/" and line:sub(i + 1, i + 1) == "/" then
      comment = i
      break
    elseif c == '"' or c == "'" or c == "`" then
      quote = c
    else
      out[#out + 1] = c
    end
    i = i + 1
  end
  return table.concat(out), quote == "`", comment
end

-- The code of line l as the scan upwards from below sees it, and the next line to look at.
-- A line that ends inside a raw string closes one that began further up (the scan starts
-- outside strings): its code is what follows the closing backtick, and the scan goes on at
-- the line that opened the string, of which the code before the backtick counts.
local function code_above(l)
  local code, raw = strip(vim.fn.getline(l), false)
  if not raw then
    return code, l - 1
  end
  code = strip(vim.fn.getline(l), true)
  local o = l - 1
  while o >= 1 do
    local head, opens = strip(vim.fn.getline(o), false)
    if opens then
      return head .. '""' .. code, o - 1, o
    end
    o = o - 1
  end
  return code, 0
end

-- The innermost bracket open at the start of line lnum (depth 0), or with `depth` more
-- closing brackets still to match: its line, its code up to the bracket, the bracket, and
-- whether code follows it on that line.
local function find_open(lnum, depth)
  local l = lnum - 1
  while l >= 1 do
    local code, nxt, at = code_above(l)
    if depth == 0 and code == "}" and vim.fn.indent(l) == 0 then
      return nil
    end
    for i = #code, 1, -1 do
      local c = code:sub(i, i)
      if CLOSE[c] then
        depth = depth + 1
      elseif OPEN[c] then
        if depth == 0 then
          return at or l, code:sub(1, i - 1), c, code:sub(i + 1):match("%S") ~= nil
        end
        depth = depth - 1
      end
    end
    l = nxt
  end
  return nil
end

-- Does the last line of code above lnum end in a binary operator?
local function continues(lnum)
  local l = lnum - 1
  while l >= 1 do
    local code, nxt = code_above(l)
    code = code:gsub("%s+$", "")
    if code ~= "" then
      return code:match("[-+*/%%^&|=]$") ~= nil or code:match("<<$") ~= nil or code:match("[->=]>$") ~= nil
    end
    l = nxt
  end
  return false
end

-- The indentation of the statement that holds the bracket found at line l after `before`:
-- line l itself, unless that is the tail of a wrapped signature or condition
-- (`b: i64) -> T {`, `    y > 0 {`): then the line the wrapped construct starts on.
local function block_indent(l, before)
  while true do
    local depth = 0
    for i = #before, 1, -1 do
      local c = before:sub(i, i)
      if CLOSE[c] then
        depth = depth + 1
      elseif OPEN[c] and depth > 0 then
        depth = depth - 1
      end
    end
    if depth == 0 then
      break
    end
    local ol, obefore = find_open(l, depth - 1)
    if not ol then
      break
    end
    l, before = ol, obefore
  end
  local ind = vim.fn.indent(l)
  if continues(l) then
    ind = math.max(0, ind - vim.fn.shiftwidth())
  end
  return ind
end

-- Is the comment at column col of line lnum under the trailing comment of the code above?
local function under_trailing_comment(lnum, col)
  for l = lnum - 1, 1, -1 do
    local line = vim.fn.getline(l)
    local code, _, comment = strip(line, false)
    if not (comment == col and not code:match("%S")) then
      return comment == col and code:match("%S") ~= nil
    end
  end
  return false
end

function _G.al_indent_expr(lnum)
  local line = vim.fn.getline(lnum)
  local first = line:match("^%s*()")
  if vim.g.syntax_on and vim.fn.synIDattr(vim.fn.synID(lnum, 1, 1), "name") == "alRawString" then
    return -1
  end
  if line:sub(first, first + 1) == "//" and under_trailing_comment(lnum, first) then
    return -1
  end
  local sw = vim.fn.shiftwidth()
  local ol, before, bracket, more = find_open(lnum, 0)
  local base = ol and block_indent(ol, before) or nil
  if CLOSE[line:sub(first, first)] then
    return base or 0
  end
  local ind = base and base + sw or 0
  -- no second level for `f(a +` / `    b)`: the wrapped argument list is the continuation
  if (not ol or bracket == "{" or not more) and continues(lnum) then
    ind = ind + sw
  end
  return ind
end

vim.bo.indentexpr = "v:lua.al_indent_expr(v:lnum)"
vim.bo.indentkeys = "0{,0},0),0],!^F,o,O"
vim.b.undo_indent = "setlocal indentexpr< indentkeys<"
