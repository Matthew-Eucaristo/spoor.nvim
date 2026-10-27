if vim.g.loaded_spoor then
  return
end
vim.g.loaded_spoor = true

local subcommands = {
  bowtie = function()
    require("spoor").bowtie()
  end,
  trace = function()
    require("spoor").trace()
  end,
  resume = function()
    require("spoor").resume()
  end,
  trails = function()
    require("spoor").trails()
  end,
  entries = function()
    require("spoor").entries()
  end,
  changes = function(args)
    require("spoor").changes(args[1])
  end,
  live = function(args)
    -- "on" / "off"; anything else toggles
    local state = ({ on = true, off = false })[args[1] or ""]
    require("spoor").toggle(state)
  end,
  graph = function()
    local g = require("spoor").current_graph()
    print(g and vim.json.encode(g) or "no bow-tie open")
  end,
  trail = function()
    local t = require("spoor").current_trail()
    print(t and vim.json.encode(t) or "no trail")
  end,
}

vim.api.nvim_create_user_command("Spoor", function(cmd)
  local args = vim.split(vim.trim(cmd.args), "%s+", { trimempty = true })
  local name = table.remove(args, 1) or "bowtie"
  local fn = subcommands[name]
  if not fn then
    return vim.notify("Unknown :Spoor subcommand: " .. name, vim.log.levels.ERROR, { title = "spoor" })
  end
  if not require("spoor").did_setup then
    require("spoor").setup()
  end
  fn(args)
end, {
  nargs = "*",
  desc = "spoor: bow-tie, trace, trails, entries, changes, live",
  complete = function(arglead, line)
    local words = vim.split(line, "%s+")
    if #words <= 2 then
      return vim.tbl_filter(function(s)
        return s:find(arglead, 1, true) == 1
      end, vim.tbl_keys(subcommands))
    end
    if words[2] == "live" then
      return { "on", "off", "toggle" }
    end
    return {}
  end,
})
