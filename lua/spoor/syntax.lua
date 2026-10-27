--- Same-file bow-tie from tree-sitter, for buffers whose language server has no call
--- hierarchy (or that have no server at all). Generic: functions and calls are found by
--- node type name ("function", "method", "call", "invocation", ...), so any tree-sitter
--- parser works without per-language queries. Labelled "syntax only · this file"; the
--- language server always wins when it can answer.
local model = require("spoor.model")
local util = require("spoor.util")

local M = {}

-- Node type names, matched as Lua patterns against each grammar's named node types.
M.def_words = { "function", "method", "constructor", "lambda", "closure", "^func_", "procedure", "subroutine" }
M.call_words = { "call", "invocation" }
-- Parts of a type name that make it something else (a call, a signature, a name, ...).
M.not_def = {
  "call",
  "invocation",
  "signature",
  "type",
  "parameter",
  "argument",
  "modifier",
  "name",
  "reference",
  "spec",
  "elem",
  "receiver",
  "builtin",
  "identifier",
  "keyword",
  "index",
  "declarator",
  "body",
  "import",
  "export",
  "field",
  "clause",
  "table", -- Lua's table_constructor and other literals are data
  "object",
  "array",
}
M.not_call = { "signature", "type", "suffix", "argument", "callable", "parameter" }
-- Languages without any such node type: their calls by name.
M.extra_calls = { bash = { "command" } }

local CALLEE_FIELDS = { "function", "name", "method", "macro", "callee", "constructor", "target" }
local NAME_FIELDS = { "name", "left", "key", "pattern" }

local function any(s, words)
  for _, w in ipairs(words) do
    if s:find(w) then
      return true
    end
  end
  return false
end

---@class spoor.SyntaxLang
---@field defs? vim.treesitter.Query
---@field calls? vim.treesitter.Query
---@field def_types table<string, boolean>
---@field call_types table<string, boolean>

---@type table<string, spoor.SyntaxLang|false>
local langs = {}

--- One query over a list of node types; types the query engine rejects are left out.
local function query(lang, types)
  if #types == 0 then
    return nil
  end
  local function src(list)
    return "["
      .. table.concat(
        vim.tbl_map(function(t)
          return "(" .. t .. ")"
        end, list),
        " "
      )
      .. "] @node"
  end
  local ok, q = pcall(vim.treesitter.query.parse, lang, src(types))
  if ok then
    return q
  end
  local valid = vim.tbl_filter(function(t)
    return (pcall(vim.treesitter.query.parse, lang, src({ t })))
  end, types)
  return #valid > 0 and vim.treesitter.query.parse(lang, src(valid)) or nil
end

--- Function and call node types of a language, from its grammar.
---@param lang string
---@return spoor.SyntaxLang?
function M.lang(lang)
  if langs[lang] ~= nil then
    return langs[lang] or nil
  end
  local ok, info = pcall(vim.treesitter.language.inspect, lang)
  if not ok or type(info.symbols) ~= "table" then
    langs[lang] = false
    return nil
  end
  local defs, calls = {}, {}
  for name, named in pairs(info.symbols) do
    if named == true and type(name) == "string" and not name:find("^_") then
      if any(name, M.call_words) and not any(name, M.not_call) then
        calls[#calls + 1] = name
      elseif any(name, M.def_words) and not any(name, M.not_def) then
        defs[#defs + 1] = name
      end
    end
  end
  vim.list_extend(calls, M.extra_calls[lang] or {})
  table.sort(defs)
  table.sort(calls)
  local l = {
    defs = query(lang, defs),
    calls = query(lang, calls),
    def_types = {},
    call_types = {},
  }
  for _, t in ipairs(defs) do
    l.def_types[t] = true
  end
  for _, t in ipairs(calls) do
    l.call_types[t] = true
  end
  langs[lang] = l
  return l
end

local function text(node, buf)
  local ok, t = pcall(vim.treesitter.get_node_text, node, buf)
  return ok and t or ""
end

--- "M.foo" -> "foo", "a:b" -> "b", "Foo::bar" -> "bar", "println!" -> "println"
local function key_of(name)
  return name:match("([%a_$][%w_$]*)[!?]?%s*$")
end

local function contains(outer, inner)
  local sr, sc, er, ec = outer:range()
  local isr, isc, ier, iec = inner:range()
  return (isr > sr or (isr == sr and isc >= sc)) and (ier < er or (ier == er and iec <= ec))
end

--- The node that names a function: its name field, a C declarator, or what it is assigned to.
---@param node TSNode
---@param l spoor.SyntaxLang
local function name_node(node, l)
  local n = node:field("name")[1]
  if n then
    return n
  end
  local d = node:field("declarator")[1]
  while d and d:field("declarator")[1] do
    d = d:field("declarator")[1]
  end
  if d then
    return d
  end
  -- `local f = function`, `const f = () =>`, `f := func`, `{ f = function }`; not `g(function)`
  local child, anc = node, node:parent()
  for _ = 1, 3 do
    if not anc or l.call_types[anc:type()] or anc:type():find("argument") or l.def_types[anc:type()] then
      return nil
    end
    for _, f in ipairs(NAME_FIELDS) do
      local c = anc:field(f)[1]
      if c and not contains(c, node) then
        return c
      end
    end
    local first = anc:named_child(0)
    if first and first ~= child and not contains(first, node) and first:type():find("list") then
      return first:field("name")[1] or first:named_child(0)
    end
    child, anc = anc, anc:parent()
  end
end

--- What a call calls: its function/name/method field, else its first child.
---@param call TSNode
local function callee_node(call)
  for _, f in ipairs(CALLEE_FIELDS) do
    local c = call:field(f)[1]
    if c then
      return c
    end
  end
  return call:named_child(0)
end

local function kind_of(t)
  if t:find("constructor") then
    return util.kinds.Constructor
  elseif t:find("method") then
    return util.kinds.Method
  end
  return util.kinds.Function
end

---@class spoor.SyntaxDef
---@field node TSNode
---@field name string
---@field key string
---@field kind integer
---@field sel integer[] {row, col, end_row, end_col} of the name

---@class spoor.SyntaxIndex
---@field tick integer
---@field lang string
---@field l spoor.SyntaxLang
---@field root TSNode
---@field lines string[]
---@field defs spoor.SyntaxDef[]
---@field by_key table<string, spoor.SyntaxDef[]>
---@field by_id table<string, spoor.SyntaxDef>
---@field names table<string, boolean> "row:col" where each function's key starts in its name

---@type table<integer, spoor.SyntaxIndex>
local cache = {}

--- Index the named functions of one tree (cached per buffer, edit and language tree).
---@param buf integer
---@param lang string
---@param root TSNode
---@return spoor.SyntaxIndex?
local function index(buf, lang, root)
  local tick = vim.b[buf].changedtick
  local c = cache[buf]
  if c and c.tick == tick and c.lang == lang and c.root:equal(root) then
    return c
  end
  local l = M.lang(lang)
  if not (l and l.defs) then
    return nil
  end
  local idx = {
    tick = tick,
    lang = lang,
    l = l,
    root = root,
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    defs = {},
    by_key = {},
    by_id = {},
    names = {},
  }
  for _, node in l.defs:iter_captures(root, buf) do
    local n = name_node(node, l)
    local name = n and vim.trim(text(n, buf))
    local key = name and not name:find("\n") and key_of(name)
    if key then
      local sr, sc, er, ec = n:range()
      local def = { node = node, name = name, key = key, kind = kind_of(node:type()), sel = { sr, sc, er, ec } }
      idx.defs[#idx.defs + 1] = def
      idx.by_key[key] = idx.by_key[key] or {}
      table.insert(idx.by_key[key], def)
      idx.by_id[node:id()] = def
      -- where the key itself starts: "process" in "M.process"
      idx.names[sr .. ":" .. (sc + name:find(vim.pesc(key) .. "[!?]?%s*$") - 1)] = true
    end
  end
  for b in pairs(cache) do
    if not vim.api.nvim_buf_is_valid(b) then
      cache[b] = nil
    end
  end
  cache[buf] = idx
  return idx
end

--- The innermost named function around a node, or nil at the top level.
---@param idx spoor.SyntaxIndex
---@param node TSNode?
local function enclosing(idx, node)
  while node do
    local def = idx.by_id[node:id()]
    if def then
      return def
    end
    node = node:parent()
  end
end

--- Is `node` what a call calls (the `foo` in `foo(x)` or `a.foo(x)`)?
---@param idx spoor.SyntaxIndex
---@param node TSNode
local function is_callee(idx, node)
  local anc = node:parent()
  for _ = 1, 4 do
    if not anc then
      return false
    end
    if idx.l.call_types[anc:type()] then
      local c = callee_node(anc)
      return c ~= nil and contains(c, node)
    end
    anc = anc:parent()
  end
  return false
end

local function range(r)
  return { start = { line = r[1], character = r[2] }, ["end"] = { line = r[3], character = r[4] } }
end

--- A graph node for a function in this file.
---@param def spoor.SyntaxDef
---@param uri string
---@return spoor.Node
local function def_node(def, uri)
  local sr, sc, er, ec = def.node:range()
  local sel = range(def.sel)
  return {
    id = util.id(uri, sel.start),
    name = def.name,
    kind = def.kind,
    uri = uri,
    range = range({ sr, sc, er, ec }),
    selection = sel,
    tags = {},
  }
end

--- Short label for a callee: `fmt.Println`, `self.save`, or just the name.
local function callee_label(t, key)
  t = vim.trim((t:match("^[^\n]*")))
  if #t <= 48 and t:match("^[%w_$.:%->]+$") and not t:find("^[.:%->]") then
    return t
  end
  return key
end

--- Build a bow-tie for the function `def`: callees inside it, callers anywhere in this file.
---@param idx spoor.SyntaxIndex
---@param buf integer
---@param def spoor.SyntaxDef
---@return spoor.Graph
local function build(idx, buf, def)
  local uri = vim.uri_from_bufnr(buf)
  local root = util.root(buf)
  local focus = def_node(def, uri)
  local g = model.graph(focus, { root = root })
  g.source, g.encoding, g.complete = "syntax", "utf-8", true
  g.status = { incoming = "done", outgoing = "done" }
  local fw = require("spoor.config").options.frameworks and require("spoor.frameworks").detect(focus, root)
  if fw then
    focus.framework = { id = fw.id, label = fw.label, only_if_empty = fw.only_if_empty }
  end

  -- callees: every call inside the function, linked to its definition when it is in this file
  if idx.l.calls then
    local sr, _, er = def.node:range()
    for _, call in idx.l.calls:iter_captures(def.node, buf, sr, er + 1) do
      local c = callee_node(call)
      if c and not idx.l.call_types[c:type()] then -- `call foo()` statements wrap the call itself
        local t = text(c, buf)
        local key = key_of((t:match("^[^(\n]*")))
        if key then
          local csr, csc, cer, cec = c:range()
          local site = range({ csr, csc, cer, cec })
          local target = idx.by_key[key] and idx.by_key[key][1]
          local to
          if target then
            to = model.add_node(g, def_node(target, uri))
          else
            to = g.nodes["syntax:" .. key]
              or model.add_node(g, {
                id = "syntax:" .. key,
                name = callee_label(t, key),
                kind = util.kinds.Function,
                uri = uri,
                range = site,
                selection = site,
                tags = { outside = true }, -- defined in another file, or not a function at all
              })
          end
          model.add_edge(g, { from = focus.id, to = to.id, kind = "call", sites = { site }, source = "syntax" })
        end
      end
    end
  end
  g.expanded[focus.id .. ">out"] = true

  -- callers: where this file uses the name, grouped by the function around each use
  local key = def.key
  local rs, _, re = idx.root:range()
  local top
  for row = rs, math.min(re, #idx.lines - 1) do
    local line = idx.lines[row + 1]
    local init = 1
    while true do
      local s, e = line:find(key, init, true)
      if not s then
        break
      end
      init = e + 1
      local before, after = line:sub(s - 1, s - 1), line:sub(e + 1, e + 1)
      if
        not (s > 1 and before:match("[%w_$]"))
        and not after:match("[%w_$]")
        and not idx.names[row .. ":" .. (s - 1)] -- a definition, not a use
      then
        local node = idx.root:named_descendant_for_range(row, s - 1, row, e)
        local t = node and node:type() or ""
        if node and not t:find("string") and not t:find("comment") and text(node, buf) == key then
          local site = range({ row, s - 1, row, e })
          local call = is_callee(idx, node) or line:sub(e + 1):find("^%s*[%(%[<`!]") ~= nil
          local from = enclosing(idx, node)
          local caller
          if from then
            caller = model.add_node(g, def_node(from, uri))
          else
            top = top
              or model.add_node(g, {
                id = "syntax:top",
                name = "(top level)",
                kind = util.kinds.File,
                uri = uri,
                range = site,
                selection = site,
                tags = {},
              })
            caller = top
          end
          model.add_edge(g, {
            from = caller.id,
            to = focus.id,
            kind = call and "call" or "ref",
            sites = { site },
            source = "syntax",
          })
        end
      end
    end
  end
  g.expanded[focus.id .. "<in"] = true
  return g
end

--- The language tree and its root under a position, once parsed.
---@param buf integer
---@param pos integer[] {row, col} 0-based
---@param cb fun(lang: string?, root: TSNode?)
local function tree_at(buf, pos, cb)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
  if not ok or not parser then
    return cb(nil)
  end
  local r = { pos[1], pos[2], pos[1], pos[2] }
  local function done()
    if not vim.api.nvim_buf_is_valid(buf) then
      return cb(nil)
    end
    local lt = parser:language_for_range(r)
    local tree = lt:tree_for_range(r, { ignore_injections = true }) or lt:trees()[1]
    cb(lt:lang(), tree and tree:root())
  end
  -- incremental and asynchronous: a big file never blocks typing
  local called = false
  parser:parse({ pos[1], pos[1] + 1 }, function(err)
    if called then
      return
    end
    called = true
    if err then
      return cb(nil)
    end
    done()
  end)
end

--- Build the same-file bow-tie at a position: the function there (or the one it calls).
---@param buf integer
---@param pos integer[] {row, col} 0-based, byte column
---@param cb fun(g: spoor.Graph?)
function M.at(buf, pos, cb)
  tree_at(buf, pos, function(lang, root)
    if not (lang and root) or not vim.api.nvim_buf_is_valid(buf) then
      return cb(nil)
    end
    local idx = index(buf, lang, root)
    if not idx then
      return cb(nil)
    end
    local node = root:named_descendant_for_range(pos[1], pos[2], pos[1], pos[2])
    local def
    if node then
      -- on a call to a function of this file, or on a function's name: that function
      local key = key_of(text(node, buf))
      local hits = key and idx.by_key[key]
      if hits and (is_callee(idx, node) or idx.names[table.concat({ node:range() }, ":", 1, 2)]) then
        def = hits[1]
        for _, d in ipairs(hits) do
          if d.sel[1] == pos[1] and d.sel[2] <= pos[2] and pos[2] <= d.sel[4] then
            def = d
          end
        end
      else
        def = enclosing(idx, node)
      end
    end
    if not def then
      return cb(nil)
    end
    cb(build(idx, buf, def))
  end)
end

--- The same-file bow-tie at a window's cursor.
---@param win integer
---@param cb fun(g: spoor.Graph?)
function M.at_cursor(win, cb)
  local buf = vim.api.nvim_win_get_buf(win)
  local cur = vim.api.nvim_win_get_cursor(win)
  M.at(buf, { cur[1] - 1, cur[2] }, cb)
end

--- Is there a tree-sitter parser for this buffer?
---@param buf integer
function M.available(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
  return ok and parser ~= nil
end

function M.clear_cache()
  cache, langs = {}, {}
end

return M
