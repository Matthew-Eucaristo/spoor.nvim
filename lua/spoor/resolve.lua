--- Cursor -> call hierarchy item. On a call or a function name, that symbol;
--- anywhere else inside a function, the enclosing function.
local lsp = require("spoor.lsp")
local util = require("spoor.util")

local M = {}

local CALLABLE = {
  [util.kinds.Function] = true,
  [util.kinds.Method] = true,
  [util.kinds.Constructor] = true,
}
-- Arrow functions and React components often come back as variables/constants.
local MAYBE_CALLABLE = {
  [util.kinds.Variable] = true,
  [util.kinds.Constant] = true,
  [util.kinds.Field] = true,
  [util.kinds.Property] = true,
}

---@type table<string, {tick: integer, symbols: table[]}>
local symbol_cache = {}

local function contains(range, pos)
  local s, e = range.start, range["end"]
  if pos.line < s.line or pos.line > e.line then
    return false
  end
  if pos.line == s.line and pos.character < s.character then
    return false
  end
  if pos.line == e.line and pos.character > e.character then
    return false
  end
  return true
end

--- Enclosing symbols that could be functions, innermost first.
---@param symbols table[] DocumentSymbol[] or SymbolInformation[]
---@param pos lsp.Position
---@return table[]
function M.enclosing(symbols, pos)
  local out = {}
  local function walk(list)
    for _, s in ipairs(list or {}) do
      local range = s.range or (s.location and s.location.range)
      if range and contains(range, pos) then
        local multiline = range["end"].line > range.start.line
        if CALLABLE[s.kind] or (MAYBE_CALLABLE[s.kind] and multiline) then
          table.insert(out, 1, s)
        end
        walk(s.children)
      end
    end
  end
  walk(symbols)
  -- SymbolInformation is flat: order by range size, smallest first
  table.sort(out, function(a, b)
    local ra, rb = a.range or a.location.range, b.range or b.location.range
    return (ra["end"].line - ra.start.line) < (rb["end"].line - rb.start.line)
  end)
  return out
end

---@param client vim.lsp.Client
---@param bufnr integer
---@param cb fun(symbols: table[]?)
local function document_symbols(client, bufnr, opts, cb)
  local key = client.id .. ":" .. bufnr
  local tick = vim.b[bufnr].changedtick
  local cached = symbol_cache[key]
  if cached and cached.tick == tick then
    return cb(cached.symbols)
  end
  if not client:supports_method("textDocument/documentSymbol") then
    return cb(nil)
  end
  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
  lsp.request(client, "textDocument/documentSymbol", params, opts, function(err, result)
    if not err then
      symbol_cache[key] = { tick = tick, symbols = result or {} }
    end
    cb(result)
  end)
end

---@param client vim.lsp.Client
---@param bufnr integer
---@param pos lsp.Position
---@param cb fun(item: lsp.CallHierarchyItem?)
local function prepare(client, bufnr, pos, opts, cb)
  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = pos }
  lsp.request(client, "textDocument/prepareCallHierarchy", params, opts, function(_, items)
    cb(items and items[1] or nil)
  end)
end

--- Resolve the focus at a window's cursor.
---@param client vim.lsp.Client
---@param win integer
---@param opts {group?: spoor.Group, timeout?: integer, enclosing?: boolean}
---@param cb fun(item: lsp.CallHierarchyItem?)
function M.at_cursor(client, win, opts, cb)
  local bufnr = vim.api.nvim_win_get_buf(win)
  local params = vim.lsp.util.make_position_params(win, client.offset_encoding)
  local req = { bufnr = bufnr, group = opts.group, timeout = opts.timeout }
  prepare(client, bufnr, params.position, req, function(item)
    if item or opts.enclosing == false then
      return cb(item)
    end
    document_symbols(client, bufnr, req, function(symbols)
      local candidates = M.enclosing(symbols or {}, params.position)
      local i = 0
      local function next_candidate()
        i = i + 1
        local s = candidates[i]
        if not s or i > 3 then
          return cb(nil)
        end
        local pos = (s.selectionRange or (s.location and s.location.range)).start
        prepare(client, bufnr, pos, req, function(found)
          if found then
            return cb(found)
          end
          next_candidate()
        end)
      end
      next_candidate()
    end)
  end)
end

--- Resolve the focus at a position in a buffer (pickers, trails).
---@param client vim.lsp.Client
---@param bufnr integer
---@param pos lsp.Position
---@param opts {group?: spoor.Group, timeout?: integer}
---@param cb fun(item: lsp.CallHierarchyItem?)
function M.at(client, bufnr, pos, opts, cb)
  prepare(client, bufnr, pos, { bufnr = bufnr, group = opts.group, timeout = opts.timeout }, cb)
end

--- Document symbols for a buffer (cached by changedtick).
M.document_symbols = function(client, bufnr, opts, cb)
  document_symbols(client, bufnr, { bufnr = bufnr, group = opts.group, timeout = opts.timeout }, cb)
end

function M.clear_cache()
  symbol_cache = {}
end

return M
