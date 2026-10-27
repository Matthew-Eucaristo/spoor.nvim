-- Plain lazy.nvim, no LazyVim: snacks comes in through spoor's lazy.lua only.
vim.g.mapleader = "\\"
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "--branch=stable",
    "https://github.com/folke/lazy.nvim.git",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)
require("lazy").setup({
  spec = { dofile(os.getenv("SPOOR_REPO") .. "/tests/smoke/spoor_spec.lua") },
  install = { colorscheme = { "habamax" } },
  checker = { enabled = false },
  change_detection = { enabled = false },
  rocks = { enabled = false },
})
