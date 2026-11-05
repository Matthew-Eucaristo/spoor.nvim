-- Renders the page's bow-tie explorer with spoor itself. Run by site/build.sh:
--   nvim --headless --clean -l site/bowtie.lua <gopls> <out.json>
-- gopls answers call hierarchy on tests/fixtures/go (the demo's synthetic shop repo); spoor's own
-- graph.build and render.bowtie lay out each bow-tie with the gag float's depth and row limits,
-- at three widths. The JSON holds the lines as highlighted segments, which node each row points
-- at, each function's code for the preview, and the Mermaid that y copies. Re-rooting walks every
-- project function reachable from Process. No paths outside the fixture are written (build.sh
-- checks that).
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(repo)
local gopls, out = arg[1], arg[2]
assert(gopls and out, "usage: nvim --headless --clean -l site/bowtie.lua <gopls> <out.json>")

local Config = require("spoor.config")
local graph = require("spoor.graph")
local export = require("spoor.export")
local render = require("spoor.render")
local resolve = require("spoor.resolve")
local util = require("spoor.util")

local root = repo .. "/tests/fixtures/go"
-- the float's defaults; a generous timeout because a cold runner indexes slowly
Config.setup({ timeout = 20000, cold_timeout = 60000 })
local depth, max_items = Config.options.float.depth, Config.options.float.max_items
local WIDTHS = { 112, 84, 60 } -- the page picks the widest that fits its box

local function wait(cond, what)
  assert(vim.wait(60000, cond, 10), "timed out waiting for " .. what)
end

vim.cmd.edit(vim.fn.fnameescape(root .. "/internal/order/order.go"))
local bufnr = vim.api.nvim_get_current_buf()
local id = vim.lsp.start({ name = "gopls", cmd = { gopls }, root_dir = root }, { bufnr = bufnr })
local client
wait(function()
  client = vim.lsp.get_client_by_id(id)
  return client and client.initialized
end, "gopls")

-- Process, the demo's starting point: the cursor on its name, as gag would see it.
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  local s = l:find("func Process")
  if s then
    vim.api.nvim_win_set_cursor(0, { i, s + 4 })
    break
  end
end
local first
resolve.at_cursor(client, 0, {}, function(it)
  first = it or false
end)
wait(function()
  return first ~= nil
end, "prepare")
assert(first, "gopls gave no call hierarchy item for Process")

local function build(item)
  local done = false
  local g = graph.build(client, item, { root = root, depth = depth, max_items = max_items }, function(_, phase)
    if phase == "complete" then
      done = true
    end
  end)
  wait(function()
    return done
  end, "bow-tie for " .. item.name)
  return g
end

-- Lines as { {text, group?}, ... } from render's byte-column highlights.
local function segments(line, hls)
  table.sort(hls, function(a, b)
    return a.col < b.col
  end)
  local segs, at = {}, 0
  for _, h in ipairs(hls) do
    if h.col > at then
      segs[#segs + 1] = { line:sub(at + 1, h.col) }
    end
    if h.col >= at then
      segs[#segs + 1] = { line:sub(h.col + 1, h.end_col), h.group }
      at = h.end_col
    end
  end
  if at < #line then
    segs[#segs + 1] = { line:sub(at + 1) }
  end
  return segs
end

local function rel(uri)
  local r, inside = util.relative(util.path(uri), root)
  return inside and r or nil
end

local views, nodes, queue, seen = {}, {}, { first }, {}
local function key(item)
  return rel(item.uri)
    .. "#"
    .. (item.selectionRange.start.line + 1)
    .. ":"
    .. (item.selectionRange.start.character + 1)
end

-- The code a preview shows: the declaration with its doc comment, down to the closing brace
-- (the fixture is Go). A value use shows its line with one line around it.
local function snippet(n)
  local lines = vim.fn.readfile(util.path(n.uri))
  local first, last = n.selection.start.line + 1, n.selection.start.line + 1
  if n.tags.value then
    return { unpack(lines, math.max(first - 1, 1), math.min(first + 1, #lines)) }, math.max(first - 1, 1)
  end
  while first > 1 and lines[first - 1]:match("^%s*//") do
    first = first - 1
  end
  local one_line = lines[last]:match("}%s*$") ~= nil
  while not one_line and last < #lines and last - first < 40 and not lines[last]:match("^}") do
    last = last + 1
  end
  return { unpack(lines, first, last) }, first
end

local function remember(n)
  local path = rel(n.uri)
  local k = key(n.item or { uri = n.uri, selectionRange = n.selection })
  if not path or nodes[k] then
    return
  end
  local code, first = snippet(n)
  nodes[k] = { name = n.name, path = path, line = first, code = code }
end

while #queue > 0 and vim.tbl_count(views) < 24 do
  local item = table.remove(queue, 1)
  local k = key(item)
  if not seen[k] then
    seen[k] = true
    local g = build(item)
    local function id_of(nid)
      local n = nid and g.nodes[nid]
      if not n or not rel(n.uri) then
        return nil
      end
      remember(n)
      if n.item and not n.tags.value then
        if not seen[key(n.item)] then
          queue[#queue + 1] = n.item
        end
        return key(n.item)
      end
      return key({ uri = n.uri, selectionRange = n.selection })
    end
    remember(g.nodes[g.focus])
    local v = { name = item.name, widths = {} }
    for _, w in ipairs(WIDTHS) do
      local r = render.bowtie(g, { width = w, max_items = max_items })
      local by_row = {}
      for _, h in ipairs(r.hls) do
        by_row[h.row] = by_row[h.row] or {}
        table.insert(by_row[h.row], h)
      end
      local lines, rows = {}, {}
      for i, line in ipairs(r.lines) do
        lines[i] = segments(line, by_row[i - 1] or {})
        local m = r.map[i] or {}
        rows[i] = {
          l = m.left and m.left.id and id_of(m.left.id) or vim.NIL,
          r = m.right and m.right.id and id_of(m.right.id) or vim.NIL,
          f = m.focus or false,
        }
      end
      v.widths[tostring(w)] =
        { lines = lines, rows = rows, left_end = r.cols.left_end, right_start = r.cols.right_start }
      v.legend = r.legend
    end
    v.mermaid = export.bowtie_mermaid(g) -- what y copies
    views[k] = v
  end
end

local data = {
  generated_by = "site/bowtie.lua: gopls on tests/fixtures/go, rendered by spoor's render.bowtie",
  server = client.name,
  start = key(first),
  widths = WIDTHS,
  views = views,
  nodes = nodes,
}
local f = assert(io.open(out, "w"))
f:write(vim.json.encode(data))
f:close()
client:stop(true)
vim.cmd("qa!")
