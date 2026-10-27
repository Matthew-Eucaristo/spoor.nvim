local M = {}

M.kinds = vim.lsp.protocol.SymbolKind

---@param uri string
function M.path(uri)
  return vim.uri_to_fname(uri)
end

--- Project root for a buffer: the language server's root, else the git root, else cwd.
---@param bufnr? integer
---@param client? vim.lsp.Client
function M.root(bufnr, client)
  if client and client.root_dir then
    return client.root_dir
  end
  if client and client.workspace_folders and client.workspace_folders[1] then
    return vim.uri_to_fname(client.workspace_folders[1].uri)
  end
  local name = bufnr and vim.api.nvim_buf_get_name(bufnr) or ""
  local git = vim.fs.root(name ~= "" and name or vim.fn.getcwd(), ".git")
  return git or vim.fn.getcwd()
end

---@param path string
---@param root? string
---@return string rel, boolean inside
function M.relative(path, root)
  if root and root ~= "" then
    root = root:gsub("/$", "")
    if path == root then
      return ".", true
    end
    if path:sub(1, #root + 1) == root .. "/" then
      return path:sub(#root + 2), true
    end
  end
  return vim.fn.fnamemodify(path, ":~"), false
end

--- "internal/order/order.go" -> "order/order.go"; keeps the last `n` segments.
---@param rel string
---@param n? integer
function M.tail(rel, n)
  n = n or 2
  local parts = vim.split(rel, "/", { plain = true })
  if #parts <= n then
    return rel
  end
  return table.concat(parts, "/", #parts - n + 1)
end

--- Truncate to a display width, ending with "…" when cut.
---@param s string
---@param width integer
function M.truncate(s, width)
  if width <= 0 then
    return ""
  end
  if vim.api.nvim_strwidth(s) <= width then
    return s
  end
  local out, w = {}, 0
  for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
    local cw = vim.api.nvim_strwidth(ch)
    if w + cw > width - 1 then
      break
    end
    out[#out + 1] = ch
    w = w + cw
  end
  return table.concat(out) .. "…"
end

---@param s string
---@param width integer
function M.pad(s, width)
  local w = vim.api.nvim_strwidth(s)
  if w >= width then
    return s
  end
  return s .. string.rep(" ", width - w)
end

--- Lines of a file, from its loaded buffer when there is one. Capped for safety.
---@param path string
---@param max? integer
---@return string[]
function M.read_lines(path, max)
  local bufnr = vim.fn.bufnr(path)
  if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, 0, max or -1, false)
  end
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, lines = pcall(vim.fn.readfile, path, "", max or 5000)
  return ok and lines or {}
end

--- Byte column of an LSP character offset on a line (UTF-16 by default).
---@param line string
---@param character integer
---@param encoding? string
function M.byte_col(line, character, encoding)
  local ok, col = pcall(vim.str_byteindex, line, encoding or "utf-16", character, false)
  return ok and col or math.min(character, #line)
end

--- A window that shows code (not a float, a picker, or one of spoor's own panels).
---@param win? integer
function M.is_code_window(win)
  if not (win and vim.api.nvim_win_is_valid(win)) or vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == "" and vim.bo[buf].filetype ~= "spoor"
end

--- The best code window in the current tab: `preferred` if it qualifies, else the previous
--- window, else the first code window.
---@param preferred? integer
function M.code_window(preferred)
  if M.is_code_window(preferred) then
    return preferred
  end
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if M.is_code_window(prev) then
    return prev
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if M.is_code_window(w) then
      return w
    end
  end
end

--- Debounce `fn` by `ms`; returns the wrapped function and a cancel function.
---@param ms integer
---@param fn fun(...)
function M.debounce(ms, fn)
  local timer = assert(vim.uv.new_timer())
  local function call(...)
    local args = { ... }
    timer:stop()
    timer:start(ms, 0, function()
      vim.schedule(function()
        fn(unpack(args))
      end)
    end)
  end
  return call, function()
    timer:stop()
  end
end

--- Stable id for a call hierarchy item / symbol location.
---@param uri string
---@param pos lsp.Position
function M.id(uri, pos)
  return ("%s#%d:%d"):format(uri, pos.line, pos.character)
end

--- Put text in the clipboard (and ""), or only in "" when there is no clipboard provider.
---@param text string
---@param what string e.g. "the bow-tie"
function M.copy(text, what)
  vim.fn.setreg('"', text)
  if vim.fn.has("clipboard") == 1 and pcall(vim.fn.setreg, "+", text) then
    return M.notify(("Copied %s as Mermaid"):format(what))
  end
  M.notify(('Yanked %s as Mermaid into "" (no clipboard provider)'):format(what))
end

---@param msg string
---@param level? integer
function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "spoor" })
end

--- Directory for spoor's own state (toggle, trails). Documented in :h spoor-files.
function M.state_dir()
  local dir = vim.fs.joinpath(vim.fn.stdpath("state") --[[@as string]], "spoor")
  vim.fn.mkdir(dir, "p")
  return dir
end

---@param path string
---@return table?
function M.read_json(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, data, { luanil = { object = true, array = true } })
  return ok and decoded or nil
end

---@param path string
---@param value table
function M.write_json(path, value)
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(vim.json.encode(value))
  f:close()
  assert(vim.uv.fs_rename(tmp, path))
end

--- Run a command synchronously; returns stdout lines or nil on failure.
---@param cmd string[]
---@param cwd? string
---@return string[]?, string?
function M.system(cmd, cwd)
  local ok, res = pcall(function()
    return vim.system(cmd, { cwd = cwd, text = true }):wait(5000)
  end)
  if not ok or not res or res.code ~= 0 then
    return nil, ok and res and res.stderr or tostring(res)
  end
  return vim.split(res.stdout or "", "\n", { trimempty = true })
end

return M
