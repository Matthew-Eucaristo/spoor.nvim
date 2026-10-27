--- "What did the agent change": symbols touched since a git ref, each with its
--- bow-tie. New functions nobody calls are flagged; that is the classic sign of
--- an agent drifting off the path.
local Config = require("spoor.config")
local graph = require("spoor.graph")
local lsp = require("spoor.lsp")
local render = require("spoor.render")
local resolve = require("spoor.resolve")
local util = require("spoor.util")

local M = {}

local CALLABLE = {
  [util.kinds.Function] = true,
  [util.kinds.Method] = true,
  [util.kinds.Constructor] = true,
}

-- Git ----------------------------------------------------------------------

---@param root string
---@return string? ref, string label
function M.base(root, ref)
  ref = ref or Config.options.changes.base
  if ref then
    -- resolve to a commit first, so a ref can never be read as a git option
    local sha = util.system({ "git", "rev-parse", "--verify", "--quiet", "--end-of-options", ref .. "^{commit}" }, root)
    if not sha then
      return nil, "unknown ref " .. ref
    end
    return sha[1], ref
  end
  local default
  local head = util.system({ "git", "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD" }, root)
  if head and head[1] then
    default = head[1]
  else
    for _, b in ipairs({ "main", "master", "trunk", "develop" }) do
      if util.system({ "git", "rev-parse", "--verify", "--quiet", b }, root) then
        default = b
        break
      end
    end
  end
  if default then
    local mb = util.system({ "git", "merge-base", "HEAD", default }, root)
    local rev = util.system({ "git", "rev-parse", "HEAD" }, root)
    if mb and rev and mb[1] ~= rev[1] then
      return mb[1], default
    end
  end
  if util.system({ "git", "rev-parse", "--verify", "--quiet", "HEAD" }, root) then
    return "HEAD", "HEAD (uncommitted)"
  end
  return nil, "no commits"
end

---@class spoor.Hunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer

---@class spoor.FileDiff
---@field path string relative to the repo root
---@field hunks spoor.Hunk[]
---@field new boolean
---@field deleted boolean
---@field abs? string absolute path
---@field old_has? fun(name: string): boolean

--- Parse `git diff -U0` output.
---@param lines string[]
---@return spoor.FileDiff[]
function M.parse_diff(lines)
  local files, cur = {}, nil
  for _, l in ipairs(lines) do
    if l:find("^diff %-%-git ") then
      cur = { hunks = {}, new = false, deleted = false }
      files[#files + 1] = cur
    elseif cur and l:find("^new file mode") then
      cur.new = true
    elseif cur and l:find("^deleted file mode") then
      cur.deleted = true
    elseif cur and l:find("^%+%+%+ ") then
      -- `git diff` adds a tab after paths with spaces
      local p = l:match("^%+%+%+ b/(.-)\t?$")
      if p then
        cur.path = p
      end
    elseif cur and l:find("^rename from ") then
      cur.old_path = l:match("^rename from (.*)$")
    elseif cur and l:find("^%-%-%- ") and not cur.path then
      cur.old_path = cur.old_path or l:match("^%-%-%- a/(.-)\t?$")
    elseif cur and l:find("^@@") then
      local os_, oc, ns_, nc = l:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      if os_ then
        cur.hunks[#cur.hunks + 1] = {
          old_start = tonumber(os_),
          old_count = oc == "" and 1 or tonumber(oc),
          new_start = tonumber(ns_),
          new_count = nc == "" and 1 or tonumber(nc),
        }
      end
    end
  end
  return vim.tbl_filter(function(f)
    return f.path ~= nil and not f.deleted
  end, files)
end

---@param root string
---@param ref string
---@return spoor.FileDiff[]?, string?
function M.diff(root, ref)
  local top = util.system({ "git", "rev-parse", "--show-toplevel" }, root)
  if not top then
    return nil, "not a git repository"
  end
  -- fixed prefixes and unquoted paths, whatever the user's diff settings
  local lines, err = util.system({
    "git",
    "-c",
    "core.quotePath=false",
    "diff",
    "-U0",
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--src-prefix=a/",
    "--dst-prefix=b/",
    ref,
    "--",
  }, top[1])
  if not lines then
    return nil, err
  end
  local files = M.parse_diff(lines)
  local untracked = { "git", "-c", "core.quotePath=false", "ls-files", "--others", "--exclude-standard" }
  for _, p in ipairs(util.system(untracked, top[1]) or {}) do
    files[#files + 1] = { path = p, hunks = {}, new = true, deleted = false }
  end
  for _, f in ipairs(files) do
    f.abs = vim.fs.joinpath(top[1], f.path)
  end
  -- submodules show up as paths too; they have no symbols of their own here
  files = vim.tbl_filter(function(f)
    return vim.fn.isdirectory(f.abs) == 0
  end, files)
  for _, f in ipairs(files) do
    if not f.new then
      local old
      f.old_has = function(name)
        local path = f.old_path or f.path -- renamed files: compare with the old name
        old = old or table.concat(util.system({ "git", "show", ref .. ":" .. path }, top[1]) or {}, "\n")
        return old:find("%f[%w_]" .. vim.pesc(name) .. "%f[^%w_]") ~= nil
      end
    end
  end
  return files
end

-- Symbols -------------------------------------------------------------------

--- Flatten DocumentSymbol[] / SymbolInformation[] with depth.
local function flatten(symbols)
  local out = {}
  local function walk(list, depth)
    for _, s in ipairs(list or {}) do
      local range = s.range or (s.location and s.location.range)
      if range then
        out[#out + 1] = { symbol = s, range = range, depth = depth, sel = s.selectionRange or range }
      end
      walk(s.children, depth + 1)
    end
  end
  walk(symbols, 0)
  return out
end

---@class spoor.Changed
---@field name string
---@field kind integer
---@field range lsp.Range
---@field selection lsp.Range
---@field status "new"|"modified"|"top"
---@field added integer
---@field removed integer

--- Symbols touched by hunks: the innermost symbol around each changed line.
---@param symbols table[]
---@param hunks spoor.Hunk[]
---@param new_file boolean
---@param line_count integer
---@param old_has? fun(name: string): boolean does the name appear in the old version of the file?
---@return spoor.Changed[]
function M.touched(symbols, hunks, new_file, line_count, old_has)
  local flat = flatten(symbols)
  local function innermost(line0)
    local best
    for _, f in ipairs(flat) do
      if line0 >= f.range.start.line and line0 <= f.range["end"].line then
        if
          not best
          or f.depth > best.depth
          or (f.range["end"].line - f.range.start.line) < (best.range["end"].line - best.range.start.line)
        then
          best = f
        end
      end
    end
    return best
  end
  if new_file then
    hunks = { { old_start = 0, old_count = 0, new_start = 1, new_count = line_count } }
  end
  local by, order = {}, {}
  local function hit(f, line0, added, removed)
    local key = f and (f.sel.start.line .. ":" .. f.sel.start.character) or ("top:" .. line0)
    local c = by[key]
    if not c then
      c = f
          and {
            name = f.symbol.name,
            kind = f.symbol.kind,
            range = f.range,
            selection = f.sel,
            added = 0,
            removed = 0,
            lines = {},
          }
        or {
          name = "(top level)",
          kind = util.kinds.File,
          range = { start = { line = line0, character = 0 }, ["end"] = { line = line0, character = 0 } },
          selection = { start = { line = line0, character = 0 }, ["end"] = { line = line0, character = 0 } },
          added = 0,
          removed = 0,
          lines = {},
        }
      by[key] = c
      order[#order + 1] = key
    end
    c.added, c.removed = c.added + added, c.removed + removed
    if added > 0 then
      c.lines[line0] = true
    end
  end
  for _, h in ipairs(hunks) do
    if h.new_count == 0 then
      -- pure deletion after line new_start (1-based)
      local line0 = math.max(h.new_start - 1, 0)
      hit(innermost(line0), line0, 0, h.old_count)
    else
      for l = h.new_start, h.new_start + h.new_count - 1 do
        hit(innermost(l - 1), l - 1, 1, 0)
      end
      -- attribute removed lines to the symbol at the hunk start
      if h.old_count > 0 then
        local line0 = h.new_start - 1
        local key_f = innermost(line0)
        hit(key_f, line0, 0, h.old_count)
      end
    end
  end
  local out = {}
  for _, key in ipairs(order) do
    local c = by[key]
    -- new: its name line was added and the name is nowhere in the old file
    -- (diffs often pair a new function's closing brace with an old one)
    if key:find("^top:") then
      c.status = "top"
    elseif new_file or (c.lines[c.selection.start.line] and not (old_has and old_has(c.name))) then
      c.status = "new"
    else
      c.status = "modified"
    end
    c.lines = nil
    out[#out + 1] = c
  end
  -- lines outside every symbol (imports, doc comments, blank lines) only get a row
  -- of their own when nothing else in the file changed
  local symbols_hit, top = {}, nil
  for _, c in ipairs(out) do
    if c.status == "top" then
      if top then
        top.added, top.removed = top.added + c.added, top.removed + c.removed
      else
        top = c
      end
    else
      symbols_hit[#symbols_hit + 1] = c
    end
  end
  if #symbols_hit == 0 and top then
    return { top }
  end
  return symbols_hit
end

-- Picker --------------------------------------------------------------------

---@param bufnr integer
---@param cb fun(client: vim.lsp.Client?)
local function when_attached(bufnr, cb)
  local client = lsp.client(bufnr, "textDocument/documentSymbol")
  if client then
    return cb(client)
  end
  -- a running server for this filetype attaches right away; otherwise give a new one a moment
  local ft, known = vim.bo[bufnr].filetype, false
  for _, c in ipairs(vim.lsp.get_clients()) do
    if vim.tbl_contains(c.config.filetypes or {}, ft) then
      known = true
    end
  end
  if ft == "" or ft == "markdown" or ft == "text" or ft == "json" then
    return cb(nil)
  end
  local done = false
  local id = vim.api.nvim_create_autocmd("LspAttach", {
    buffer = bufnr,
    callback = function()
      local c = lsp.client(bufnr, "textDocument/documentSymbol")
      if c and not done then
        done = true
        vim.schedule(function()
          cb(c)
        end)
        return true
      end
    end,
  })
  vim.defer_fn(function()
    if not done then
      done = true
      pcall(vim.api.nvim_del_autocmd, id)
      cb(nil)
    end
  end, known and 4000 or 1500)
end

--- Buffers this picker loaded, unloaded again when it closes.
local loaded = {}

--- Byte column of an LSP position in a loaded buffer.
local function byte_col(bufnr, pos, client)
  local line = vim.api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1] or ""
  return util.byte_col(line, pos.character, client and client.offset_encoding)
end

--- Load a file into a hidden, unlisted buffer so its language server attaches.
local function load_buffer(path)
  local bufnr = vim.fn.bufadd(path)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    loaded[bufnr] = true
    vim.bo[bufnr].buflisted = false
    vim.fn.bufload(bufnr)
    if vim.bo[bufnr].filetype == "" then
      local ft = vim.filetype.match({ buf = bufnr })
      if ft then
        vim.bo[bufnr].filetype = ft
      end
    end
  end
  return bufnr
end

--- Collect changed symbols, then call `cb(items, label)`.
---@param opts {ref?: string, root?: string}
---@param cb fun(items: table[], label: string, err?: string)
function M.collect(opts, cb)
  local root = opts.root or util.root(0, lsp.client(0))
  local ref, label = M.base(root, opts.ref)
  if not ref then
    return cb({}, label, "no commits to compare against")
  end
  local files, err = M.diff(root, ref)
  if not files then
    return cb({}, label, err)
  end
  local max = Config.options.changes.max_files
  local items, pending = {}, 0
  local function finish()
    table.sort(items, function(a, b)
      if a.file ~= b.file then
        return a.file < b.file
      end
      return a.pos[1] < b.pos[1]
    end)
    cb(items, label)
  end
  local group = lsp.group()
  for i, f in ipairs(files) do
    if i > max then
      break
    end
    if vim.fn.filereadable(f.abs) == 1 then
      pending = pending + 1
      local bufnr = load_buffer(f.abs)
      when_attached(bufnr, function(client)
        local function add(symbols)
          local count = vim.api.nvim_buf_line_count(bufnr)
          for _, c in ipairs(M.touched(symbols or {}, f.hunks, f.new, count, f.old_has)) do
            items[#items + 1] = {
              text = c.name .. " " .. f.path,
              name = c.name,
              kind = c.kind,
              status = c.status,
              added = c.added,
              removed = c.removed,
              file = f.abs,
              rel = f.path,
              pos = { c.selection.start.line + 1, byte_col(bufnr, c.selection.start, client) },
              lsp_pos = c.selection.start,
              bufnr = bufnr,
              client = client,
              callable = CALLABLE[c.kind] or false,
            }
          end
        end
        local function counted()
          pending = pending - 1
          if pending == 0 then
            finish()
          end
        end
        if not client then
          add({})
          return counted()
        end
        resolve.document_symbols(client, bufnr, { group = group }, function(symbols)
          add(symbols)
          -- caller counts for new callables: "new and nobody calls it" stands out
          local waits = 1 -- held until the loop has sent everything
          local function settle()
            waits = waits - 1
            if waits == 0 then
              counted()
            end
          end
          for _, it in ipairs(items) do
            if it.bufnr == bufnr and it.callable and it.status == "new" then
              waits = waits + 1
              resolve.at(client, bufnr, it.lsp_pos, { group = group }, function(hitem)
                it.hitem = hitem
                if not hitem then
                  return settle()
                end
                local params = { item = hitem }
                lsp.request(client, "callHierarchy/incomingCalls", params, { group = group }, function(e, calls)
                  it.callers = not e and calls and #calls or nil
                  settle()
                end)
              end)
            end
          end
          settle()
        end)
      end)
    end
  end
  if pending == 0 then
    finish()
  end
end

local ns = vim.api.nvim_create_namespace("spoor.changes")
local graphs = {}

--- Preview: the bow-tie of the highlighted symbol, built lazily.
local function preview(ctx)
  local item = ctx.item
  ctx.preview:reset()
  ctx.preview:set_title(item.name)
  ctx.preview:wo({ number = false, relativenumber = false, signcolumn = "no", statuscolumn = "", foldcolumn = "0" })
  local buf = ctx.buf
  local win = ctx.preview.win.win
  local function paint(g)
    if not (vim.api.nvim_buf_is_valid(buf) and ctx.picker:current() == item) then
      return
    end
    local r = render.bowtie(g, { width = vim.api.nvim_win_get_width(win) - 1, max_items = 8 })
    ctx.preview:set_lines(r.lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(r.hls) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.row, h.col, { end_col = h.end_col, hl_group = h.group })
    end
  end
  if not (item.client and item.callable) then
    ctx.preview:set_lines({
      "",
      "  " .. (item.status == "top" and "Changes outside any symbol." or "Not a function: no call hierarchy."),
    })
    return
  end
  local key = item.file .. ":" .. item.pos[1] .. ":" .. item.pos[2]
  if graphs[key] then
    return paint(graphs[key])
  end
  ctx.preview:set_lines({ "", "  ⋯" })
  if M.preview_group then
    M.preview_group:cancel()
  end
  M.preview_group = lsp.group()
  local function build(hitem)
    if not hitem then
      if ctx.picker:current() == item then
        ctx.preview:set_lines({ "", "  No call hierarchy here." })
      end
      return
    end
    graph.build(item.client, hitem, { root = util.root(item.bufnr, item.client), group = M.preview_group }, function(g)
      if g.complete then
        graphs[key] = g -- only finished bow-ties; a cancelled one is rebuilt next time
      end
      paint(g)
    end)
  end
  if item.hitem then
    build(item.hitem)
  else
    resolve.at(item.client, item.bufnr, item.lsp_pos, { group = M.preview_group }, build)
  end
end

local function format(item)
  local ic = Config.options.icons
  local icons = require("spoor.icons")
  local status = item.status == "new" and { ic.new, "SpoorAdd" }
    or item.status == "top" and { "·", "SpoorDim" }
    or { ic.modified, "SpoorChange" }
  local icon, icon_hl = icons.kind(item.kind)
  local out = {
    { status[1] .. " ", status[2] },
    { icon .. " ", icon_hl },
    { util.pad(util.truncate(item.name, 26), 26), "SpoorName" },
    { " " .. util.pad(util.truncate(util.tail(item.rel, 2), 30), 30), "SpoorLoc" },
  }
  if item.status == "new" then
    out[#out + 1] = { "  new", "SpoorAdd" }
  else
    out[#out + 1] = { ("  +%d −%d"):format(item.added, item.removed), "SpoorDim" }
  end
  if item.callers == 0 then
    out[#out + 1] = { "  " .. ic.warn .. " 0 callers", "SpoorWarn" }
  elseif item.callers then
    out[#out + 1] = { ("  %d caller%s"):format(item.callers, item.callers == 1 and "" or "s"), "SpoorDim" }
  end
  return out
end

--- Unload the hidden buffers the picker loaded, unless you opened or changed them.
function M.unload()
  for bufnr in pairs(loaded) do
    local hidden = vim.api.nvim_buf_is_valid(bufnr) and vim.fn.bufwinid(bufnr) == -1 and not vim.bo[bufnr].buflisted
    if hidden and not vim.bo[bufnr].modified then
      pcall(vim.api.nvim_buf_delete, bufnr, {})
    end
  end
  loaded = {}
end

--- Open the changes picker (<leader>cG, :Spoor changes [ref]).
---@param opts? {ref?: string}
function M.open(opts)
  opts = opts or {}
  graphs = {}
  local slow = vim.defer_fn(function()
    util.notify("Reading changed files…")
  end, 500)
  M.collect(opts, function(items, label, err)
    if not slow:is_closing() then
      slow:stop()
      slow:close()
    end
    if err then
      return util.notify(err, vim.log.levels.WARN)
    end
    if #items == 0 then
      return util.notify("No changes since " .. label)
    end
    local files = {}
    for _, it in ipairs(items) do
      files[it.file] = true
    end
    require("spoor.ui").pick({
      source = "spoor_changes",
      title = ("Changed since %s · %s · %s"):format(
        label,
        util.plural(#items, "symbol"),
        util.plural(vim.tbl_count(files), "file")
      ),
      items = items,
      format = format,
      preview = preview,
      layout = { preset = "vertical", layout = { width = 0.9, height = 0.9 } }, -- room for the bow-tie
      on_close = function()
        vim.schedule(M.unload)
      end,
      confirm = function(picker, item)
        picker:close()
        if not item then
          return
        end
        vim.cmd.edit(vim.fn.fnameescape(item.file))
        pcall(vim.api.nvim_win_set_cursor, 0, item.pos)
        vim.cmd("normal! zz")
        if not require("spoor.live").enabled() and item.callable then
          require("spoor.bowtie").open()
        end
      end,
    })
  end)
end

return M
