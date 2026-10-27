local H = require("tests.helpers")
local T = MiniTest.new_set({ hooks = { pre_case = H.reset } })
local eq, expect = MiniTest.expect.equality, MiniTest.expect

-- Copy a fixture into a throwaway git repo (git grep needs one).
local function repo(src)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.system({ "cp", "-R", src .. "/.", dir }):wait()
  vim.system({ "git", "init", "-q" }, { cwd = dir }):wait()
  return dir
end

local function names(entries)
  return vim.tbl_map(function(e)
    return e.lang .. " " .. e.name
  end, entries)
end

T["go: main and http routes"] = function()
  local dir = repo(H.go)
  local found = require("spoor.entries").find(dir)
  local n = names(found)
  eq(n[1], "go main")
  expect.no_equality(vim.tbl_contains(n, "route /orders") or nil, nil)
  expect.no_equality(vim.tbl_contains(n, "route /health") or nil, nil)
  -- routes put the cursor on the handler, so a trace starts there
  for _, e in ipairs(found) do
    if e.name == "/orders" then
      local line = vim.fn.readfile(e.file)[e.lnum]
      eq(line:sub(e.col + 1, e.col + #"handleOrders"), "handleOrders")
    end
  end
end

T["next.js: pages, route handlers, scripts"] = function()
  local dir = repo(H.ts)
  local n = names(require("spoor.entries").find(dir))
  expect.no_equality(vim.tbl_contains(n, "next page /orders") or nil, nil)
  expect.no_equality(vim.tbl_contains(n, "next GET /api/orders") or nil, nil)
  expect.no_equality(vim.tbl_contains(n, "next POST /api/orders") or nil, nil)
  expect.no_equality(vim.tbl_contains(n, "npm script: dev") or nil, nil)
  -- manifests come last
  eq(n[#n]:find("^npm") ~= nil, true)
end

T["next_route drops groups and parallel slots"] = function()
  local e = require("spoor.entries")
  eq(e.next_route("app/page.tsx"), "/")
  eq(e.next_route("app/(shop)/orders/[id]/page.tsx"), "/orders/[id]")
  eq(e.next_route("src/app/@modal/login/page.tsx"), "/login")
  eq(e.next_route("app/api/orders/route.ts"), "/api/orders")
end

T["handler_col finds the handler identifier"] = function()
  local e = require("spoor.entries")
  local line = '\ts.mux.HandleFunc("/orders", s.handleOrders)'
  local col = e.handler_col(line)
  eq(line:sub(col + 1, col + 12), "handleOrders")
  line = '\tr.GET("/x", listOrders)'
  col = e.handler_col(line)
  eq(line:sub(col + 1, col + 10), "listOrders")
end

T["python, dart, jvm, rust detectors"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/app", "p")
  vim.fn.mkdir(dir .. "/lib", "p")
  vim.fn.mkdir(dir .. "/src", "p")
  vim.fn.writefile({
    "from fastapi import FastAPI",
    "app = FastAPI()",
    "",
    '@app.get("/orders")',
    "def list_orders():",
    "    return []",
  }, dir .. "/app/api.py")
  vim.fn.writefile({ "def run():", "    pass", "", 'if __name__ == "__main__":', "    run()" }, dir .. "/app/cli.py")
  vim.fn.writefile(
    { "[project]", 'name = "shop"', "", "[project.scripts]", 'shop = "app.cli:run"', "", "[tool.x]" },
    dir .. "/pyproject.toml"
  )
  vim.fn.writefile(
    { "import 'package:flutter/material.dart';", "", "void main() {", "  runApp(const App());", "}" },
    dir .. "/lib/main.dart"
  )
  vim.fn.writefile({ "class App {", "  public static void main(String[] args) {}", "}" }, dir .. "/src/App.java")
  vim.fn.writefile({ "fn main() {", "}" }, dir .. "/src/main.rs")
  vim.system({ "git", "init", "-q" }, { cwd = dir }):wait()
  local n = names(require("spoor.entries").find(dir))
  for _, want in ipairs({
    "py __main__",
    "route GET /orders",
    "py script: shop",
    "dart main → runApp",
    "jvm main",
    "rust main",
  }) do
    eq({ want, vim.tbl_contains(n, want) }, { want, true })
  end
end

T["outside git: nothing, no error"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  eq(require("spoor.entries").find(dir), {})
end

return T
