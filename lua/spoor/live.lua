--- The live bow-tie: a card next to the cursor once it rests (and the full bow-tie on K), or a
--- bottom panel you toggle. Debounced, cancels stale requests, caches finished bow-ties, and
--- never runs in insert mode.
local Config = require("spoor.config")
local bowtie = require("spoor.bowtie")
local lsp = require("spoor.lsp")
local resolve = require("spoor.resolve")
local syntax = require("spoor.syntax")
local util = require("spoor.util")
local view = require("spoor.view")

local M = {}

---@type table<integer, spoor.View> panel per tabpage
M.panels = {}
M.generation = 0 -- bumped on edits/writes; part of every cache key
M.paused = false -- the user closed the panel window this session

local rest, cancel_rest -- the card's rest timer (set up in M.setup)

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

--- Is the bottom panel on? <leader>uB toggles it and the choice persists.
function M.enabled()
  if M._enabled == nil then
    local state = util.read_json(state_file()) or {}
    if state.panel == nil then
      M._enabled = Config.options.live.panel == true
    else
      M._enabled = state.panel
    end
  end
  return M._enabled
end

--- The card shows after the cursor rests (live.card.delay), unless it is turned off.
local function card_on()
  local card = Config.options.live.card
  return type(card) == "table" and card.delay ~= false
end

--- The panel is showing (on, and not closed by hand this session).
local function panel_mode()
  return M.enabled() and not M.paused
end

--- Anything live to do at all?
local function active()
  return panel_mode() or card_on()
end
M.active = active

---@param on boolean
function M.set(on)
  M._enabled = on
  M.paused = false
  local state = util.read_json(state_file()) or {}
  state.panel = on
  pcall(util.write_json, state_file(), state)
  if on then
    M.update()
  else
    M.close_all()
    if card_on() and rest then
      rest() -- the card comes back once the cursor has rested
    end
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

--- The card has nothing to say right now (insert mode, no function, another window or float).
---@type table<integer, {graph: spoor.Graph, client: vim.lsp.Client, load_opts: spoor.LoadOpts, origin: integer, key?: string}>
M.last_card = {} -- per tabpage: what the card showed, so K can still grow it after it hid

---@param keep? boolean remember what it showed, for K (only when a hover made it step aside)
local function hide_card(keep)
  local tab = vim.api.nvim_get_current_tabpage()
  local v = M.panels[tab]
  M.last_card[tab] = nil
  if v and v.opts.kind == "card" then
    if keep and v.graph and v.client and v.load_opts then
      M.last_card[tab] = { graph = v.graph, client = v.client, load_opts = v.load_opts, origin = v.origin }
    end
    v.closing = true
    v:close()
    M.panels[tab] = nil
  end
end
M.hide_card = hide_card

---@type table<integer, spoor.View> per tabpage: the full bow-tie shown next to a hover (K)
M.expanded = {}

--- Back to the small card: the cursor moved, you started typing, or the hover closed.
local function collapse()
  local tab = vim.api.nvim_get_current_tabpage()
  local e = M.expanded[tab]
  M.expanded[tab] = nil
  if e then
    if e.group then
      e.group:cancel()
    end
    e:close()
  end
end
M.collapse = collapse

--- K opened a hover over the function the card shows: grow the card into the full bow-tie
--- (callers of callers, callees of callees, more rows) on the other side of the cursor.
---@param hover integer
local function expand(hover)
  local tab = vim.api.nvim_get_current_tabpage()
  if M.expanded[tab] or M.expanding then
    return -- already showing (or hidden because the hover leaves no room)
  end
  local win = vim.api.nvim_get_current_win()
  if M.panels[tab] and M.panels[tab].opts.kind == "card" then
    hide_card(true)
  end
  ---@param graph? spoor.Graph a finished graph (tree-sitter) instead of loading one
  local function open(client, item, opts, graph)
    if M.expanded[tab] or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_get_current_win() ~= win then
      return
    end
    local e = view.new({
      kind = "expanded",
      max_items = Config.options.float.max_items,
      actions = M.actions,
      keys = {},
      win = {
        position = "float",
        relative = "editor",
        width = 40,
        height = 4,
        row = 0,
        col = 0,
        border = "rounded",
        backdrop = false,
        focusable = false,
        zindex = 45, -- just under the hover
        wo = { cursorline = false },
      },
    })
    e.origin, e.hover = win, hover
    e:show()
    M.expanded[tab] = e
    -- hovers (noice, LSP) size themselves after opening: place again once they settle
    vim.defer_fn(function()
      if M.expanded[tab] == e then
        e:place_expanded()
      end
    end, 120)
    if graph then
      return e:render(graph)
    end
    bowtie.load(e, client, item, vim.tbl_extend("force", opts, { depth = Config.for_server(client.name).depth }))
  end
  -- the card showed this function a moment ago (hovers open their windows one by one)
  local last = M.last_card[tab]
  if last and last.origin == win and last.graph then
    local focus = last.graph.nodes[last.graph.focus]
    if focus and focus.item and last.client then
      return open(last.client, focus.item, last.load_opts)
    end
  end
  -- nothing shown yet (the card waits for a rest): ask now
  local bufnr = vim.api.nvim_win_get_buf(win)
  local client = lsp.client(bufnr)
  if client then
    M.expanding = true
    resolve.at_cursor(client, win, { group = lsp.group() }, function(item)
      M.expanding = false
      if item and hover and vim.api.nvim_win_is_valid(hover) then
        open(client, item, {
          root = util.root(bufnr, client),
          bufnr = bufnr,
          callers = Config.for_server(client.name).live_callers,
        })
      end
    end)
  elseif Config.options.syntax then
    syntax.at_cursor(win, function(g)
      if g and hover and vim.api.nvim_win_is_valid(hover) then
        open(nil, nil, nil, g)
      end
    end)
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

--- Is a hover, signature or diagnostic float open at the cursor? Returns it.
--- Neovim reports cursor floats as relative to the cursor's window, and some plugins nest them
--- (noice draws a frame anchored to the code window and the text anchored to the frame). So: a
--- float anchored to the code window, directly or through another float, that touches the
--- cursor line. Sidebars like the snacks explorer anchor to their own window and don't count.
---@param win? integer the code window
---@return integer? hover window (the outermost one)
local function cursor_float(win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local cursor = vim.fn.screenpos(win, vim.fn.line(".", win), vim.fn.col(".", win)).row - 1
  -- screen rows from the configs, not nvim_win_get_position: a new float isn't placed until the
  -- next redraw on some versions
  local info = vim.fn.getwininfo(win)[1]
  local top = { [win] = info.winrow - 1 }
  local found
  -- floats can nest: resolve anchors a few levels deep
  for _ = 1, 3 do
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local cfg = vim.api.nvim_win_get_config(w)
      if not top[w] and not own_panel(w) and vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "spoor" then
        local base = cfg.relative == "cursor" and cursor or (cfg.relative == "win" and top[cfg.win])
        if base then
          local row = cfg.row
          if type(row) == "table" then -- older Neovim returns {false, n}
            row = row[#row]
          end
          local t = math.floor(base + (tonumber(row) or 0))
          top[w] = t
          if t - 1 <= cursor + 2 and t + vim.api.nvim_win_get_height(w) + 1 >= cursor - 2 then
            found = found or w
          end
        end
      end
    end
  end
  return found
end
M.cursor_float = cursor_float

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
    if node and view.can_trace(v) then
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
  local want = panel_mode() and "panel" or "card"
  if v and v:valid() and v.opts.kind == want then
    return v
  end
  if v and v:valid() then -- switching between the card and the panel
    v.closing = true
    v:close()
    M.panels[tab] = nil
  end
  local o = Config.options.live
  local float = o.layout == "float"
  local width = math.min(math.floor(vim.o.columns * 0.62), 140)
  if want == "card" then
    local w = math.min(o.card.width, vim.o.columns - 4)
    v = view.new({
      kind = "card",
      max_items = o.card.max_items,
      actions = M.actions,
      keys = {},
      win = {
        position = "float",
        relative = "editor",
        width = w,
        height = 4,
        row = 1,
        col = 1,
        border = "rounded",
        backdrop = false,
        focusable = false,
        zindex = 40, -- under hover (50), completion and notifications
        wo = { cursorline = false },
      },
    })
  else
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
  end
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
  if not active() then
    return
  end
  local mode = vim.api.nvim_get_mode().mode
  if mode:sub(1, 1) == "i" or mode:sub(1, 1) == "R" then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if not followable(win) then
    return hide_card()
  end
  if not panel_mode() and not M.card_due then
    return -- the card waits until the cursor has rested (live.card.delay)
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  local client = lsp.client(bufnr)
  if M.group then
    M.group:cancel()
  end
  M.group = lsp.group()
  local group, tick = M.group, M.generation
  local tab = vim.api.nvim_get_current_tabpage()

  --- The view to show `key` in, or nil when there is nothing (new) to show.
  ---@param found boolean
  ---@param key? string
  ---@return spoor.View?
  local function target(found, key)
    -- drop answers for an edited buffer, a closed window, a tab you have left or a newer cursor
    if
      group.cancelled
      or tick ~= M.generation
      or not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_win_get_buf(win) ~= bufnr
      or vim.api.nvim_get_current_tabpage() ~= tab
    then
      return nil
    end
    local v = M.panels[tab]
    if not found then
      if v and v:valid() then
        v:set_stale(true)
      end
      return hide_card()
    end
    if cursor_float(win) then
      return expand(cursor_float(win) --[[@as integer]]) -- K: the full bow-tie next to the hover
    end
    local kind = panel_mode() and "panel" or "card"
    if v and v:valid() and v.key == key and v.opts.kind == kind then
      if v.opts.kind == "card" then
        v.origin = win
        v:place_card() -- follow the cursor
      end
      return v:set_stale(false)
    end
    v = panel()
    v.origin = win
    v:set_stale(false)
    v.key = key
    return v
  end

  if not client then
    if not Config.options.syntax then
      return target(false)
    end
    -- no call hierarchy here: a same-file bow-tie from tree-sitter
    return syntax.at_cursor(win, function(g)
      local v = target(g ~= nil, g and ("syntax:" .. g.focus .. "@" .. tick))
      if v and g then
        if v.group then
          v.group:cancel()
        end
        v.client, v.load_opts = nil, nil
        v:render(g)
      end
    end)
  end
  resolve.at_cursor(client, win, { group = group }, function(item)
    local key = item and key_for(item)
    local v = target(item ~= nil, key)
    if not v then
      return
    end
    local opts = {
      root = util.root(bufnr, client),
      bufnr = bufnr,
      depth = 1,
      callers = Config.for_server(client.name).live_callers,
      on_done = function(g)
        if g.complete and g.status.incoming == "done" and g.status.outgoing == "done" then
          M.cache_put(key, g)
        end
      end,
    }
    local cached = M.cache_get(key)
    if cached then
      if v.group then
        v.group:cancel()
      end
      v.client, v.load_opts = client, opts -- K can grow a cached card too
      return v:render(cached)
    end
    bowtie.load(v, client, item, opts)
  end)
end

--- Look for a hover at the cursor every 50 ms for up to a second, and grow the card when one
--- shows up. Hovers are often positioned after their window opens (noice waits for the
--- server's answer and opens windows without autocommands), so one look is not enough.
local watching
local function watch_hover()
  if watching then
    return
  end
  local tries = 0
  watching = assert(vim.uv.new_timer())
  watching:start(
    0,
    50,
    vim.schedule_wrap(function()
      if not watching then
        return
      end
      tries = tries + 1
      local hover = cursor_float()
      if hover or tries >= 20 then
        watching:stop()
        watching:close()
        watching = nil
        if hover then
          expand(hover)
        end
      end
    end)
  )
end

local schedule, cancel_schedule

function M.setup()
  schedule, cancel_schedule = util.debounce(Config.options.live.debounce, M.update)
  local card = Config.options.live.card
  local delay = type(card) == "table" and tonumber(card.delay) or 0
  rest, cancel_rest = util.debounce(math.max(delay, Config.options.live.debounce), function()
    M.card_due = true -- the cursor stayed put: the card may show
    M.update()
  end)
  local group = vim.api.nvim_create_augroup("spoor_live", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter", "InsertLeave", "LspAttach", "TabEnter" }, {
    group = group,
    callback = function(ev)
      local e = M.expanded[vim.api.nvim_get_current_tabpage()]
      -- moving on (j, k, ...) folds the full bow-tie back into the card
      if e and ev.event == "CursorMoved" and vim.api.nvim_get_current_win() == e.origin then
        collapse()
      end
      if ev.event == "CursorMoved" then
        M.card_due = false -- a rest starts over whenever the cursor moves
      end
      if panel_mode() then
        schedule()
      elseif card_on() then
        -- moving hides the card; it comes back once the cursor rests again
        M.card_due = false
        hide_card()
        rest()
      end
    end,
  })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    callback = function()
      cancel_schedule()
      cancel_rest()
      M.card_due = false
      for _, g in ipairs({ M.group, bowtie.open_group, require("spoor.trace").start_group }) do
        g:cancel()
      end
      hide_card()
      collapse()
    end,
  })
  -- a hover or diagnostic float opened at the cursor: hide the card; when it closes, come back
  -- K (hover) over the card's function: show the full bow-tie next to it. The hover closing
  -- brings the card back.
  -- after K (or any pause), a hover may be opening
  vim.api.nvim_create_autocmd("CursorHold", {
    group = group,
    callback = function()
      local e = M.expanded[vim.api.nvim_get_current_tabpage()]
      if e and not (e.hover and vim.api.nvim_win_is_valid(e.hover)) then
        collapse() -- its hover closed without telling anyone (noice closes with noautocmd)
        if panel_mode() or M.card_due then
          schedule() -- back to what was showing before K
        end
        return
      end
      if Config.options.live.hover ~= false then
        watch_hover()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinNew", "WinClosed" }, {
    group = group,
    callback = function(ev)
      local closed = ev.event == "WinClosed" and tonumber(ev.match) or nil
      if closed then
        return vim.schedule(function()
          local e = M.expanded[vim.api.nvim_get_current_tabpage()]
          if e and closed == e.hover then
            collapse()
          end
          if panel_mode() or M.card_due then
            schedule()
          end
        end)
      end
      if Config.options.live.hover ~= false then
        watch_hover()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = group,
    callback = function()
      M.generation = M.generation + 1
    end,
  })
  -- Don't keep Neovim open just for spoor's windows (card, panel, trail, a pinned bow-tie).
  vim.api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      local tab = vim.api.nvim_get_current_tabpage()
      local v = M.panels[tab]
      local cur = vim.api.nvim_get_current_win()
      if v and v:valid() and cur == v.win.win then
        v.user_quit = true -- :q in the panel itself
        return
      end
      -- :q in another spoor window closes just that; :qa from there quits everything by itself.
      -- Closing the current window here would make Neovim abandon the quit.
      if vim.bo[vim.api.nvim_win_get_buf(cur)].filetype == "spoor" then
        return
      end
      local code, ours = 0, {}
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        local buf = vim.api.nvim_win_get_buf(w)
        if vim.bo[buf].filetype == "spoor" then
          ours[#ours + 1] = w
        elseif vim.api.nvim_win_get_config(w).relative == "" then
          code = code + 1
        end
      end
      if code <= 1 then
        if v and v:valid() then
          v.closing = true
        end
        M.panels[tab] = nil
        require("spoor.trace").close()
        for _, w in ipairs(ours) do
          if vim.api.nvim_win_is_valid(w) then
            pcall(vim.api.nvim_win_close, w, true)
          end
        end
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
