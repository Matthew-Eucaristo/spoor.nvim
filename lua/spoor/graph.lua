--- Builds a bow-tie graph around one focus from the language server.
--- Progressive: `on_update(graph)` runs after each answer, so callees (cheap)
--- paint before callers (a workspace-wide search) and badges arrive last.
local Config = require("spoor.config")
local filters = require("spoor.filters")
local frameworks = require("spoor.frameworks")
local lsp = require("spoor.lsp")
local model = require("spoor.model")
local util = require("spoor.util")

local M = {}

---@class spoor.BuildOpts
---@field root string
---@field bufnr? integer
---@field depth? integer levels per side (1 = neighbours)
---@field max_items? integer
---@field timeout? integer
---@field group? spoor.Group
---@field callers? boolean false: skip the caller search (status "skipped", R fetches it)

--- What kind of use is a call site? Read from the source so every server gets
--- the same honest labels: `<Foo` is JSX, `foo(` / `foo[T](` is a call, and a
--- bare name (`HandleFunc("/x", handler)`, `onClick={save}`) is a value use.
---@param path string
---@param range lsp.Range
---@param encoding? string the server's position encoding (default utf-16)
---@return "call"|"jsx"|"ref"
function M.site_kind(path, range, encoding)
  local line = util.read_lines(path, range.start.line + 1)[range.start.line + 1]
  if not line or range["end"].line ~= range.start.line then
    return "call"
  end
  local s = util.byte_col(line, range.start.character, encoding)
  local e = util.byte_col(line, range["end"].character, encoding)
  local before = line:sub(1, s)
  local word = line:sub(s + 1, e)
  local after = line:sub(e + 1)
  if path:find("%.[jt]sx$") and before:find("<%s*$") then
    return "jsx"
  end
  if not word:match("^[%w_$.]+$") then
    return "call" -- the server gave a whole expression; trust it
  end
  if after:find("^%s*[%(%[<`!]") or after:find("^%s*%?%.%(") then
    return "call"
  end
  return "ref"
end

local function line_text(uri, line)
  local lines = util.read_lines(util.path(uri), line + 1)
  return vim.trim(lines[line + 1] or "")
end

--- Does the declaration line look like an abstract signature (no body)?
---@param node spoor.Node
function M.looks_abstract(node)
  local path = util.path(node.uri)
  local ext = path:match("%.(%w+)$") or ""
  local line = util.read_lines(path, node.selection.start.line + 1)[node.selection.start.line + 1] or ""
  if ext == "go" then
    return not line:match("^%s*func")
  elseif ext == "ts" or ext == "tsx" or ext == "js" or ext == "jsx" or ext == "mts" or ext == "cts" then
    if path:find("%.d%.[mc]?ts$") or line:find("abstract%s") then
      return true
    end
    return not line:find("{%s*$")
      and not line:find("=>")
      and not line:find("^%s*export")
      and not line:find("^%s*function")
  elseif ext == "dart" or ext == "java" or ext == "kt" or ext == "cs" then
    return line:find("abstract%s") ~= nil or (line:find(";%s*$") ~= nil and not line:find("=>"))
  end
  return node.kind == util.kinds.Method
end

---@param g spoor.Graph
---@param node spoor.Node
local function tag(g, node)
  node.tags = vim.tbl_extend("force", node.tags or {}, filters.classify(util.path(node.uri), g.root))
  return node
end

--- Visible neighbours of a node in one direction, after filters.
---@param g spoor.Graph
---@param id string
---@param dir "in"|"out"
---@param show_all? boolean
---@return spoor.Edge[] visible, table<string, integer> hidden counts by reason
function M.neighbours(g, id, dir, show_all)
  local edges = dir == "in" and model.incoming(g, id) or model.outgoing(g, id)
  local visible, hidden = {}, {}
  for _, e in ipairs(edges) do
    local other = g.nodes[dir == "in" and e.from or e.to]
    local reason = other and filters.hidden_reason(other.tags, show_all)
    if reason then
      hidden[reason] = (hidden[reason] or 0) + 1
    elseif other then
      visible[#visible + 1] = e
    end
  end
  return visible, hidden
end

---@param g spoor.Graph
---@param node spoor.Node
---@param client vim.lsp.Client
---@param opts spoor.BuildOpts
---@param done fun()
local function fetch_out(g, node, client, opts, done)
  lsp.request(client, "callHierarchy/outgoingCalls", { item = node.item }, opts, function(err, calls)
    if node.id == g.focus then
      g.status.outgoing = err and (err.timeout and "timeout" or "error") or "done"
      g.status.message = err and err.message or g.status.message
    end
    local path = util.path(node.uri)
    for _, call in ipairs(calls or {}) do
      local to = model.add_node(g, tag(g, model.node(call.to)))
      local site = call.fromRanges and call.fromRanges[1]
      local kind = site and M.site_kind(path, site, client.offset_encoding) or "call"
      model.add_edge(g, { from = node.id, to = to.id, kind = kind, sites = call.fromRanges, source = "lsp" })
    end
    g.expanded[node.id .. ">out"] = true
    done()
  end)
end

---@param g spoor.Graph
---@param node spoor.Node
---@param client vim.lsp.Client
---@param opts spoor.BuildOpts
---@param done fun()
local function fetch_in(g, node, client, opts, done)
  lsp.request(client, "callHierarchy/incomingCalls", { item = node.item }, opts, function(err, calls)
    if node.id == g.focus then
      g.status.incoming = err and (err.timeout and "timeout" or "error") or "done"
      g.status.message = err and err.message or g.status.message
    end
    for _, call in ipairs(calls or {}) do
      local from = model.add_node(g, tag(g, model.node(call.from)))
      local site = call.fromRanges and call.fromRanges[1]
      local kind = site and M.site_kind(util.path(from.uri), site, client.offset_encoding) or "call"
      model.add_edge(g, { from = from.id, to = node.id, kind = kind, sites = call.fromRanges, source = "lsp" })
    end
    g.expanded[node.id .. "<in"] = true
    done()
  end)
end

--- "Used as a value" sites: references that are not call sites (handlers, callbacks, props).
---@param g spoor.Graph
---@param client vim.lsp.Client
---@param opts spoor.BuildOpts
---@param done fun()
local function fetch_value_refs(g, client, opts, done)
  local focus = g.nodes[g.focus]
  if not client:supports_method("textDocument/references") then
    return done()
  end
  local params = {
    textDocument = { uri = focus.uri },
    position = focus.selection.start,
    context = { includeDeclaration = false },
  }
  lsp.request(client, "textDocument/references", params, opts, function(_, locations)
    local calls = {}
    for _, e in ipairs(model.incoming(g, focus.id)) do
      local from = g.nodes[e.from]
      for _, r in ipairs(e.sites) do
        calls[util.id(from.uri, r.start)] = true
      end
    end
    local n = 0
    for _, loc in ipairs(locations or {}) do
      local uri, range = loc.uri or loc.targetUri, loc.range or loc.targetSelectionRange
      local id = util.id(uri, range.start)
      local self_site = uri == focus.uri and range.start.line == focus.selection.start.line
      if not calls[id] and not self_site and n < (opts.max_items or 12) then
        n = n + 1
        local ref = tag(g, {
          id = id,
          name = line_text(uri, range.start.line),
          kind = 0,
          uri = uri,
          range = range,
          selection = range,
          tags = { value = true },
        })
        model.add_node(g, ref)
        model.add_edge(g, { from = id, to = focus.id, kind = "ref", sites = { range }, source = "lsp" })
      end
    end
    done()
  end)
end

--- ◇N badges: ask for implementations of method callees that look abstract.
---@param g spoor.Graph
---@param client vim.lsp.Client
---@param opts spoor.BuildOpts
---@param done fun()
local function fetch_impls(g, client, opts, done)
  if not Config.options.implementations or not client:supports_method("textDocument/implementation") then
    return done()
  end
  local pending, budget = 0, Config.options.max_implementation_lookups
  local visible = M.neighbours(g, g.focus, "out")
  for _, e in ipairs(visible) do
    local node = g.nodes[e.to]
    local callable = node.kind == util.kinds.Method or node.kind == util.kinds.Function
    if budget > 0 and callable and node.impls == nil and M.looks_abstract(node) then
      budget, pending = budget - 1, pending + 1
      local params = { textDocument = { uri = node.uri }, position = node.selection.start }
      lsp.request(client, "textDocument/implementation", params, opts, function(_, result)
        local impls = {}
        if result and result.uri then
          result = { result }
        end
        for _, loc in ipairs(result or {}) do
          local uri, range = loc.uri or loc.targetUri, loc.range or loc.targetSelectionRange
          if not (uri == node.uri and range.start.line == node.selection.start.line) then
            impls[#impls + 1] = { uri = uri, range = range }
          end
        end
        node.impls = #impls
        node.implementations = impls
        if #impls > 0 then
          node.tags.interface = true
        end
        pending = pending - 1
        if pending == 0 then
          done()
        end
      end)
    end
  end
  if pending == 0 then
    done()
  end
end

--- Open one more level from `id` in a direction (float <Tab>, auto depth).
---@param g spoor.Graph
---@param id string
---@param dir "in"|"out"
---@param client vim.lsp.Client
---@param opts spoor.BuildOpts
---@param on_done fun()
function M.expand(g, id, dir, client, opts, on_done)
  local node = g.nodes[id]
  local key = id .. (dir == "in" and "<in" or ">out")
  if not node or not node.item or g.expanded[key] or vim.tbl_count(g.nodes) >= Config.options.max_nodes then
    return on_done()
  end
  if dir == "in" then
    fetch_in(g, node, client, opts, on_done)
  else
    fetch_out(g, node, client, opts, on_done)
  end
end

--- Build a bow-tie around `item`.
---@param client vim.lsp.Client
---@param item lsp.CallHierarchyItem
---@param opts spoor.BuildOpts
---@param on_update fun(g: spoor.Graph, phase: string)
---@return spoor.Graph
function M.build(client, item, opts, on_update)
  local focus = model.node(item)
  local g = model.graph(focus, { server = client.name, root = opts.root })
  tag(g, focus)
  if Config.options.frameworks then
    local rule = frameworks.detect(focus, opts.root)
    if rule then
      focus.framework =
        { id = rule.id, label = rule.label, only_if_empty = rule.only_if_empty, skip_incoming = rule.skip_incoming }
    end
  end
  opts.group = opts.group or lsp.group()
  local depth = opts.depth or 1
  local max_items = opts.max_items or 12

  -- g.complete turns true once every phase (badges and value references included) has
  -- answered, so caches never keep a half-built bow-tie
  local open = 0
  local function begin()
    open = open + 1
  end
  local function finish(phase)
    on_update(g, phase)
    open = open - 1
    if open == 0 then
      g.complete = true
      on_update(g, "complete")
    end
  end

  local function deeper(dir)
    if depth < 2 then
      return
    end
    local visible = M.neighbours(g, g.focus, dir)
    for i = 1, math.min(#visible, max_items) do
      local e = visible[i]
      local id = dir == "in" and e.from or e.to
      if g.nodes[id].item then
        begin()
        M.expand(g, id, dir, client, opts, function()
          finish(dir == "in" and "callers2" or "callees2")
        end)
      end
    end
  end

  begin()
  fetch_out(g, focus, client, opts, function()
    begin()
    fetch_impls(g, client, opts, function()
      finish("impls")
    end)
    deeper("out")
    finish("callees")
  end)
  local framework_only = focus.framework and focus.framework.skip_incoming
  if framework_only or opts.callers == false then
    g.status.incoming = framework_only and "done" or "skipped"
    begin()
    vim.schedule(function()
      finish("callers")
    end)
    return g
  end
  begin()
  fetch_in(g, focus, client, opts, function()
    local visible = M.neighbours(g, g.focus, "in")
    if #visible == 0 and Config.options.references and g.status.incoming == "done" then
      begin()
      fetch_value_refs(g, client, opts, function()
        finish("refs")
      end)
    end
    deeper("in")
    finish("callers")
  end)
  return g
end

return M
