--- Same-file bow-tie from tree-sitter, for buffers whose language server has no call
--- hierarchy (or that have no server at all). Generic: functions and calls are found by
--- node type name ("function", "method", "call", "invocation", ...), so any tree-sitter
--- parser works without per-language queries. On a call to a function in another file, a
--- server's go-to-definition (lua_ls has one) leads to that file. Labelled "syntax only ·
--- this file" (or that file's name); the language server always wins when it can answer.
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
---@field src integer|string the buffer, or the text of a file that is not loaded
---@field uri string
---@field project? string the project root, for file text
---@field tick? integer
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
---@param src integer|string a buffer, or a file's text
---@param lang string
---@param root TSNode
---@param o {uri: string, project?: string}
---@return spoor.SyntaxIndex?
local function index(src, lang, root, o)
  local buf = type(src) == "number" and src or nil
  local tick = buf and vim.b[buf].changedtick
  local c = buf and cache[buf]
  if c and c.tick == tick and c.lang == lang and c.root:equal(root) then
    return c
  end
  local l = M.lang(lang)
  if not (l and l.defs) then
    return nil
  end
  local idx = {
    src = src,
    uri = o.uri,
    project = o.project,
    tick = tick,
    lang = lang,
    l = l,
    root = root,
    lines = buf and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or vim.split(src --[[@as string]], "\n"),
    defs = {},
    by_key = {},
    by_id = {},
    names = {},
  }
  for _, node in l.defs:iter_captures(root, src) do
    local n = name_node(node, l)
    local name = n and vim.trim(text(n, src))
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
  if buf then
    cache[buf] = idx
  end
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

--- Build a bow-tie for the function `def`: callees inside it, callers anywhere in its file.
---@param idx spoor.SyntaxIndex
---@param def spoor.SyntaxDef
---@return spoor.Graph
local function build(idx, def)
  local buf, uri = idx.src, idx.uri
  local root = idx.project or util.root(buf --[[@as integer]])
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
---@param src integer|string a buffer, or a file's text in language `lang`
---@param pos integer[] {row, col} 0-based
---@param lang? string
---@param cb fun(lang: string?, root: TSNode?)
local function tree_at(src, pos, lang, cb)
  local ok, parser
  if type(src) == "string" then
    ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
  else
    ok, parser = pcall(vim.treesitter.get_parser, src, nil, { error = false })
  end
  if not ok or not parser then
    return cb(nil)
  end
  local r = { pos[1], pos[2], pos[1], pos[2] }
  local function done()
    if type(src) == "number" and not vim.api.nvim_buf_is_valid(src) then
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

--- Where a server's go-to-definition puts the name at `pos`, when one can tell.
---@param buf integer
---@param pos integer[] {row, col} 0-based, byte column
---@param cb fun(uri?: string, pos?: lsp.Position, encoding?: string)
local function definition(buf, pos, cb)
  local lsp = require("spoor.lsp")
  local client = lsp.client(buf, "textDocument/definition")
  if not client then
    return cb()
  end
  local line = vim.api.nvim_buf_get_lines(buf, pos[1], pos[1] + 1, false)[1] or ""
  local ok, character = pcall(vim.str_utfindex, line, client.offset_encoding, pos[2], false)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = pos[1], character = ok and character or pos[2] },
  }
  lsp.request(client, "textDocument/definition", params, { bufnr = buf }, function(err, result)
    local loc = not err and result and (result.uri or result.targetUri) and result or (result or {})[1]
    if not loc or not vim.api.nvim_buf_is_valid(buf) then
      return cb()
    end
    local r = loc.targetSelectionRange or loc.targetRange or loc.range
    cb(loc.uri or loc.targetUri, r and r.start, client.offset_encoding)
  end)
end

local function inside(sel, pos)
  return (pos[1] > sel[1] or (pos[1] == sel[1] and pos[2] >= sel[2]))
    and (pos[1] < sel[3] or (pos[1] == sel[3] and pos[2] <= sel[4]))
end

local at_file

---@param src integer|string
---@param pos integer[] {row, col} 0-based, byte column
---@param o {uri: string, lang?: string, project?: string, exact?: boolean}
---@param cb fun(g: spoor.Graph?)
local function at(src, pos, o, cb)
  tree_at(src, pos, o.lang, function(lang, root)
    if not (lang and root) or (type(src) == "number" and not vim.api.nvim_buf_is_valid(src)) then
      return cb(nil)
    end
    local idx = index(src, lang, root, o)
    if not idx then
      return cb(nil)
    end
    if o.exact then -- where go-to-definition pointed: a function named there, or nothing
      for _, d in ipairs(idx.defs) do
        if inside(d.sel, pos) then
          return cb(build(idx, d))
        end
      end
      return cb(nil)
    end
    local node = root:named_descendant_for_range(pos[1], pos[2], pos[1], pos[2])
    if not node then
      return cb(nil)
    end
    -- on a call to a function of this file, or on a function's name: that function
    local key = key_of(text(node, src))
    local hits = key and idx.by_key[key]
    if hits and (is_callee(idx, node) or idx.names[table.concat({ node:range() }, ":", 1, 2)]) then
      local def = hits[1]
      for _, d in ipairs(hits) do
        if d.sel[1] == pos[1] and d.sel[2] <= pos[2] and pos[2] <= d.sel[4] then
          def = d
        end
      end
      return cb(build(idx, def))
    end
    local around = enclosing(idx, node)
    local function fallback()
      cb(around and build(idx, around) or nil)
    end
    if not (key and type(src) == "number" and is_callee(idx, node)) then
      return fallback()
    end
    -- on a call to a function defined elsewhere: follow go-to-definition there
    definition(src, pos, function(uri, dpos, encoding)
      if not uri then
        return fallback()
      end
      at_file(uri, dpos, encoding, { exact = true, project = idx.project or util.root(src) }, function(g)
        if not g then
          return fallback()
        end
        if around and uri ~= o.uri then -- the call you are on is one of its callers
          local caller = model.add_node(g, def_node(around, o.uri))
          local site = range({ node:range() })
          model.add_edge(g, { from = caller.id, to = g.focus, kind = "call", sites = { site }, source = "syntax" })
        end
        cb(g)
      end)
    end)
  end)
end

--- A file's source for tree-sitter: its buffer when loaded, else its text (no buffer is created).
---@param path string
---@return (integer|string)? src, string[] lines, string? lang (for text)
local function source(path)
  local buf = vim.fn.bufnr(path)
  local lines = util.read_lines(path, 20000)
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
    return buf, lines
  end
  local ft = #lines > 0 and vim.filetype.match({ filename = path, contents = lines })
  local lang = ft and vim.treesitter.language.get_lang(ft)
  if not lang then
    return nil, lines
  end
  return table.concat(lines, "\n"), lines, lang
end

---@param uri string
---@param pos lsp.Position
---@param encoding? string
---@param o {exact?: boolean, project?: string}
---@param cb fun(g: spoor.Graph?)
function at_file(uri, pos, encoding, o, cb)
  local path = util.path(uri)
  local src, lines, lang = source(path)
  if not src then
    return cb(nil)
  end
  local p = { pos.line, util.byte_col(lines[pos.line + 1] or "", pos.character, encoding) }
  at(src, p, { uri = uri, lang = lang, exact = o.exact, project = o.project }, function(g)
    -- name the file when it is not the one in the code window ("syntax only · store.lua")
    local win = util.code_window(vim.api.nvim_get_current_win())
    if g and not (win and vim.uri_from_bufnr(vim.api.nvim_win_get_buf(win)) == g.nodes[g.focus].uri) then
      g.scope = vim.fs.basename(path)
    end
    cb(g)
  end)
end

--- Sites already in the graph: "uri:line:col" of every edge into the focus.
local function known_sites(g)
  local seen = {}
  for _, e in ipairs(g.edges) do
    if e.to == g.focus then
      local from = g.nodes[e.from]
      for _, site in ipairs(e.sites) do
        seen[from.uri .. ":" .. site.start.line .. ":" .. site.start.character] = true
      end
    end
  end
  return seen
end

--- Add callers from other files: each use grouped by the function around it, as a call or a
--- reference. `hits` are {uri, line, col} with a byte column.
---@param g spoor.Graph
---@param hits {uri: string, line: integer, col: integer}[]
---@param by_name boolean hits come from a name search: skip definitions and non-identifiers
local function add_callers(g, hits, by_name)
  local focus = g.nodes[g.focus]
  local key = key_of(focus.name)
  local seen = known_sites(g)
  local files, order = {}, {}
  for _, h in ipairs(hits) do
    if h.uri ~= focus.uri and not seen[h.uri .. ":" .. h.line .. ":" .. h.col] then
      if not files[h.uri] then
        files[h.uri] = {}
        order[#order + 1] = h.uri
      end
      table.insert(files[h.uri], h)
    end
  end
  for i, uri in ipairs(order) do
    if i > M.max_files then
      g.truncated = true
      break
    end
    local src, _, lang = source(util.path(uri))
    local ok, parser = false, nil
    if type(src) == "number" then
      ok, parser = pcall(vim.treesitter.get_parser, src, nil, { error = false })
    elseif src then
      ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    end
    local trees = ok and parser and parser:parse()
    local root = trees and trees[1] and trees[1]:root()
    local idx = root and index(src --[[@as integer|string]], parser:lang(), root, { uri = uri })
    -- a file with its own function of that name most likely calls its own
    local own = by_name and idx and key and idx.by_key[key]
    for _, h in ipairs(idx and not own and files[uri] or {}) do
      local node = root:named_descendant_for_range(h.line, h.col, h.line, h.col)
      local t = node and node:type() or ""
      local word = node and text(node, src --[[@as integer|string]])
      local ok_use = node and not t:find("string") and not t:find("comment")
      if by_name then -- the name itself, not another function's definition of the same name
        ok_use = ok_use and word == key and not idx.names[h.line .. ":" .. h.col]
      end
      if ok_use then
        ---@cast node TSNode
        local site = range({ node:range() })
        local from = enclosing(idx, node)
        local caller
        if from then
          caller = model.add_node(g, def_node(from, uri))
        else
          caller = model.add_node(g, {
            id = "syntax:top:" .. uri,
            name = "(top level)",
            kind = util.kinds.File,
            uri = uri,
            range = site,
            selection = site,
            tags = {},
          })
        end
        local line = idx.lines[h.line + 1] or ""
        local call = is_callee(idx, node) or line:sub(select(4, node:range()) + 1):find("^%s*[%(%[<`!]") ~= nil
        model.add_edge(
          g,
          { from = caller.id, to = focus.id, kind = call and "call" or "ref", sites = { site }, source = "syntax" }
        )
      end
    end
  end
end

--- Name-search hits for `key` in the project (git grep, same file extension as `path`).
---@param root string
---@param path string
---@param key string
---@param cb fun(hits?: {uri: string, line: integer, col: integer}[])
local function grep(root, path, key, cb)
  local ext = path:match("%.([%w_]+)$")
  local cmd = { "git", "grep", "-n", "--column", "-w", "-F", "-I", "-e", key }
  if ext then
    vim.list_extend(cmd, { "--", "*." .. ext })
  end
  local ok = pcall(vim.system, cmd, { cwd = root, text = true }, function(r)
    vim.schedule(function()
      if r.code ~= 0 then
        return cb(r.code == 1 and {} or nil) -- 1: no match; else not a git repo
      end
      local hits = {}
      for l in r.stdout:gmatch("[^\n]+") do
        local file, line, col = l:match("^(.-):(%d+):(%d+):")
        if file and #hits < M.max_hits then
          hits[#hits + 1] =
            { uri = vim.uri_from_fname(root .. "/" .. file), line = tonumber(line) - 1, col = tonumber(col) - 1 }
        end
      end
      cb(hits)
    end)
  end)
  if not ok then
    cb(nil)
  end
end

M.max_files = 60 -- files opened to place project-wide uses
M.max_hits = 400

--- Callers and references from the whole project, added to `g` in place: the server's
--- find-references when it has one, else a git grep for the name. Views showing `g` re-render.
---@param g spoor.Graph
---@param buf? integer the buffer you are in (for its language server)
function M.project(g, buf)
  local focus = g.nodes[g.focus]
  local path = util.path(focus.uri)
  buf = buf or vim.api.nvim_win_get_buf(util.code_window(vim.api.nvim_get_current_win()) or 0)
  local lsp = require("spoor.lsp")
  local client = lsp.client(buf, "textDocument/references")
  local before = g.status.incoming
  g.status.incoming = "loading"
  local function done(hits, reach, by_name)
    g.status.incoming = before
    if hits then
      add_callers(g, hits, by_name)
      g.reach = reach
    end
    require("spoor.view").refresh(g)
  end
  local function by_name()
    local root = g.root or util.root(buf)
    grep(root, path, key_of(focus.name) or focus.name, function(hits)
      done(hits, "name search", true)
    end)
  end
  if not client then
    return by_name()
  end
  -- ask at the name itself: "load" in "M.load" (at "M" a server finds the module's uses)
  local start = focus.selection.start
  local line = util.read_lines(path, start.line + 1)[start.line + 1] or ""
  local key = key_of(focus.name)
  local col = start.character + ((key and focus.name:find(vim.pesc(key) .. "[!?]?%s*$")) or 1) - 1
  local ok, character = pcall(vim.str_utfindex, line, client.offset_encoding, col, false)
  local params = {
    textDocument = { uri = focus.uri },
    position = { line = start.line, character = ok and character or col },
    context = { includeDeclaration = false },
  }
  lsp.request(client, "textDocument/references", params, { bufnr = buf }, function(err, result)
    if err or type(result) ~= "table" then
      return by_name()
    end
    local hits, lines = {}, {}
    for _, loc in ipairs(result) do
      local p = util.path(loc.uri)
      lines[p] = lines[p] or util.read_lines(p, 20000)
      local s = loc.range.start
      hits[#hits + 1] = {
        uri = loc.uri,
        line = s.line,
        col = util.byte_col(lines[p][s.line + 1] or "", s.character, client.offset_encoding),
      }
    end
    done(hits, client.name .. " references")
  end)
end

--- Callbacks that also look across the project once the file's bow-tie is shown.
local function with_project(cb, buf)
  return function(g)
    cb(g)
    if g then
      M.project(g, buf)
    end
  end
end

--- Build the bow-tie at a position: the function there (or the one it calls). Callers from
--- the rest of the project arrive afterwards (views showing the graph re-render).
---@param buf integer
---@param pos integer[] {row, col} 0-based, byte column
---@param cb fun(g: spoor.Graph?)
function M.at(buf, pos, cb)
  at(buf, pos, { uri = vim.uri_from_bufnr(buf) }, with_project(cb, buf))
end

--- The bow-tie at a position in any file: its buffer when loaded, else its text (no buffer is
--- created for it).
---@param uri string
---@param pos lsp.Position
---@param encoding? string of `pos.character` ("utf-8" for spoor's own syntax graphs)
---@param cb fun(g: spoor.Graph?)
function M.at_file(uri, pos, encoding, cb)
  at_file(uri, pos, encoding, {}, with_project(cb))
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
