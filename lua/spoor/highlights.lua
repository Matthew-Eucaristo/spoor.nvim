--- Highlight groups. All link to standard groups so the colorscheme decides the look.
local M = {}

M.links = {
  SpoorHeader = "Title",
  SpoorCount = "Number",
  SpoorName = "Function",
  SpoorLoc = "Comment",
  SpoorEdge = "Comment",
  SpoorBadge = "Special",
  SpoorInterface = "Type",
  SpoorValue = "Special",
  SpoorFramework = "DiagnosticInfo",
  SpoorMessage = "Comment",
  SpoorWarn = "DiagnosticWarn",
  SpoorMore = "Comment",
  SpoorDim = "Comment",
  SpoorNote = "String",
  SpoorKey = "Special",
  SpoorHere = "DiagnosticOk",
  SpoorAdd = "Added",
  SpoorChange = "Changed",
}

function M.setup()
  for group, link in pairs(M.links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  -- The focus is the one bold thing on screen.
  local fn = vim.api.nvim_get_hl(0, { name = "Function", link = false })
  vim.api.nvim_set_hl(0, "SpoorFocus", { fg = fn.fg, bold = true, default = true })
end

return M
