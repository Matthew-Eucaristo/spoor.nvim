-- spoor without snacks.nvim: plain windows, vim.ui.select pickers, no errors.
local H = require("tests.helpers")
local restore
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      H.reset()
      restore = H.without_snacks()
      vim.v.errmsg = ""
    end,
    post_case = function()
      restore()
      MiniTest.expect.equality(vim.v.errmsg, "")
    end,
  },
})
local eq, expect = MiniTest.expect.equality, MiniTest.expect

local function start(config)
  local w = H.go_world()
  local p = w.process.selectionRange.start
  local bufnr = H.edit(H.go .. "/internal/order/order.go", p.line + 1, p.character)
  H.fake_server(bufnr, { handlers = H.go_handlers(w) })
  require("spoor").setup(vim.tbl_deep_extend("force", { live = { debounce = 10, card = { delay = 0 } } }, config or {}))
  return w, bufnr
end

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function panel()
  return require("spoor.live").panels[vim.api.nvim_get_current_tabpage()]
end

local function shown(v)
  return v and v:valid() and v.graph and v.graph.complete and text(v.win.buf):find("handleOrders", 1, true) ~= nil
end

T["setup maps the keys and needs nothing else"] = function()
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  start()
  vim.notify = orig
  eq(msgs, {})
  eq(require("spoor.ui").snacks(), false)
  eq(vim.fn.maparg("gag", "n", false, true).desc, "Bow-tie (callers | callees)")
  eq(vim.fn.maparg(vim.keycode("<leader>uB"), "n", false, true).desc, "Toggle Bow-tie Panel")
end

T["the live card follows the cursor in a plain float"] = function()
  start()
  local code = vim.api.nvim_get_current_win()
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    return shown(panel())
  end, 3000, "card")
  local v = panel()
  local cfg = vim.api.nvim_win_get_config(v.win.win)
  eq(cfg.relative, "editor")
  eq(cfg.focusable, false)
  eq(vim.api.nvim_get_current_win(), code)
  eq(vim.bo[v.win.buf].filetype, "spoor")
end

T["the bottom panel is a plain split; g? lists its keys; q turns live off"] = function()
  start({ live = { panel = true, layout = "bottom" } })
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    return shown(panel())
  end, 3000, "panel")
  local v = panel()
  eq(vim.api.nvim_win_get_config(v.win.win).relative, "")
  eq(vim.wo[v.win.win].winfixbuf, true)
  vim.api.nvim_set_current_win(v.win.win)
  vim.api.nvim_feedkeys(vim.keycode("g?"), "x", false)
  local help = vim.tbl_filter(function(w)
    return vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "spoor_help"
  end, vim.api.nvim_tabpage_list_wins(0))
  eq(#help, 1)
  expect.no_equality(text(vim.api.nvim_win_get_buf(help[1])):find("Jump to node", 1, true), nil)
  vim.api.nvim_feedkeys("q", "x", false)
  eq(require("spoor.live").enabled(), false)
  eq(v:valid(), false)
  eq(vim.api.nvim_win_is_valid(help[1]), false)
end

T["gag opens a float, <C-v> moves it to a split, q closes it"] = function()
  start({ live = { enabled = false } })
  local code = vim.api.nvim_get_current_win()
  require("spoor").bowtie()
  local bowtie = require("spoor.bowtie")
  H.wait(function()
    return shown(bowtie.current)
  end, 3000, "float")
  local v = bowtie.current
  eq(vim.api.nvim_get_current_win(), v.win.win)
  eq(vim.api.nvim_win_get_config(v.win.win).relative, "editor")
  vim.api.nvim_feedkeys(vim.keycode("<C-v>"), "x", false)
  local p = bowtie.pinned
  eq(p:valid(), true)
  eq(v:valid(), false)
  eq(vim.api.nvim_win_get_config(p.win.win).relative, "")
  eq(vim.api.nvim_get_current_win(), p.win.win)
  vim.api.nvim_feedkeys("q", "x", false)
  eq(p:valid(), false)
  eq(vim.api.nvim_get_current_win(), code)
end

T["gat opens the trail beside the code window"] = function()
  start({ live = { enabled = false } })
  local code = vim.api.nvim_get_current_win()
  require("spoor").trace()
  local s = require("spoor.trace").state
  H.wait(function()
    return s.win and s.win:valid() and #s.hops >= 5
  end, 3000, "trace")
  eq(vim.api.nvim_win_get_width(s.win.win), require("spoor.config").options.trace.width)
  require("spoor.trace").close()
  eq(s.win:valid(), false)
  eq(vim.api.nvim_get_current_win(), code)
end

T["health says snacks.nvim is optional"] = function()
  start({ live = { enabled = false } })
  vim.cmd("checkhealth spoor")
  local buf, out = vim.api.nvim_get_current_buf(), ""
  H.wait(function()
    out = text(buf)
    return out:find("fake:", 1, true) ~= nil
  end, 3000, "health output")
  expect.no_equality(out:find("snacks.nvim not found: plain windows and vim.ui.select", 1, true), nil)
  eq(out:find("ERROR", 1, true), nil)
  vim.cmd("bwipeout!")
end

T["pickers go through vim.ui.select"] = function()
  start({ live = { enabled = false } })
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/cmd", "p")
  vim.fn.writefile({ "package main", "", "func main() {", "}" }, dir .. "/cmd/main.go")
  vim.system({ "git", "init", "-q" }, { cwd = dir }):wait()
  local orig, seen = vim.ui.select, nil
  vim.ui.select = function(items, opts, cb)
    seen = { items = items, prompt = opts.prompt, first = opts.format_item(items[1]) }
    cb(items[1])
  end
  vim.cmd.edit(dir .. "/go.mod") -- a buffer in that repo, without a language server
  require("spoor").entries()
  vim.ui.select = orig
  eq(seen.prompt, "Entry points")
  expect.no_equality(seen.first:find("main", 1, true), nil)
  eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "main.go")
  eq(vim.api.nvim_win_get_cursor(0)[1], 3)
end

T["K grows the card without snacks too, and a hover with no room left is fine"] = function()
  start()
  vim.cmd("normal! zz")
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    return shown(panel())
  end, 3000, "card")
  vim.cmd("redraw")
  local buf = vim.api.nvim_create_buf(false, true)
  local hover = vim.api.nvim_open_win(buf, false, { relative = "cursor", row = 1, col = 0, width = 30, height = 3 })
  H.wait(function()
    local e = require("spoor.live").expanded[vim.api.nvim_get_current_tabpage()]
    return e and e.graph and e.graph.complete
  end, 3000, "full bow-tie")
  vim.api.nvim_win_close(hover, true)
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  -- now a hover that leaves no room at all
  vim.cmd("normal! zz")
  H.wait(function()
    return shown(panel())
  end, 3000, "card again")
  vim.cmd("redraw")
  hover = vim.api.nvim_open_win(
    buf,
    false,
    { relative = "editor", row = 0, col = 0, width = vim.o.columns, height = vim.o.lines - 3 }
  )
  vim.api.nvim_win_set_config(hover, { relative = "cursor", row = -(vim.fn.winline() - 1), col = 0 })
  vim.wait(500)
  vim.api.nvim_win_close(hover, true)
  vim.api.nvim_exec_autocmds("CursorMoved", {})
end

return T
