-- Real language servers on tests/fixtures. Each case skips when its server is missing.
-- Server binaries: $PATH, or SPOOR_GOPLS / SPOOR_VTSLS / SPOOR_TSGO.
local H = require("tests.helpers")
local T = MiniTest.new_set({ hooks = { pre_case = H.reset } })
local eq, expect = MiniTest.expect.equality, MiniTest.expect

local function bin(env, name)
  local p = os.getenv(env)
  if p and vim.fn.executable(p) == 1 then
    return p
  end
  local gobin = vim.fn.expand("~/go/bin/") .. name
  if vim.fn.executable(name) == 1 then
    return name
  elseif vim.fn.executable(gobin) == 1 then
    return gobin
  end
  -- CI sets this so a missing server fails instead of skipping
  assert(not os.getenv("SPOOR_REQUIRE_SERVERS"), name .. " is required but not installed")
end

local function start(cmd, root, file, line_pattern)
  local bufnr = H.edit(file)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local s = l:find(line_pattern)
    if s then
      vim.api.nvim_win_set_cursor(0, { i, s - 1 })
      break
    end
  end
  local id = vim.lsp.start({ name = vim.fs.basename(cmd[1]), cmd = cmd, root_dir = root }, { bufnr = bufnr })
  H.wait(function()
    local c = vim.lsp.get_client_by_id(id)
    return c and c.initialized
  end, 20000, "server init")
  -- correctness, not runner speed: a cold CI runner can take seconds per lookup
  require("spoor.config").setup({ timeout = 10000, cold_timeout = 30000 })
  return vim.lsp.get_client_by_id(id)
end

local function bowtie(client)
  local resolve, graph = require("spoor.resolve"), require("spoor.graph")
  local item
  local t0 = vim.uv.hrtime()
  resolve.at_cursor(client, 0, {}, function(it)
    item = it or false
  end)
  H.wait(function()
    return item ~= nil
  end, 30000, "prepare")
  assert(item, "no call hierarchy item at the cursor")
  local phases = {}
  local g = graph.build(client, item, { root = client.root_dir, depth = 1 }, function(_, p)
    phases[p] = true
  end)
  H.wait(function()
    return phases.callers and phases.callees and (phases.impls or not phases.callees)
  end, 30000, "bow-tie")
  vim.wait(300) -- value references / implementation badges
  local names = { ["in"] = {}, out = {} }
  for _, dir in ipairs({ "in", "out" }) do
    for _, e in ipairs(graph.neighbours(g, g.focus, dir, true)) do
      local n = g.nodes[dir == "in" and e.from or e.to]
      names[dir][n.name] = { node = n, edge = e }
    end
  end
  return g, names, (vim.uv.hrtime() - t0) / 1e6
end

T["gopls: Process bow-tie"] = function()
  local gopls = bin("SPOOR_GOPLS", "gopls")
  if not gopls then
    MiniTest.skip("gopls not found")
  end
  local client = start({ gopls }, H.go, H.go .. "/internal/order/order.go", "func Process")
  vim.cmd("normal! w") -- onto the name
  local g, n = bowtie(client)
  eq(g.nodes[g.focus].name, "Process")
  for _, want in ipairs({ "validate", "applyDiscount", "subtotal", "Save", "Emit" }) do
    eq({ want, n.out[want] ~= nil }, { want, true })
  end
  eq(n.out.Save.node.impls, 3) -- Memory, Postgres, and the test's fakeRepo
  eq(n["in"].handleOrders ~= nil, true)
  eq(n["in"].TestProcess.node.tags.test, true)
  local text = table.concat(require("spoor.render").bowtie(g, { width = 140 }).lines, "\n")
  expect.no_equality(text:find("Save ◇3", 1, true), nil)
end

T["gopls: handler registered by value + framework label"] = function()
  local gopls = bin("SPOOR_GOPLS", "gopls")
  if not gopls then
    MiniTest.skip("gopls not found")
  end
  local client = start({ gopls }, H.go, H.go .. "/internal/server/server.go", "%) handleOrders%(")
  vim.cmd("normal! w")
  local g, n = bowtie(client)
  eq(g.nodes[g.focus].name, "handleOrders")
  eq(g.nodes[g.focus].framework.id, "go.http")
  -- gopls lists New as a caller; the site is HandleFunc("/orders", s.handleOrders), a value use
  eq(n["in"].New.edge.kind, "ref")
  eq(n.out.Process.edge.kind, "call")
end

T["gopls: main is a program entry"] = function()
  local gopls = bin("SPOOR_GOPLS", "gopls")
  if not gopls then
    MiniTest.skip("gopls not found")
  end
  local client = start({ gopls }, H.go, H.go .. "/cmd/shop/main.go", "func main")
  vim.cmd("normal! w")
  local g, n = bowtie(client)
  eq(g.nodes[g.focus].framework.id, "go.main")
  eq(n.out.Load ~= nil and n.out.New ~= nil and n.out.Run ~= nil, true)
end

local function ts_server()
  local p = os.getenv("SPOOR_VTSLS")
  if (p and vim.fn.executable(p) == 1) or vim.fn.executable("vtsls") == 1 then
    return { p or "vtsls", "--stdio" }
  end
  p = os.getenv("SPOOR_TSGO")
  if (p and vim.fn.executable(p) == 1) or vim.fn.executable("tsgo") == 1 then
    return { p or "tsgo", "--lsp", "--stdio" }
  end
  assert(not os.getenv("SPOOR_REQUIRE_SERVERS"), "vtsls or tsgo is required but not installed")
end

T["typescript: JSX edges and Next.js page"] = function()
  local cmd = ts_server()
  if not cmd then
    MiniTest.skip("vtsls/tsgo not found")
  end
  local client = start(cmd, H.ts, H.ts .. "/app/orders/page.tsx", "OrdersPage")
  local g, n = bowtie(client)
  eq(g.nodes[g.focus].name, "OrdersPage")
  eq(g.nodes[g.focus].framework.id, "next.page")
  eq(n.out.OrderList and n.out.OrderList.edge.kind, "jsx")
end

T["typescript: callers across a server action and a route"] = function()
  local cmd = ts_server()
  if not cmd then
    MiniTest.skip("vtsls/tsgo not found")
  end
  local client = start(cmd, H.ts, H.ts .. "/lib/orders.ts", "function createOrder")
  vim.cmd("normal! w")
  local g, n = bowtie(client)
  eq(g.nodes[g.focus].name, "createOrder")
  eq(n["in"].placeOrder ~= nil, true)
  eq(n["in"].POST ~= nil, true)
  eq(n.out.priceOrder ~= nil, true)
  eq(n.out.save.node.impls ~= nil and n.out.save.node.impls >= 1, true)
end

return T
