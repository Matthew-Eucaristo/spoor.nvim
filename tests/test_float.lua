local H = require("tests.helpers")
local T = MiniTest.new_set({ hooks = { pre_case = H.reset } })
local eq, expect = MiniTest.expect.equality, MiniTest.expect

local function open_float()
  local w = H.go_world()
  local p = w.process.selectionRange.start
  local bufnr = H.edit(H.go .. "/internal/order/order.go", p.line + 1, p.character)
  local handlers = H.go_handlers(w, {
    ["callHierarchy/outgoingCalls"] = function(params)
      if params.item.name == "Process" then
        return w.outgoing
      elseif params.item.name == "validate" then
        return { { to = w.emit, fromRanges = { H.site(w.validate) } } }
      end
      return {}
    end,
  })
  local server = H.fake_server(bufnr, { handlers = handlers })
  require("spoor").setup({ live = { enabled = false }, float = { depth = 1 } })
  require("spoor").bowtie()
  H.wait(function()
    local v = require("spoor.bowtie").current
    return v and v:valid() and v.graph.status.incoming == "done" and v.graph.status.outgoing == "done"
  end)
  return require("spoor.bowtie").current, w, server
end

local function cursor_on(v, name)
  local lines = vim.api.nvim_buf_get_lines(v.win.buf, 0, -1, false)
  for i, l in ipairs(lines) do
    local s = l:find(name, 1, true)
    if s then
      vim.api.nvim_win_set_cursor(v.win.win, { i, s - 1 })
      return
    end
  end
  error("no " .. name .. " in the float")
end

local function text(v)
  return table.concat(vim.api.nvim_buf_get_lines(v.win.buf, 0, -1, false), "\n")
end

T["pressing gag twice quickly opens one float"] = function()
  local v = open_float()
  v:close()
  require("spoor").bowtie()
  require("spoor").bowtie()
  vim.wait(200)
  local floats = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      floats = floats + 1
    end
  end
  eq(floats, 1)
end

T["opens on the focus row"] = function()
  local v = open_float()
  local row = vim.api.nvim_win_get_cursor(v.win.win)[1]
  eq(v.rendered.map[row].focus, true)
end

T["<Tab> opens one more level and folds it again"] = function()
  local v = open_float()
  cursor_on(v, "validate")
  require("spoor.bowtie").expand(v)
  H.wait(function()
    return text(v):find("▸", 1, true) ~= nil
  end)
  cursor_on(v, "validate")
  require("spoor.bowtie").expand(v)
  eq(text(v):find("▸", 1, true), nil)
end

T["re-root and back"] = function()
  local v = open_float()
  cursor_on(v, "validate")
  require("spoor.bowtie").float_actions.reroot(v)
  H.wait(function()
    return v.graph.nodes[v.graph.focus].name == "validate" and v.graph.complete
  end)
  -- the cursor lands on the new focus, not where it was
  local _, side = v:node_at_cursor()
  eq(side, "focus")
  require("spoor.bowtie").float_actions.back(v)
  eq(v.graph.nodes[v.graph.focus].name, "Process")
  _, side = v:node_at_cursor()
  eq(side, "focus")
end

T["<CR> jumps and closes"] = function()
  local v, w = open_float()
  cursor_on(v, "Emit")
  require("spoor.bowtie").float_actions.jump(v)
  eq(v:valid(), false)
  eq(vim.api.nvim_buf_get_name(0), vim.uri_to_fname(w.emit.uri))
end

T["H shows hidden nodes; y copies Mermaid"] = function()
  local v = open_float()
  require("spoor.bowtie").float_actions.toggle_hidden(v)
  eq(v.show_all, true)
  require("spoor.bowtie").float_actions.yank(v)
  expect.no_equality(vim.fn.getreg('"'):find("^graph LR"), nil)
end

T["a late update after closing never moves the code cursor"] = function()
  local v = open_float()
  vim.bo[v.win.buf].bufhidden = "hide" -- LazyVim's snacks keeps the buffer after close
  v:close()
  local code = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(code, { 1, 0 })
  v:render(v.graph)
  eq(vim.api.nvim_win_get_cursor(code), { 1, 0 })
end

return T
