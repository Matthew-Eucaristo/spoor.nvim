-- Runs inside a real config (see run.sh): loads spoor the way that config does, drives the
-- live panel, gag, gat and :checkhealth against the in-process fake server on the Go
-- fixture, checks the keys, then quits with the panel open. Writes OK or the failures to
-- $SPOOR_SMOKE_RESULT.
local repo = os.getenv("SPOOR_REPO")
local result = os.getenv("SPOOR_SMOKE_RESULT")
package.path = repo .. "/?.lua;" .. repo .. "/?/init.lua;" .. package.path
_G.SPOOR_ROOT = repo

local failures = {}
local function fail(msg)
  failures[#failures + 1] = msg
end
local function wait(cond, ms, what)
  if not vim.wait(ms or 5000, cond, 10) then
    fail("timed out: " .. what)
    return false
  end
  return true
end
local function finish()
  local f = assert(io.open(result, "w"))
  f:write(#failures == 0 and "OK\n" or table.concat(failures, "\n") .. "\n")
  f:close()
end

local ok, err = xpcall(function()
  -- headless has no UIEnter, so lazy.nvim never fires VeryLazy by itself
  if package.loaded.lazy and not vim.g.did_very_lazy then
    vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy", modeline = false })
  end
  wait(function()
    return package.loaded.spoor ~= nil and require("spoor").did_setup
  end, 20000, "spoor setup")

  local H = require("tests.helpers")
  local w = H.go_world()
  local p = w.process.selectionRange.start
  local bufnr = H.edit(H.go .. "/internal/order/order.go", p.line + 1, p.character)
  H.fake_server(bufnr, { handlers = H.go_handlers(w), root = H.go })
  local code_win = vim.api.nvim_get_current_win()
  vim.wait(200) -- let LspAttach handlers (LazyVim's buffer keys) run

  -- keys: spoor's own, and nobody else's mapping on the same or an overlapping lhs
  local Config = require("spoor.config")
  local mine = {}
  for _, lhs in pairs(Config.defaults.keys) do
    mine[vim.keycode(lhs)] = lhs
  end
  local ours = {
    ["Bow-tie (callers | callees)"] = true,
    ["Trace from here"] = true,
    ["Resume Trail"] = true,
    ["Trails"] = true,
    ["Entry Points"] = true,
    ["Changed Symbols (git)"] = true,
    ["Toggle Live Bow-tie"] = true,
    ["Enable Live Bow-tie"] = true, -- Snacks.toggle names the action by state
    ["Disable Live Bow-tie"] = true,
  }
  local all = vim.list_extend(vim.api.nvim_get_keymap("n"), vim.api.nvim_buf_get_keymap(bufnr, "n"))
  for raw, lhs in pairs(mine) do
    local m = vim.fn.maparg(raw, "n", false, true)
    if not ours[m.desc or ""] then
      fail("key " .. lhs .. " is not spoor's: " .. vim.inspect(m.desc))
    end
    for _, other in ipairs(all) do
      -- which-key's own trigger maps are how it shows the popup, not competing keys
      local o = other.desc == "which-key-trigger" and "" or vim.keycode(other.lhs)
      local overlap = o ~= "" and o ~= raw and (o:sub(1, #raw) == raw or raw:sub(1, #o) == o)
      -- which-key groups are not keymaps, so any mapping that is a prefix of ours shadows it
      if overlap and #o < #raw then
        fail(("key %s is shadowed by %s (%s)"):format(lhs, other.lhs, other.desc or other.rhs or "?"))
      elseif overlap and #o > #raw then
        fail(("key %s delays %s (%s)"):format(lhs, other.lhs, other.desc or "?"))
      end
    end
  end

  -- live panel
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  local live = require("spoor.live")
  local function panel_text()
    local v = live.panels[vim.api.nvim_get_current_tabpage()]
    return v and v:valid() and table.concat(vim.api.nvim_buf_get_lines(v.win.buf, 0, -1, false), "\n") or ""
  end
  wait(function()
    return panel_text():find("handleOrders", 1, true) and panel_text():find("Emit", 1, true)
  end, 5000, "live panel")

  -- gag float
  vim.api.nvim_set_current_win(code_win)
  require("spoor").bowtie()
  wait(function()
    local v = require("spoor.bowtie").current
    return v and v:valid() and v.graph and v.graph.complete
  end, 5000, "gag float")
  local float = require("spoor.bowtie").current
  if float and float:valid() then
    float:close()
  end
  -- closing it must leave the code cursor where it was
  if vim.api.nvim_win_get_cursor(code_win)[1] ~= p.line + 1 then
    fail("the code cursor moved to line " .. vim.api.nvim_win_get_cursor(code_win)[1])
  end

  -- gat trace
  vim.api.nvim_set_current_win(code_win)
  require("spoor").trace()
  wait(function()
    local s = require("spoor.trace").state
    return s.win and s.win:valid() and #s.hops >= 5
  end, 5000, "trace panel")
  require("spoor.trace").close()

  -- health names this buffer's server
  vim.api.nvim_set_current_win(code_win)
  vim.cmd("checkhealth spoor")
  local health = vim.api.nvim_get_current_buf()
  local htext = ""
  if
    not vim.wait(5000, function()
      htext = table.concat(vim.api.nvim_buf_get_lines(health, 0, -1, false), "\n")
      return htext:find("fake: ✓ prepareCallHierarchy", 1, true) ~= nil
    end, 10)
  then
    fail("checkhealth output:\n" .. htext)
  end
  if vim.api.nvim_get_current_buf() == health then
    pcall(vim.cmd, #vim.api.nvim_list_tabpages() > 1 and "tabclose" or "bdelete")
  end

  if vim.v.errmsg ~= "" then
    fail("v:errmsg: " .. vim.v.errmsg)
  end
  local msgs = vim.api.nvim_exec2("messages", { output = true }).output
  for line in msgs:gmatch("[^\n]+") do
    if line:find("^E%d+:") or line:find("Error") or line:find("stack traceback") then
      fail("message: " .. line)
    end
  end

  -- leave only the code window and the live panel, then quit once
  vim.api.nvim_set_current_win(code_win)
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  wait(function()
    return panel_text():find("Emit", 1, true)
  end, 5000, "panel before :q")
  vim.cmd("silent! only")
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  wait(function()
    return panel_text():find("Emit", 1, true)
  end, 5000, "panel after :only")
end, debug.traceback)
if not ok then
  fail(err)
end
finish()
vim.cmd("silent! %bdelete!") -- drop terminal/scratch buffers that would block :q
vim.cmd("q")
