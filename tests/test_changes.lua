local H = require("tests.helpers")
local T = MiniTest.new_set({ hooks = { pre_case = H.reset } })
local eq = MiniTest.expect.equality

local DIFF = [[
diff --git a/internal/order/order.go b/internal/order/order.go
index 1111111..2222222 100644
--- a/internal/order/order.go
+++ b/internal/order/order.go
@@ -26 +26,2 @@ func Process(ctx context.Context, repo Repo, o Order, discount int) error {
-	o.Total = applyDiscount(subtotal(o), discount)
+	o.Total = applyDiscount(subtotal(o), discount)
+	o.Total = roundCents(o.Total)
@@ -40,0 +42,4 @@ func subtotal(o Order) int {
+
+func roundCents(total int) int {
+	return total
+}
diff --git a/internal/order/discount.go b/internal/order/discount.go
deleted file mode 100644
--- a/internal/order/discount.go
+++ /dev/null
@@ -1,3 +0,0 @@
-package order
diff --git a/internal/new/thing.go b/internal/new/thing.go
new file mode 100644
--- /dev/null
+++ b/internal/new/thing.go
@@ -0,0 +1,5 @@
+package thing
]]

T["parse_diff reads hunks, new and deleted files"] = function()
  local files = require("spoor.changes").parse_diff(vim.split(DIFF, "\n"))
  eq(#files, 2) -- the deleted file has nothing to show
  eq(files[1].path, "internal/order/order.go")
  eq(files[1].hunks[1], { old_start = 26, old_count = 1, new_start = 26, new_count = 2 })
  eq(files[1].hunks[2], { old_start = 40, old_count = 0, new_start = 42, new_count = 4 })
  eq(files[2].path, "internal/new/thing.go")
  eq(files[2].new, true)
end

local function sym(name, kind, s, e, children)
  return {
    name = name,
    kind = kind,
    range = { start = { line = s, character = 0 }, ["end"] = { line = e, character = 1 } },
    selectionRange = { start = { line = s, character = 5 }, ["end"] = { line = s, character = 5 + #name } },
    children = children,
  }
end

T["touched: modified, new and top-level symbols"] = function()
  local changes = require("spoor.changes")
  local symbols = {
    sym("Process", 12, 21, 32),
    sym("subtotal", 12, 34, 40),
    sym("roundCents", 12, 42, 44),
  }
  local hunks = {
    { old_start = 26, old_count = 1, new_start = 26, new_count = 2 },
    { old_start = 40, old_count = 0, new_start = 42, new_count = 4 },
  }
  local out = changes.touched(symbols, hunks, false, 50)
  local by = {}
  for _, c in ipairs(out) do
    by[c.name] = c
  end
  eq(by.Process.status, "modified")
  eq(by.Process.added, 2)
  eq(by.Process.removed, 1)
  eq(by.roundCents.status, "new")
  eq(by["(top level)"], nil) -- the blank line before roundCents is not a row of its own
  eq(by.subtotal, nil)
  -- only top-level lines changed: one row for the file
  out = changes.touched(symbols, { { old_start = 1, old_count = 1, new_start = 1, new_count = 1 } }, false, 50)
  eq(#out, 1)
  eq(out[1].status, "top")
end

T["touched: a renamed-in-place function with an existing name is modified, not new"] = function()
  local changes = require("spoor.changes")
  local hunks = { { old_start = 10, old_count = 0, new_start = 10, new_count = 3 } }
  local out = changes.touched({ sym("Run", 12, 9, 11) }, hunks, false, 20, function(name)
    return name == "Run"
  end)
  eq(out[1].status, "modified")
  out = changes.touched({ sym("Fresh", 12, 9, 11) }, hunks, false, 20, function()
    return false
  end)
  eq(out[1].status, "new")
end

T["touched: innermost symbol wins (methods inside classes)"] = function()
  local changes = require("spoor.changes")
  local symbols = { sym("Server", 5, 0, 30, { sym("Run", 6, 10, 14), sym("Stop", 6, 16, 20) }) }
  local out = changes.touched(symbols, { { old_start = 12, old_count = 1, new_start = 12, new_count = 1 } }, false, 30)
  eq(#out, 1)
  eq(out[1].name, "Run")
end

T["touched: a whole new file is all new"] = function()
  local out = require("spoor.changes").touched({ sym("main", 12, 2, 4) }, {}, true, 5)
  eq(#out, 1)
  eq(out[1].name, "main")
  eq(out[1].status, "new")
end

T["touched: pure deletions count against the symbol"] = function()
  local out = require("spoor.changes").touched(
    { sym("Run", 12, 10, 20) },
    { { old_start = 15, old_count = 3, new_start = 14, new_count = 0 } },
    false,
    30
  )
  eq(out[1].name, "Run")
  eq(out[1].removed, 3)
  eq(out[1].status, "modified")
end

local function git(dir, ...)
  local res = vim
    .system({ "git", "-c", "user.name=t", "-c", "user.email=t@example.com", ... }, { cwd = dir, text = true })
    :wait()
  assert(res.code == 0, res.stderr)
  return res.stdout
end

T["base: merge-base on a branch, HEAD on the default branch"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  git(dir, "init", "-q", "-b", "main")
  vim.fn.writefile({ "a" }, dir .. "/a.txt")
  git(dir, "add", ".")
  git(dir, "commit", "-q", "-m", "one")
  local changes = require("spoor.changes")
  local ref, label = changes.base(dir)
  eq(ref, "HEAD")
  eq(label, "HEAD (uncommitted)")
  local main = vim.trim(git(dir, "rev-parse", "HEAD"))
  git(dir, "checkout", "-q", "-b", "agent/work")
  vim.fn.writefile({ "b" }, dir .. "/a.txt")
  git(dir, "commit", "-q", "-am", "two")
  ref, label = changes.base(dir)
  eq(ref, main)
  eq(label, "main")
  eq({ changes.base(dir, "HEAD~1") }, { main, "HEAD~1" })
  -- refs are resolved to commits, so nothing can be passed to git as an option
  eq(changes.base(dir, "--output=/tmp/x"), nil)
end

T["diff includes untracked files as new"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  git(dir, "init", "-q", "-b", "main")
  vim.fn.writefile({ "package a", "", "func A() {}" }, dir .. "/a.go")
  git(dir, "add", ".")
  git(dir, "commit", "-q", "-m", "one")
  vim.fn.writefile({ "package a", "", "func A() { B() }" }, dir .. "/a.go")
  vim.fn.writefile({ "package a", "", "func B() {}" }, dir .. "/b.go")
  local files = require("spoor.changes").diff(dir, "HEAD")
  table.sort(files, function(x, y)
    return x.path < y.path
  end)
  eq(#files, 2)
  eq(files[1].path, "a.go")
  eq(files[1].new, false)
  eq(files[2].path, "b.go")
  eq(files[2].new, true)
end

T["diff survives mnemonicPrefix, spaces and non-ASCII paths"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  git(dir, "init", "-q", "-b", "main")
  git(dir, "config", "diff.mnemonicPrefix", "true")
  git(dir, "config", "diff.noprefix", "true")
  vim.fn.writefile({ "a" }, dir .. "/my file.go")
  vim.fn.writefile({ "a" }, dir .. "/café.go")
  git(dir, "add", ".")
  git(dir, "commit", "-q", "-m", "one")
  vim.fn.writefile({ "b" }, dir .. "/my file.go")
  vim.fn.writefile({ "b" }, dir .. "/café.go")
  local files = require("spoor.changes").diff(dir, "HEAD")
  local paths = vim.tbl_map(function(f)
    return f.path
  end, files)
  table.sort(paths)
  eq(paths, { "café.go", "my file.go" })
  eq(vim.fn.filereadable(files[1].abs), 1)
end

T["collect finds changed symbols and flags new uncalled functions"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  git(dir, "init", "-q", "-b", "main")
  vim.fn.writefile({ "package a", "", "func A() {", "}" }, dir .. "/a.go")
  git(dir, "add", ".")
  git(dir, "commit", "-q", "-m", "one")
  vim.fn.writefile({ "package a", "", "func A() {", "\tprintln(1)", "}", "", "func Lonely() {", "}" }, dir .. "/a.go")
  local uri = vim.uri_from_fname(dir .. "/a.go")
  local function s(name, a, b)
    return {
      name = name,
      kind = 12,
      range = { start = { line = a, character = 0 }, ["end"] = { line = b, character = 1 } },
      selectionRange = { start = { line = a, character = 5 }, ["end"] = { line = a, character = 5 + #name } },
    }
  end
  local handlers = {
    ["textDocument/documentSymbol"] = function()
      return { s("A", 2, 4), s("Lonely", 6, 7) }
    end,
    ["textDocument/prepareCallHierarchy"] = function(p)
      local name = p.position.line == 6 and "Lonely" or "A"
      local it = s(name, p.position.line, p.position.line + 1)
      it.uri = uri
      return { it }
    end,
    ["callHierarchy/incomingCalls"] = function()
      return {}
    end,
  }
  -- the fake server attaches when the changes module loads the buffer
  local started = false
  vim.api.nvim_create_autocmd("BufReadPost", {
    pattern = "*.go",
    callback = function(ev)
      if not started then
        started = true
        vim.schedule(function()
          H.fake_server(ev.buf, { root = dir, handlers = handlers })
        end)
      end
    end,
  })
  require("spoor.config").setup({})
  local result
  require("spoor.changes").collect({ root = dir }, function(items, label)
    result = { items = items, label = label }
  end)
  H.wait(function()
    return result ~= nil
  end, 6000, "changes")
  eq(result.label, "HEAD (uncommitted)")
  local by = {}
  for _, it in ipairs(result.items) do
    by[it.name] = it
  end
  eq(by.A.status, "modified")
  eq(by.Lonely.status, "new")
  eq(by.Lonely.callers, 0)
  -- the hidden buffer stays out of the buffer list
  eq(vim.bo[by.A.bufnr].buflisted, false)
end

return T
