--- The graph and trail model. Plain tables that serialize to JSON, so a future
--- CLI (or an optional AI module) can read exactly what the editor shows.
---
--- graph = { version, focus, nodes = { [id] = node }, edges = { edge, ... }, status, server, root, source }
--- node  = { id, name, kind, detail, uri, range, selection, tags = { [tag] = true }, impls?, framework? }
--- edge  = { from, to, kind = "call"|"ref"|"jsx"|"impl"|"framework", sites = { range, ... }, source = "lsp"|"syntax" }
local util = require("spoor.util")

local M = {}

M.VERSION = 1

---@class spoor.Node
---@field id string
---@field name string
---@field kind integer LSP SymbolKind
---@field detail? string
---@field uri string
---@field range lsp.Range
---@field selection lsp.Range
---@field tags table<string, boolean>
---@field impls? integer implementations, when the node is an interface/abstract method
---@field framework? {id: string, label: string, only_if_empty?: boolean, skip_incoming?: boolean}
---@field implementations? {uri: string, range: lsp.Range}[]
---@field item? lsp.CallHierarchyItem the server's item, kept for follow-up requests
---@field text? string source line, for "used as a value" sites

---@class spoor.Edge
---@field from string
---@field to string
---@field kind "call"|"ref"|"jsx"|"impl"|"framework"
---@field sites lsp.Range[]
---@field source "lsp"|"framework"|"syntax"

---@class spoor.Graph
---@field version integer
---@field focus string
---@field nodes table<string, spoor.Node>
---@field edges spoor.Edge[]
---@field status {incoming: string, outgoing: string, message?: string}
---@field encoding? string the server's position encoding
---@field server? string
---@field root? string
---@field expanded table<string, boolean>
---@field source? "lsp"|"syntax" syntax: built from tree-sitter, this file only
---@field scope? string syntax: the file it was built from, when not the one you are in
---@field complete? boolean

---@param item lsp.CallHierarchyItem
---@return spoor.Node
function M.node(item)
  return {
    id = util.id(item.uri, item.selectionRange.start),
    name = item.name,
    kind = item.kind,
    detail = item.detail,
    uri = item.uri,
    range = item.range,
    selection = item.selectionRange,
    tags = {},
    item = item,
  }
end

---@param focus spoor.Node
---@param opts? {server?: string, root?: string}
---@return spoor.Graph
function M.graph(focus, opts)
  opts = opts or {}
  return {
    version = M.VERSION,
    focus = focus.id,
    nodes = { [focus.id] = focus },
    edges = {},
    status = { incoming = "loading", outgoing = "loading" },
    server = opts.server,
    root = opts.root,
    expanded = {},
  }
end

--- Add a node, merging with an existing one with the same id.
---@param g spoor.Graph
---@param node spoor.Node
---@return spoor.Node
function M.add_node(g, node)
  local existing = g.nodes[node.id]
  if existing then
    return existing
  end
  g.nodes[node.id] = node
  return node
end

---@param g spoor.Graph
---@param edge spoor.Edge
function M.add_edge(g, edge)
  for _, e in ipairs(g.edges) do
    if e.from == edge.from and e.to == edge.to and e.kind == edge.kind then
      vim.list_extend(e.sites, edge.sites or {})
      return e
    end
  end
  edge.sites = edge.sites or {}
  table.insert(g.edges, edge)
  return edge
end

---@param g spoor.Graph
---@param id string
---@return spoor.Edge[]
function M.incoming(g, id)
  return vim.tbl_filter(function(e)
    return e.to == id
  end, g.edges)
end

---@param g spoor.Graph
---@param id string
---@return spoor.Edge[]
function M.outgoing(g, id)
  return vim.tbl_filter(function(e)
    return e.from == id
  end, g.edges)
end

--- Portable id: "path/relative/to/root.go#line:col" instead of a file:// uri.
local function rel_id(n, root)
  local rel = util.relative(util.path(n.uri), root)
  return ("%s#%d:%d"):format(rel, n.selection.start.line, n.selection.start.character)
end

local function strip_node(n, root)
  local path = util.path(n.uri)
  local rel = util.relative(path, root)
  return {
    id = rel_id(n, root),
    name = n.name,
    kind = util.kinds[n.kind] or n.kind,
    detail = n.detail,
    path = rel,
    range = n.range,
    selection = n.selection,
    tags = vim.tbl_keys(n.tags),
    impls = n.impls,
    framework = n.framework and n.framework.label or nil,
  }
end

--- JSON-ready copy of a graph: paths relative to the project root, server items dropped.
---@param g spoor.Graph
function M.export(g)
  local nodes = {}
  for _, n in pairs(g.nodes) do
    nodes[#nodes + 1] = strip_node(n, g.root)
  end
  table.sort(nodes, function(a, b)
    return a.id < b.id
  end)
  local function id(raw)
    return g.nodes[raw] and rel_id(g.nodes[raw], g.root) or raw
  end
  local edges = vim.tbl_map(function(e)
    return { from = id(e.from), to = id(e.to), kind = e.kind, sites = e.sites, source = e.source }
  end, g.edges)
  return {
    version = g.version,
    focus = id(g.focus),
    server = g.server,
    source = g.source or "lsp",
    nodes = nodes,
    edges = edges,
  }
end

--- A trail is an ordered walk through nodes with your notes.
---@class spoor.Step
---@field node spoor.Node
---@field via? string edge kind used to arrive here
---@field note? string

---@class spoor.Trail
---@field version integer
---@field id string
---@field root string
---@field title string
---@field created integer
---@field updated integer
---@field steps spoor.Step[]

---@param root string
---@param first spoor.Node
---@return spoor.Trail
function M.trail(root, first)
  local now = os.time()
  return {
    version = M.VERSION,
    id = ("%d-%04d"):format(now, math.random(0, 9999)),
    root = root,
    title = first.name,
    created = now,
    updated = now,
    steps = { { node = M.persistable(first) } },
  }
end

--- Node fields worth saving (no server item, no transient state).
---@param n spoor.Node
---@return spoor.Node
function M.persistable(n)
  return {
    id = n.id,
    name = n.name,
    kind = n.kind,
    detail = n.detail,
    uri = n.uri,
    range = n.range,
    selection = n.selection,
    tags = vim.deepcopy(n.tags or {}),
    impls = n.impls,
    framework = n.framework,
    item = n.item,
  }
end

return M
