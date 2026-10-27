--- Framework-invoked roots. A Next.js page or a Flutter build() has no static
--- callers by design; spoor says who calls it instead of showing an empty column.
---
--- A rule is data plus one `match(ctx)` function, so adding a framework is one
--- table entry and one test. Rules never run the language server.
local util = require("spoor.util")

local M = {}

---@class spoor.FrameworkCtx
---@field rel string path relative to the project root
---@field name string symbol name as the server reports it
---@field kind integer LSP SymbolKind
---@field head string first lines of the file, joined by "\n"
---@field decl string the declaration: a few lines above the name (decorators) through the signature

---@class spoor.FrameworkRule
---@field id string
---@field label string who invokes this, shown as the caller row
---@field ft string[] file extensions the rule applies to
---@field only_if_empty? boolean show only when there are no static callers
---@field skip_incoming? boolean don't ask for callers: only the framework calls it, and the search is slow
---@field match fun(ctx: spoor.FrameworkCtx): boolean

local HTTP_VERBS = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true, HEAD = true, OPTIONS = true }

local function base(rel)
  return rel:match("([^/]+)$") or rel
end

local function stem(rel)
  return (base(rel):gsub("%.[^.]+$", ""))
end

local function is_app_router(rel)
  return rel:find("^app/") or rel:find("/app/") or rel:find("^src/app/")
end

---@type spoor.FrameworkRule[]
M.rules = {
  -- Go ----------------------------------------------------------------------
  {
    id = "go.main",
    label = "Go runtime · program entry",
    ft = { "go" },
    match = function(c)
      return c.name == "main" and (c.head:find("^package main") or c.head:find("\npackage main")) ~= nil
    end,
  },
  {
    id = "go.init",
    label = "Go runtime · package init",
    ft = { "go" },
    match = function(c)
      return c.name == "init"
    end,
  },
  {
    id = "go.test",
    label = "go test",
    ft = { "go" },
    match = function(c)
      return c.rel:find("_test%.go$") ~= nil
        and (c.name:find("^Test") or c.name:find("^Benchmark") or c.name:find("^Fuzz") or c.name:find("^Example"))
          ~= nil
    end,
  },
  {
    id = "go.http",
    label = "net/http · handler (router calls this)",
    ft = { "go" },
    match = function(c)
      return (c.decl:find("http%.ResponseWriter") and c.decl:find("%*http%.Request")) ~= nil
        or c.name:find("ServeHTTP$") ~= nil
    end,
  },
  {
    id = "go.web",
    label = "gin/echo/fiber · handler (router calls this)",
    ft = { "go" },
    match = function(c)
      return (c.decl:find("%*gin%.Context") or c.decl:find("echo%.Context") or c.decl:find("%*fiber%.Ctx")) ~= nil
    end,
  },
  -- Next.js / React -----------------------------------------------------------
  {
    id = "next.page",
    label = "Next.js router · renders this",
    ft = { "tsx", "jsx", "ts", "js" },
    match = function(c)
      local s = stem(c.rel)
      local special = s == "page"
        or s == "layout"
        or s == "template"
        or s == "loading"
        or s == "error"
        or s == "not-found"
        or s == "default"
        or s == "global-error"
      if special and is_app_router(c.rel) then
        return c.decl:find("export%s+default") ~= nil or c.name == "default" or c.name:match("^%u") ~= nil
      end
      -- pages router
      if (c.rel:find("^pages/") or c.rel:find("^src/pages/")) and not c.rel:find("^s?r?c?/?pages/api/") then
        return c.decl:find("export%s+default") ~= nil
      end
      return false
    end,
  },
  {
    id = "next.route",
    label = "Next.js router · route handler",
    ft = { "ts", "js" },
    match = function(c)
      if stem(c.rel) == "route" and is_app_router(c.rel) then
        return HTTP_VERBS[c.name] == true
      end
      return (c.rel:find("^pages/api/") or c.rel:find("^src/pages/api/")) ~= nil
        and c.decl:find("export%s+default") ~= nil
    end,
  },
  {
    id = "next.data",
    label = "Next.js · build/request time",
    ft = { "tsx", "jsx", "ts", "js" },
    match = function(c)
      local n = c.name
      return n == "generateMetadata"
        or n == "generateStaticParams"
        or n == "getServerSideProps"
        or n == "getStaticProps"
        or n == "getStaticPaths"
        or n == "generateViewport"
    end,
  },
  {
    id = "next.middleware",
    label = "Next.js · middleware",
    ft = { "ts", "js" },
    match = function(c)
      local s = stem(c.rel)
      return (s == "middleware" or s == "proxy")
        and (c.name == "middleware" or c.name == "proxy" or c.name == "default")
    end,
  },
  {
    id = "next.action",
    label = "Next.js · server action (client calls via RPC)",
    ft = { "ts", "tsx", "js", "jsx" },
    match = function(c)
      local file_level = c.head:match("^%s*['\"]use server['\"]") or c.head:match("\n%s*['\"]use server['\"]")
      return file_level ~= nil or c.decl:find("['\"]use server['\"]") ~= nil
    end,
  },
  {
    id = "react.component",
    label = "React · rendered via JSX",
    ft = { "tsx", "jsx" },
    only_if_empty = true,
    match = function(c)
      return c.name:match("^%u%w*$") ~= nil
    end,
  },
  {
    id = "react.hook",
    label = "React · hook (called during render)",
    ft = { "tsx", "jsx", "ts", "js" },
    only_if_empty = true,
    match = function(c)
      return c.name:match("^use%u") ~= nil
    end,
  },
  -- Flutter / Dart ------------------------------------------------------------
  {
    id = "flutter.build",
    label = "Flutter · framework calls build()",
    ft = { "dart" },
    skip_incoming = true,
    match = function(c)
      return c.name == "build" and c.decl:find("BuildContext") ~= nil
    end,
  },
  {
    id = "flutter.lifecycle",
    label = "Flutter · State lifecycle",
    ft = { "dart" },
    skip_incoming = true,
    match = function(c)
      local n = c.name
      return n == "createState"
        or n == "initState"
        or n == "dispose"
        or n == "didChangeDependencies"
        or n == "didUpdateWidget"
        or n == "deactivate"
    end,
  },
  {
    id = "dart.main",
    label = "Dart runtime · program entry",
    ft = { "dart" },
    match = function(c)
      return c.name == "main"
    end,
  },
  -- Python --------------------------------------------------------------------
  {
    id = "py.route",
    label = "web framework · route (router calls this)",
    ft = { "py" },
    match = function(c)
      return c.decl:find("@[%w_%.]+%.get%(")
        or c.decl:find("@[%w_%.]+%.post%(")
        or c.decl:find("@[%w_%.]+%.put%(")
        or c.decl:find("@[%w_%.]+%.patch%(")
        or c.decl:find("@[%w_%.]+%.delete%(")
        or c.decl:find("@[%w_%.]+%.route%(")
        or c.decl:find("@[%w_%.]+%.websocket%(")
    end,
  },
  {
    id = "py.task",
    label = "task queue · worker calls this",
    ft = { "py" },
    match = function(c)
      return (c.decl:find("@shared_task") or c.decl:find("@[%w_%.]+%.task") or c.decl:find("@dramatiq%.actor")) ~= nil
    end,
  },
  {
    id = "py.test",
    label = "pytest",
    ft = { "py" },
    match = function(c)
      return c.name:find("^test_") ~= nil
    end,
  },
  {
    id = "py.main",
    label = "Python · program entry",
    ft = { "py" },
    only_if_empty = true,
    match = function(c)
      return c.name == "main"
    end,
  },
  -- JVM -----------------------------------------------------------------------
  {
    id = "jvm.main",
    label = "JVM · program entry",
    ft = { "java", "kt" },
    match = function(c)
      return c.name:find("^main") ~= nil and (c.decl:find("static%s+void%s+main") or c.decl:find("fun%s+main")) ~= nil
    end,
  },
  {
    id = "spring",
    label = "Spring · container calls this",
    ft = { "java", "kt" },
    match = function(c)
      return c.decl:find("@%a*Mapping")
        or c.decl:find("@Scheduled")
        or c.decl:find("@EventListener")
        or c.decl:find("@Bean")
        or c.decl:find("@KafkaListener")
    end,
  },
  {
    id = "junit",
    label = "JUnit",
    ft = { "java", "kt" },
    match = function(c)
      return c.decl:find("@Test") ~= nil
    end,
  },
}

---@param rel string
local function ext(rel)
  return rel:match("%.([%w]+)$") or ""
end

--- Build the context for a node from file lines (0-based LSP ranges).
---@param node {name: string, kind: integer, range: lsp.Range, selection: lsp.Range}
---@param rel string
---@param lines string[]
---@return spoor.FrameworkCtx
function M.context(node, rel, lines)
  local first = math.max(node.range.start.line - 3, 0)
  local last = math.min(node.selection["end"].line + 2, node.range["end"].line + 1, #lines - 1)
  local decl = {}
  for l = first, last do
    decl[#decl + 1] = lines[l + 1]
  end
  local head = {}
  for l = 1, math.min(#lines, 12) do
    head[#head + 1] = lines[l]
  end
  return {
    rel = rel,
    name = node.name,
    kind = node.kind,
    head = table.concat(head, "\n"),
    decl = table.concat(decl, "\n"),
  }
end

--- First matching rule for a context, or nil.
---@param ctx spoor.FrameworkCtx
---@return spoor.FrameworkRule?
function M.match(ctx)
  local e = ext(ctx.rel)
  for _, rule in ipairs(M.rules) do
    if vim.tbl_contains(rule.ft, e) and rule.match(ctx) then
      return rule
    end
  end
end

--- Detect the framework that invokes a node, reading its file once.
---@param node spoor.Node
---@param root? string
---@return spoor.FrameworkRule?
function M.detect(node, root)
  local path = util.path(node.uri)
  local rel = util.relative(path, root)
  local lines = util.read_lines(path, math.max(node.selection["end"].line + 3, 12))
  if #lines == 0 then
    return nil
  end
  return M.match(M.context(node, rel, lines))
end

return M
