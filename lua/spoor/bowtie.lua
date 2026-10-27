--- Loads bow-ties into views, and the on-demand float (gag) with deeper levels.
local Config = require("spoor.config")
local graph = require("spoor.graph")
local lsp = require("spoor.lsp")
local resolve = require("spoor.resolve")
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
    if v.graph == updated then
      v:render(updated)
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

--- Float actions (the live panel overrides a few in live.lua).
M.float_actions = vim.tbl_extend("force", view.base_actions, {
  jump = function(v)
    local node = v:node_at_cursor()
    if node then
      v:close()
      v:jump(node)
    end
  end,
  expand = M.expand,
  retry = M.retry,
  reroot = function(v)
    local node = v:node_at_cursor()
    if node and node.item and v.client then
      v.history = v.history or {}
      table.insert(v.history, v.graph)
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
      v:render(prev)
    end
  end,
  trace = function(v)
    local node = v:node_at_cursor() or (v.graph and v.graph.nodes[v.graph.focus])
    if node then
      v:close()
      require("spoor.trace").start(node, { client = v.client, root = v.graph.root })
    end
  end,
  close = function(v)
    v:close()
  end,
})

M.float_keys = vim.tbl_extend("force", view.keys, {
  ["<BS>"] = { "back", desc = "Back to the previous focus" },
  ["q"] = { "close", desc = "Close" },
  ["<Esc>"] = { "close", desc = "Close" },
})

--- The on-demand float at the cursor (gag).
function M.open()
  local win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  local client = lsp.client(bufnr)
  if not client then
    return util.notify("No language server with call hierarchy for this buffer", vim.log.levels.WARN)
  end
  local root = util.root(bufnr, client)
  if M.open_group then
    M.open_group:cancel()
  end
  M.open_group = lsp.group()
  resolve.at_cursor(client, win, { group = M.open_group }, function(item)
    -- a slow server must not steal focus after you moved on
    if vim.api.nvim_get_current_win() ~= win or vim.api.nvim_get_mode().mode:sub(1, 1) ~= "n" then
      return
    end
    if M.current and M.current:valid() then
      M.current:close()
    end
    if not item then
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
    M.load(v, client, item, { root = root, bufnr = bufnr, depth = Config.for_server(client.name).depth })
    M.current = v
  end)
end

return M
