local H = require("tests.helpers")
local T = MiniTest.new_set({ hooks = { pre_case = H.reset } })
local eq, expect = MiniTest.expect.equality, MiniTest.expect

local function start()
  local w = H.go_world()
  local p = w.process.selectionRange.start
  local bufnr = H.edit(H.go .. "/internal/order/order.go", p.line + 1, p.character)
  local handlers = H.go_handlers(w)
  local server = H.fake_server(bufnr, { handlers = handlers })
  require("spoor.config").setup({})
  require("spoor.highlights").setup()
  local code_win = vim.api.nvim_get_current_win()
  require("spoor.trace").start_at_cursor()
  H.wait(function()
    local s = require("spoor.trace").state
    return s.win and s.win:valid() and #s.hops >= 5
  end, 3000, "trace window with hops")
  return w, server, code_win
end

local function text()
  local s = require("spoor.trace").state
  return table.concat(vim.api.nvim_buf_get_lines(s.win.buf, 0, -1, false), "\n")
end

T["gat opens a trail panel with numbered next hops"] = function()
  local _, _, code_win = start()
  local t = text()
  expect.no_equality(t:find("Process", 1, true), nil)
  expect.no_equality(t:find("next hop", 1, true), nil)
  expect.no_equality(t:find("1  ", 1, true), nil)
  expect.no_equality(t:find("Save ◇2", 1, true), nil)
  -- the trail panel has focus, the code stays visible on the left
  local s = require("spoor.trace").state
  eq(vim.api.nvim_get_current_win(), s.win.win)
  eq(s.origin, code_win)
end

T["picking a hop extends the trail and shows the code"] = function()
  local w, _, code_win = start()
  local trace = require("spoor.trace")
  -- hop 1 is validate (source order)
  trace.pick(1)
  H.wait(function()
    return #trace.state.trail.steps == 2
  end)
  eq(trace.state.trail.steps[2].node.name, "validate")
  eq(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code_win)), vim.uri_to_fname(w.validate.uri))
  expect.no_equality(text():find("└▶", 1, true), nil)
  -- back
  trace.back()
  eq(#trace.state.trail.steps, 1)
end

T["interface hops offer the implementations"] = function()
  start()
  local trace = require("spoor.trace")
  local choices
  local orig = vim.ui.select
  vim.ui.select = function(items, _, on_choice)
    choices = items
    on_choice(items[2])
  end
  local k
  for _, m in pairs(trace.state.rendered.map) do
    if m.id and trace.state.graph.nodes[m.id].name == "Save" then
      k = m.hop
    end
  end
  trace.pick(k)
  vim.ui.select = orig
  eq(#choices, 3) -- the interface itself + 2 implementations
  H.wait(function()
    return #trace.state.trail.steps == 2
  end)
  eq(trace.state.trail.steps[2].via, "impl")
end

T["notes, persistence and resume"] = function()
  start()
  local trace = require("spoor.trace")
  local orig = vim.ui.input
  vim.ui.input = function(_, cb)
    cb("validate mutates the total?")
  end
  trace.note()
  vim.ui.input = orig
  expect.no_equality(text():find("✎ validate mutates the total?", 1, true), nil)
  local root = trace.state.trail.root
  local data = trace.load(root)
  eq(data.trails[data.last].steps[1].note, "validate mutates the total?")
  trace.close()
  -- resume reopens the same trail
  trace.state.trail = nil
  trace.resume()
  eq(trace.state.trail.id, data.last)
  expect.no_equality(text():find("✎ validate", 1, true), nil)
end

T["quickfix and mermaid"] = function()
  start()
  local trace = require("spoor.trace")
  trace.pick(1)
  H.wait(function()
    return #trace.state.trail.steps == 2
  end)
  trace.quickfix()
  local qf = vim.fn.getqflist()
  eq(#qf, 2)
  expect.no_equality(qf[2].text:find("validate", 1, true), nil)
  vim.cmd("cclose")
  trace.mermaid()
  local m = vim.fn.getreg('"')
  expect.no_equality(m:find("^graph TD"), nil)
  expect.no_equality(m:find("s1 --> s2", 1, true), nil)
end

T["i flips next hops to callers"] = function()
  start()
  local trace = require("spoor.trace")
  vim.api.nvim_feedkeys("i", "x", false)
  eq(trace.state.dir, "in")
  expect.no_equality(text():find("callers of", 1, true), nil)
  expect.no_equality(text():find("handleOrders", 1, true), nil)
end

T["render is pure and stable"] = function()
  local model = require("spoor.model")
  local w = H.go_world()
  local trail = model.trail(H.go, model.node(w.process))
  table.insert(trail.steps, { node = model.node(w.validate), via = "call", note = "check" })
  local out = require("spoor.trace").render(trail, {}, { width = 60, dir = "out" })
  eq(out.lines[1]:find("Process", 1, true) ~= nil, true)
  eq(out.lines[2]:find("└▶", 1, true) ~= nil, true)
  eq(out.lines[3]:find("✎ check", 1, true) ~= nil, true)
  local json = require("spoor.export").trail_json(trail)
  eq(json.steps[2].path, "internal/order/validate.go")
  eq(json.steps[2].note, "check")
end

T["a narrow trail window keeps the label and cuts old crumbs"] = function()
  start()
  local s = require("spoor.trace").state
  local bar =
    vim.api.nvim_eval_statusline(vim.wo[s.win.win].winbar, { winid = s.win.win, use_winbar = true, maxwidth = 16 })
  eq(bar.str:sub(1, 13), " spoor trace ")
end

T["a dead end says how to turn around"] = function()
  local trail = require("spoor.model").trail("/p", {
    id = "a",
    name = "leaf",
    kind = 12,
    uri = "file:///p/a.go",
    range = { start = { line = 0, character = 0 }, ["end"] = { line = 1, character = 0 } },
    selection = { start = { line = 0, character = 5 }, ["end"] = { line = 0, character = 9 } },
    tags = {},
  })
  require("spoor.config").setup({})
  local r = require("spoor.trace").render(trail, {}, { width = 60, dir = "out", graph = { nodes = {} } })
  expect.no_equality(table.concat(r.lines, "\n"):find("i show callers instead", 1, true), nil)
end

T["g? in the trail panel shows help"] = function()
  start()
  local s = require("spoor.trace").state
  vim.api.nvim_set_current_win(s.win.win)
  vim.v.errmsg = ""
  vim.api.nvim_feedkeys(vim.keycode("g?"), "x", false)
  eq(vim.v.errmsg, "")
  local help = vim.tbl_filter(function(w)
    return vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "snacks_win_help"
  end, vim.api.nvim_tabpage_list_wins(0))
  eq(#help, 1)
end

return T
