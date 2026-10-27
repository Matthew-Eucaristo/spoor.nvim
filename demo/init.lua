-- Throwaway LazyVim for trying spoor.nvim and recording the demo. Run through demo/run.sh,
-- which points every XDG directory at .tests/demo so nothing touches your real config.
local repo = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")
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
  spec = {
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    { import = "lazyvim.plugins.extras.lang.go" },
    { import = "lazyvim.plugins.extras.lang.typescript" },
    { import = "lazyvim.plugins.extras.lang.java" }, -- brings the <leader>cg prefix spoor must avoid
    -- language servers come from $PATH (demo/run.sh); don't download anything
    { "mason-org/mason.nvim", enabled = false },
    { "mason-org/mason-lspconfig.nvim", enabled = false },
    { "jay-babu/mason-nvim-dap.nvim", enabled = false },
    { "folke/snacks.nvim", opts = { dashboard = { enabled = false } } },
    { "mfussenegger/nvim-lint", enabled = false }, -- keep linter noise out of the recording
    {
      dir = repo,
      name = "spoor.nvim",
      event = "VeryLazy",
      dependencies = { "folke/snacks.nvim" },
      opts = {},
    },
  },
  defaults = { lazy = false, version = false },
  install = { colorscheme = { "tokyonight" } },
  checker = { enabled = false },
  change_detection = { enabled = false },
  rocks = { enabled = false },
})
