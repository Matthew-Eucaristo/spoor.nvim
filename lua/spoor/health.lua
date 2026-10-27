local M = {}

--- :checkhealth runs in its own buffer (a new tab, or a float with vim.g.health.style);
--- report on the code buffer you came from, preferring one with a language server.
---@return integer?
function M.code_buffer()
  local candidates = { vim.api.nvim_get_current_buf() }
  local prev_tab = vim.fn.tabpagenr("#")
  if prev_tab > 0 then
    local tab = vim.api.nvim_list_tabpages()[prev_tab]
    candidates[#candidates + 1] = tab and vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(tab))
  end
  local prev_win = vim.fn.win_getid(vim.fn.winnr("#"))
  if prev_win > 0 then
    candidates[#candidates + 1] = vim.api.nvim_win_get_buf(prev_win)
  end
  candidates[#candidates + 1] = vim.fn.bufnr("#")
  local first
  for _, buf in ipairs(candidates) do
    if buf and buf > 0 and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" then
      if #vim.lsp.get_clients({ bufnr = buf }) > 0 then
        return buf
      end
      first = first or buf
    end
  end
  return first
end

function M.check()
  local h = vim.health
  h.start("spoor.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.11 or newer is required")
  end
  if require("spoor.ui").snacks() then
    h.ok("snacks.nvim found (windows, pickers with previews, toggles)")
  else
    h.info("snacks.nvim not found: plain windows and vim.ui.select (pickers without previews)")
  end
  if vim.fn.executable("git") == 1 then
    h.ok("git found (entry points, changed symbols)")
  else
    h.warn("git not found: entry points and changed symbols need it")
  end
  local opts = require("spoor.config").options
  local rules = type(opts.frameworks) == "table" and opts.frameworks or {}
  for i, rule in ipairs(rules) do
    local why = require("spoor.frameworks").invalid(rule)
    if why then
      h.warn(("frameworks[%d] (%s) is skipped: %s"):format(i, type(rule) == "table" and rule.id or "?", why))
    end
  end
  for name, fn in pairs(opts.entries or {}) do
    if fn ~= false and type(fn) ~= "function" then
      h.warn(("entries.%s is skipped: a detector is function(root, files) or false"):format(name))
    end
  end
  if #rules > 0 or next(opts.entries or {}) then
    h.info(("your rules: %d framework, %d entry-point"):format(#rules, vim.tbl_count(opts.entries or {})))
  end
  local live = require("spoor.live")
  h.info("live bow-tie: " .. (live.enabled() and "on" or "off") .. (live.paused and " (paused this session)" or ""))
  h.info("state: " .. require("spoor.util").state_dir())

  h.start("spoor.nvim: language servers in this buffer")
  local bufnr = M.code_buffer()
  local clients = bufnr and vim.lsp.get_clients({ bufnr = bufnr }) or {}
  if bufnr and vim.api.nvim_buf_get_name(bufnr) ~= "" then
    h.info("buffer: " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:."))
  end
  local hierarchy = false
  for _, c in ipairs(clients) do
    hierarchy = hierarchy or c:supports_method("textDocument/prepareCallHierarchy", bufnr)
  end
  if #clients == 0 then
    h.info("No language server attached to the current buffer; open a code file and run :checkhealth spoor again.")
  end
  if bufnr and not hierarchy then
    local syntax = require("spoor.syntax")
    if require("spoor.config").options.syntax and syntax.available(bufnr) then
      local ok, parser = pcall(vim.treesitter.get_parser, bufnr, nil, { error = false })
      h.ok(("tree-sitter (%s): same-file bow-tie, syntax only"):format(ok and parser and parser:lang() or "?"))
    else
      h.info("No call hierarchy and no tree-sitter parser here: spoor stays quiet in this buffer")
    end
  end
  for _, c in ipairs(clients) do
    local caps = {}
    for _, m in ipairs({
      "textDocument/prepareCallHierarchy",
      "callHierarchy/incomingCalls",
      "callHierarchy/outgoingCalls",
      "textDocument/implementation",
      "textDocument/references",
      "textDocument/documentSymbol",
    }) do
      caps[#caps + 1] = (c:supports_method(m, bufnr) and "✓ " or "✗ ") .. m:gsub("^.*/", "")
    end
    local fn = c:supports_method("textDocument/prepareCallHierarchy", bufnr) and h.ok or h.warn
    fn(("%s: %s"):format(c.name, table.concat(caps, ", ")))
  end
end

return M
