-- The default live layout (a card next to the cursor), gag's code preview, and moving gag to a split or tab.
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

local function start(config)
  local w = H.go_world()
  local p = w.process.selectionRange.start
  local bufnr = H.edit(H.go .. "/internal/order/order.go", p.line + 1, p.character)
  local server = H.fake_server(bufnr, { handlers = H.go_handlers(w) })
  require("spoor").setup(vim.tbl_deep_extend("force", { live = { debounce = 10 } }, config or {}))
  return w, bufnr, server
end

local function card()
  local v = require("spoor.live").panels[vim.api.nvim_get_current_tabpage()]
  return v and v:valid() and v.opts.kind == "card" and v or nil
end

local function wait_card()
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    local v = card()
    return v and v.graph and v.graph.complete
  end, 3000, "card")
  return card()
end

local function open_float()
  require("spoor").bowtie()
  H.wait(function()
    local v = require("spoor.bowtie").current
    return v and v:valid() and v.graph and v.graph.complete
  end, 3000, "float")
  return require("spoor.bowtie").current
end

local function cursor_on(v, name)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(v.win.buf, 0, -1, false)) do
    local s = l:find(name, 1, true)
    if s then
      vim.api.nvim_win_set_cursor(v.win.win, { i, s - 1 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = v.win.buf })
      return
    end
  end
  error("no " .. name)
end

local function rows(v)
  local cfg = vim.api.nvim_win_get_config(v.win.win)
  return cfg.row, cfg.row + cfg.height + 1 -- border rows included
end

local function cursor_row()
  local pos = vim.fn.screenpos(0, vim.fn.line("."), vim.fn.col("."))
  return pos.row - 1
end

T["the default is a card next to the cursor that never takes focus or covers its line"] = function()
  start()
  local code = vim.api.nvim_get_current_win()
  vim.cmd("normal! zz")
  local v = wait_card()
  local cfg = vim.api.nvim_win_get_config(v.win.win)
  eq(cfg.relative, "editor")
  eq(cfg.focusable, false)
  local top, bottom = rows(v)
  eq(bottom < cursor_row(), true) -- above the cursor line
  eq(cursor_row() - bottom <= 1, true) -- right above it
  eq(vim.api.nvim_get_current_win(), code)
  local text = table.concat(vim.api.nvim_buf_get_lines(v.win.buf, 0, -1, false), "\n")
  expect.no_equality(text:find("handleOrders", 1, true), nil)
  expect.no_equality(text:find("more", 1, true), nil) -- 5 callees, 4 shown
  eq(cfg.footer[2][1], "gag")
  local _ = top
end

T["near the top of the window the card goes below the cursor line"] = function()
  start()
  vim.cmd("normal! zt") -- the focus line is now the top screen row
  local v = wait_card()
  local top = rows(v)
  eq(top > cursor_row(), true)
end

T["the card steps aside for a hover float and comes back"] = function()
  start()
  wait_card()
  local buf = vim.api.nvim_create_buf(false, true)
  local hover = vim.api.nvim_open_win(buf, false, { relative = "cursor", row = 1, col = 0, width = 20, height = 2 })
  H.wait(function()
    return card() == nil
  end, 2000, "card hidden for hover")
  vim.api.nvim_win_close(hover, true)
  H.wait(function()
    local v = card()
    return v and v.graph and v.graph.complete
  end, 3000, "card back")
end

T["the card hides while typing and where there is no function"] = function()
  start()
  wait_card()
  vim.api.nvim_exec_autocmds("InsertEnter", {})
  eq(card(), nil)
  wait_card()
  vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- `package order`: nothing to show
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  H.wait(function()
    return card() == nil
  end, 3000, "card gone")
end

T["gag previews the node under the cursor and <Esc> puts the code window back"] = function()
  local _, bufnr = start({ live = { enabled = false } })
  local code = vim.api.nvim_get_current_win()
  local before = vim.api.nvim_win_get_cursor(code)
  local v = open_float()
  cursor_on(v, "validate")
  local shown = vim.api.nvim_win_get_buf(code)
  expect.no_equality(shown, bufnr)
  eq(vim.fs.basename(vim.api.nvim_buf_get_name(shown)), "validate.go")
  eq(vim.bo[shown].buflisted, false) -- a preview doesn't clutter the buffer list
  eq(vim.api.nvim_win_get_cursor(code)[1], 7) -- on validate's name
  vim.api.nvim_set_current_win(v.win.win)
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
  eq(v:valid(), false)
  eq(vim.api.nvim_win_get_buf(code), bufnr)
  eq(vim.api.nvim_win_get_cursor(code), before)
  eq(vim.api.nvim_buf_is_valid(shown), false) -- opened only for the preview
end

T["<CR> after a preview stays there and lists the buffer"] = function()
  start({ live = { enabled = false } })
  local code = vim.api.nvim_get_current_win()
  local v = open_float()
  cursor_on(v, "validate")
  vim.api.nvim_set_current_win(v.win.win)
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  eq(vim.api.nvim_get_current_win(), code)
  local buf = vim.api.nvim_get_current_buf()
  eq(vim.fs.basename(vim.api.nvim_buf_get_name(buf)), "validate.go")
  eq(vim.bo[buf].buflisted, true)
end

T["<C-v> moves the graph to a vertical split that stays open"] = function()
  start({ live = { enabled = false } })
  local v = open_float()
  vim.api.nvim_set_current_win(v.win.win)
  vim.api.nvim_feedkeys(vim.keycode("<C-v>"), "x", false)
  eq(v:valid(), false)
  local p = require("spoor.bowtie").pinned
  eq(p:valid(), true)
  eq(vim.api.nvim_win_get_config(p.win.win).relative, "")
  eq(vim.api.nvim_win_get_width(p.win.win) < vim.o.columns, true)
  eq(p.graph.nodes[p.graph.focus].name, "Process")
  eq(vim.wo[p.win.win].winbar:find("Process", 1, true) ~= nil, true)
  vim.api.nvim_set_current_win(p.win.win)
  cursor_on(p, "Emit")
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  eq(p:valid(), true) -- still open
  eq(vim.fs.basename(vim.api.nvim_buf_get_name(0)), "bus.go")
  p:close()
end

T["<C-s> and <C-t> move it to a bottom split or a tab of its own"] = function()
  start({ live = { enabled = false } })
  local v = open_float()
  vim.api.nvim_set_current_win(v.win.win)
  vim.api.nvim_feedkeys(vim.keycode("<C-s>"), "x", false)
  local p = require("spoor.bowtie").pinned
  eq(vim.api.nvim_win_get_width(p.win.win), vim.o.columns)
  p:close()
  local tabs = #vim.api.nvim_list_tabpages()
  v = open_float()
  vim.api.nvim_set_current_win(v.win.win)
  vim.api.nvim_feedkeys(vim.keycode("<C-t>"), "x", false)
  eq(#vim.api.nvim_list_tabpages(), tabs + 1)
  p = require("spoor.bowtie").pinned
  eq(vim.api.nvim_win_get_tabpage(p.win.win), vim.api.nvim_get_current_tabpage())
  vim.cmd("tabclose")
end

return T
