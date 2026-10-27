local H = require("tests.helpers")
local T = MiniTest.new_set({ hooks = { pre_case = H.reset } })
local eq, expect = MiniTest.expect.equality, MiniTest.expect

local function world_graph(opts)
  opts = opts or {}
  local model = require("spoor.model")
  local filters = require("spoor.filters")
  local w = H.go_world()
  local focus = model.node(w.process)
  local g = model.graph(focus, { server = "gopls", root = H.go })
  local function add(item, edge)
    local n = model.add_node(g, model.node(item))
    n.tags = filters.classify(vim.uri_to_fname(n.uri), H.go)
    model.add_edge(g, edge(n))
    return n
  end
  for _, c in ipairs(opts.callees or w.outgoing) do
    add(c.to, function(n)
      return { from = focus.id, to = n.id, kind = "call", sites = c.fromRanges, source = "lsp" }
    end)
  end
  for _, c in ipairs(opts.callers or w.incoming) do
    add(c.from, function(n)
      return { from = n.id, to = focus.id, kind = "call", sites = c.fromRanges, source = "lsp" }
    end)
  end
  g.status = { incoming = "done", outgoing = "done" }
  return g, w
end

T["junction glyphs cover every connection"] = function()
  local r = require("spoor.render")
  eq(r.junction(true, true, true, true), "┼")
  eq(r.junction(true, false, false, true), "╮")
  eq(r.junction(true, false, true, false), "╯")
  eq(r.junction(false, true, false, true), "╭")
  eq(r.junction(false, true, true, false), "╰")
  eq(r.junction(false, false, true, true), "│")
  eq(r.junction(true, true, false, false), "─")
  eq(r.junction(true, false, true, true), "┤")
  eq(r.junction(false, true, true, true), "├")
end

T["bow-tie shows callers, focus and callees in reading order"] = function()
  local g = world_graph()
  local out = require("spoor.render").bowtie(g, { width = 140 })
  local text = table.concat(out.lines, "\n")
  expect.no_equality(text:find("CALLERS 2", 1, true), nil)
  expect.no_equality(text:find("CALLEES 5", 1, true), nil)
  expect.no_equality(text:find("Process", 1, true), nil)
  -- callees keep source order: validate, applyDiscount, subtotal, Save, Emit
  local order = {}
  for _, name in ipairs({ "validate", "applyDiscount", "subtotal", "Save", "Emit" }) do
    order[#order + 1] = text:find(name, 1, true)
  end
  for i = 2, #order do
    expect.equality(order[i - 1] < order[i], true)
  end
  -- the test caller sorts after the real caller
  expect.equality(text:find("handleOrders", 1, true) < text:find("TestProcess", 1, true), true)
  -- every line fits the width
  for _, l in ipairs(out.lines) do
    expect.equality(vim.api.nvim_strwidth(l) <= 140, true)
  end
end

T["connectors join every neighbour to the focus row"] = function()
  local g = world_graph()
  local out = require("spoor.render").bowtie(g, { width = 140 })
  local text = table.concat(out.lines, "\n")
  -- 5 callees: one opening corner, one closing corner, arrows into each
  local arrows = select(2, text:gsub("─▶", ""))
  eq(arrows >= 6, true) -- 5 callees + the arrow into the focus
  expect.no_equality(text:find("╭", 1, true), nil)
  expect.no_equality(text:find("╰", 1, true), nil)
  expect.no_equality(text:find("▶ ", 1, true), nil)
end

T["hidden counts and filters"] = function()
  local Config = require("spoor.config")
  Config.setup({ hide = { tests = true } })
  local g = world_graph()
  local out = require("spoor.render").bowtie(g, { width = 140 })
  local text = table.concat(out.lines, "\n")
  expect.no_equality(text:find("CALLERS 1 +1 tests hidden", 1, true), nil)
  eq(text:find("TestProcess", 1, true), nil)
  out = require("spoor.render").bowtie(g, { width = 140, show_all = true })
  expect.no_equality(table.concat(out.lines, "\n"):find("TestProcess", 1, true), nil)
end

T["no static callers is said out loud, not left empty"] = function()
  local g = world_graph({ callers = {} })
  local out = require("spoor.render").bowtie(g, { width = 120 })
  local text = table.concat(out.lines, "\n")
  expect.no_equality(text:find("no static callers", 1, true), nil)
  expect.no_equality(text:find("framework or dynamic entry?", 1, true), nil)
end

T["framework roots get a labelled caller row"] = function()
  local g = world_graph({ callers = {} })
  g.nodes[g.focus].framework = { id = "go.http", label = "net/http · handler (router calls this)" }
  local out = require("spoor.render").bowtie(g, { width = 120 })
  local text = table.concat(out.lines, "\n")
  expect.no_equality(text:find("⚑ net/http", 1, true), nil)
  eq(text:find("no static callers", 1, true), nil)
end

T["loading and timeout states"] = function()
  local g = world_graph({ callers = {}, callees = {} })
  g.status = { incoming = "loading", outgoing = "timeout" }
  local text = table.concat(require("spoor.render").bowtie(g, { width = 120 }).lines, "\n")
  expect.no_equality(text:find("finding callers", 1, true), nil)
  expect.no_equality(text:find("timed out · R to retry", 1, true), nil)
end

T["max_rows clamps a side and keeps the count honest"] = function()
  local g = world_graph()
  local out = require("spoor.render").bowtie(g, { width = 140, max_rows = 4 })
  eq(#out.lines, 4)
  expect.no_equality(table.concat(out.lines, "\n"):find("+3 more", 1, true), nil)
end

T["interface badge, jsx badge and site counts"] = function()
  local g, w = world_graph()
  local util = require("spoor.util")
  local save = g.nodes[util.id(w.save.uri, w.save.selectionRange.start)]
  save.impls = 2
  local text = table.concat(require("spoor.render").bowtie(g, { width = 140 }).lines, "\n")
  expect.no_equality(text:find("Save ◇2", 1, true), nil)
  local legend = require("spoor.render").legend(g)
  local flat = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, legend))
  expect.no_equality(flat:find("static calls only", 1, true), nil)
  expect.no_equality(flat:find("interface", 1, true), nil)
end

T["hit testing maps columns to nodes"] = function()
  local g = world_graph()
  local r = require("spoor.render")
  local out = r.bowtie(g, { width = 140 })
  local found_left, found_right, found_focus
  for row = 1, #out.lines do
    local id = r.hit(out, row, 2, g.focus)
    if id then
      found_left = true
    end
    local rid = r.hit(out, row, out.cols.right_start + 2, g.focus)
    if rid then
      found_right = true
    end
    local fid, side = r.hit(out, row, out.cols.left_end + 3, g.focus)
    if side == "focus" and fid == g.focus then
      found_focus = true
    end
  end
  eq({ found_left, found_right, found_focus }, { true, true, true })
end

T["highlights stay inside their lines"] = function()
  local g = world_graph()
  local out = require("spoor.render").bowtie(g, { width = 100, offset = 6 })
  for _, h in ipairs(out.hls) do
    local line = out.lines[h.row + 1]
    eq(h.end_col <= #line, true)
    eq(h.col >= 0 and h.col < h.end_col, true)
  end
end

T["narrow windows still render"] = function()
  local g = world_graph()
  local out = require("spoor.render").bowtie(g, { width = 40 })
  eq(#out.lines > 3, true)
end

return T
