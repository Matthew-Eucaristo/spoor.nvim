local H = require("tests.helpers")
local T = MiniTest.new_set({ hooks = { pre_case = H.reset } })
local eq, expect = MiniTest.expect.equality, MiniTest.expect

local function setup_world(extra, delay)
  local w = H.go_world()
  local bufnr = H.edit(H.go .. "/internal/order/order.go")
  local server = H.fake_server(bufnr, { handlers = H.go_handlers(w, extra), delay = delay })
  require("spoor.config").setup({})
  return w, bufnr, server
end

local function build(w, server, opts, on)
  local graph = require("spoor.graph")
  local phases = {}
  local g = graph.build(
    server.client,
    w.process,
    vim.tbl_extend("force", { root = H.go, bufnr = 0 }, opts or {}),
    function(_, phase)
      phases[phase] = true
      if on then
        on(phase)
      end
    end
  )
  return g, phases
end

T["builds callers and callees from the server"] = function()
  local w, _, server = setup_world()
  local g, phases = build(w, server)
  H.wait(function()
    return phases.callees and phases.callers and phases.impls
  end)
  local graph = require("spoor.graph")
  eq(#graph.neighbours(g, g.focus, "out"), 5)
  eq(#graph.neighbours(g, g.focus, "in"), 2)
  eq(g.status, { incoming = "done", outgoing = "done" })
end

T["interface callees get an implementation count"] = function()
  local w, _, server = setup_world()
  local g, phases = build(w, server)
  H.wait(function()
    return phases.impls
  end)
  local save = g.nodes[require("spoor.util").id(w.save.uri, w.save.selectionRange.start)]
  eq(save.impls, 2)
  eq(save.tags.interface, true)
  -- concrete callees are never asked (only methods that look abstract)
  eq(H.count(server.requests, "textDocument/implementation"), 1)
end

T["looks_abstract tells interface methods from concrete ones"] = function()
  local graph = require("spoor.graph")
  local model = require("spoor.model")
  local w = H.go_world()
  eq(graph.looks_abstract(model.node(w.save)), true)
  eq(graph.looks_abstract(model.node(w.mem_save)), false)
  eq(graph.looks_abstract(model.node(w.process)), false)
  local ts = H.item(H.ts .. "/lib/orders.ts", "save", { kind = H.Method, pattern = "  save%(" })
  eq(graph.looks_abstract(model.node(ts)), true)
end

T["site_kind reads calls, JSX and value uses from the source"] = function()
  local graph = require("spoor.graph")
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function kind(file, line, word)
    local path = dir .. "/" .. file
    vim.fn.writefile({ line }, path)
    local s = line:find(word, 1, true) - 1
    return graph.site_kind(path, { start = { line = 0, character = s }, ["end"] = { line = 0, character = s + #word } })
  end
  eq(kind("a.go", "\tvalidate(o)", "validate"), "call")
  eq(kind("a.go", "\tx := Map[int](xs)", "Map"), "call")
  eq(kind("a.go", '\tmux.HandleFunc("/x", s.handleOrders)', "handleOrders"), "ref")
  eq(kind("a.tsx", "  return <OrderList orders={o} />", "OrderList"), "jsx")
  eq(kind("a.tsx", "  <button onClick={save}>", "save"), "ref")
  eq(kind("a.ts", "  const x = parse<Order>(raw)", "parse"), "call")
  eq(kind("a.ts", "  obj.fn?.(1)", "fn"), "call")
end

T["tests and externals are tagged"] = function()
  local w, _, server = setup_world()
  local g, phases = build(w, server)
  H.wait(function()
    return phases.callers
  end)
  local test = g.nodes[require("spoor.util").id(w.test.uri, w.test.selectionRange.start)]
  eq(test.tags.test, true)
end

T["no static callers asks for value references"] = function()
  local w = H.go_world()
  local handle = w.handle
  local server_file = H.go .. "/internal/server/server.go"
  local lines = vim.fn.readfile(server_file)
  local reg
  for i, l in ipairs(lines) do
    if l:find('HandleFunc%("/orders"') then
      reg = { line = i - 1, character = l:find("handleOrders", 1, true) - 1 }
    end
  end
  local bufnr = H.edit(server_file)
  local handlers = H.go_handlers(w, {
    ["callHierarchy/incomingCalls"] = function()
      return {}
    end,
    ["callHierarchy/outgoingCalls"] = function()
      return {}
    end,
    ["textDocument/references"] = function()
      return {
        { uri = handle.uri, range = { start = reg, ["end"] = { line = reg.line, character = reg.character + 12 } } },
      }
    end,
  })
  local server = H.fake_server(bufnr, { handlers = handlers })
  require("spoor.config").setup({})
  local phases = {}
  local g = require("spoor.graph").build(server.client, handle, { root = H.go }, function(_, p)
    phases[p] = true
  end)
  H.wait(function()
    return phases.refs
  end)
  local callers = require("spoor.graph").neighbours(g, g.focus, "in")
  eq(#callers, 1)
  eq(callers[1].kind, "ref")
  local ref = g.nodes[callers[1].from]
  expect.no_equality(ref.name:find("HandleFunc", 1, true), nil)
  -- and the focus is recognised as an HTTP handler
  eq(g.nodes[g.focus].framework.id, "go.http")
  local text = table.concat(require("spoor.render").bowtie(g, { width = 140 }).lines, "\n")
  expect.no_equality(text:find("~", 1, true), nil)
  expect.no_equality(text:find("router calls this", 1, true), nil)
end

T["a slow server times out and is cancelled"] = function()
  local w, _, server = setup_world(nil, { ["callHierarchy/incomingCalls"] = "never" })
  require("spoor.config").setup({ timeout = 80, cold_timeout = 80 })
  local g, phases = build(w, server)
  H.wait(function()
    return phases.callers
  end, 2000, "timeout")
  eq(g.status.incoming, "timeout")
  eq(g.status.outgoing, "done")
  eq(#server.cancels >= 1, true)
  local text = table.concat(require("spoor.render").bowtie(g, { width = 120 }).lines, "\n")
  expect.no_equality(text:find("timed out", 1, true), nil)
end

T["cancelling a group stops pending requests"] = function()
  local w, _, server =
    setup_world(nil, { ["callHierarchy/incomingCalls"] = 300, ["callHierarchy/outgoingCalls"] = 300 })
  local lsp = require("spoor.lsp")
  local group = lsp.group()
  local _, phases = build(w, server, { group = group })
  group:cancel()
  vim.wait(500, function()
    return false
  end)
  eq(phases.callers, nil)
  eq(phases.callees, nil)
  eq(#server.cancels, 2)
  eq(lsp.inflight, 0)
end

T["depth 2 expands neighbours of neighbours"] = function()
  local w = H.go_world()
  local extra = {
    ["callHierarchy/incomingCalls"] = function(params)
      if params.item.name == "Process" then
        return w.incoming
      elseif params.item.name == "handleOrders" then
        return { { from = H.item(H.go .. "/internal/server/server.go", "New"), fromRanges = { H.site(w.handle) } } }
      end
      return {}
    end,
  }
  local _, _, server = setup_world(extra)
  local g, phases = build(w, server, { depth = 2 })
  H.wait(function()
    return phases.callers2 and phases.callees2
  end)
  local util = require("spoor.util")
  local handle_id = util.id(w.handle.uri, w.handle.selectionRange.start)
  eq(g.expanded[handle_id .. "<in"], true)
  local text = table.concat(require("spoor.render").bowtie(g, { width = 140 }).lines, "\n")
  expect.no_equality(text:find("◂", 1, true), nil)
  expect.no_equality(text:find("New", 1, true), nil)
end

T["flutter build() skips the slow caller search"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/lib", "p")
  local file = dir .. "/lib/home.dart"
  vim.fn.writefile({
    "class HomePage extends StatelessWidget {",
    "  @override",
    "  Widget build(BuildContext context) {",
    "    return Text(title());",
    "  }",
    "}",
  }, file)
  local item = {
    name = "build",
    kind = H.Method,
    uri = vim.uri_from_fname(file),
    range = { start = { line = 1, character = 2 }, ["end"] = { line = 4, character = 3 } },
    selectionRange = { start = { line = 2, character = 9 }, ["end"] = { line = 2, character = 14 } },
  }
  local bufnr = H.edit(file)
  local server = H.fake_server(bufnr, {
    root = dir,
    handlers = {
      ["callHierarchy/outgoingCalls"] = function()
        return {}
      end,
    },
  })
  require("spoor.config").setup({})
  local phases = {}
  local g = require("spoor.graph").build(server.client, item, { root = dir }, function(_, p)
    phases[p] = true
  end)
  H.wait(function()
    return phases.callers and phases.callees
  end)
  eq(H.count(server.requests, "callHierarchy/incomingCalls"), 0)
  eq(g.nodes[g.focus].framework.id, "flutter.build")
end

T["export is JSON with relative paths"] = function()
  local w, _, server = setup_world()
  local g, phases = build(w, server)
  H.wait(function()
    return phases.callers and phases.callees
  end)
  local data = require("spoor.model").export(g)
  local json = vim.json.encode(data)
  eq(json:find(H.root, 1, true), nil)
  expect.no_equality(json:find("internal/order/order.go", 1, true), nil)
  eq(#data.edges, 7)
  eq(data.version, 1)
end

T["mermaid export"] = function()
  local w, _, server = setup_world()
  local g, phases = build(w, server)
  H.wait(function()
    return phases.callers and phases.callees and phases.impls
  end)
  local text = require("spoor.export").bowtie_mermaid(g)
  expect.no_equality(text:find("^graph LR"), nil)
  expect.no_equality(text:find('"Save ◇2"', 1, true), nil)
end

return T
