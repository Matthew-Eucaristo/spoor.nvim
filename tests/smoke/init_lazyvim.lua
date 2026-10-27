-- Stock LazyVim (the starter's lazy.lua) plus the README snippet. Mason is off so nothing is
-- downloaded besides plugins.
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
local spoor = dofile(os.getenv("SPOOR_REPO") .. "/tests/smoke/spoor_spec.lua")
spoor.event = "VeryLazy"
local extras = {}
for name in (os.getenv("SPOOR_SMOKE_EXTRAS") or ""):gmatch("[^,]+") do
  extras[#extras + 1] = { import = "lazyvim.plugins.extras." .. name } -- e.g. editor.fzf
  local picker = name:match("^editor%.(%a+)$")
  if picker == "fzf" or picker == "telescope" then
    -- LazyVim enables a picker extra only when it is the chosen one, set in lua/config/options.lua
    local dir = vim.fn.stdpath("config") .. "/lua/config"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ ("vim.g.lazyvim_picker = %q"):format(picker) }, dir .. "/options.lua")
  end
end
require("lazy").setup({
  spec = {
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    extras,
    { "mason-org/mason.nvim", enabled = false },
    { "mason-org/mason-lspconfig.nvim", enabled = false },
    -- no parser downloads: a deep-merged table would keep LazyVim's list, so use a function
    {
      "nvim-treesitter/nvim-treesitter",
      build = false,
      opts = function(_, opts)
        opts.ensure_installed = {}
      end,
    },
    spoor,
  },
  defaults = { lazy = false, version = false },
  install = { colorscheme = { "tokyonight", "habamax" } },
  checker = { enabled = false },
  change_detection = { enabled = false },
  rocks = { enabled = false },
})
