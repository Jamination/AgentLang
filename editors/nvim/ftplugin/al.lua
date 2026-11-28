-- Buffer-local configuration for AgentLang (.al) files
vim.bo.commentstring = "// %s"
vim.bo.shiftwidth = 4
vim.bo.tabstop = 4
vim.bo.softtabstop = 4
vim.bo.expandtab = true

vim.cmd("compiler alc")

local al = require("al")

-- Buffer-local user commands
vim.api.nvim_buf_create_user_command(0, "AlFmt", function()
  al.format(0)
end, { desc = "Format buffer with alc fmt" })

vim.api.nvim_buf_create_user_command(0, "AlCheck", function()
  al.check(0)
end, { desc = "Type-check current file with alc check -W" })

vim.api.nvim_buf_create_user_command(0, "AlTest", function()
  al.run_cmd("test")
end, { desc = "Run tests in current file with alc test" })

vim.api.nvim_buf_create_user_command(0, "AlRun", function()
  al.run_cmd("run")
end, { desc = "Build and run current file with alc run" })

vim.api.nvim_buf_create_user_command(0, "AlSigs", function()
  al.run_cmd("sigs", { "--pub" })
end, { desc = "List public declarations with alc sigs --pub" })

-- If the user hasn't called require("al").setup() (or on Neovim < 0.11), start LSP directly
if not al._setup_done or not (vim.lsp and vim.lsp.enable) then
  al.start_lsp(0)
end
