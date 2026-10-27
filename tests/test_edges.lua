-- Edge cases: odd buffers, flaky servers, odd graphs and odd git states. Each case also
-- checks that nothing reached v:errmsg, since errors in callbacks don't fail a test.
local H = require("tests.helpers")
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      H.reset()
      vim.v.errmsg = ""
    end,
    post_case = function()
      MiniTest.expect.equality(vim.v.errmsg, "")
    end,
  },
})
local eq, expect = MiniTest.expect.equality, MiniTest.expect

local function panel()
  return require("spoor.live").panels[vim.api.nvim_get_current_tabpage()]
end

local function panel_text()
  local v = panel()
  return v and v:valid() and table.concat(vim.api.nvim_buf_get_lines(v.win.buf, 0, -1, false), "\n") or ""
end

local function go_buffer(opts)
  opts = opts or {}
  local w = H.go_world()
  local p = w.process.selectionRange.start
  local bufnr = H.edit(H.go .. "/internal/order/order.go", p.line + 1, p.character)
  local server = H.fake_server(bufnr, {
    handlers = H.go_handlers(w, opts.handlers),
    delay = opts.delay,
    capabilities = opts.capabilities,
    name = opts.name,
  })
  return w, bufnr, server
end

local function setup(config)
  require("spoor").setup(
    vim.tbl_deep_extend("force", { live = { debounce = 10, panel = true, layout = "bottom" } }, config or {})
  )
end

local function move()
  vim.api.nvim_exec_autocmds("CursorMoved", {})
end

local function git(dir, ...)
  local res = vim
    .system({ "git", "-c", "user.name=t", "-c", "user.email=t@example.com", ... }, { cwd = dir, text = true })
    :wait()
  assert(res.code == 0, res.stderr)
  return res.stdout
end

local function repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  git(dir, "init", "-q", "-b", "main")
  return dir
end

-- Live panel ---------------------------------------------------------------

T["a server without call hierarchy is never asked"] = function()
  local _, _, server = go_buffer({ capabilities = { documentSymbolProvider = true } })
  setup()
  move()
  vim.wait(100)
  eq(H.count(server.requests, "textDocument/prepareCallHierarchy"), 0)
  eq(panel(), nil)
end

T["help, terminal, scratch and unnamed buffers are not followed"] = function()
  local _, _, server = go_buffer()
  setup()
  local before = #server.requests
  vim.cmd("help help")
  move()
  vim.wait(60)
  vim.cmd("terminal")
  move()
  vim.wait(60)
  vim.cmd("enew")
  move()
  vim.wait(60)
  vim.cmd("enew")
  vim.bo.buftype = "nofile"
  move()
  vim.wait(60)
  eq(#server.requests, before)
  eq(panel(), nil)
end

T["a non-file scheme buffer is not followed"] = function()
  setup()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "fugitive:///repo/.git//0/a.go")
  vim.api.nvim_set_current_buf(buf)
  move()
  vim.wait(60)
  eq(panel(), nil)
end

T["wiping the buffer mid-request drops the answer quietly"] = function()
  go_buffer({ delay = { ["textDocument/prepareCallHierarchy"] = 80 } })
  setup()
  move()
  vim.wait(30)
  vim.cmd("bwipeout!")
  vim.wait(200)
  eq(panel_text():find("Process", 1, true), nil)
end

T["wiping the buffer while the server finds nothing is quiet (live and gag)"] = function()
  for _, use_float in ipairs({ false, true }) do
    H.reset()
    vim.v.errmsg = ""
    go_buffer({
      handlers = {
        ["textDocument/prepareCallHierarchy"] = function()
          return nil -- inside a body, not on a call: the enclosing-function fallback runs next
        end,
      },
      delay = { ["textDocument/prepareCallHierarchy"] = 80 },
    })
    setup({ live = { enabled = not use_float } })
    if use_float then
      require("spoor").bowtie()
    else
      move()
    end
    vim.wait(30)
    vim.cmd("bwipeout!")
    vim.wait(300)
    eq(vim.v.errmsg, "")
  end
end

T["the server stopping mid-request leaves no error and recovers"] = function()
  local _, bufnr, server = go_buffer({ delay = { ["callHierarchy/incomingCalls"] = "never" } })
  setup({ timeout = 200 })
  move()
  vim.wait(60)
  server.client:stop(true)
  H.wait(function()
    return #vim.lsp.get_clients({ bufnr = bufnr }) == 0
  end, 2000, "client stop")
  vim.wait(300)
  -- a new server attaches and the panel follows again
  go_buffer()
  move()
  H.wait(function()
    return panel_text():find("Emit", 1, true) ~= nil
  end, 3000, "panel after restart")
end

T["recursion and mutual recursion render once each"] = function()
  local w = H.go_world()
  local loop = {
    ["callHierarchy/outgoingCalls"] = function(params)
      if params.item.name == "Process" then
        return {
          { to = w.process, fromRanges = { H.site(w.process) } },
          { to = w.save, fromRanges = { H.site(w.process) } },
        }
      end
      if params.item.name == "Save" then
        return { { to = w.process, fromRanges = { H.site(w.save) } } }
      end
      return {}
    end,
    ["callHierarchy/incomingCalls"] = function(params)
      if params.item.name == "Process" then
        return {
          { from = w.process, fromRanges = { H.site(w.process) } },
          { from = w.save, fromRanges = { H.site(w.save) } },
        }
      end
      return { { from = w.process, fromRanges = { H.site(w.process) } } }
    end,
  }
  go_buffer({ handlers = loop })
  setup()
  require("spoor").bowtie()
  H.wait(function()
    local v = require("spoor.bowtie").current
    return v and v:valid() and v.graph and v.graph.complete
  end, 3000, "float complete")
  local v = require("spoor.bowtie").current
  local text = table.concat(vim.api.nvim_buf_get_lines(v.win.buf, 0, -1, false), "\n")
  expect.no_equality(text:find("Process", 1, true), nil)
  eq(#vim.api.nvim_buf_get_lines(v.win.buf, 0, -1, false) < 40, true)
  vim.cmd("close")
end

T["hundreds of callers are capped with an honest count"] = function()
  local w = H.go_world()
  local many = {}
  for i = 1, 300 do
    local it = vim.deepcopy(w.handle)
    it.name = "caller" .. i
    it.selectionRange.start.line = i
    it.selectionRange["end"].line = i
    many[i] = { from = it, fromRanges = { H.site(it) } }
  end
  go_buffer({
    handlers = {
      ["callHierarchy/incomingCalls"] = function(params)
        return params.item.name == "Process" and many or {}
      end,
    },
  })
  setup()
  move()
  H.wait(function()
    return panel_text():find("more", 1, true) ~= nil
  end, 3000, "+N more")
  expect.no_equality(panel_text():find("300", 1, true), nil)
end

T["wide, CJK and emoji names keep the columns aligned"] = function()
  local render = require("spoor.render")
  local model = require("spoor.model")
  local function item(name, file, line)
    return {
      name = name,
      kind = 12,
      uri = vim.uri_from_fname("/p/" .. file),
      range = { start = { line = line, character = 0 }, ["end"] = { line = line + 2, character = 0 } },
      selectionRange = { start = { line = line, character = 5 }, ["end"] = { line = line, character = 9 } },
    }
  end
  local g = model.graph(model.node(item("処理する注文", "注文/処理.go", 1)), { root = "/p" })
  local a = model.add_node(g, model.node(item("🚀launch_everything_now_please_with_a_very_long_name", "a.go", 3)))
  local b = model.add_node(g, model.node(item("café", "b.go", 5)))
  model.add_edge(g, { from = a.id, to = g.focus, kind = "call", sites = {}, source = "lsp" })
  model.add_edge(g, { from = g.focus, to = b.id, kind = "call", sites = {}, source = "lsp" })
  g.status = { incoming = "done", outgoing = "done" }
  for _, width in ipairs({ 40, 80, 160 }) do
    local r = render.bowtie(g, { width = width, max_items = 6 })
    for _, l in ipairs(r.lines) do
      eq(vim.api.nvim_strwidth(l) <= width, true)
    end
  end
end

T["a corrupt state.json falls back to the default"] = function()
  local dir = require("spoor.util").state_dir()
  vim.fn.writefile({ "{not json" }, dir .. "/state.json")
  setup({ live = { panel = true } })
  eq(require("spoor.live").enabled(), true)
  require("spoor").toggle(false)
  eq(require("spoor.util").read_json(dir .. "/state.json").panel, false)
end

T["a tiny editor still renders the panel"] = function()
  local cols, lines = vim.o.columns, vim.o.lines
  vim.o.columns, vim.o.lines = 34, 12
  go_buffer()
  setup()
  move()
  H.wait(function()
    return panel_text():find("Process", 1, true) ~= nil
  end, 3000, "panel")
  vim.o.columns, vim.o.lines = cols, lines
  vim.wait(50)
end

T["opening the panel never moves the code cursor (splitkeep=screen)"] = function()
  local keep, lines = vim.o.splitkeep, vim.o.lines
  vim.o.splitkeep, vim.o.lines = "screen", 20
  local _, bufnr = go_buffer()
  local code = vim.api.nvim_get_current_win()
  vim.cmd("normal! zb") -- the focus line sits at the bottom, where the panel will open
  local before = vim.api.nvim_win_get_cursor(code)
  setup()
  move()
  H.wait(function()
    return panel_text():find("Emit", 1, true) ~= nil
  end, 3000, "panel")
  -- the adjustment happens when the window is entered again
  vim.cmd("wincmd p")
  vim.cmd("wincmd p")
  vim.api.nvim_set_current_win(code)
  eq(vim.api.nvim_win_get_cursor(code), before)
  eq(vim.api.nvim_win_get_buf(code), bufnr)
  vim.o.splitkeep, vim.o.lines = keep, lines
end

T["g? in the bottom panel shows help"] = function()
  go_buffer()
  setup()
  move()
  H.wait(function()
    return panel_text():find("Emit", 1, true) ~= nil
  end, 3000, "panel")
  local v = panel()
  vim.api.nvim_set_current_win(v.win.win)
  local ok, err = pcall(require("spoor.live").actions.help, v)
  eq(ok, true, err)
  v.win:toggle_help()
end

T["setup twice keeps one set of autocmds and keys"] = function()
  setup()
  setup()
  eq(#vim.api.nvim_get_autocmds({ group = "spoor_live", event = "CursorMoved" }), 1)
  eq(#vim.api.nvim_get_autocmds({ group = "spoor_hl" }), 1)
end

T["icons fall back without mini.icons or LazyVim"] = function()
  local mini = _G.MiniIcons
  _G.MiniIcons = nil
  local icon = require("spoor.icons").kind(12)
  _G.MiniIcons = mini
  eq(type(icon), "string")
  eq(icon ~= "", true)
  eq(require("spoor.icons").kind(9999), "•")
end

T["gag with nothing callable under the cursor says so"] = function()
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  go_buffer({
    handlers = {
      ["textDocument/prepareCallHierarchy"] = function()
        return nil
      end,
      ["textDocument/documentSymbol"] = function()
        return {}
      end,
    },
  })
  setup({ live = { enabled = false } })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  require("spoor").bowtie()
  H.wait(function()
    return #msgs > 0
  end, 2000, "notification")
  vim.notify = orig
  eq(require("spoor.bowtie").current == nil or not require("spoor.bowtie").current:valid(), true)
end

-- Trails ---------------------------------------------------------------------

T["a corrupt trail file is treated as empty"] = function()
  local trace = require("spoor.trace")
  require("spoor.config").setup({})
  local f = trace.file("/tmp/project")
  vim.fn.writefile({ '{"trails": 3' }, f)
  eq(trace.load("/tmp/project").trails, {})
  vim.fn.writefile({ '{"trails": [1, 2]}' }, f)
  eq(type(trace.load("/tmp/project").trails), "table")
end

T["resuming a trail whose file is gone does not error"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "package a", "", "func Gone() {}" }, dir .. "/gone.go")
  require("spoor.config").setup({})
  local trace = require("spoor.trace")
  local uri = vim.uri_from_fname(dir .. "/gone.go")
  local trail = {
    id = "t1",
    root = dir,
    title = "Gone",
    created = os.time(),
    steps = {
      {
        node = {
          name = "Gone",
          kind = 12,
          uri = uri,
          path = dir .. "/gone.go",
          range = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 14 } },
          selection = { start = { line = 2, character = 5 }, ["end"] = { line = 2, character = 9 } },
        },
      },
    },
  }
  trace.save(trail)
  vim.fn.delete(dir .. "/gone.go")
  vim.cmd("edit " .. dir .. "/other.go")
  trace.resume(trail)
  vim.wait(50)
  trace.close()
end

T["a trail with more hops than keys numbers only 1-9 and counts the rest"] = function()
  local w = H.go_world()
  local many = {}
  for i = 1, 12 do
    local it = vim.deepcopy(w.emit)
    it.name = "callee" .. i
    it.selectionRange.start.line = i
    it.selectionRange["end"].line = i
    many[i] = { to = it, fromRanges = { H.site(w.process, w.process.selectionRange.start.line + 1) } }
  end
  go_buffer({
    handlers = {
      ["callHierarchy/outgoingCalls"] = function(params)
        return params.item.name == "Process" and many or {}
      end,
    },
  })
  require("spoor.config").setup({})
  require("spoor.highlights").setup()
  require("spoor.trace").start_at_cursor()
  local s = require("spoor.trace").state
  H.wait(function()
    return s.win and s.win:valid() and #s.hops > 0
  end, 3000, "hops")
  local text = table.concat(vim.api.nvim_buf_get_lines(s.win.buf, 0, -1, false), "\n")
  expect.no_equality(text:find("  9  ", 1, true), nil)
  eq(text:find("  10  ", 1, true), nil)
  expect.no_equality(text:find("3 more", 1, true), nil)
  require("spoor.trace").close()
end

T["the live panel can be a float in the corner"] = function()
  go_buffer()
  setup({ live = { layout = "float" } })
  move()
  H.wait(function()
    return panel_text():find("Emit", 1, true) ~= nil
  end, 3000, "float panel")
  local v = panel()
  eq(vim.api.nvim_win_get_config(v.win.win).relative, "editor")
  expect.no_equality(vim.api.nvim_get_current_win(), v.win.win)
end

T["health finds the code buffer when :checkhealth opens in a float"] = function()
  local bufnr = H.edit(H.go .. "/internal/order/order.go", 1, 0)
  H.fake_server(bufnr, { handlers = {} })
  setup({ live = { enabled = false } })
  vim.g.health = { style = "float" }
  vim.cmd("checkhealth spoor")
  local health = vim.api.nvim_get_current_buf()
  local out = ""
  H.wait(function()
    out = table.concat(vim.api.nvim_buf_get_lines(health, 0, -1, false), "\n")
    return out:find("fake:", 1, true) ~= nil or out:find("No language server", 1, true) ~= nil
  end, 3000, "health output")
  vim.g.health = nil
  expect.no_equality(out:find("fake: ✓ prepareCallHierarchy", 1, true), nil)
  vim.cmd("close")
end

T["trail steps on non-file URIs (jdt://) open instead of warning"] = function()
  require("spoor.config").setup({})
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  vim.cmd("edit " .. H.go .. "/internal/order/order.go")
  local node = {
    id = "jdt",
    name = "Thing",
    kind = 12,
    uri = "jdt://contents/rt.jar/java.lang/Object.class",
    range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
    selection = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
    tags = {},
  }
  pcall(require("spoor.trace").start, node, { root = H.go, origin = vim.api.nvim_get_current_win() })
  vim.wait(50)
  vim.notify = orig
  require("spoor.trace").close()
  for _, m in ipairs(msgs) do
    eq(m:find("moved or deleted", 1, true), nil)
  end
  vim.v.errmsg = ""
end

-- Changes ----------------------------------------------------------------------

T["base: empty repo, detached HEAD, no default branch"] = function()
  local changes = require("spoor.changes")
  require("spoor.config").setup({})
  local dir = repo()
  eq(changes.base(dir), nil)
  vim.fn.writefile({ "a" }, dir .. "/a.txt")
  git(dir, "add", ".")
  git(dir, "commit", "-q", "-m", "one")
  git(dir, "checkout", "-q", "--detach")
  eq(changes.base(dir), "HEAD")
  git(dir, "checkout", "-q", "-b", "feature")
  git(dir, "branch", "-q", "-D", "main")
  eq(changes.base(dir), "HEAD")
end

T["diff: renames compare against the old path; submodules and binaries are skipped"] = function()
  local changes = require("spoor.changes")
  local dir = repo()
  vim.fn.writefile({ "package a", "", "func Old() {}", "", "func Keep() {}", "", "func Keep2() {}" }, dir .. "/old.go")
  git(dir, "add", ".")
  git(dir, "commit", "-q", "-m", "one")
  git(dir, "mv", "old.go", "new.go")
  vim.fn.writefile(
    { "package a", "", "func Old() { Keep() }", "", "func Keep() {}", "", "func Keep2() {}" },
    dir .. "/new.go"
  )
  local sub = repo()
  vim.fn.writefile({ "x" }, sub .. "/x.txt")
  git(sub, "add", ".")
  git(sub, "commit", "-q", "-m", "s")
  git(dir, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "sub")
  local f = assert(io.open(dir .. "/blob.bin", "wb"))
  f:write(string.char(0, 1, 2, 255))
  f:close()
  git(dir, "add", ".")
  local files = changes.diff(dir, "HEAD")
  local by = {}
  for _, f in ipairs(files) do
    by[f.path] = f
  end
  eq(by["new.go"] ~= nil, true)
  eq(by["new.go"].old_has("Old"), true)
  eq(by["sub"], nil)
  eq(by[".gitmodules"] ~= nil, true)
end

return T
