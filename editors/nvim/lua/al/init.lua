-- AgentLang (AL) Neovim plugin: native LSP (`alc lsp`), formatting (`alc fmt`), and CLI commands.
local M = {}

M.config = {
  alc = "alc",
  lsp = true,
  format_on_save = false,
  on_attach = nil,
  root_markers = { ".lsp.json", "build.sh", ".git" },
}

M._setup_done = false

function M.alc_cmd()
  return M.config.alc or vim.g.al_alc_command or "alc"
end

-- Format current buffer in-place using `alc fmt -` (preserving cursor & view)
function M.format(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local input = table.concat(lines, "\n") .. "\n"
  local res = vim.system({ M.alc_cmd(), "fmt", "-" }, { stdin = input, text = true }):wait()
  if res.code ~= 0 then
    local err = vim.trim(res.stderr or "")
    if err ~= "" then
      vim.notify("alc fmt: " .. err, vim.log.levels.WARN)
    end
    return false
  end
  local out = res.stdout or ""
  if out == input then
    return true
  end
  local new_lines = vim.split(out:gsub("\n$", ""), "\n", { plain = true })
  local view = vim.fn.winsaveview()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
  vim.fn.winrestview(view)
  return true
end

-- Run `alc check -W` on current file and populate quickfix list
function M.check(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then
    vim.notify("alc check: buffer has no file name", vim.log.levels.WARN)
    return
  end
  vim.cmd("silent update")
  local res = vim.system({ M.alc_cmd(), "check", "-W", "--json", file }, { text = true }):wait()
  local ok, diags = pcall(vim.json.decode, res.stdout or "[]")
  if not ok or type(diags) ~= "table" then
    vim.notify("alc check: " .. vim.trim(res.stderr or res.stdout or "failed"), vim.log.levels.ERROR)
    return
  end
  local qf = {}
  for _, d in ipairs(diags) do
    qf[#qf + 1] = {
      filename = d.file or file,
      lnum = math.max(d.line or 1, 1),
      col = math.max(d.col or 1, 1),
      text = d.message or "",
      type = d.severity == "warning" and "W" or "E",
    }
  end
  vim.fn.setqflist({}, "r", { title = "alc check", items = qf })
  if #qf > 0 then
    vim.cmd("copen")
  else
    vim.cmd("cclose")
    vim.notify("alc check: clean (0 issues)", vim.log.levels.INFO)
  end
end

-- Run `alc <subcmd> <current-file>` and display output
function M.run_cmd(subcmd, extra)
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    vim.notify("alc " .. subcmd .. ": buffer has no file name", vim.log.levels.WARN)
    return
  end
  vim.cmd("silent update")
  local argv = { M.alc_cmd(), subcmd }
  for _, a in ipairs(extra or {}) do
    argv[#argv + 1] = a
  end
  argv[#argv + 1] = file
  local res = vim.system(argv, { text = true }):wait()
  local out = vim.trim((res.stdout or "") .. "\n" .. (res.stderr or ""))
  local lvl = res.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
  vim.notify(out ~= "" and out or ("alc " .. subcmd .. ": exit " .. res.code), lvl)
end

-- Start or attach `alc lsp` for the given buffer
function M.start_lsp(bufnr)
  if not M.config.lsp then
    return
  end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local alc = M.alc_cmd()
  if vim.fn.executable(alc) ~= 1 then
    return
  end
  local root_dir = vim.fs.root(bufnr, M.config.root_markers) or vim.fn.getcwd()
  vim.lsp.start({
    name = "alc",
    cmd = { alc, "lsp" },
    root_dir = root_dir,
    -- after setup() the LspAttach autocmd calls on_attach
    on_attach = not M._setup_done and M.config.on_attach or nil,
  }, { bufnr = bufnr })
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  vim.g.al_alc_command = M.config.alc
  M._setup_done = true

  -- Register with Neovim 0.11+ native vim.lsp.config when available
  if M.config.lsp and vim.lsp and vim.lsp.config and vim.lsp.enable then
    vim.lsp.config("alc", {
      cmd = { M.alc_cmd(), "lsp" },
      filetypes = { "al" },
      root_markers = M.config.root_markers,
    })
    vim.lsp.enable("alc")
  end

  local group = vim.api.nvim_create_augroup("AgentLang", { clear = true })
  if M.config.format_on_save then
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = group,
      pattern = "*.al",
      callback = function(ev)
        M.format(ev.buf)
      end,
    })
  end

  if M.config.on_attach then
    vim.api.nvim_create_autocmd("LspAttach", {
      group = group,
      callback = function(ev)
        local client = vim.lsp.get_client_by_id(ev.data.client_id)
        if client and client.name == "alc" then
          M.config.on_attach(client, ev.buf)
        end
      end,
    })
  end
end

return M
