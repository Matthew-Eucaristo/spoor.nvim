-- No plugin manager: snacks and spoor on the runtimepath, setup() by hand.
local repo = os.getenv("SPOOR_REPO")
vim.opt.rtp:prepend(repo .. "/deps/snacks.nvim")
vim.opt.rtp:prepend(repo)
vim.cmd("silent! helptags " .. vim.fn.fnameescape(repo .. "/doc")) -- the README's :helptags step
require("spoor").setup()
