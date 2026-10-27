-- Child Neovim for test_quit.lua: live panel and a trail open, the cursor in the window named
-- by $WHERE, then run $CMD. Reaching the end means the quit was abandoned (exit 3).
local repo = os.getenv("SPOOR_REPO")
local H = dofile(repo .. "/tests/helpers.lua")
local w = H.go_world()
local p = w.process.selectionRange.start
local bufnr = H.edit(H.go .. "/internal/order/order.go", p.line + 1, p.character)
H.fake_server(bufnr, { handlers = H.go_handlers(w) })
local code = vim.api.nvim_get_current_win()
local panel = os.getenv("LAYOUT") == "bottom"
require("spoor").setup({ live = { debounce = 10, panel = panel, layout = "bottom", card = { delay = 0 } } })
if panel then
  require("spoor").toggle(true)
end
vim.api.nvim_exec_autocmds("CursorMoved", {})
H.wait(function()
  local v = require("spoor.live").panels[vim.api.nvim_get_current_tabpage()]
  return v and v:valid() and v.graph ~= nil
end, 3000, "panel")
require("spoor").trace()
local s = require("spoor.trace").state
H.wait(function()
  return s.win and s.win:valid() and #s.hops > 0
end, 3000, "trail")
local where = os.getenv("WHERE")
if where == "trace" then
  vim.api.nvim_set_current_win(s.win.win)
elseif where == "code+trail" then
  vim.api.nvim_set_current_win(code)
  require("spoor.live").close_all() -- e.g. the card hid itself: no live view while the trail is open
elseif where == "code+pinned" then
  vim.api.nvim_set_current_win(code)
  require("spoor.trace").close()
  require("spoor").bowtie()
  H.wait(function()
    local v = require("spoor.bowtie").current
    return v and v:valid() and v.graph and v.graph.complete
  end, 3000, "float")
  require("spoor.bowtie").float_actions.pin_right(require("spoor.bowtie").current)
  vim.api.nvim_set_current_win(code)
elseif where == "panel" then
  vim.api.nvim_set_current_win(require("spoor.live").panels[vim.api.nvim_get_current_tabpage()].win.win)
else
  vim.api.nvim_set_current_win(code)
  require("spoor.trace").close()
end
pcall(vim.cmd, os.getenv("CMD"))
os.exit(3)
