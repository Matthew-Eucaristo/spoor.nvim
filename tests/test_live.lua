local H = require("tests.helpers")
local T = MiniTest.new_set({ hooks = { pre_case = H.reset } })
local eq, expect = MiniTest.expect.equality, MiniTest.expect

local function start(opts)
  local w = H.go_world()
  local p = w.process.selectionRange.start
  local bufnr = H.edit(H.go .. "/internal/order/order.go", p.line + 1, p.character)
  local server = H.fake_server(bufnr, { handlers = H.go_handlers(w), delay = opts and opts.delay })
  require("spoor").setup(vim.tbl_deep_extend("force", { live = { debounce = 10 } }, opts and opts.config or {}))
  return w, bufnr, server
end

local function panel()
  return require("spoor.live").panels[vim.api.nvim_get_current_tabpage()]
end

local function panel_text()
  local v = panel()
  return v and v:valid() and table.concat(vim.api.nvim_buf_get_lines(v.win.buf, 0, -1, false), "\n") or ""
end

T["follows the cursor into a bottom panel"] = function()
  start()
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    return panel_text():find("handleOrders", 1, true) ~= nil and panel_text():find("Emit", 1, true) ~= nil
  end, 3000, "panel")
  local v = panel()
  eq(vim.api.nvim_win_get_config(v.win.win).relative, "")
  -- focus stays in the code window
  expect.no_equality(vim.api.nvim_get_current_win(), v.win.win)
  expect.no_equality(vim.wo[v.win.win].winbar:find("static calls only", 1, true), nil)
end

T["inside a function body, the enclosing function is the focus"] = function()
  local w, _, server = start()
  local p = w.process.selectionRange.start
  vim.api.nvim_win_set_cursor(0, { p.line + 3, 2 }) -- the `return err` line
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    return panel_text():find("Process", 1, true) ~= nil
  end, 3000, "panel")
  eq(H.count(server.requests, "textDocument/documentSymbol") >= 1, true)
end

T["same focus does not ask again; cache serves revisits"] = function()
  local w, _, server = start()
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    return panel_text():find("Emit", 1, true) ~= nil
  end)
  local before = H.count(server.requests, "callHierarchy/incomingCalls")
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  vim.wait(100)
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  vim.wait(100)
  eq(H.count(server.requests, "callHierarchy/incomingCalls"), before)
  -- force a different key, then come back: served from cache
  require("spoor.live").panels[vim.api.nvim_get_current_tabpage()].key = "other"
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  vim.wait(100)
  eq(H.count(server.requests, "callHierarchy/incomingCalls"), before)
  local _ = w
end

T["edits invalidate the cache"] = function()
  local _, _, server = start()
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    return panel_text():find("Emit", 1, true) ~= nil
  end)
  local before = H.count(server.requests, "callHierarchy/incomingCalls")
  vim.api.nvim_exec_autocmds("TextChanged", {})
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    return H.count(server.requests, "callHierarchy/incomingCalls") > before
  end)
end

T["debounce: a burst of moves sends one round of requests"] = function()
  local _, _, server = start({ config = { live = { debounce = 60 } } })
  H.wait(function()
    return panel_text():find("Emit", 1, true) ~= nil
  end)
  vim.wait(100)
  local before = H.count(server.requests, "textDocument/prepareCallHierarchy")
  for _ = 1, 20 do
    vim.api.nvim_exec_autocmds("CursorMoved", {})
  end
  vim.wait(250)
  eq(H.count(server.requests, "textDocument/prepareCallHierarchy") - before, 1)
end

T["entering insert mode cancels a pending update"] = function()
  local _, _, server = start({ config = { live = { debounce = 40 } } })
  vim.wait(150)
  local before = #server.requests
  require("spoor.live").panels[vim.api.nvim_get_current_tabpage()].key = "other"
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  vim.api.nvim_exec_autocmds("InsertEnter", {})
  vim.wait(150)
  eq(#server.requests, before)
end

T["toggle off closes the panel and persists"] = function()
  start()
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    return panel() ~= nil and panel():valid()
  end)
  require("spoor").toggle(false)
  eq(panel(), nil)
  local state = require("spoor.util").read_json(require("spoor.util").state_dir() .. "/state.json")
  eq(state.live, false)
  -- a fresh session reads the saved choice
  package.loaded["spoor.live"] = nil
  eq(require("spoor.live").enabled(), false)
  require("spoor").toggle(true)
  eq(require("spoor.live").enabled(), true)
end

T["closing the panel by hand pauses it for the session"] = function()
  start()
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    return panel() ~= nil and panel():valid()
  end)
  local code = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(panel().win.win)
  vim.cmd("quit")
  vim.wait(50)
  eq(require("spoor.live").paused, true)
  eq(vim.api.nvim_get_current_win(), code)
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  vim.wait(80)
  eq(panel(), nil)
end

T["closing it from elsewhere (:only, :tabclose) doesn't pause"] = function()
  start()
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    return panel() ~= nil and panel():valid()
  end)
  vim.cmd("only")
  vim.wait(50)
  eq(require("spoor.live").paused, false)
end

T["t in the panel traces from the code window"] = function()
  start()
  local code = vim.api.nvim_get_current_win()
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    return panel_text():find("Emit", 1, true) ~= nil
  end)
  local v = panel()
  vim.api.nvim_set_current_win(v.win.win)
  require("spoor.live").actions.trace(v)
  local s = require("spoor.trace").state
  H.wait(function()
    return s.win and s.win:valid()
  end)
  eq(s.origin, code)
  -- split beside the code, not inside the 8-row panel
  eq(vim.api.nvim_win_get_height(s.win.win), vim.api.nvim_win_get_height(code))
end

T["buffers without a language server leave the panel alone"] = function()
  require("spoor").setup({ live = { debounce = 10 } })
  vim.cmd("enew")
  vim.bo.buftype = "nofile"
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  vim.wait(80)
  eq(panel(), nil)
end

T["a slow server times out instead of hanging"] = function()
  start({ delay = { ["callHierarchy/incomingCalls"] = "never" }, config = { timeout = 60, cold_timeout = 60 } })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    return panel_text():find("timed out", 1, true) ~= nil
  end, 3000, "timeout message")
  expect.no_equality(panel_text():find("Emit", 1, true), nil)
end

T["<CR> in the panel jumps the code window"] = function()
  local w = start()
  local code_win = vim.api.nvim_get_current_win()
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    return panel_text():find("Emit", 1, true) ~= nil
  end)
  local v = panel()
  local lines = vim.api.nvim_buf_get_lines(v.win.buf, 0, -1, false)
  local row
  for i, l in ipairs(lines) do
    if l:find("Emit", 1, true) then
      row = i
    end
  end
  vim.api.nvim_set_current_win(v.win.win)
  vim.api.nvim_win_set_cursor(v.win.win, { row, #lines[row] - 3 })
  local node = v:node_at_cursor()
  eq(node.name, "Emit")
  v:jump(node)
  eq(vim.api.nvim_get_current_win(), code_win)
  eq(vim.api.nvim_buf_get_name(0), w.emit.uri:gsub("^file://", ""))
end

return T
