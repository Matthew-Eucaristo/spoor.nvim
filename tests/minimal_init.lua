-- Test init: this plugin, mini.test and snacks.nvim from ./deps, nothing else.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. "/deps/snacks.nvim")
vim.opt.rtp:prepend(root .. "/deps/mini.nvim")
vim.opt.swapfile = false
vim.o.shortmess = vim.o.shortmess .. "WIcF"
vim.cmd("filetype on")

require("snacks").setup({})
require("mini.test").setup()
_G.SPOOR_ROOT = root
