--- spoor.nvim: follow the trail through a codebase.
--- Public API; everything here is safe to call from keymaps and other plugins.
local Config = require("spoor.config")

local M = {}

M.did_setup = false

local function map(lhs, rhs, desc)
  if lhs and lhs ~= false and lhs ~= "" then
    vim.keymap.set("n", lhs, rhs, { desc = desc, silent = true })
  end
end

---@param opts? spoor.Opts|table
function M.setup(opts)
  if vim.fn.has("nvim-0.11") == 0 then
    return vim.notify("spoor.nvim needs Neovim 0.11 or newer", vim.log.levels.ERROR, { title = "spoor" })
  end
  Config.setup(opts)
  require("spoor.highlights").setup()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("spoor_hl", { clear = true }),
    callback = function()
      require("spoor.highlights").setup()
    end,
  })
  require("spoor.live").setup()

  local keys = Config.options.keys or {}
  map(keys.bowtie, M.bowtie, "Bow-tie (callers | callees)")
  map(keys.trace, M.trace, "Trace from here")
  map(keys.resume, M.resume, "Resume Trail")
  map(keys.trails, M.trails, "Trails")
  map(keys.entries, M.entries, "Entry Points")
  map(keys.changes, M.changes, "Changed Symbols (git)")
  if keys.toggle then
    if require("spoor.ui").snacks() and Snacks.toggle then
      Snacks.toggle({
        id = "spoor_live",
        name = "Bow-tie Panel",
        get = function()
          return require("spoor.live").enabled()
        end,
        set = function(state)
          require("spoor.live").set(state)
        end,
      }):map(keys.toggle)
    else
      map(keys.toggle, M.toggle, "Toggle Bow-tie Panel")
    end
  end
  local ok, wk = pcall(require, "which-key")
  if ok and keys.bowtie and keys.bowtie:sub(1, 2) == "ga" then
    wk.add({ { "ga", group = "calls" } })
  end
  M.did_setup = true
  -- Start following right away if Neovim is already showing a code buffer.
  vim.schedule(function()
    require("spoor.live").update()
  end)
end

--- Open the bow-tie float at the cursor, with deeper levels (gag).
function M.bowtie()
  require("spoor.bowtie").open()
end

--- Start a trace at the cursor (gat).
function M.trace()
  require("spoor.trace").start_at_cursor()
end

--- Resume the last trail in this project (<leader>ct).
function M.resume()
  require("spoor.trace").resume()
end

--- Pick a trail in this project (<leader>cT).
function M.trails()
  require("spoor.trace").pick_trail()
end

--- Entry-point picker (<leader>ce).
function M.entries()
  require("spoor.entries").open()
end

--- Changed symbols since a git ref (<leader>cG).
---@param ref? string
function M.changes(ref)
  require("spoor.changes").open({ ref = ref })
end

--- Turn the bottom bow-tie panel on or off; the choice persists.
---@param on? boolean
function M.toggle(on)
  local live = require("spoor.live")
  if on == nil then
    live.toggle()
  else
    live.set(on)
  end
end

--- The bow-tie currently shown in the live panel or float, as plain JSON-ready data.
--- This is the seam for anything built on top of spoor (an AI explainer, a CLI, a test).
---@return table?
function M.current_graph()
  local float = require("spoor.bowtie").current
  local live = require("spoor.live").panels[vim.api.nvim_get_current_tabpage()]
  local v = (float and float:valid() and float) or (live and live:valid() and live) or nil
  return v and v.graph and require("spoor.model").export(v.graph) or nil
end

--- The trail being traced (or nil), as portable JSON-ready data.
---@return table?
function M.current_trail()
  local trail = require("spoor.trace").state.trail
  return trail and require("spoor.export").trail_json(trail) or nil
end

return M
