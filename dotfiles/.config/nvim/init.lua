-- Managed by linux-server-bootstrap.
-- Deliberately plugin-free so Neovim remains usable without network access.

vim.g.mapleader = " "
vim.g.maplocalleader = " "

local options = {
  number = true,
  relativenumber = true,
  mouse = "a",
  ignorecase = true,
  smartcase = true,
  expandtab = true,
  shiftwidth = 2,
  tabstop = 2,
  softtabstop = 2,
  smartindent = true,
  wrap = false,
  splitbelow = true,
  splitright = true,
  undofile = true,
  swapfile = false,
  updatetime = 300,
  signcolumn = "yes",
  termguicolors = true,
}

for name, value in pairs(options) do
  local ok = pcall(function()
    vim.opt[name] = value
  end)
  if not ok then
    -- Older distribution builds may not expose every option. Optional options
    -- must never prevent the editor from starting.
  end
end

vim.cmd("filetype plugin indent on")
vim.cmd("syntax enable")

local function map(mode, lhs, rhs, description)
  if vim.keymap and vim.keymap.set then
    vim.keymap.set(mode, lhs, rhs, { silent = true, desc = description })
  else
    vim.api.nvim_set_keymap(mode, lhs, rhs, { noremap = true, silent = true })
  end
end

map("n", "<leader>w", "<cmd>write<cr>", "Write file")
map("n", "<leader>q", "<cmd>quit<cr>", "Quit window")
map("n", "<C-h>", "<C-w>h", "Move to left window")
map("n", "<C-j>", "<C-w>j", "Move to lower window")
map("n", "<C-k>", "<C-w>k", "Move to upper window")
map("n", "<C-l>", "<C-w>l", "Move to right window")
map("v", "<", "<gv", "Indent left")
map("v", ">", ">gv", "Indent right")
