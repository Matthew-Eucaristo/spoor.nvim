--- Language server requests with a hard timeout and cancellation.
--- Every request spoor makes goes through `M.request`, so nothing can hang the editor.
local Config = require("spoor.config")

local M = {}

---@type table<integer, boolean> client ids that have answered at least once
local warm = {}

--- Requests in flight, for tests and :checkhealth.
M.inflight = 0

---@param bufnr integer
---@param method? string
---@return vim.lsp.Client?
function M.client(bufnr, method)
  method = method or "textDocument/prepareCallHierarchy"
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if c:supports_method(method, bufnr) then
      return c
    end
  end
end

---@class spoor.Group
---@field cancels table<integer, fun()>
---@field cancelled boolean
local Group = {}
Group.__index = Group

--- A set of requests that are cancelled together (one bow-tie, one picker preview, ...).
function M.group()
  return setmetatable({ cancels = {}, cancelled = false, n = 0 }, Group)
end

function Group:cancel()
  self.cancelled = true
  for _, cancel in pairs(self.cancels) do
    cancel()
  end
  self.cancels = {}
end

--- Send one request. `cb(err, result)` runs at most once, on the main loop.
--- `err` is `{ timeout = true }` after the timeout and `{ cancelled = true }` is never delivered.
---@param client vim.lsp.Client
---@param method string
---@param params table
---@param opts {bufnr?: integer, timeout?: integer, group?: spoor.Group}
---@param cb fun(err: table?, result: any)
function M.request(client, method, params, opts, cb)
  local group = opts.group
  if group and group.cancelled then
    return
  end
  local done = false
  local timer ---@type uv.uv_timer_t?
  local req_id ---@type integer?
  local key

  local function finish()
    done = true
    M.inflight = M.inflight - 1
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    if group and key then
      group.cancels[key] = nil
    end
  end

  M.inflight = M.inflight + 1
  local ok, id = client:request(method, params, function(err, result)
    if done then
      return
    end
    finish()
    warm[client.id] = true
    cb(err, result)
  end, opts.bufnr)
  if not ok then
    finish()
    cb({ message = "request failed: " .. method }, nil)
    return
  end
  if done then -- answered synchronously
    return
  end
  req_id = id

  local timeout = opts.timeout or Config.for_server(client.name).timeout
  if not warm[client.id] then
    timeout = math.max(timeout, Config.options.cold_timeout)
  end
  timer = vim.uv.new_timer()
  timer:start(timeout, 0, function()
    vim.schedule(function()
      if done then
        return
      end
      finish()
      pcall(client.cancel_request, client, req_id)
      cb({ timeout = true, message = ("%s timed out after %d ms"):format(method, timeout) }, nil)
    end)
  end)

  if group then
    group.n = group.n + 1
    key = group.n
    group.cancels[key] = function()
      if not done then
        finish()
        pcall(client.cancel_request, client, req_id)
      end
    end
  end
end

--- Forget which servers are warm (tests).
function M.reset()
  warm = {}
  M.inflight = 0
end

---@param client vim.lsp.Client
function M.is_warm(client)
  return warm[client.id] == true
end

return M
