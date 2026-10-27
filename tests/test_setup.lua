local H = require("tests.helpers")
local T = MiniTest.new_set({ hooks = { pre_case = H.reset } })
local eq, expect = MiniTest.expect.equality, MiniTest.expect

local function maparg(lhs)
  return vim.fn.maparg(vim.keycode(lhs), "n", false, true)
end

T["setup maps the default keys"] = function()
  require("spoor").setup({})
  for _, lhs in ipairs({ "gag", "gat", "<leader>ct", "<leader>cT", "<leader>ce", "<leader>cG", "<leader>uB" }) do
    expect.no_equality(maparg(lhs).lhs, nil)
  end
  eq(maparg("gag").desc, "Bow-tie (callers | callees)")
end

T["keys can be remapped or disabled"] = function()
  require("spoor").setup({ keys = { bowtie = "<leader>cb", changes = false } })
  expect.no_equality(maparg("<leader>cb").lhs, nil)
  eq(maparg("<leader>cG").lhs, nil)
  H.reset()
  require("spoor").setup({ keys = false })
  eq(maparg("gag").lhs, nil)
end

T["default keys avoid LazyVim's own"] = function()
  -- Taken by LazyVim 16 core or its extras (lang.java has a <leader>cg prefix).
  local taken = {
    "gai",
    "gao",
    "<leader>uS",
    "<leader>uG",
    "<leader>cg",
    "<leader>cs",
    "<leader>cS",
    "<leader>ca",
    "<leader>cA",
    "<leader>cc",
    "<leader>cC",
    "<leader>cd",
    "<leader>cf",
    "<leader>cF",
    "<leader>cl",
    "<leader>cm",
    "<leader>co",
    "<leader>cr",
    "<leader>cR",
    "<leader>cp",
    "<leader>cP",
    "<leader>cv",
    "<leader>cx",
    "<leader>ch",
    "<leader>cn",
    "<leader>cM",
    "<leader>cD",
    "<leader>cV",
    "<leader>ub",
    "<leader>us",
    "<leader>uA",
  }
  for _, lhs in pairs(require("spoor.config").defaults.keys) do
    eq({ lhs, vim.tbl_contains(taken, lhs) }, { lhs, false })
  end
end

T[":Spoor command and completion"] = function()
  require("spoor").setup({})
  vim.cmd("runtime plugin/spoor.lua")
  eq(vim.fn.exists(":Spoor"), 2)
  local c = vim.fn.getcompletion("Spoor ", "cmdline")
  for _, sub in ipairs({ "bowtie", "trace", "resume", "trails", "entries", "changes", "live" }) do
    eq({ sub, vim.tbl_contains(c, sub) }, { sub, true })
  end
  vim.cmd("Spoor live off")
  eq(require("spoor.live").enabled(), false)
  vim.cmd("Spoor live")
  eq(require("spoor.live").enabled(), true)
end

T["highlights link to the colorscheme and survive :colorscheme"] = function()
  require("spoor").setup({})
  eq(vim.api.nvim_get_hl(0, { name = "SpoorLoc" }).link, "Comment")
  vim.cmd("hi clear")
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  eq(vim.api.nvim_get_hl(0, { name = "SpoorLoc" }).link, "Comment")
  eq(vim.api.nvim_get_hl(0, { name = "SpoorFocus" }).bold, true)
end

T["health check runs"] = function()
  require("spoor").setup({})
  vim.cmd("checkhealth spoor")
  local out = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  expect.no_equality(out:find("snacks.nvim found", 1, true), nil)
  vim.cmd("bwipeout!")
end

T["gag without a server says so"] = function()
  require("spoor").setup({})
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  vim.cmd("enew")
  require("spoor").bowtie()
  vim.notify = orig
  expect.no_equality(msgs[1]:find("No language server", 1, true), nil)
end

T["gag opens a focused float with deeper levels"] = function()
  local w = H.go_world()
  local p = w.process.selectionRange.start
  local bufnr = H.edit(H.go .. "/internal/order/order.go", p.line + 1, p.character)
  H.fake_server(bufnr, { handlers = H.go_handlers(w) })
  require("spoor").setup({ live = { enabled = false } })
  require("spoor").bowtie()
  H.wait(function()
    local v = require("spoor.bowtie").current
    return v and v:valid() and v.graph and v.graph.status.incoming == "done"
  end)
  local v = require("spoor.bowtie").current
  eq(vim.api.nvim_get_current_win(), v.win.win)
  eq(vim.api.nvim_win_get_config(v.win.win).relative, "editor")
  local json = require("spoor").current_graph()
  eq(json.focus:find("^internal/order/order.go#") ~= nil, true)
  vim.api.nvim_feedkeys("q", "x", false)
  eq(v:valid(), false)
end

return T
