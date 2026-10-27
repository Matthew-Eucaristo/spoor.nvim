-- Shared test helpers: an in-process fake language server and fixture items.
local H = {}

H.root = _G.SPOOR_ROOT
H.go = H.root .. "/tests/fixtures/go"
H.ts = H.root .. "/tests/fixtures/ts"

local Function, Method = 12, 6

--- Wait until `cond()` is true (processes events), or fail.
function H.wait(cond, ms, what)
  local ok = vim.wait(ms or 2000, cond, 5)
  if not ok then
    error("timed out waiting for " .. (what or "condition"), 2)
  end
end

--- A CallHierarchyItem for `name` in a fixture file: finds the first line matching `pattern`
--- (default: the name followed by "(") and points the selection at the name.
---@param file string absolute path
---@param name string
---@param opts? {kind?: integer, pattern?: string, lines?: integer}
function H.item(file, name, opts)
  opts = opts or {}
  local lines = vim.fn.readfile(file)
  local pattern = opts.pattern or (vim.pesc(name) .. "%(")
  for i, l in ipairs(lines) do
    local s = l:find(pattern)
    if s then
      local col = l:find(name, s, true) - 1
      local last = math.min(i - 1 + (opts.lines or 6), #lines - 1)
      return {
        name = name,
        kind = opts.kind or Function,
        uri = vim.uri_from_fname(file),
        detail = vim.fs.basename(file),
        range = { start = { line = i - 1, character = 0 }, ["end"] = { line = last, character = 1 } },
        selectionRange = {
          start = { line = i - 1, character = col },
          ["end"] = { line = i - 1, character = col + #name },
        },
      }
    end
  end
  error(("no %q in %s"):format(name, file))
end

H.Function, H.Method = Function, Method

---@param item table
---@param line? integer
function H.site(item, line)
  local l = line or item.selectionRange.start.line
  return { start = { line = l, character = 2 }, ["end"] = { line = l, character = 8 } }
end

--- Start a fake language server attached to `bufnr`.
--- spec.handlers[method] = function(params) return result end
--- spec.delay[method] = ms | "never"
---@return {client: vim.lsp.Client, requests: table[], cancels: integer[]}
function H.fake_server(bufnr, spec)
  local state = { requests = {}, cancels = {} }
  local caps = spec.capabilities
    or {
      callHierarchyProvider = true,
      implementationProvider = true,
      referencesProvider = true,
      documentSymbolProvider = true,
    }
  local cmd = function(dispatchers)
    local closing, id = false, 0
    local cancelled = {}
    return {
      request = function(method, params, callback, notify_reply)
        id = id + 1
        local my = id
        if method == "initialize" then
          callback(nil, { capabilities = caps })
          return true, my
        end
        if method == "shutdown" then
          callback(nil, nil)
          return true, my
        end
        table.insert(state.requests, { method = method, params = params, id = my })
        local function respond()
          if cancelled[my] then
            return
          end
          if notify_reply then
            notify_reply(my)
          end
          local handler = spec.handlers[method]
          callback(nil, handler and handler(params) or nil)
        end
        local delay = spec.delay and spec.delay[method]
        if delay == "never" then
          return true, my
        elseif delay then
          vim.defer_fn(respond, delay)
        else
          vim.schedule(respond)
        end
        return true, my
      end,
      notify = function(method, params)
        if method == "$/cancelRequest" then
          cancelled[params.id] = true
          table.insert(state.cancels, params.id)
        elseif method == "exit" then
          closing = true
          dispatchers.on_exit(0, 15)
        end
        return true
      end,
      is_closing = function()
        return closing
      end,
      terminate = function()
        if not closing then
          closing = true
          dispatchers.on_exit(0, 15)
        end
      end,
    }
  end
  local client_id = vim.lsp.start(
    { name = spec.name or "fake", cmd = cmd, root_dir = spec.root or H.go },
    { bufnr = bufnr }
  )
  H.wait(function()
    local c = vim.lsp.get_client_by_id(client_id)
    return c and c.initialized and vim.lsp.buf_is_attached(bufnr, client_id)
  end, 2000, "fake server")
  state.client = vim.lsp.get_client_by_id(client_id)
  return state
end

function H.count(requests, method)
  local n = 0
  for _, r in ipairs(requests) do
    if r.method == method then
      n = n + 1
    end
  end
  return n
end

--- Fresh plugin state between tests.
function H.reset()
  for _, c in ipairs(vim.lsp.get_clients()) do
    c:stop(true)
  end
  pcall(function()
    require("spoor.live").close_all()
  end)
  pcall(function()
    require("spoor.trace").close()
  end)
  for name in pairs(package.loaded) do
    if name:find("^spoor") then
      package.loaded[name] = nil
    end
  end
  vim.cmd("silent! %bwipeout!")
  for _, lhs in ipairs({
    "gag",
    "gat",
    "<leader>ct",
    "<leader>cT",
    "<leader>ce",
    "<leader>cG",
    "<leader>uB",
    "<leader>cb",
  }) do
    pcall(vim.keymap.del, "n", lhs)
  end
  pcall(vim.api.nvim_del_augroup_by_name, "spoor_live")
  vim.fn.delete(vim.fn.stdpath("state") .. "/spoor", "rf")
end

--- The standard fixture graph for internal/order/order.go:Process.
function H.go_world()
  local order = H.go .. "/internal/order/order.go"
  local w = {
    process = H.item(order, "Process", { lines = 12 }),
    validate = H.item(H.go .. "/internal/order/validate.go", "validate"),
    subtotal = H.item(order, "subtotal", { pattern = "^func subtotal%(" }),
    discount = H.item(H.go .. "/internal/order/discount.go", "applyDiscount"),
    save = H.item(H.go .. "/internal/order/repo.go", "Save", { kind = Method, lines = 0 }),
    emit = H.item(H.go .. "/internal/events/bus.go", "Emit"),
    handle = H.item(
      H.go .. "/internal/server/server.go",
      "handleOrders",
      { kind = Method, pattern = "%) handleOrders%(" }
    ),
    test = H.item(H.go .. "/internal/order/order_test.go", "TestProcess"),
    mem_save = H.item(H.go .. "/internal/store/memory.go", "Save", { kind = Method, pattern = "%) Save%(" }),
    pg_save = H.item(H.go .. "/internal/store/postgres.go", "Save", { kind = Method, pattern = "%) Save%(" }),
  }
  local p = w.process.selectionRange.start.line
  w.outgoing = {
    { to = w.validate, fromRanges = { H.site(w.process, p + 1) } },
    { to = w.subtotal, fromRanges = { H.site(w.process, p + 4) } },
    { to = w.discount, fromRanges = { H.site(w.process, p + 4) } },
    { to = w.save, fromRanges = { H.site(w.process, p + 5) } },
    { to = w.emit, fromRanges = { H.site(w.process, p + 8) } },
  }
  -- applyDiscount is called before subtotal on the same line in source; order by column
  w.outgoing[2].fromRanges[1].start.character = 30
  w.outgoing[3].fromRanges[1].start.character = 10
  w.incoming = {
    { from = w.handle, fromRanges = { H.site(w.handle, w.handle.selectionRange.start.line + 6) } },
    { from = w.test, fromRanges = { H.site(w.test, w.test.selectionRange.start.line + 3) } },
  }
  return w
end

--- Handlers that answer like gopls would for the Go fixture.
function H.go_handlers(w, extra)
  local by_name = {}
  for _, it in pairs(w) do
    if type(it) == "table" and it.name then
      by_name[it.uri .. it.selectionRange.start.line] = it
    end
  end
  local handlers = {
    ["textDocument/prepareCallHierarchy"] = function(params)
      local p = params.position
      for _, it in pairs(by_name) do
        if it.uri == params.textDocument.uri and it.selectionRange.start.line == p.line then
          return { it }
        end
      end
      return nil
    end,
    ["callHierarchy/outgoingCalls"] = function(params)
      if params.item.name == "Process" then
        return w.outgoing
      end
      return {}
    end,
    ["callHierarchy/incomingCalls"] = function(params)
      if params.item.name == "Process" then
        return w.incoming
      end
      return {}
    end,
    ["textDocument/implementation"] = function(params)
      if params.textDocument.uri == w.save.uri then
        return {
          { uri = w.mem_save.uri, range = w.mem_save.selectionRange },
          { uri = w.pg_save.uri, range = w.pg_save.selectionRange },
        }
      end
      return {}
    end,
    ["textDocument/documentSymbol"] = function()
      return {
        {
          name = "Process",
          kind = Function,
          range = w.process.range,
          selectionRange = w.process.selectionRange,
        },
      }
    end,
  }
  return vim.tbl_extend("force", handlers, extra or {})
end

--- Copy a directory tree (no `cp`, so it runs on Windows too).
function H.copy_dir(src, dst)
  for name, type in vim.fs.dir(src, { depth = math.huge }) do
    local from, to = src .. "/" .. name, dst .. "/" .. name
    if type == "directory" then
      vim.fn.mkdir(to, "p")
    elseif type == "file" then
      vim.fn.mkdir(vim.fs.dirname(to), "p")
      assert(vim.uv.fs_copyfile(from, to))
    end
  end
end

--- Hide snacks.nvim, as if it were not installed. Returns a function that brings it back.
function H.without_snacks()
  local snacks, loaded = rawget(_G, "Snacks"), package.loaded.snacks
  _G.Snacks, package.loaded.snacks = nil, nil
  package.preload.snacks = function()
    error("module 'snacks' not found")
  end
  return function()
    package.preload.snacks = nil
    _G.Snacks, package.loaded.snacks = snacks, loaded
  end
end

--- Open a fixture file in the current window.
function H.edit(file, line, col)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  if line then
    vim.api.nvim_win_set_cursor(0, { line, col or 0 })
  end
  return vim.api.nvim_get_current_buf()
end

return H
