--- Loads bow-ties into views, and the on-demand float (gag) with deeper levels.
local Config = require("spoor.config")
local graph = require("spoor.graph")
local lsp = require("spoor.lsp")
local resolve = require("spoor.resolve")
local syntax = require("spoor.syntax")
local util = require("spoor.util")
local view = require("spoor.view")

local M = {}

---@class spoor.LoadOpts
---@field root string
---@field bufnr integer
---@field depth? integer
---@field callers? boolean
---@field on_done? fun(g: spoor.Graph)

--- Build a bow-tie for `item` and render it into `v` as answers arrive.
--- Cancels whatever `v` was loading before.
---@param v spoor.View
---@param client vim.lsp.Client
---@param item lsp.CallHierarchyItem
---@param opts spoor.LoadOpts
---@return spoor.Graph
function M.load(v, client, item, opts)
  if v.group then
    v.group:cancel()
  end
  v.group = lsp.group()
  v.client = client
  v.load_opts = opts
  local g
  g = graph.build(client, item, {
    root = opts.root,
    bufnr = opts.bufnr,
    depth = opts.depth or 1,
    max_items = v.opts.max_items,
    group = v.group,
    callers = opts.callers,
  }, function(updated)
    local target = v.moved_to or v -- the float may have been moved to a split or tab
    if target.graph == updated then
      target:render(updated)
    end
    if opts.on_done and updated.status.incoming ~= "loading" and updated.status.outgoing ~= "loading" then
      opts.on_done(updated)
    end
  end)
  g.encoding = client.offset_encoding
  v:render(g)
  return g
end

--- Reload the view's current focus (R).
---@param v spoor.View
function M.retry(v)
  local g = v.graph
  if not (g and v.client and v.load_opts) then
    return
  end
  local focus = g.nodes[g.focus]
  if focus.item then
    -- a retry always asks for callers, even where live mode skips them
    M.load(v, v.client, focus.item, vim.tbl_extend("force", v.load_opts, { callers = true }))
  end
end

--- Open one more level from the node under the cursor, or fold it again (<Tab>).
---@param v spoor.View
function M.expand(v)
  local node, side = v:node_at_cursor()
  if not (node and v.graph and v.client) or side == "focus" then
    return
  end
  local g = v.graph
  local dir = side == "left" and "in" or "out"
  local key = node.id .. (dir == "in" and "<in" or ">out")
  if g.expanded[key] then
    g.expanded[key] = nil
    return v:render(g)
  end
  graph.expand(g, node.id, dir, v.client, { root = g.root, group = v.group, max_items = v.opts.max_items }, function()
    if v.graph == g then
      v:render(g)
    end
  end)
end

local preview_ns = vim.api.nvim_create_namespace("spoor_preview")

--- Show the node under the cursor in the code window without leaving the view. The first
--- preview remembers what the code window showed, so closing the float can put it back.
---@param v spoor.View
function M.preview(v)
  if not (Config.options.float.preview and v:valid()) then
    return
  end
  local node = v:node_at_cursor()
  local win = v.origin
  if not (node and vim.api.nvim_win_is_valid(win)) or (v.preview and v.preview.shown == node.id) then
    return
  end
  if node.uri:find("^file:") and not vim.uv.fs_stat(vim.uri_to_fname(node.uri)) then
    return
  end
  local p = v.preview
  if not p then
    p = {
      buf = vim.api.nvim_win_get_buf(win),
      view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
      opened = {},
    }
    v.preview = p
  end
  p.shown = node.id
  local buf = vim.uri_to_bufnr(node.uri)
  if not vim.api.nvim_buf_is_loaded(buf) then
    p.opened[buf] = true -- unlisted until you jump there; wiped again on close
    pcall(vim.fn.bufload, buf)
  end
  local line = node.selection.start.line
  local text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ""
  local col = util.byte_col(text, node.selection.start.character, v.graph and v.graph.encoding)
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_win_set_buf(win, buf)
    pcall(vim.api.nvim_win_set_cursor, win, { line + 1, col })
    vim.fn.winrestview({ topline = math.max(line - 2, 1) }) -- near the top: the float sits below
  end)
  if p.hl_buf and vim.api.nvim_buf_is_valid(p.hl_buf) then
    vim.api.nvim_buf_clear_namespace(p.hl_buf, preview_ns, 0, -1)
  end
  pcall(vim.api.nvim_buf_set_extmark, buf, preview_ns, line, 0, { line_hl_group = "SpoorPreview" })
  p.hl_buf = buf
end

--- End previews: put the code window back (unless `keep`) and wipe buffers opened only to preview.
---@param v spoor.View
---@param keep? boolean
function M.finish_preview(v, keep)
  local p = v.preview
  if not p then
    return
  end
  v.preview = nil
  if p.hl_buf and vim.api.nvim_buf_is_valid(p.hl_buf) then
    vim.api.nvim_buf_clear_namespace(p.hl_buf, preview_ns, 0, -1)
  end
  local win = v.origin
  if not keep and vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(p.buf) then
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_win_set_buf(win, p.buf)
      vim.fn.winrestview(p.view)
    end)
  end
  local shown = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) or nil
  if keep and shown then
    vim.bo[shown].buflisted = true
  end
  for buf in pairs(p.opened) do
    if
      buf ~= shown
      and vim.api.nvim_buf_is_valid(buf)
      and not vim.bo[buf].modified
      and #vim.fn.win_findbuf(buf) == 0
    then
      pcall(vim.api.nvim_buf_delete, buf, {})
    end
  end
end

--- Wire previews into a float or pinned view.
---@param v spoor.View
local function follow(v)
  v.win:on("CursorMoved", function()
    M.preview(v)
  end, { buf = true })
  v.win:on("WinClosed", function()
    M.finish_preview(v, v.keep)
  end, { win = true })
end

--- Move the float to a split or a tab (<C-v>, <C-s>, <C-t>). It keeps its graph, history and keys,
--- and <CR> no longer closes it.
---@param how "right"|"bottom"|"tab"
local function pin(how)
  return function(v)
    if not v.graph then
      return
    end
    local origin = v.origin
    v.keep = true
    v:close()
    if how == "tab" and vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
      vim.cmd("tab split")
      origin = vim.api.nvim_get_current_win()
    end
    local win = how == "bottom"
        and { position = "bottom", height = 0.35, relative = "editor", wo = { winfixheight = true, winbar = " " } }
      or {
        position = "right",
        width = 0.5, -- a bow-tie is wide; less makes names unreadable
        relative = "editor",
        wo = { winfixwidth = true, winbar = " " },
      }
    win.enter = true
    local p = view.new({
      kind = "pinned",
      max_items = Config.options.float.max_items,
      actions = M.pinned_actions,
      keys = M.pinned_keys,
      win = win,
    })
    p.origin, p.client, p.load_opts, p.history, p.group = origin, v.client, v.load_opts, v.history, v.group
    p.keep = true
    v.moved_to = p
    p:show()
    follow(p)
    p:render(v.graph)
    M.pinned = p
  end
end

--- Float actions (the live panel overrides a few in live.lua).
M.float_actions = vim.tbl_extend("force", view.base_actions, {
  jump = function(v)
    local node = v:node_at_cursor()
    if node then
      v.keep = true
      v:close()
      v:jump(node)
    end
  end,
  pin_right = pin("right"),
  pin_bottom = pin("bottom"),
  pin_tab = pin("tab"),
  expand = M.expand,
  retry = M.retry,
  reroot = function(v)
    local node = v:node_at_cursor()
    if node and v.graph and v.graph.source == "syntax" and not node.tags.outside then
      local pos = node.selection.start
      return syntax.at(vim.uri_to_bufnr(node.uri), { pos.line, pos.character }, function(g)
        if g and v:valid() then
          v.history = v.history or {}
          table.insert(v.history, v.graph)
          v.placed = nil
          v:render(g)
        end
      end)
    end
    if node and node.item and v.client then
      v.history = v.history or {}
      table.insert(v.history, v.graph)
      v.placed = nil -- put the cursor on the new focus
      M.load(
        v,
        v.client,
        node.item,
        vim.tbl_extend("force", v.load_opts, { depth = Config.for_server(v.client.name).depth })
      )
    end
  end,
  back = function(v)
    local prev = v.history and table.remove(v.history)
    if prev then
      v.placed = nil
      v:render(prev)
    end
  end,
  trace = function(v)
    local node = v:node_at_cursor() or (v.graph and v.graph.nodes[v.graph.focus])
    if node and view.can_trace(v) then
      v.keep = true
      v:close()
      require("spoor.trace").start(node, { client = v.client, root = v.graph.root })
    end
  end,
  close = function(v)
    v:close()
  end,
})

M.float_keys = vim.tbl_extend("force", view.keys, {
  ["<BS>"] = { "back", desc = "Previous focus" },
  ["q"] = { "close", desc = "Close" },
  ["<Esc>"] = { "close", desc = "Close" },
  ["<C-v>"] = { "pin_right", desc = "Move to a vsplit" },
  ["<C-s>"] = { "pin_bottom", desc = "Move to a split" },
  ["<C-t>"] = { "pin_tab", desc = "Move to a tab" },
})

-- A pinned view stays open: <CR> shows the code and moves you there.
M.pinned_actions = vim.tbl_extend("force", M.float_actions, {
  jump = function(v)
    local node = v:node_at_cursor()
    if node then
      v:jump(node)
    end
  end,
})

M.pinned_keys = vim.tbl_extend("force", view.keys, {
  ["<BS>"] = { "back", desc = "Previous focus" },
  ["q"] = { "close", desc = "Close" },
})

--- A new float for the bow-tie at `win`'s cursor, replacing the one open; nil when the answer
--- came too late (you moved on) or found no function.
---@param win integer
---@param found boolean
---@return spoor.View?
local function float_for(win, found)
  -- a slow server must not steal focus after you moved on
  if vim.api.nvim_get_current_win() ~= win or vim.api.nvim_get_mode().mode:sub(1, 1) ~= "n" then
    return nil
  end
  if M.current and M.current:valid() then
    M.current:close()
  end
  if not found then
    return util.notify("No function at the cursor", vim.log.levels.WARN)
  end
  local v = view.new({
    kind = "float",
    max_items = Config.options.float.max_items,
    actions = M.float_actions,
    keys = M.float_keys,
    win = {
      position = "float",
      width = Config.options.float.width,
      height = 8,
      border = "rounded",
      backdrop = false,
      enter = true,
      zindex = 45,
    },
  })
  v.origin = win
  v:show()
  follow(v)
  M.current = v
  return v
end

--- The on-demand float at the cursor (gag).
function M.open()
  local win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  local client = lsp.client(bufnr)
  if M.open_group then
    M.open_group:cancel()
  end
  M.open_group = lsp.group()
  local group = M.open_group
  if not client then
    if not (Config.options.syntax and syntax.available(bufnr)) then
      return util.notify("No language server with call hierarchy for this buffer", vim.log.levels.WARN)
    end
    -- a same-file bow-tie from tree-sitter
    return syntax.at_cursor(win, function(g)
      local v = not group.cancelled and float_for(win, g ~= nil)
      if v and g then
        v:render(g)
      end
    end)
  end
  local root = util.root(bufnr, client)
  resolve.at_cursor(client, win, { group = group }, function(item)
    local v = float_for(win, item ~= nil)
    if v then
      M.load(v, client, item, { root = root, bufnr = bufnr, depth = Config.for_server(client.name).depth })
    end
  end)
end

return M
