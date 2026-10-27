--- Kind icons from LazyVim's own sources (mini.icons, then LazyVim.config.icons),
--- so spoor looks like the rest of the editor.
local M = {}

local fallback = {
  Function = "󰊕",
  Method = "󰊕",
  Constructor = "",
  Class = "",
  Interface = "",
  Struct = "󰆼",
  Variable = "󰀫",
  Constant = "󰏿",
  Field = "",
  Property = "",
  Module = "",
  Event = "",
}

---@param kind integer|string LSP SymbolKind
---@return string icon, string hl
function M.kind(kind)
  local name = type(kind) == "number" and vim.lsp.protocol.SymbolKind[kind] or kind
  if type(name) ~= "string" then
    return "•", "SpoorName"
  end
  if _G.MiniIcons then
    local ok, icon, hl = pcall(_G.MiniIcons.get, "lsp", name:lower())
    if ok and icon then
      return icon, hl
    end
  end
  local lazy = rawget(_G, "LazyVim")
  if lazy and lazy.config and lazy.config.icons and lazy.config.icons.kinds and lazy.config.icons.kinds[name] then
    return vim.trim(lazy.config.icons.kinds[name]), "SpoorName"
  end
  return fallback[name] or "•", "SpoorName"
end

return M
