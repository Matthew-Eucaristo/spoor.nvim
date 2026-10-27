--- The always-on bow-tie panel. Follows the cursor with a debounce, cancels
--- stale requests, caches finished bow-ties, and never runs in insert mode.
local Config = require("spoor.config")
local bowtie = require("spoor.bowtie")
local lsp = require("spoor.lsp")
local resolve = require("spoor.resolve")
local util = require("spoor.util")
local view = require("spoor.view")

local M = {}

---@type table<integer, spoor.View> panel per tabpage
M.panels = {}
M.generation = 0 -- bumped on edits/writes; part of every cache key
M.paused = false -- the user closed the panel window this session

local cache = { map = {}, order = {}, size = 64 }

function M.cache_get(key)
  return cache.map[key]
end

function M.cache_put(key, g)
  if not cache.map[key] then
    table.insert(cache.order, key)
    if #cache.order > cache.size then
      cache.map[table.remove(cache.order, 1)] = nil
    end
  end
  cache.map[key] = g
end

function M.cache_clear()
  cache.map, cache.order = {}, {}
end

local function state_file()
  return vim.fs.joinpath(util.state_dir(), "state.json")
end

--- Live is on unless the user turned it off (the choice persists).
function M.enabled()
  if M._enabled == nil then
    local state = util.read_json(state_file()) or {}
    if state.live == nil then
      M._enabled = Config.options.live.enabled
    else
      M._enabled = state.live
    end
  end
  return M._enabled
end

---@param on boolean
function M.set(on)
  M._enabled = on
  M.paused = false
  local state = util.read_json(state_file()) or {}
  state.live = on
  pcall(util.write_json, state_file(), state)
  if on then
    M.update()
  else
    M.close_all()
  end
end

function M.toggle()
  M.set(not M.enabled())
end

function M.close_all()
  if M.group then
    M.group:cancel()
  end
  for tab, v in pairs(M.panels) do
    v.closing = true
    v:close()
    M.panels[tab] = nil
  end
end

---@param v spoor.View
local function own_panel(win)
  for _, v in pairs(M.panels) do
    if v:valid() and v.win.win == win then
      return true
    end
  end
  return false
end

--- Should spoor follow the cursor in this window?
---@param win integer
local function followable(win)
  if own_panel(win) or vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

M.actions = vim.tbl_extend("force", view.base_actions, {
  jump = function(v)
    local node = v:node_at_cursor()
    if node then
      v:jump(node)
    end
  end,
  expand = function(v)
    -- the panel is one level; <Tab> opens the deeper float on that node
    local node = v:node_at_cursor()
    if node then
      v:jump(node)
      bowtie.open()
    end
  end,
  reroot = function(v)
    local node = v:node_at_cursor()
    if node then
      v:jump(node)
    end
  end,
  trace = function(v)
    local node = v:node_at_cursor() or (v.graph and v.graph.nodes[v.graph.focus])
    if node then
      require("spoor.trace").start(node, { client = v.client, root = v.graph.root, origin = v.origin })
    end
  end,
  retry = bowtie.retry,
  close = function()
    M.set(false)
  end,
})

M.keys = vim.tbl_extend("force", view.keys, {
  ["q"] = { "close", desc = "Turn live off" },
})

---@return spoor.View
local function panel()
  local tab = vim.api.nvim_get_current_tabpage()
  local v = M.panels[tab]
  if v and v:valid() then
    return v
  end
  local o = Config.options.live
  local float = o.layout == "float"
  local width = math.min(math.floor(vim.o.columns * 0.62), 140)
  v = view.new({
    kind = "panel",
    max_items = o.max_items,
    max_rows = o.height - 1,
    actions = M.actions,
    keys = M.keys,
    win = float and {
      position = "float",
      relative = "editor",
      width = width,
      height = o.height,
      row = vim.o.lines - o.height - 4,
      col = vim.o.columns - width - 2,
      border = "rounded",
      backdrop = false,
      focusable = true,
      zindex = 20,
    } or {
      position = "bottom",
      height = o.height,
      relative = "editor",
      wo = { winfixheight = true, winbar = " " },
    },
  })
  v.origin = vim.api.nvim_get_current_win()
  v:show()
  v.win:on("WinClosed", function()
    -- :q from inside the panel pauses it for the session; :tabclose, :only and
    -- friends just close it, and it comes back on the next cursor rest
    if v.user_quit then
      M.paused = true
    end
    M.panels[tab] = nil
  end, { win = true })
  M.panels[tab] = v
  return v
end

local function key_for(item)
  return util.id(item.uri, item.selectionRange.start) .. "@" .. M.generation
end

--- Follow the cursor once (called debounced).
function M.update()
  if not M.enabled() or M.paused then
    return
  end
  local mode = vim.api.nvim_get_mode().mode
  if mode:sub(1, 1) == "i" or mode:sub(1, 1) == "R" then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if not followable(win) then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  local client = lsp.client(bufnr)
  local existing = M.panels[vim.api.nvim_get_current_tabpage()]
  if not client then
    if existing and existing:valid() then
      existing:set_stale(true)
    end
    return
  end
  if M.group then
    M.group:cancel()
  end
  M.group = lsp.group()
  local tick = M.generation
  local tab = vim.api.nvim_get_current_tabpage()
  resolve.at_cursor(client, win, { group = M.group }, function(item)
    -- drop answers for an edited buffer, a closed window or a tab you have left
    if
      tick ~= M.generation
      or not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_win_get_buf(win) ~= bufnr
      or vim.api.nvim_get_current_tabpage() ~= tab
    then
      return
    end
    local v = M.panels[vim.api.nvim_get_current_tabpage()]
    if not item then
      if v and v:valid() then
        v:set_stale(true)
      end
      return
    end
    local key = key_for(item)
    if v and v:valid() and v.key == key then
      return v:set_stale(false)
    end
    v = panel()
    v.origin = win
    v:set_stale(false)
    v.key = key
    local cached = M.cache_get(key)
    if cached then
      if v.group then
        v.group:cancel()
      end
      v.client = client
      return v:render(cached)
    end
    bowtie.load(v, client, item, {
      root = util.root(bufnr, client),
      bufnr = bufnr,
      depth = 1,
      callers = Config.for_server(client.name).live_callers,
      on_done = function(g)
        if g.complete and g.status.incoming == "done" and g.status.outgoing == "done" then
          M.cache_put(key, g)
        end
      end,
    })
  end)
end

local schedule, cancel_schedule

function M.setup()
  schedule, cancel_schedule = util.debounce(Config.options.live.debounce, M.update)
  local group = vim.api.nvim_create_augroup("spoor_live", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter", "InsertLeave", "LspAttach", "TabEnter" }, {
    group = group,
    callback = function()
      if M.enabled() and not M.paused then
        schedule()
      end
    end,
  })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    callback = function()
      cancel_schedule()
      for _, g in ipairs({ M.group, bowtie.open_group, require("spoor.trace").start_group }) do
        g:cancel()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = group,
    callback = function()
      M.generation = M.generation + 1
    end,
  })
  -- Don't keep Neovim open just for the panel.
  vim.api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      local tab = vim.api.nvim_get_current_tabpage()
      local v = M.panels[tab]
      if not (v and v:valid()) then
        return
      end
      if vim.api.nvim_get_current_win() == v.win.win then
        v.user_quit = true -- :q in the panel itself
        return
      end
      local code = 0
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        local buf = vim.api.nvim_win_get_buf(w)
        if vim.api.nvim_win_get_config(w).relative == "" and vim.bo[buf].filetype ~= "spoor" then
          code = code + 1
        end
      end
      if code <= 1 then
        v.closing = true
        v:close()
        M.panels[tab] = nil
        require("spoor.trace").close()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      for _, v in pairs(M.panels) do
        if v:valid() and v.graph then
          v:render(v.graph)
        end
      end
    end,
  })
end

return M
