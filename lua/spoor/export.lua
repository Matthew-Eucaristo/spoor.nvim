--- Mermaid, quickfix and JSON views of bow-ties and trails.
local graph = require("spoor.graph")
local model = require("spoor.model")
local util = require("spoor.util")

local M = {}

local function mid(id, ids)
  if not ids[id] then
    ids.n = ids.n + 1
    ids[id] = "n" .. ids.n
  end
  return ids[id]
end

local function label(s)
  s = s:gsub('"', "'"):gsub("[%[%]{}<>|]", " ")
  return '"' .. s .. '"'
end

--- `graph LR` of a bow-tie: callers --> focus --> callees.
---@param g spoor.Graph
---@param opts? {show_all?: boolean}
function M.bowtie_mermaid(g, opts)
  opts = opts or {}
  local ids = { n = 0 }
  local lines = { "graph LR" }
  local focus = g.nodes[g.focus]
  lines[#lines + 1] = ("  %s[[%s]]"):format(mid(focus.id, ids), label(focus.name))
  if focus.framework then
    lines[#lines + 1] = ("  fw([%s]) -.-> %s"):format(label(focus.framework.label), mid(focus.id, ids))
  end
  local arrow = { call = "-->", jsx = "-->|jsx|", ref = "-.->|value|" }
  for _, dir in ipairs({ "in", "out" }) do
    for _, e in ipairs((graph.neighbours(g, g.focus, dir, opts.show_all))) do
      local other = g.nodes[dir == "in" and e.from or e.to]
      local name = other.name .. (other.impls and other.impls > 0 and (" ◇" .. other.impls) or "")
      lines[#lines + 1] = ("  %s[%s]"):format(mid(other.id, ids), label(name))
      lines[#lines + 1] = ("  %s %s %s"):format(mid(e.from, ids), arrow[e.kind] or "-->", mid(e.to, ids))
    end
  end
  return table.concat(lines, "\n")
end

--- `graph TD` of a trail, notes as side notes.
---@param trail spoor.Trail
function M.trail_mermaid(trail)
  local lines = { "graph TD" }
  for i, step in ipairs(trail.steps) do
    lines[#lines + 1] = ("  s%d[%s]"):format(i, label(step.node.name))
    if i > 1 then
      local via = step.via and step.via ~= "call" and ("|" .. step.via .. "|") or ""
      lines[#lines + 1] = ("  s%d -->%s s%d"):format(i - 1, via, i)
    end
    if step.note and step.note ~= "" then
      lines[#lines + 1] = ("  s%d -.- note%d>%s]"):format(i, i, label(step.note))
    end
  end
  return table.concat(lines, "\n")
end

--- Quickfix items for a trail, notes as the text.
---@param trail spoor.Trail
function M.trail_qf(trail)
  local items = {}
  for i, step in ipairs(trail.steps) do
    local n = step.node
    local path = util.path(n.uri)
    local line = util.read_lines(path, n.selection.start.line + 1)[n.selection.start.line + 1] or ""
    items[#items + 1] = {
      filename = path,
      lnum = n.selection.start.line + 1,
      col = util.byte_col(line, n.selection.start.character) + 1,
      text = ("%d %s%s"):format(i, n.name, step.note and (" — " .. step.note) or ""),
    }
  end
  return items
end

--- Trail as portable JSON: relative paths, no server items.
---@param trail spoor.Trail
function M.trail_json(trail)
  local steps = {}
  for _, step in ipairs(trail.steps) do
    local n = step.node
    steps[#steps + 1] = {
      name = n.name,
      kind = util.kinds[n.kind] or n.kind,
      path = (util.relative(util.path(n.uri), trail.root)),
      line = n.selection.start.line + 1,
      via = step.via,
      note = step.note,
      framework = n.framework and n.framework.label or nil,
    }
  end
  return {
    version = model.VERSION,
    title = trail.title,
    created = trail.created,
    updated = trail.updated,
    steps = steps,
  }
end

return M
