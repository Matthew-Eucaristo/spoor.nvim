-- Runs inside a real config (see run.sh): loads spoor the way that config does, drives the
-- live panel, gag, gat and :checkhealth against the in-process fake server on the Go
-- fixture, the tree-sitter bow-tie on a C file without a server, checks the keys, then quits
-- with the panel open. Writes OK or the failures to $SPOOR_SMOKE_RESULT.
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

  local H = dofile(repo .. "/tests/helpers.lua") -- by path: other plugins ship lua/tests/ too
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
  local function shown()
    local v = live.panels[vim.api.nvim_get_current_tabpage()]
    return v and v:valid() and v.graph and v.graph.complete and panel_text():find("handleOrders", 1, true) ~= nil
  end
  wait(shown, 5000, "live panel")

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

  -- pickers are Snacks.picker, whichever picker the config uses elsewhere; without snacks,
  -- vim.ui.select
  vim.api.nvim_set_current_win(code_win)
  local snacks = require("spoor.ui").snacks()
  if (os.getenv("SPOOR_SMOKE_CONFIG") == "nosnacks") == snacks then
    fail("snacks.nvim " .. (snacks and "is loaded" or "is missing"))
  end
  if snacks then
    require("spoor").entries()
    wait(function()
      return vim.bo.filetype == "snacks_picker_input"
    end, 5000, "entries picker")
    for _, p in ipairs(Snacks.picker.get()) do
      p:close()
    end
  else
    local select, picked = vim.ui.select, nil
    vim.ui.select = function(items, opts, cb)
      picked = opts.prompt .. ": " .. opts.format_item(items[1])
      cb(nil)
    end
    require("spoor").entries()
    vim.ui.select = select
    if not (picked and picked:find("main", 1, true)) then
      fail("entries through vim.ui.select: " .. tostring(picked))
    end
  end
  vim.wait(100)

  -- no language server: the tree-sitter bow-tie, labelled as such
  vim.api.nvim_set_current_win(code_win)
  vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/tests/fixtures/syntax/stats.c"))
  local c_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(code_win, { 5, 5 }) -- int total(
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  wait(function()
    local v = live.panels[vim.api.nvim_get_current_tabpage()]
    return v and v:valid() and v.graph and v.graph.source == "syntax" and panel_text():find("add", 1, true) ~= nil
  end, 5000, "syntax bow-tie on a C file")
  vim.api.nvim_win_set_buf(code_win, bufnr)
  vim.api.nvim_win_set_cursor(code_win, { p.line + 1, p.character })
  pcall(vim.api.nvim_buf_delete, c_buf, { force = true })

  -- the help file is installed and indexed
  if not pcall(vim.cmd, "help spoor") then
    fail(":h spoor not found")
  end
  pcall(vim.cmd, "helpclose")
  -- a help split under splitkeep=screen (LazyVim) moves the code cursor; put it back
  vim.api.nvim_win_set_cursor(code_win, { p.line + 1, p.character })

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
    if
      line:find("^E%d+:")
      or line:find("Error")
      or line:find("stack traceback")
      or line:find("not installed") -- lazy.nvim: a spec names a plugin that isn't there
      or line:find("missing plugins")
    then
      fail("message: " .. line)
    end
  end

  -- leave only the code window and the live panel, then quit once
  vim.api.nvim_set_current_win(code_win)
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  wait(shown, 5000, "panel before :q")
  vim.cmd("silent! only")
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  wait(shown, 5000, "panel after :only")
end, debug.traceback)
if not ok then
  fail(err)
end
finish()
vim.cmd("silent! %bdelete!") -- drop terminal/scratch buffers that would block :q
vim.cmd("q")
