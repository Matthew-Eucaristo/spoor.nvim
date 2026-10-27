--- Trace mode: walk from an entry point one hop at a time, reading real code
--- in the main window while the trail panel remembers how you got here.
--- Trails persist per project in stdpath("state")/spoor/trails/.
local Config = require("spoor.config")
local export = require("spoor.export")
local graph = require("spoor.graph")
local icons = require("spoor.icons")
local lsp = require("spoor.lsp")
local model = require("spoor.model")
local render = require("spoor.render")
local resolve = require("spoor.resolve")
local util = require("spoor.util")

local M = {}

---@class spoor.TraceState
---@field trail? spoor.Trail
---@field win? snacks.win
---@field origin? integer
---@field client? vim.lsp.Client
---@field graph? spoor.Graph
---@field hops spoor.Row[]
---@field dir "out"|"in"
---@field group? spoor.Group
M.state = { hops = {}, dir = "out" }

local ns = vim.api.nvim_create_namespace("spoor.trace")

-- Persistence ---------------------------------------------------------------

---@param root string
function M.file(root)
  local name = root:gsub("[^%w%-_.]", "_"):sub(-80) .. "-" .. vim.fn.sha256(root):sub(1, 8)
  local dir = vim.fs.joinpath(util.state_dir(), "trails")
  vim.fn.mkdir(dir, "p")
  return vim.fs.joinpath(dir, name .. ".json")
end

---@param root string
---@return {root: string, last?: string, trails: table<string, spoor.Trail>}
function M.load(root)
  local data = util.read_json(M.file(root))
  if type(data) ~= "table" or type(data.trails) ~= "table" then
    return { root = root, trails = {} }
  end
  return data
end

---@param trail spoor.Trail
function M.save(trail)
  trail.updated = os.time()
  local data = M.load(trail.root)
  data.trails[trail.id] = trail
  data.last = trail.id
  util.write_json(M.file(trail.root), data)
  vim.api.nvim_exec_autocmds("User", { pattern = "SpoorTrail", data = { trail = trail }, modeline = false })
end

---@param root string
---@param id string
function M.delete(root, id)
  local data = M.load(root)
  data.trails[id] = nil
  if data.last == id then
    data.last = nil
  end
  util.write_json(M.file(root), data)
end

-- Rendering -----------------------------------------------------------------

local Line = {}
Line.__index = Line
local function line()
  return setmetatable({ parts = {}, hls = {}, bytes = 0 }, Line)
end
function Line:add(text, hl)
  if hl and text ~= "" then
    table.insert(self.hls, { self.bytes, self.bytes + #text, hl })
  end
  table.insert(self.parts, text)
  self.bytes = self.bytes + #text
  return self
end

--- Pure: trail + hops -> lines, highlights, and a row map.
---@param trail spoor.Trail
---@param hops spoor.Row[]
---@param opts {width: integer, dir: "out"|"in", graph?: spoor.Graph, loading?: boolean, hidden?: table<string, integer>}
function M.render(trail, hops, opts)
  local ic = Config.options.icons
  local out = { lines = {}, hls = {}, map = {} }
  local function push(l, map)
    out.lines[#out.lines + 1] = table.concat(l.parts)
    for _, h in ipairs(l.hls) do
      out.hls[#out.hls + 1] = { row = #out.lines - 1, col = h[1], end_col = h[2], group = h[3] }
    end
    out.map[#out.lines] = map
  end
  local root = trail.root
  for i, step in ipairs(trail.steps) do
    local n = step.node
    local icon, icon_hl = icons.kind(n.kind)
    local indent = i == 1 and " " or (" " .. string.rep("  ", math.min(i - 2, 8)) .. "└▶ ")
    local l = line():add(indent, "SpoorEdge"):add(icon .. " ", icon_hl)
    l:add(n.name, i == #trail.steps and "SpoorFocus" or "SpoorName")
    if step.via == "impl" then
      l:add(" " .. ic.interface, "SpoorInterface")
    elseif step.via == "ref" then
      l:add(" " .. ic.value, "SpoorValue")
    elseif step.via == "in" then
      l:add(" ◂", "SpoorEdge")
    end
    local rel = util.relative(util.path(n.uri), root)
    l:add("  " .. util.tail(rel, 2) .. ":" .. (n.selection.start.line + 1), "SpoorLoc")
    if i == #trail.steps then
      l:add("  " .. ic.here, "SpoorHere")
    end
    push(l, { step = i })
    local pad = string.rep(" ", vim.api.nvim_strwidth(indent) + 2)
    if n.framework then
      push(line():add(pad .. ic.framework .. " " .. n.framework.label, "SpoorFramework"), { step = i })
    end
    if step.note and step.note ~= "" then
      push(line():add(pad .. ic.note .. " " .. step.note, "SpoorNote"), { step = i })
    end
  end
  push(line(), {})
  local current = trail.steps[#trail.steps].node
  local title = opts.dir == "in" and "callers of " or "next hop · "
  push(line():add(" " .. title, "SpoorHeader"):add(current.name, "SpoorFocus"), {})
  local k = 0
  for _, row in ipairs(hops) do
    if row.kind == "node" then
      k = k + 1
      local n = opts.graph.nodes[row.id]
      local icon, icon_hl = icons.kind(n.kind)
      local l = line():add(("  %d  "):format(k), "SpoorKey")
      if row.edge and row.edge.kind == "ref" then
        l:add(ic.value .. " ", "SpoorValue"):add(util.truncate(n.name, opts.width - 10), "SpoorValue")
      else
        l:add(icon .. " ", icon_hl):add(n.name, "SpoorName")
      end
      if n.impls and n.impls > 0 then
        l:add(" " .. ic.interface .. n.impls, "SpoorInterface")
      end
      if row.edge and row.edge.kind == "jsx" then
        l:add(" " .. ic.jsx, "SpoorBadge")
      end
      local rel = util.relative(util.path(n.uri), root)
      l:add("  " .. util.tail(rel, 2) .. ":" .. (n.selection.start.line + 1), "SpoorLoc")
      push(l, { hop = k, id = row.id })
    else
      push(line():add("     " .. row.text, row.hl), {})
    end
  end
  if opts.loading and #hops == 0 then
    push(line():add("     ⋯", "SpoorMessage"), {})
  elseif not opts.loading and k == 0 then
    -- a dead end: say how to turn around
    local other = opts.dir == "in" and "callees" or "callers"
    push(line():add("     ", "SpoorDim"):add("i", "SpoorKey"):add(" show " .. other .. " instead", "SpoorDim"), {})
  end
  local hidden = {}
  for reason, n in pairs(opts.hidden or {}) do
    hidden[#hidden + 1] = ("%d %s"):format(n, reason)
  end
  if #hidden > 0 then
    table.sort(hidden)
    push(line():add("     +" .. table.concat(hidden, " · ") .. " hidden", "SpoorDim"), {})
  end
  push(line(), {})
  push(
    line()
      :add(" 1-9", "SpoorKey")
      :add(" step ", "SpoorDim")
      :add("<BS>", "SpoorKey")
      :add(" back ", "SpoorDim")
      :add("n", "SpoorKey")
      :add(" note ", "SpoorDim")
      :add("i", "SpoorKey")
      :add(" in/out ", "SpoorDim")
      :add("g?", "SpoorKey")
      :add(" more", "SpoorDim"),
    {}
  )
  return out
end

-- Window --------------------------------------------------------------------

local function valid()
  return M.state.win and M.state.win:valid()
end

function M.redraw()
  local s = M.state
  if not (valid() and s.trail) then
    return
  end
  local width = vim.api.nvim_win_get_width(s.win.win)
  local r =
    M.render(s.trail, s.hops, { width = width, dir = s.dir, graph = s.graph, loading = s.loading, hidden = s.hidden })
  s.rendered = r
  local buf = s.win.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, r.lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(r.hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h.row, h.col, { end_col = h.end_col, hl_group = h.group })
  end
  -- keep the cursor on the newest step, so n notes what you just reached
  if s.cursor_steps ~= #s.trail.steps then
    s.cursor_steps = #s.trail.steps
    for row = 1, #r.lines do
      if r.map[row] and r.map[row].step == #s.trail.steps then
        pcall(vim.api.nvim_win_set_cursor, s.win.win, { row, 0 })
        break
      end
    end
  end
  local crumbs = vim.tbl_map(function(st)
    return st.node.name
  end, s.trail.steps)
  -- when narrow, cut the oldest crumbs, never the label
  vim.wo[s.win.win].winbar = "%#SpoorHeader# spoor trace %*%<%#SpoorDim#"
    .. table.concat(crumbs, " ▸ "):gsub("%%", "%%%%")
    .. "%*"
end

--- Show a node in the code window without leaving the trail panel.
---@param node spoor.Node
local function show(node)
  local s = M.state
  local win = s.origin
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  -- only files can go missing; jdt://, deno: and friends are opened by their own handlers
  local path = vim.uri_to_fname(node.uri)
  if node.uri:find("^file:") and not vim.uv.fs_stat(path) then
    return util.notify(vim.fn.fnamemodify(path, ":~:.") .. " was moved or deleted", vim.log.levels.WARN)
  end
  vim.api.nvim_win_call(win, function()
    local loc = { uri = node.uri, range = node.selection }
    if not pcall(vim.lsp.util.show_document, loc, s.encoding or "utf-16", { focus = true }) then
      -- the file is shorter than when the step was saved: land on its last line
      pcall(vim.api.nvim_win_set_cursor, 0, { vim.api.nvim_buf_line_count(0), 0 })
    end
    vim.cmd("normal! zz")
  end)
end

--- Ask the server for the next hops around the current step.
function M.refresh()
  local s = M.state
  if not s.trail then
    return
  end
  if s.group then
    s.group:cancel()
  end
  s.group = lsp.group()
  s.hops, s.loading = {}, true
  M.redraw()
  local node = s.trail.steps[#s.trail.steps].node
  local function with_item(client, item)
    s.client, s.encoding = client, client.offset_encoding
    graph.build(
      client,
      item,
      { root = s.trail.root, depth = 1, max_items = Config.options.trace.max_hops, group = s.group },
      function(g)
        s.graph = g
        s.loading = (s.dir == "in" and g.status.incoming or g.status.outgoing) == "loading"
        local current = g.nodes[g.focus]
        s.trail.steps[#s.trail.steps].node.framework = current.framework
        s.hops, _, s.hidden = render.side(g, s.dir, { max_items = Config.options.trace.max_hops })
        M.redraw()
      end
    )
  end
  -- Prefer a fresh item from the buffer (resumed trails, edited code).
  local bufnr = vim.fn.bufadd(util.path(node.uri))
  local client = vim.api.nvim_buf_is_loaded(bufnr) and lsp.client(bufnr) or nil
  if client then
    resolve.at(client, bufnr, node.selection.start, { group = s.group }, function(item)
      if item then
        with_item(client, item)
      elseif node.item then
        with_item(client, node.item)
      else
        s.loading = false
        M.redraw()
      end
    end)
  elseif s.client and node.item then
    with_item(s.client, node.item)
  else
    s.loading = false
    M.redraw()
  end
end

---@param node spoor.Node
---@param via string
local function push_step(node, via)
  local s = M.state
  table.insert(s.trail.steps, { node = model.persistable(node), via = via })
  s.trail.title = s.trail.steps[1].node.name .. " ▸ " .. node.name
  M.save(s.trail)
  show(node)
  M.refresh()
end

--- Take next hop number `k`.
---@param k integer
function M.pick(k)
  local s = M.state
  local id
  for _, row in pairs(s.rendered and s.rendered.map or {}) do
    if row.hop == k then
      id = row.id
    end
  end
  local node = id and s.graph and s.graph.nodes[id]
  if not node then
    return
  end
  local via = "in"
  if s.dir == "out" then
    for _, e in ipairs(model.outgoing(s.graph, s.graph.focus)) do
      if e.to == id then
        via = e.kind
      end
    end
  end
  if node.implementations and #node.implementations > 0 then
    local choices = {}
    for _, impl in ipairs(node.implementations) do
      local path = util.path(impl.uri)
      local rel = util.relative(path, s.trail.root)
      local tags = require("spoor.filters").classify(path, s.trail.root)
      local rank = (tags.test and 2 or 0) + (tags.external and 1 or 0)
      local label = ("%s:%d%s"):format(rel, impl.range.start.line + 1, tags.test and "  (test)" or "")
      choices[#choices + 1] = { label = label, loc = impl, rank = rank }
    end
    table.sort(choices, function(a, b)
      if a.rank ~= b.rank then
        return a.rank < b.rank
      end
      return a.label < b.label
    end)
    -- implementations first, so <CR> follows the code that runs; the declaration stays reachable
    choices[#choices + 1] = { label = node.name .. " (the interface itself)", loc = nil }
    return vim.ui.select(choices, {
      prompt = node.name .. " has " .. #node.implementations .. " implementations",
      format_item = function(c)
        return c.label
      end,
    }, function(choice)
      if not choice then
        return
      end
      if not choice.loc then
        return push_step(node, via)
      end
      M.step_to_location(choice.loc, "impl")
    end)
  end
  push_step(node, via)
end

--- Step to a location that is not a call hierarchy item yet (an implementation).
---@param loc {uri: string, range: lsp.Range}
---@param via string
function M.step_to_location(loc, via)
  local s = M.state
  show({ uri = loc.uri, selection = loc.range })
  local bufnr = vim.uri_to_bufnr(loc.uri)
  local client = lsp.client(bufnr) or s.client
  if not client then
    return
  end
  resolve.at(client, bufnr, loc.range.start, {}, function(item)
    if item then
      push_step(model.node(item), via)
    end
  end)
end

function M.back()
  local s = M.state
  if s.trail and #s.trail.steps > 1 then
    table.remove(s.trail.steps)
    M.save(s.trail)
    show(s.trail.steps[#s.trail.steps].node)
    M.refresh()
  end
end

function M.note()
  local s = M.state
  if not s.trail then
    return
  end
  local step = s.trail.steps[#s.trail.steps]
  local cursor_step = M.step_at_cursor()
  if cursor_step then
    step = s.trail.steps[cursor_step]
  end
  vim.ui.input({ prompt = "Note on " .. step.node.name .. ": ", default = step.note or "" }, function(text)
    if text == nil then
      return
    end
    step.note = text ~= "" and text or nil
    M.save(s.trail)
    M.redraw()
  end)
end

function M.step_at_cursor()
  local s = M.state
  if not (valid() and s.rendered) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(s.win.win)[1]
  local m = s.rendered.map[row]
  return m and m.step, m and m.hop
end

function M.quickfix()
  local s = M.state
  if not s.trail then
    return
  end
  vim.fn.setqflist({}, " ", { title = "spoor trail: " .. s.trail.title, items = export.trail_qf(s.trail) })
  vim.cmd("botright copen")
end

function M.mermaid()
  local s = M.state
  if not s.trail then
    return
  end
  local text = export.trail_mermaid(s.trail)
  util.copy(text, "the trail")
end

local actions = {
  enter = function()
    local step, hop = M.step_at_cursor()
    if hop then
      return M.pick(hop)
    end
    if step then
      show(M.state.trail.steps[step].node)
    end
  end,
  back = M.back,
  note = M.note,
  flip = function()
    M.state.dir = M.state.dir == "out" and "in" or "out"
    if M.state.graph then
      M.state.hops, _, M.state.hidden =
        render.side(M.state.graph, M.state.dir, { max_items = Config.options.trace.max_hops })
    end
    M.redraw()
  end,
  quickfix = M.quickfix,
  mermaid = M.mermaid,
  close = function()
    M.close()
  end,
  help = function()
    if valid() then
      M.state.win.opts.zindex = M.state.win.opts.zindex or 50 -- a split has none; snacks needs one
      M.state.win:toggle_help()
    end
  end,
}

function M.open_window()
  local s = M.state
  if valid() then
    return
  end
  local keys = {
    ["<CR>"] = { "<CR>", actions.enter, desc = "Take hop / show" },
    ["<BS>"] = { "<BS>", actions.back, desc = "Step back" },
    n = { "n", actions.note, desc = "Note on step" },
    i = { "i", actions.flip, desc = "Callers ⇄ callees" },
    ["<C-q>"] = { "<C-q>", actions.quickfix, desc = "Trail to quickfix" },
    m = { "m", actions.mermaid, desc = "Copy as Mermaid" },
    q = { "q", actions.close, desc = "Close (saved)" },
    ["g?"] = { "g?", actions.help, desc = "Help" },
  }
  for k = 1, 9 do
    keys[tostring(k)] = {
      tostring(k),
      function()
        M.pick(k)
      end,
      desc = "Take hop " .. k,
    }
  end
  s.win = Snacks.win({
    position = "right",
    relative = "win", -- split the code window, so the live panel keeps the full width
    win = s.origin and vim.api.nvim_win_is_valid(s.origin) and s.origin or nil,
    width = Config.options.trace.width,
    enter = true,
    fixbuf = true,
    ft = "spoor",
    bo = { modifiable = false, filetype = "spoor" },
    wo = { wrap = false, cursorline = true, winfixwidth = true, winbar = " " },
    keys = keys,
  })
end

function M.close()
  local s = M.state
  if s.group then
    s.group:cancel()
  end
  if valid() then
    s.win:close()
  end
end

--- Start a new trail at a node.
---@param node spoor.Node
---@param opts {client?: vim.lsp.Client, root?: string, origin?: integer}
function M.start(node, opts)
  local s = M.state
  s.origin = util.code_window(opts.origin or vim.api.nvim_get_current_win()) or util.code_window(s.origin)
  s.client = opts.client or s.client
  s.encoding = s.client and s.client.offset_encoding or s.encoding
  s.dir, s.cursor_steps = "out", nil
  s.trail = model.trail(opts.root or util.root(0, s.client), node)
  M.save(s.trail)
  M.open_window()
  show(node)
  M.refresh()
end

--- Start a trail at the cursor (gat).
function M.start_at_cursor()
  local win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  local client = lsp.client(bufnr)
  if not client then
    return util.notify("No language server with call hierarchy for this buffer", vim.log.levels.WARN)
  end
  if M.start_group then
    M.start_group:cancel()
  end
  M.start_group = lsp.group()
  resolve.at_cursor(client, win, { group = M.start_group }, function(item)
    -- a slow server must not open the panel after you moved on
    if vim.api.nvim_get_current_win() ~= win or vim.api.nvim_get_mode().mode:sub(1, 1) ~= "n" then
      return
    end
    if not item then
      return util.notify("No function at the cursor", vim.log.levels.WARN)
    end
    M.start(model.node(item), { client = client, root = util.root(bufnr, client), origin = win })
  end)
end

--- Resume a trail (the last one in this project by default).
---@param trail? spoor.Trail
function M.resume(trail)
  local s = M.state
  if not trail then
    local root = util.root(0, lsp.client(0))
    local data = M.load(root)
    trail = data.last and data.trails[data.last]
    if not trail then
      return util.notify("No trail yet in this project. Start one with gat or <leader>ce.", vim.log.levels.INFO)
    end
  end
  s.origin = util.code_window(vim.api.nvim_get_current_win()) or util.code_window(s.origin)
  s.trail, s.dir, s.cursor_steps = trail, "out", nil
  M.open_window()
  local last = trail.steps[#trail.steps].node
  show(last)
  -- the buffer just opened; give its language server a moment to attach
  local bufnr = vim.uri_to_bufnr(last.uri)
  if lsp.client(bufnr) then
    M.refresh()
  else
    M.redraw()
    vim.api.nvim_create_autocmd("LspAttach", {
      buffer = bufnr,
      once = true,
      callback = function()
        vim.schedule(M.refresh)
      end,
    })
  end
end

--- Picker over this project's trails (<leader>cT).
function M.pick_trail()
  local root = util.root(0, lsp.client(0))
  local data = M.load(root)
  local items = {}
  for _, t in pairs(data.trails) do
    local notes = 0
    for _, st in ipairs(t.steps) do
      notes = notes + ((st.note and st.note ~= "") and 1 or 0)
    end
    items[#items + 1] = {
      text = t.title,
      trail = t,
      notes = notes,
      preview = { text = table.concat(M.render(t, {}, { width = 80, dir = "out" }).lines, "\n"), ft = "spoor" },
    }
  end
  table.sort(items, function(a, b)
    return a.trail.updated > b.trail.updated
  end)
  if #items == 0 then
    return util.notify("No trails yet in this project. Start one with gat or <leader>ce.")
  end
  Snacks.picker.pick({
    source = "spoor_trails",
    title = "Trails",
    items = items,
    preview = "preview",
    format = function(item)
      local t = item.trail
      return {
        { ("%-40s"):format(util.truncate(t.title, 40)), "SpoorName" },
        { ("  %2d steps"):format(#t.steps), "SpoorDim" },
        { item.notes > 0 and ("  %s %d"):format(Config.options.icons.note, item.notes) or "", "SpoorNote" },
        { "  " .. os.date("%Y-%m-%d %H:%M", t.updated), "SpoorLoc" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        M.resume(item.trail)
      end
    end,
    actions = {
      delete_trail = function(picker, item)
        if not item then
          return
        end
        vim.ui.select({ "Delete", "Keep" }, { prompt = "Delete trail '" .. item.trail.title .. "'?" }, function(choice)
          if choice == "Delete" then
            M.delete(root, item.trail.id)
            picker:close()
            M.pick_trail()
          end
        end)
      end,
    },
    win = { input = { keys = { ["<c-x>"] = { "delete_trail", mode = { "n", "i" } } } } },
  })
end

return M
