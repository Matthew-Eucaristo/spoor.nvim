--- Pure rendering: graph -> lines, highlights and a row map. No windows, no LSP,
--- so every layout case is unit-tested.
---
---   CALLERS 3 +1 hidden                                        CALLEES 4
---   󰊕 main       cmd/app/main.go:9 ──╮                     ╭─▶ 󰊕 loadConfig   cfg/load.go:20
---   󰊕 Run           server.go:88   ──┼─▶ 󰊕 ProcessOrder ───┼─▶ 󰊕 validate     order/validate.go:9
---   󰊕 TestProcess  order_test.go:12 ──╯   order/order.go:42 ├─▶ 󰊕 Save ◇2      store/store.go:14
---                                                          ╰─▶ 󰊕 emit         evt/bus.go:31
local Config = require("spoor.config")
local graph = require("spoor.graph")
local icons = require("spoor.icons")
local util = require("spoor.util")

local M = {}

---@class spoor.RenderOpts
---@field width integer
---@field max_items? integer rows per side at the first level
---@field max_rows? integer hard cap on body rows (live panel height)
---@field show_all? boolean ignore hide filters
---@field children? integer rows per expanded node at the second level
---@field header? boolean
---@field offset? integer left margin in columns (centers the bow-tie in wide windows)

---@class spoor.Row
---@field kind "node"|"more"|"framework"|"message"
---@field depth integer 0 = message (no connector), 1 = neighbour, 2 = neighbour of neighbour
---@field id? string node id
---@field edge? spoor.Edge
---@field text? string
---@field hl? string
---@field count? integer

---@class spoor.Rendered
---@field lines string[]
---@field hls {row: integer, col: integer, end_col: integer, group: string}[] 0-based rows, byte cols
---@field map table<integer, {left?: spoor.Row, right?: spoor.Row, focus?: boolean}> 1-based rows
---@field cols {left_end: integer, right_start: integer} display columns
---@field legend {[1]: string, [2]: string}[]

-- Junction glyph from connections: left, right, up, down.
local JUNCTION = {
  ["1111"] = "┼",
  ["1110"] = "┴",
  ["1101"] = "┬",
  ["1100"] = "─",
  ["1011"] = "┤",
  ["1010"] = "╯",
  ["1001"] = "╮",
  ["1000"] = "─",
  ["0111"] = "├",
  ["0110"] = "╰",
  ["0101"] = "╭",
  ["0100"] = "─",
  ["0011"] = "│",
  ["0010"] = "│",
  ["0001"] = "│",
  ["0000"] = " ",
}

---@param l boolean
---@param r boolean
---@param u boolean
---@param d boolean
function M.junction(l, r, u, d)
  local key = (l and "1" or "0") .. (r and "1" or "0") .. (u and "1" or "0") .. (d and "1" or "0")
  return JUNCTION[key]
end

--- A line made of highlighted segments; tracks byte and display columns.
local Line = {}
Line.__index = Line

function Line.new()
  return setmetatable({ parts = {}, hls = {}, bytes = 0, width = 0 }, Line)
end

function Line:add(text, hl)
  if text == "" then
    return self
  end
  if hl then
    table.insert(self.hls, { col = self.bytes, end_col = self.bytes + #text, group = hl })
  end
  table.insert(self.parts, text)
  self.bytes = self.bytes + #text
  self.width = self.width + vim.api.nvim_strwidth(text)
  return self
end

function Line:pad_to(width)
  if self.width < width then
    self:add(string.rep(" ", width - self.width))
  end
  return self
end

function Line:text()
  return table.concat(self.parts)
end

local function location(node, root, segments)
  local rel = util.relative(util.path(node.uri), root)
  return ("%s:%d"):format(util.tail(rel, segments or 2), node.selection.start.line + 1)
end

--- Badges after a name: ◇2, </>, ×3, test/external markers.
---@return {[1]: string, [2]: string}[]
local function badges(node, edge)
  local ic = Config.options.icons
  local out = {}
  if node.impls and node.impls > 0 then
    out[#out + 1] = { " " .. ic.interface .. node.impls, "SpoorInterface" }
  end
  if edge and edge.kind == "jsx" then
    out[#out + 1] = { " " .. ic.jsx, "SpoorBadge" }
  end
  if edge and edge.sites and #edge.sites > 1 then
    out[#out + 1] = { " ×" .. #edge.sites, "SpoorBadge" }
  end
  if node.tags.test then
    out[#out + 1] = { " " .. ic.test, "SpoorDim" }
  end
  if node.tags.external then
    out[#out + 1] = { " " .. ic.external, "SpoorDim" }
  end
  if node.tags.generated then
    out[#out + 1] = { " " .. ic.generated, "SpoorDim" }
  end
  return out
end

--- Fill `line` with one side entry, `width` display columns, location right-aligned.
---@param line table
---@param row spoor.Row?
---@param g spoor.Graph
---@param width integer
---@param side "left"|"right"
local function entry(line, row, g, width, side)
  local start = line.width
  if not row then
    return line:pad_to(start + width)
  end
  if row.kind ~= "node" then
    local indent = row.depth == 2 and "   " or ""
    line:add(util.truncate(indent .. row.text, width), row.hl)
    return line:pad_to(start + width)
  end
  local node = g.nodes[row.id]
  local ic = Config.options.icons
  local indent = row.depth == 2 and (side == "left" and "  ◂ " or "  ▸ ") or ""
  local icon, icon_hl
  if row.edge and row.edge.kind == "ref" then
    icon, icon_hl = ic.value, "SpoorValue"
  else
    icon, icon_hl = icons.kind(node.kind)
  end
  -- outside: a syntax-only callee that is not defined in this file
  local name_hl = (node.tags.external or node.tags.generated or node.tags.test or node.tags.outside) and "SpoorDim"
    or "SpoorName"
  if row.edge and row.edge.kind == "ref" then
    name_hl = "SpoorValue"
  end
  local marks = badges(node, row.edge)
  local marks_w = 0
  for _, b in ipairs(marks) do
    marks_w = marks_w + vim.api.nvim_strwidth(b[1])
  end
  local head = indent .. icon .. " "
  local avail = width - vim.api.nvim_strwidth(head) - marks_w - 1 -- 1: gap before connectors
  -- the name gets priority; the location shortens (dir/file:line, file:line) or drops
  local name = util.truncate(node.name, math.max(avail, 4))
  local loc_room = avail - vim.api.nvim_strwidth(name) - 2
  line:add(indent, "SpoorEdge"):add(icon .. " ", icon_hl):add(name, name_hl)
  for _, b in ipairs(marks) do
    line:add(b[1], b[2])
  end
  for _, segments in ipairs({ 2, 1 }) do
    local l = location(node, g.root, segments)
    if vim.api.nvim_strwidth(l) <= loc_room then
      line:pad_to(start + width - 1 - vim.api.nvim_strwidth(l))
      line:add(l, "SpoorLoc")
      break
    end
  end
  return line:pad_to(start + width)
end

local function sort_callers(g)
  return function(a, b)
    local na, nb = g.nodes[a.from], g.nodes[b.from]
    local ka = (na.tags.test and 1 or 0) + (a.kind == "ref" and 2 or 0)
    local kb = (nb.tags.test and 1 or 0) + (b.kind == "ref" and 2 or 0)
    if ka ~= kb then
      return ka < kb
    end
    return na.name < nb.name
  end
end

local function first_site(e)
  local s = e.sites and e.sites[1]
  return s and (s.start.line * 10000 + s.start.character) or math.huge
end

--- Rows for one side of the bow-tie.
---@param g spoor.Graph
---@param dir "in"|"out"
---@param opts spoor.RenderOpts
---@return spoor.Row[] rows, integer total, table<string, integer> hidden
function M.side(g, dir, opts)
  local focus = g.nodes[g.focus]
  local max_items = opts.max_items or 12
  local children = opts.children or 3
  local visible, hidden = graph.neighbours(g, g.focus, dir, opts.show_all)
  if dir == "in" then
    table.sort(visible, sort_callers(g))
  else
    table.sort(visible, function(a, b)
      return first_site(a) < first_site(b)
    end)
  end
  local rows = {} ---@type spoor.Row[]
  local ic = Config.options.icons
  if dir == "in" and focus.framework and (not focus.framework.only_if_empty or #visible == 0) then
    rows[#rows + 1] =
      { kind = "framework", depth = 1, text = ic.framework .. " " .. focus.framework.label, hl = "SpoorFramework" }
  end
  for i, e in ipairs(visible) do
    if i > max_items then
      rows[#rows + 1] = {
        kind = "more",
        depth = 1,
        text = ("+%d more"):format(#visible - max_items),
        hl = "SpoorMore",
        count = #visible - max_items,
      }
      break
    end
    local id = dir == "in" and e.from or e.to
    rows[#rows + 1] = { kind = "node", depth = 1, id = id, edge = e }
    if g.expanded[id .. (dir == "in" and "<in" or ">out")] then
      local sub = graph.neighbours(g, id, dir, opts.show_all)
      for j, se in ipairs(sub) do
        if j > children then
          rows[#rows + 1] = { kind = "more", depth = 2, text = ("+%d more"):format(#sub - children), hl = "SpoorMore" }
          break
        end
        rows[#rows + 1] = { kind = "node", depth = 2, id = dir == "in" and se.from or se.to, edge = se }
      end
    end
  end
  if #visible == 0 then
    local status = dir == "in" and g.status.incoming or g.status.outgoing
    local what = dir == "in" and "callers" or "callees"
    if status == "loading" then
      rows[#rows + 1] = { kind = "message", depth = 0, text = "⋯ finding " .. what, hl = "SpoorMessage" }
    elseif status == "timeout" then
      rows[#rows + 1] = { kind = "message", depth = 0, text = "timed out · R to retry", hl = "SpoorWarn" }
    elseif status == "skipped" then
      rows[#rows + 1] = { kind = "message", depth = 0, text = "R to find callers (slow server)", hl = "SpoorMessage" }
    elseif status == "error" then
      rows[#rows + 1] = { kind = "message", depth = 0, text = "server error · R to retry", hl = "SpoorWarn" }
    elseif dir == "in" and g.source == "syntax" and not focus.framework then
      rows[#rows + 1] = { kind = "message", depth = 0, text = "no callers in this file", hl = "SpoorMessage" }
    elseif dir == "in" and not focus.framework then
      rows[#rows + 1] = { kind = "message", depth = 0, text = ic.warn .. " no static callers", hl = "SpoorWarn" }
      rows[#rows + 1] = { kind = "message", depth = 0, text = "framework or dynamic entry?", hl = "SpoorMessage" }
    elseif dir == "out" then
      rows[#rows + 1] = { kind = "message", depth = 0, text = "no calls", hl = "SpoorMessage" }
    end
  end
  return rows, #visible, hidden
end

--- Trim a side to `max` rows, replacing the tail with "+N more".
local function clamp(rows, max)
  if not max or #rows <= max then
    return rows
  end
  local out = {}
  for i = 1, max - 1 do
    out[i] = rows[i]
  end
  local rest = 0
  for i = max, #rows do
    if rows[i].kind == "node" and rows[i].depth == 1 then
      rest = rest + 1
    elseif rows[i].kind == "more" and rows[i].depth == 1 then
      rest = rest + (rows[i].count or 0)
    end
  end
  out[max] = { kind = "more", depth = 1, text = ("+%d more"):format(rest), hl = "SpoorMore", count = rest }
  return out
end

local function hidden_text(hidden)
  local parts = {}
  for _, reason in ipairs({ "external", "generated", "tests", "excluded" }) do
    if hidden[reason] then
      parts[#parts + 1] = ("%d %s"):format(hidden[reason], reason)
    end
  end
  return #parts > 0 and (" +" .. table.concat(parts, " · ") .. " hidden") or ""
end

--- Legend chunks for a footer/winbar: honest about what the edges are.
---@param g spoor.Graph
function M.legend(g)
  local ic = Config.options.icons
  local seen = {}
  for _, n in pairs(g.nodes) do
    if n.impls and n.impls > 0 then
      seen.interface = true
    end
  end
  for _, e in ipairs(g.edges) do
    seen[e.kind] = true
  end
  local out = { { " static calls only", "SpoorMessage" } }
  if g.source == "syntax" then
    out = { { " syntax only · this file", "SpoorMessage" } }
  elseif g.server then
    out[#out + 1] = { " · " .. g.server, "SpoorMessage" }
  end
  if seen.interface then
    out[#out + 1] = { " · " .. ic.interface .. " interface (impls)", "SpoorInterface" }
  end
  if seen.ref then
    out[#out + 1] = { " · " .. ic.value .. " used as a value", "SpoorValue" }
  end
  if seen.jsx then
    out[#out + 1] = { " · " .. ic.jsx .. " JSX", "SpoorBadge" }
  end
  if g.nodes[g.focus].framework then
    out[#out + 1] = { " · " .. ic.framework .. " framework", "SpoorFramework" }
  end
  out[#out + 1] = { " ", "SpoorMessage" }
  return out
end

--- Render a bow-tie.
---@param g spoor.Graph
---@param opts spoor.RenderOpts
---@return spoor.Rendered
function M.bowtie(g, opts)
  local W = math.max(opts.width, 40)
  local pad = string.rep(" ", opts.offset or 0)
  local focus = g.nodes[g.focus]
  local left, n_in, hidden_in = M.side(g, "in", opts)
  local right, n_out, hidden_out = M.side(g, "out", opts)
  local body_max = opts.max_rows and (opts.max_rows - (opts.header == false and 0 or 1)) or nil
  left, right = clamp(left, body_max), clamp(right, body_max)

  local n = math.max(#left, #right, 2)
  local mid = math.floor((n - 1) / 2)
  if mid + 1 >= n then
    n = n + 1
  end

  local f_icon, f_icon_hl = icons.kind(focus.kind)
  local f_name = focus.name
  local f_loc = location(focus, g.root)
  local CW = math.max(vim.api.nvim_strwidth(f_name) + 5, vim.api.nvim_strwidth(f_loc) + 3, 16)
  CW = math.min(CW, math.floor(W * 0.3))
  local LC, RC = 4, 4
  local side_w = math.floor((W - CW - LC - RC - 2) / 2)
  local LW, RW = side_w, W - CW - LC - RC - 2 - side_w

  local function span(rows)
    local top, bottom, entries = mid, mid, {}
    for i, r in ipairs(rows) do
      if r.depth == 1 then
        entries[i - 1] = true
        top, bottom = math.min(top, i - 1), math.max(bottom, i - 1)
      end
    end
    return top, bottom, entries, next(entries) ~= nil
  end
  local lt, lb, le, has_l = span(left)
  local rt, rb, re, has_r = span(right)

  local out = { lines = {}, hls = {}, map = {}, cols = {}, legend = M.legend(g) }
  local function push(line, map)
    table.insert(out.lines, line:text())
    local row = #out.lines - 1
    for _, h in ipairs(line.hls) do
      table.insert(out.hls, { row = row, col = h.col, end_col = h.end_col, group = h.group })
    end
    out.map[#out.lines] = map
  end

  if opts.header ~= false then
    local h = Line.new():add(pad .. " ")
    h:add(("CALLERS %d"):format(n_in), "SpoorHeader"):add(hidden_text(hidden_in), "SpoorDim")
    h:pad_to(#pad + 1 + LW + LC + CW + RC + 1)
    h:add(("CALLEES %d"):format(n_out), "SpoorHeader"):add(hidden_text(hidden_out), "SpoorDim")
    push(h, {})
  end

  -- message rows (depth 0) sit on the focus row, like a missing branch
  local function place(rows)
    local placed = {}
    local only_messages = #rows > 0 and rows[1].depth == 0
    local offset = only_messages and mid or 0
    for i, r in ipairs(rows) do
      placed[i - 1 + offset] = r
    end
    return placed
  end
  local L, R = place(left), place(right)

  for i = 0, n - 1 do
    local line = Line.new():add(pad .. " ")
    local lrow, rrow = L[i], R[i]
    entry(line, lrow, g, LW, "left")
    -- left connector
    if has_l and i >= lt and i <= lb then
      local is_entry = le[i] == true
      line:add(is_entry and "──" or "  ", "SpoorEdge")
      line:add(M.junction(is_entry, i == mid, i > lt, i < lb), "SpoorEdge")
      line:add(i == mid and "─" or " ", "SpoorEdge")
    else
      line:add(string.rep(" ", LC))
    end
    -- center
    local cstart = line.width
    if i == mid then
      line:add(has_l and "▶ " or "  ", "SpoorEdge"):add(f_icon .. " ", f_icon_hl)
      line:add(util.truncate(f_name, CW - 4), "SpoorFocus")
      if has_r then
        line:add(" ")
        line:add(string.rep("─", math.max(cstart + CW - line.width, 0)), "SpoorEdge")
      end
    elseif i == mid + 1 then
      line:add("  " .. util.truncate(f_loc, CW - 2), "SpoorLoc")
    end
    line:pad_to(cstart + CW)
    -- right connector
    if has_r and i >= rt and i <= rb then
      local is_entry = re[i] == true
      line:add(i == mid and "─" or " ", "SpoorEdge")
      line:add(M.junction(i == mid, is_entry, i > rt, i < rb), "SpoorEdge")
      line:add(is_entry and "─▶" or "  ", "SpoorEdge")
    else
      line:add(string.rep(" ", RC))
    end
    line:add(" ")
    entry(line, rrow, g, RW, "right")
    push(line, { left = lrow, right = rrow, focus = i == mid or i == mid + 1 })
  end
  out.cols = { left_end = #pad + 1 + LW + LC, right_start = #pad + 1 + LW + LC + CW + RC + 1 }
  return out
end

--- Which node does a cursor column point at on a rendered row?
---@param r spoor.Rendered
---@param row integer 1-based
---@param col integer 0-based display column
---@return string? id, "left"|"right"|"focus"|nil side, spoor.Row?
function M.hit(r, row, col, focus_id)
  local m = r.map[row]
  if not m then
    return nil
  end
  if col < r.cols.left_end then
    if m.left and m.left.id then
      return m.left.id, "left", m.left
    end
    return nil, "left", m.left
  elseif col >= r.cols.right_start then
    if m.right and m.right.id then
      return m.right.id, "right", m.right
    end
    return nil, "right", m.right
  elseif m.focus then
    return focus_id, "focus"
  end
end

return M
