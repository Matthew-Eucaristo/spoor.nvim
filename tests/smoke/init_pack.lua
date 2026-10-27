-- Neovim 0.12's built-in plugin manager, as in the README.
local url = os.getenv("SPOOR_URL") or ("file://" .. os.getenv("SPOOR_REPO"))
vim.pack.add({ "https://github.com/folke/snacks.nvim", url }, { confirm = false })
require("spoor").setup({})
