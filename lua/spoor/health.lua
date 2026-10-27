local M = {}

function M.check()
  local h = vim.health
  h.start("spoor.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.11 or newer is required")
  end
  if _G.Snacks and Snacks.win and Snacks.picker then
    h.ok("snacks.nvim found (windows, pickers, toggles)")
  else
    h.error("snacks.nvim is required: https://github.com/folke/snacks.nvim")
  end
  if vim.fn.executable("git") == 1 then
    h.ok("git found (entry points, changed symbols)")
  else
    h.warn("git not found: entry points and changed symbols need it")
  end
  local live = require("spoor.live")
  h.info("live bow-tie: " .. (live.enabled() and "on" or "off") .. (live.paused and " (paused this session)" or ""))
  h.info("state: " .. require("spoor.util").state_dir())

  h.start("spoor.nvim: language servers in this buffer")
  local bufnr = vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    h.info("No language server attached to the current buffer; open a code file and run :checkhealth spoor again.")
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
