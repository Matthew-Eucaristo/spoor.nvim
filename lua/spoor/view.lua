--- A window that shows one bow-tie: the live panel and the gag float share it.
local Config = require("spoor.config")
local render = require("spoor.render")

local M = {}

local ns = vim.api.nvim_create_namespace("spoor")
M.ns = ns

---@class spoor.View
---@field win spoor.Win|snacks.win
---@field graph? spoor.Graph
---@field rendered? spoor.Rendered
---@field origin integer window to jump in
---@field show_all boolean
---@field opts spoor.ViewOpts
---@field client? vim.lsp.Client
---@field group? spoor.Group requests of the bow-tie being loaded
---@field load_opts? spoor.LoadOpts
---@field history? spoor.Graph[] float: previous roots for <BS>
---@field placed? integer[] float: where spoor last put the cursor (on the focus)
---@field stale? boolean
---@field key? string live: cache key of the focus shown
---@field closing? boolean closed by spoor, not by hand
---@field user_quit? boolean live: :q was typed in the panel
---@field hover? integer expanded: the hover window it sits next to
---@field preview? {buf: integer, view: table, opened: table<integer, boolean>, shown?: string} float: the code window before previews
local View = {}
View.__index = View

---@class spoor.ViewOpts
---@field kind "panel"|"float"|"card"|"expanded"|"pinned" panel/card: live; expanded: the card grown next to a hover; float: gag; pinned: a split or tab you moved the float to
---@field win snacks.win.Config|{}
---@field max_items integer
---@field max_rows? integer
---@field actions table<string, fun(view: spoor.View)>
---@field keys table<string, {[1]: string, desc: string}>

---@param opts spoor.ViewOpts
---@return spoor.View
function M.new(opts)
  local self = setmetatable({ opts = opts, show_all = false, origin = vim.api.nvim_get_current_win() }, View)
  local keys = {}
  for lhs, spec in pairs(opts.keys) do
    local action = opts.actions[spec[1]]
    keys[lhs] = {
      lhs,
      function()
        action(self)
      end,
      desc = spec.desc,
      mode = "n",
    }
  end
  self.win = require("spoor.ui").win(vim.tbl_deep_extend("force", {
    show = false,
    enter = false,
    fixbuf = true,
    ft = "spoor",
    bo = { modifiable = false, filetype = "spoor" },
    wo = { wrap = false, cursorline = true },
    keys = keys,
  }, opts.win))
  return self
end

function View:valid()
  return self.win ~= nil and self.win:valid() == true
end

function View:show()
  if not self:valid() then
    -- with splitkeep=screen (LazyVim's default) a new bottom split would push the code
    -- window's cursor off the line you are on; scroll the code instead
    local keep = vim.o.splitkeep
    vim.o.splitkeep = "cursor"
    self.win:show()
    vim.o.splitkeep = keep
  end
  return self
end

function View:width()
  if self:valid() then
    return vim.api.nvim_win_get_width(self.win.win)
  end
  return vim.o.columns
end

--- Render a graph into the window.
---@param g spoor.Graph
function View:render(g)
  self.graph = g
  if not self.win:buf_valid() then
    return
  end
  local total = self:width() - 1
  local width = math.min(total, 160)
  local r = render.bowtie(g, {
    width = width,
    offset = math.floor((total - width) / 2),
    max_items = self.opts.max_items,
    max_rows = self.opts.max_rows,
    show_all = self.show_all,
  })
  self.rendered = r
  local buf = self.win.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, r.lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(r.hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h.row, h.col, { end_col = h.end_col, hl_group = h.group })
  end
  self:decorate(r)
  if self.opts.kind == "card" then
    return self:place_card(#r.lines)
  end
  if self.opts.kind == "expanded" then
    return self:place_expanded(#r.lines)
  end
  if self.opts.kind == "float" or self.opts.kind == "pinned" then
    if self.opts.kind == "float" then
      self:fit(#r.lines)
    end
    -- follow the focus row as rows arrive, until you move the cursor yourself
    local cur = vim.api.nvim_win_get_cursor(self.win.win)
    if not self.placed or (cur[1] == self.placed[1] and cur[2] == self.placed[2]) then
      for row = 1, #r.lines do
        local m = r.map[row]
        if m and m.focus then
          local col = math.max(vim.fn.virtcol2col(self.win.win, row, r.cols.left_end + 5) - 1, 0)
          if pcall(vim.api.nvim_win_set_cursor, self.win.win, { row, col }) then
            self.placed = vim.api.nvim_win_get_cursor(self.win.win)
          end
          break
        end
      end
    end
  end
end

--- Size the float to its content and keep it centered.
---@param n integer
function View:fit(n)
  if not self:valid() then
    return
  end
  local h = math.max(math.min(n, math.floor(vim.o.lines * 0.6)), 4)
  local cfg = vim.api.nvim_win_get_config(self.win.win)
  -- sit low, so the code a preview shows stays visible above
  local row = math.max(vim.o.lines - h - vim.o.cmdheight - 4, 0)
  if cfg.height ~= h or cfg.row ~= row then
    vim.api.nvim_win_set_config(self.win.win, {
      relative = "editor",
      height = h,
      width = cfg.width,
      row = row,
      col = cfg.col,
    })
  end
end

--- Size the card to its content and put it next to the cursor, like a hover: above the cursor
--- line, or below it near the top of the window. It never covers the cursor's line.
---@param n? integer lines
function View:place_card(n)
  if not self:valid() then
    return
  end
  n = n or (self.rendered and #self.rendered.lines) or 4
  local origin = self.origin
  if not vim.api.nvim_win_is_valid(origin) then
    return
  end
  local h = math.max(math.min(n, math.floor(vim.o.lines * 0.4)), 3)
  local w = math.min(Config.options.live.card.width, vim.o.columns - 4)
  local info = vim.fn.getwininfo(origin)[1]
  local pos = vim.api.nvim_win_call(origin, function()
    return vim.fn.screenpos(0, vim.fn.line("."), vim.fn.col("."))
  end)
  local cursor_row = math.max(pos.row - 1, 0) -- 0-based screen row of the cursor
  local above = cursor_row - (h + 2) -- the border takes a row on each side
  local below = cursor_row + 1
  local fits_below = below + h + 2 <= info.winrow - 1 + info.height
  local row = (above >= info.winrow - 1 or not fits_below) and math.max(above, 0) or below
  -- line up with the code, not the cursor, so the card doesn't slide sideways as you move
  local col = math.min(info.wincol - 1 + info.textoff, vim.o.columns - w - 2)
  local cfg = vim.api.nvim_win_get_config(self.win.win)
  if cfg.height ~= h or cfg.width ~= w or cfg.row ~= row or cfg.col ~= col then
    vim.api.nvim_win_set_config(self.win.win, { relative = "editor", row = row, col = col, width = w, height = h })
  end
end

--- The full bow-tie shown next to a hover (K): in the largest band of the screen that covers
--- neither the cursor line nor the hover, shrunk to fit when the hover is big.
---@param n? integer lines
function View:place_expanded(n)
  if not self:valid() then
    return
  end
  n = n or (self.rendered and #self.rendered.lines) or 4
  local origin = self.origin
  if not vim.api.nvim_win_is_valid(origin) then
    return
  end
  local pos = vim.api.nvim_win_call(origin, function()
    return vim.fn.screenpos(0, vim.fn.line("."), vim.fn.col("."))
  end)
  local cursor = math.max(pos.row - 1, 0)
  local busy = { { cursor, cursor } }
  local hover = self.hover
  if hover and vim.api.nvim_win_is_valid(hover) then
    local top = vim.api.nvim_win_get_position(hover)[1]
    busy[#busy + 1] = { top, top + vim.api.nvim_win_get_height(hover) + 1 } -- with its border
  end
  table.sort(busy, function(a, b)
    return a[1] < b[1]
  end)
  -- the largest free band between the tabline and the statusline
  local from, last = 1, vim.o.lines - vim.o.cmdheight - 2
  local best
  local function consider(a, b)
    if b >= a and (not best or b - a > best[2] - best[1]) then
      best = { a, b }
    end
  end
  for _, b in ipairs(busy) do
    consider(from, b[1] - 1)
    from = math.max(from, b[2] + 1)
  end
  consider(from, last)
  local room = best and (best[2] - best[1] + 1 - 2) or 0 -- minus the border
  if room < 3 then
    return self.win:hide() -- no space worth drawing in; the hover has the screen
  end
  local h = math.min(math.max(n, 3), room)
  -- hug the cursor: the bottom of a band above it, the top of a band below it
  local row = best[2] < cursor and (best[2] - h - 1) or best[1]
  local w = math.min(math.floor(vim.o.columns * Config.options.float.width), vim.o.columns - 4)
  local col = math.floor((vim.o.columns - w) / 2)
  local cfg = vim.api.nvim_win_get_config(self.win.win)
  if cfg.height ~= h or cfg.width ~= w or cfg.row ~= row or cfg.col ~= col then
    vim.api.nvim_win_set_config(self.win.win, { relative = "editor", row = row, col = col, width = w, height = h })
  end
end

--- Title/footer (float, card, expanded) or winbar (panel, pinned).
---@param r spoor.Rendered
function View:decorate(r)
  if not self:valid() then
    return
  end
  local legend = r.legend
  if self.opts.kind == "panel" or self.opts.kind == "pinned" then
    local label = self.opts.kind == "pinned" and (" spoor · " .. self.graph.nodes[self.graph.focus].name .. " ")
      or " spoor "
    local parts = {
      "%#SpoorHeader#" .. label:gsub("%%", "%%%%") .. "%*" .. (self.stale and "%#SpoorDim#(paused) %*" or "") .. "%<",
    }
    -- the legend only when it fits; a cut legend reads as nonsense
    local room = self:width() - vim.api.nvim_strwidth(label) - 2
    local text = table.concat(vim.tbl_map(function(c)
      return c[1]
    end, legend))
    if vim.api.nvim_strwidth(text) <= room then
      for _, chunk in ipairs(legend) do
        parts[#parts + 1] = ("%%#%s#%s%%*"):format(chunk[2], chunk[1]:gsub("%%", "%%%%"))
      end
    end
    if self:width() >= 110 then
      parts[#parts + 1] = "%=%#SpoorDim#<CR> jump  t trace  H hidden  g? help %*"
    end
    vim.wo[self.win.win].winbar = table.concat(parts)
  else
    local focus = self.graph.nodes[self.graph.focus]
    local footer = legend
    if self.opts.kind == "card" then
      -- the card is a glance; say where the rest is
      footer = {
        {
          " "
            .. (self.graph.source == "syntax" and ("syntax only · " .. (self.graph.scope or "this file")) or self.graph.server or "lsp")
            .. " · ",
          "SpoorDim",
        },
        { "gag", "SpoorKey" },
        { " for more ", "SpoorDim" },
      }
    end
    vim.api.nvim_win_set_config(self.win.win, {
      title = { { " spoor ", "SpoorHeader" }, { "· " .. focus.name .. " ", "SpoorFocus" } },
      title_pos = "center",
      footer = footer,
      footer_pos = "center",
    })
  end
end

--- Mark the content as paused (the cursor is somewhere spoor can't follow).
function View:set_stale(stale)
  if self.stale ~= stale then
    self.stale = stale
    if self.rendered then
      self:decorate(self.rendered)
    end
  end
end

--- The node under the cursor.
---@return spoor.Node?, "left"|"right"|"focus"|nil
function View:node_at_cursor()
  if not (self.rendered and self:valid()) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(self.win.win)
  local line = vim.api.nvim_buf_get_lines(self.win.buf, cursor[1] - 1, cursor[1], false)[1] or ""
  local col = vim.api.nvim_strwidth(line:sub(1, cursor[2]))
  local id, side = render.hit(self.rendered, cursor[1], col, self.graph.focus)
  return id and self.graph.nodes[id] or nil, side
end

--- Put the cursor on the first node of a side.
---@param side "left"|"right"
function View:goto_side(side)
  if not (self.rendered and self:valid()) then
    return
  end
  local vcol = side == "left" and 2 or self.rendered.cols.right_start + 1
  local cur = vim.api.nvim_win_get_cursor(self.win.win)[1]
  local byte = vim.fn.virtcol2col(self.win.win, cur, vcol)
  vim.api.nvim_win_set_cursor(self.win.win, { cur, math.max(byte - 1, 0) })
end

--- Open a node's location in the origin window.
---@param node spoor.Node
function View:jump(node)
  local win = self.origin
  if not vim.api.nvim_win_is_valid(win) then
    win = vim.fn.win_getid(vim.fn.winnr("#"))
  end
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
  local encoding = self.graph and self.graph.encoding or "utf-16"
  vim.lsp.util.show_document({ uri = node.uri, range = node.selection }, encoding, { focus = true })
  vim.cmd("normal! zz")
end

function View:close()
  if self.win then
    self.win:close()
  end
end

M.View = View

--- Default keys for both views. Actions are filled in by live.lua and float.lua.
M.keys = {
  ["<CR>"] = { "jump", desc = "Jump to node" },
  ["<2-LeftMouse>"] = { "jump", desc = "Jump to node" },
  ["<Tab>"] = { "expand", desc = "Expand / fold" },
  ["."] = { "reroot", desc = "Re-root on node" },
  ["t"] = { "trace", desc = "Trace from node" },
  ["H"] = { "toggle_hidden", desc = "Show hidden" },
  ["R"] = { "retry", desc = "Retry" },
  ["h"] = { "left", desc = "Callers column" },
  ["l"] = { "right", desc = "Callees column" },
  ["y"] = { "yank", desc = "Copy as Mermaid" },
  ["g?"] = { "help", desc = "Help" },
}

M.base_actions = {
  left = function(v)
    v:goto_side("left")
  end,
  right = function(v)
    v:goto_side("right")
  end,
  toggle_hidden = function(v)
    v.show_all = not v.show_all
    if v.graph then
      v:render(v.graph)
    end
  end,
  help = function(v)
    require("spoor.ui").toggle_help(v.win)
  end,
  yank = function(v)
    if v.graph then
      local text = require("spoor.export").bowtie_mermaid(v.graph, { show_all = v.show_all })
      require("spoor.util").copy(text, "the bow-tie")
    end
  end,
}

--- A trace follows the language server's call hierarchy; a syntax-only bow-tie has none.
---@param v spoor.View
function M.can_trace(v)
  if v.graph and v.graph.source == "syntax" then
    require("spoor.util").notify("Tracing needs a language server with call hierarchy", vim.log.levels.WARN)
    return false
  end
  return true
end

M.Config = Config
return M
