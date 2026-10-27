-- The same-file bow-tie from tree-sitter, where no language server has call hierarchy.
-- Neovim ships the Lua and C parsers, so these run everywhere.
local H = require("tests.helpers")
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      H.reset()
      vim.v.errmsg = ""
    end,
    post_case = function()
      MiniTest.expect.equality(vim.v.errmsg, "")
    end,
  },
})
local eq, expect = MiniTest.expect.equality, MiniTest.expect

local dir = H.root .. "/tests/fixtures/syntax"

--- Open a fixture with the cursor on the first `pattern` (at `pattern`'s `at` part, if given).
local function open(file, pattern, at)
  local lines = vim.fn.readfile(dir .. "/" .. file)
  for i, l in ipairs(lines) do
    local s = l:find(pattern, 1, true)
    if s then
      local col = at and (l:find(at, s, true) - 1) or (s - 1)
      return H.edit(dir .. "/" .. file, i, col)
    end
  end
  error("no " .. pattern)
end

--- The graph at the cursor, synchronously.
local function graph_here()
  local g, done
  require("spoor.syntax").at_cursor(0, function(r)
    g, done = r, true
  end)
  H.wait(function()
    return done
  end, 2000, "syntax graph")
  return g
end

local function names(g, dir_)
  local out = {}
  for _, e in ipairs(g.edges) do
    if dir_ == "out" and e.from == g.focus then
      out[#out + 1] = g.nodes[e.to].name .. (g.nodes[e.to].tags.outside and " (outside)" or "")
    elseif dir_ == "in" and e.to == g.focus then
      out[#out + 1] = g.nodes[e.from].name .. " " .. e.kind .. " ×" .. #e.sites
    end
  end
  table.sort(out)
  return out
end

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

T["lua: callees in the function, callers and value uses in the file"] = function()
  open("shop.lua", "function M.process", "process")
  require("spoor.config").setup({})
  local g = graph_here()
  eq(g.source, "syntax")
  eq(g.nodes[g.focus].name, "M.process")
  eq(g.nodes[g.focus].kind, 12)
  eq(names(g, "out"), { "M.validate", "save (outside)", "subtotal" })
  -- comments and strings are not uses
  eq(names(g, "in"), { "(top level) call ×1", "(top level) ref ×1", "checkout call ×1" })
  -- callees in this file point at their definitions
  for _, e in ipairs(g.edges) do
    local n = g.nodes[e.to]
    if n.name == "subtotal" then
      eq(n.selection.start.line, 3)
    end
  end
end

T["lua: inside a body the enclosing function is the focus; on a call, the callee"] = function()
  open("shop.lua", "sum = sum + item.price")
  require("spoor.config").setup({})
  local g = graph_here()
  eq(g.nodes[g.focus].name, "subtotal")
  eq(names(g, "out"), { "ipairs (outside)" })
  eq(names(g, "in"), { "M.process call ×1" })
  vim.cmd("bwipeout!")
  open("shop.lua", "local total = subtotal(order)", "subtotal")
  eq(graph_here().nodes[graph_here().focus].name, "subtotal")
  vim.cmd("bwipeout!")
  open("shop.lua", "return M.process(order)", "return") -- anonymous function, named by its variable
  eq(graph_here().nodes[graph_here().focus].name, "checkout")
  vim.cmd("bwipeout!")
  open("shop.lua", "return M, handlers") -- top level: no function
  eq(graph_here(), nil)
end

T["c: function definitions through declarators"] = function()
  open("stats.c", "int total(", "total")
  require("spoor.config").setup({})
  local g = graph_here()
  eq(g.nodes[g.focus].name, "total")
  eq(names(g, "out"), { "add" })
  eq(names(g, "in"), { "main call ×1" })
  vim.cmd("bwipeout!")
  open("stats.c", "int main(", "main")
  eq(names(graph_here(), "out"), { "printf (outside)", "total" })
end

T["a language with no parser has no syntax bow-tie"] = function()
  H.edit(H.go .. "/internal/order/order.go", 1, 0)
  eq(require("spoor.syntax").available(0), false)
  eq(graph_here(), nil)
end

T["the live card falls back to syntax and says so"] = function()
  open("shop.lua", "function M.process", "process")
  require("spoor").setup({ live = { debounce = 10, panel = true, layout = "bottom" } })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  local live = require("spoor.live")
  local v
  H.wait(function()
    v = live.panels[vim.api.nvim_get_current_tabpage()]
    return v and v:valid() and text(v.win.buf):find("subtotal", 1, true) ~= nil
  end, 3000, "panel")
  expect.no_equality(vim.wo[v.win.win].winbar:find("syntax only · this file", 1, true), nil)
  eq(vim.wo[v.win.win].winbar:find("static calls only", 1, true), nil)
  expect.no_equality(text(v.win.buf):find("checkout", 1, true), nil)
end

T["the card footer names syntax, not a server"] = function()
  open("shop.lua", "function M.process", "process")
  require("spoor").setup({ live = { debounce = 10, card = { delay = 0 } } })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  local live = require("spoor.live")
  local v
  H.wait(function()
    v = live.panels[vim.api.nvim_get_current_tabpage()]
    return v and v:valid() and v.graph ~= nil
  end, 3000, "card")
  local footer = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(v.win.win).footer))
  expect.no_equality(footer:find("syntax only · this file", 1, true), nil)
end

T["a server without call hierarchy (marksman, ty) gets the syntax bow-tie"] = function()
  local bufnr = open("shop.lua", "function M.process", "process")
  local server = H.fake_server(bufnr, {
    name = "nohierarchy",
    root = dir,
    handlers = {},
    capabilities = { documentSymbolProvider = true, referencesProvider = true },
  })
  require("spoor").setup({ live = { debounce = 10, panel = true, layout = "bottom" } })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  local live = require("spoor.live")
  H.wait(function()
    local v = live.panels[vim.api.nvim_get_current_tabpage()]
    return v and v:valid() and v.graph and v.graph.source == "syntax"
  end, 3000, "syntax panel")
  eq(#server.requests, 0) -- spoor never asks it
end

T["a server with call hierarchy always wins over syntax"] = function()
  local bufnr = open("shop.lua", "function M.process", "process")
  local item = H.item(dir .. "/shop.lua", "process", { pattern = "function M%.process" })
  H.fake_server(bufnr, {
    root = dir,
    handlers = {
      ["textDocument/prepareCallHierarchy"] = function()
        return { item }
      end,
      ["callHierarchy/outgoingCalls"] = function()
        return {}
      end,
      ["callHierarchy/incomingCalls"] = function()
        return {}
      end,
    },
  })
  require("spoor").setup({ live = { debounce = 10, panel = true, layout = "bottom" } })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  local live = require("spoor.live")
  local v
  H.wait(function()
    v = live.panels[vim.api.nvim_get_current_tabpage()]
    return v and v:valid() and v.graph and v.graph.complete
  end, 3000, "lsp panel")
  eq(v.graph.source, nil)
  eq(v.graph.server, "fake")
  eq(text(v.win.buf):find("subtotal", 1, true), nil) -- the server's answer, not the syntax one
end

T["syntax = false turns the fallback off"] = function()
  open("shop.lua", "function M.process", "process")
  require("spoor").setup({ syntax = false, live = { debounce = 10, panel = true, layout = "bottom" } })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  vim.wait(200)
  eq(require("spoor.live").panels[vim.api.nvim_get_current_tabpage()], nil)
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  require("spoor").bowtie()
  vim.notify = orig
  eq(msgs, { "No language server with call hierarchy for this buffer" })
end

T["gag: float, . re-roots on a callee in this file, t says tracing needs a server"] = function()
  open("shop.lua", "function M.process", "process")
  require("spoor").setup({ live = { enabled = false } })
  local bowtie = require("spoor.bowtie")
  require("spoor").bowtie()
  H.wait(function()
    return bowtie.current and bowtie.current:valid() and bowtie.current.graph ~= nil
  end, 3000, "float")
  local v = bowtie.current
  expect.no_equality(
    table
      .concat(vim.tbl_map(function(c)
        return c[1]
      end, vim.api.nvim_win_get_config(v.win.win).footer))
      :find("syntax only", 1, true),
    nil
  )
  -- put the cursor on subtotal in the callees column and re-root there
  local row
  for i, l in ipairs(vim.api.nvim_buf_get_lines(v.win.buf, 0, -1, false)) do
    if l:find("subtotal", 1, true) then
      row = i
    end
  end
  local line = vim.api.nvim_buf_get_lines(v.win.buf, row - 1, row, false)[1]
  vim.api.nvim_win_set_cursor(v.win.win, { row, line:find("subtotal", 1, true) - 1 })
  bowtie.float_actions.reroot(v)
  H.wait(function()
    return v.graph.nodes[v.graph.focus].name == "subtotal"
  end, 2000, "re-root")
  eq(#v.history, 1)
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  bowtie.float_actions.trace(v)
  vim.notify = orig
  eq(msgs, { "Tracing needs a language server with call hierarchy" })
  eq(v:valid(), true)
  v:close()
end

local function health()
  vim.cmd("checkhealth spoor")
  local buf, out = vim.api.nvim_get_current_buf(), ""
  H.wait(function()
    out = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    return out:find("in this buffer", 1, true) ~= nil and (out:find("tree%-sitter") or out:find("stays quiet"))
  end, 3000, "health output")
  vim.cmd("bwipeout!")
  return out
end

T["health says when the syntax bow-tie is in use"] = function()
  open("shop.lua", "function M.process", "process")
  require("spoor").setup({ live = { enabled = false } })
  expect.no_equality(health():find("tree-sitter (lua): same-file bow-tie, syntax only", 1, true), nil)
  H.edit(H.go .. "/internal/order/order.go", 1, 0) -- no Go parser in the test runtime
  expect.no_equality(health():find("stays quiet in this buffer", 1, true), nil)
end

T["a 5k-line file builds without blocking"] = function()
  local lines = { "local M = {}" }
  for i = 1, 600 do
    vim.list_extend(lines, {
      ("function M.f%d(x)"):format(i),
      ("  local y = M.f%d(x) + helper(x)"):format(math.max(i - 1, 1)),
      "  if y > 1 then",
      ("    y = y + M.f%d(y)"):format((i * 7) % 600 + 1),
      "  end",
      "  -- a comment about f1",
      "  return y",
      "end",
    })
  end
  lines[#lines + 1] = "return M"
  eq(#lines >= 4800, true)
  local path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(lines, path)
  H.edit(path, 2, 11) -- on M.f1
  require("spoor.config").setup({})
  local t0 = vim.uv.hrtime()
  local g = graph_here()
  local first = (vim.uv.hrtime() - t0) / 1e6
  vim.api.nvim_win_set_cursor(0, { 2402, 11 })
  t0 = vim.uv.hrtime()
  local g2 = graph_here()
  local again = (vim.uv.hrtime() - t0) / 1e6
  eq(g.nodes[g.focus].name, "M.f1")
  eq(g2.nodes[g2.focus].name, "M.f301")
  -- generous bounds: CI machines are slow; bench/syntax.lua measures properly
  eq(first < 1000, true, ("first build took %d ms"):format(first))
  eq(again < 250, true, ("a cached build took %d ms"):format(again))
end

return T
