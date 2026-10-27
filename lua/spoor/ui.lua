--- Windows and pickers. snacks.nvim when it is installed (picker previews, help, toggles);
--- otherwise plain Neovim windows and vim.ui.select, so spoor runs in any setup.
local M = {}

--- Is snacks.nvim available?
function M.snacks()
  if rawget(_G, "Snacks") and Snacks.win and Snacks.picker then
    return true
  end
  local ok = pcall(require, "snacks")
  return ok and rawget(_G, "Snacks") ~= nil and Snacks.win ~= nil and Snacks.picker ~= nil
end

-- Plain windows ----------------------------------------------------------------

---@class spoor.Win the subset of snacks.win that spoor uses
---@field win? integer
---@field buf? integer
---@field opts table
---@field help? integer
local Win = {}
Win.__index = Win

local function size(v, total, default)
  v = v or default
  return math.max(v < 1 and math.floor(total * v) or v, 1)
end

function Win:buf_valid()
  return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
end

function Win:valid()
  return self.win ~= nil
    and vim.api.nvim_win_is_valid(self.win)
    and self:buf_valid()
    and vim.api.nvim_win_get_buf(self.win) == self.buf
end

function Win:show()
  if self:valid() then
    return self
  end
  local o = self.opts
  if not self:buf_valid() then
    self.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[self.buf].bufhidden = "wipe"
    for k, v in pairs(o.bo or {}) do
      vim.bo[self.buf][k] = v
    end
    for _, key in pairs(o.keys or {}) do
      vim.keymap.set(key.mode or "n", key[1], function()
        key[2](self)
      end, { buffer = self.buf, desc = key.desc, nowait = true, silent = true })
    end
  end
  local cfg
  if o.position == "float" then
    local width = size(o.width, vim.o.columns, 0.8)
    local height = size(o.height, vim.o.lines, 0.6)
    cfg = {
      relative = o.relative or "editor",
      width = width,
      height = height,
      row = o.row or math.floor((vim.o.lines - height) / 2),
      col = o.col or math.floor((vim.o.columns - width) / 2),
      border = o.border,
      focusable = o.focusable ~= false,
      zindex = o.zindex,
      style = "minimal",
    }
  else
    local vertical = o.position == "right" or o.position == "left"
    cfg = {
      split = ({ bottom = "below", top = "above", right = "right", left = "left" })[o.position] or "below",
      win = o.relative == "win" and o.win or -1, -- -1: along the whole editor
      width = vertical and size(o.width, vim.o.columns, 0.4) or nil,
      height = not vertical and size(o.height, vim.o.lines, 0.3) or nil,
    }
  end
  self.win = vim.api.nvim_open_win(self.buf, o.enter == true, cfg)
  local wo = { number = false, relativenumber = false, signcolumn = "no", foldcolumn = "0", spell = false }
  wo.winfixbuf = o.fixbuf ~= false
  wo.statuscolumn = ""
  for k, v in pairs(vim.tbl_extend("force", wo, o.wo or {})) do
    vim.wo[self.win][k] = v
  end
  for _, h in ipairs(self.pending or {}) do
    self:on(h[1], h[2], h[3])
  end
  self.pending = nil
  return self
end

--- Run `cb` on an autocmd for this window ({win = true}) or its buffer ({buf = true}).
function Win:on(event, cb, opts)
  if not self.win then
    self.pending = self.pending or {}
    table.insert(self.pending, { event, cb, opts })
    return
  end
  self.augroup = self.augroup or vim.api.nvim_create_augroup("spoor_win_" .. self.win, { clear = true })
  local spec = { group = self.augroup, callback = cb }
  if opts and opts.buf then
    spec.buffer = self.buf
  else
    spec.pattern = tostring(self.win)
  end
  vim.api.nvim_create_autocmd(event, spec)
end

function Win:close()
  self:close_help()
  local win, buf = self.win, self.buf
  self.win = nil
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
end

function Win:close_help()
  if self.help and vim.api.nvim_win_is_valid(self.help) then
    pcall(vim.api.nvim_win_close, self.help, true)
  end
  self.help = nil
end

--- The keys of this window in a small float; again (or any key elsewhere) closes it.
function Win:toggle_help()
  if self.help then
    return self:close_help()
  end
  local rows = {}
  for _, key in pairs(self.opts.keys or {}) do
    if key.desc then
      rows[#rows + 1] = { key[1], key.desc }
    end
  end
  table.sort(rows, function(a, b)
    return a[2] == b[2] and a[1] < b[1] or a[2] < b[2]
  end)
  local w = 0
  for _, r in ipairs(rows) do
    w = math.max(w, vim.api.nvim_strwidth(r[1]))
  end
  local lines = vim.tbl_map(function(r)
    return (" %s%s  %s "):format(r[1], (" "):rep(w - vim.api.nvim_strwidth(r[1])), r[2])
  end, rows)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.api.nvim_strwidth(l))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "spoor_help"
  self.help = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = math.min(width, vim.o.columns - 4),
    height = math.min(#lines, vim.o.lines - 4),
    row = math.max(vim.o.lines - #lines - vim.o.cmdheight - 4, 0),
    col = math.max(vim.o.columns - width - 4, 0),
    border = "rounded",
    title = " keys ",
    style = "minimal",
    focusable = false,
    zindex = 60,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinLeave", "BufLeave" }, {
    buffer = self.buf,
    once = true,
    callback = function()
      self:close_help()
    end,
  })
end

--- A window: snacks.win when snacks.nvim is there, a plain one with the same methods otherwise.
--- Takes the snacks.win options spoor uses: position (float/bottom/right), relative, win,
--- width/height (fractions or cells), row/col, border, zindex, enter, fixbuf, bo, wo, keys.
---@param opts table
---@return spoor.Win|snacks.win
function M.win(opts)
  if M.snacks() then
    return Snacks.win(opts)
  end
  local self = setmetatable({ opts = opts }, Win)
  if opts.show ~= false then
    self:show()
  end
  return self
end

--- Toggle a window's key help. snacks places its help above the window's zindex, which a
--- split doesn't have.
function M.toggle_help(w)
  w.opts.zindex = w.opts.zindex or 50
  w:toggle_help()
end

-- Pickers ------------------------------------------------------------------------

--- Pick an item: Snacks.picker with its preview, else vim.ui.select (whatever picker you
--- registered for it). `format(item)` returns {text, hl} chunks; `confirm(picker, item)`.
---@param opts {source: string, title: string, items: table[], format: fun(item): table, confirm: fun(picker, item), preview?: any, layout?: table, on_close?: fun(), actions?: table, win?: table}
function M.pick(opts)
  if M.snacks() then
    return Snacks.picker.pick(opts)
  end
  vim.ui.select(opts.items, {
    prompt = opts.title,
    kind = opts.source,
    format_item = function(item)
      local text = table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
      end, opts.format(item)))
      return vim.trim(text)
    end,
  }, function(item)
    opts.confirm({ close = function() end }, item)
    if opts.on_close then
      opts.on_close()
    end
  end)
end

return M
