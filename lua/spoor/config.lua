---@class spoor.Config
local M = {}

---@class spoor.Opts
M.defaults = {
  -- The live bow-tie: callers | focus | callees, following the cursor.
  live = {
    panel = false, -- the bottom panel: first-run default; <leader>uB toggles it and remembers
    debounce = 120, -- ms the cursor must rest before the panel asks the language server
    layout = "bottom", -- where the panel goes: "bottom" (split) or "float" (a corner)
    height = 8, -- panel rows, header included
    max_items = 6, -- panel: rows per side before "+N more"
    -- rest the cursor this long (ms) and a card shows the bow-tie next to it; false = never.
    -- K (hover) shows the full bow-tie right away either way.
    card = { delay = 5000, width = 64, max_items = 4 },
    hover = true, -- K: the full bow-tie next to the hover, at once; false leaves K alone
  },
  -- The on-demand float (gag) with deeper levels.
  float = {
    width = 0.86,
    depth = 2, -- levels per side opened up front (1 = neighbours only)
    max_items = 12, -- rows per side per level before "+N more"
    preview = true, -- show the node under the cursor in the code window; <CR> stays, <Esc> returns
  },
  -- Where no language server has call hierarchy (or there is none), a bow-tie from tree-sitter:
  -- callees in the function, callers from the project (the server's find-references, else
  -- git grep for the name). The language server's call hierarchy always wins.
  syntax = true,
  timeout = 1500, -- hard per-request timeout in ms
  cold_timeout = 15000, -- for a server's first answer, while it is still indexing
  max_nodes = 60, -- cap on nodes in one expanded graph
  implementations = true, -- ◇N badges on interface/abstract callees (textDocument/implementation)
  max_implementation_lookups = 8,
  references = true, -- when there are no static callers, show "used as a value" sites (~)
  -- Per-server tweaks, keyed by client name. Measured on real repos; see README "Performance".
  --   timeout: per-request timeout; depth: float levels; live_callers = false: the live panel
  --   shows callees right away and finds callers only when you press R (slow workspace search).
  servers = {
    dartls = { depth = 1, timeout = 20000, live_callers = false },
  },
  hide = {
    external = true, -- outside the project, vendor/, node_modules, SDKs
    generated = true, -- "Code generated ... DO NOT EDIT", *.pb.go, *.g.dart, ...
    tests = false,
  },
  -- Extra path patterns (Lua patterns, matched against the path relative to the project root)
  exclude = {},
  -- Tag framework-invoked roots (Next.js routes, Flutter build(), Go handlers, ...). true: the
  -- built-in rules; false: off; a list of rules: yours, tried before the built-in ones
  -- (see :h spoor-frameworks).
  frameworks = true,
  -- Your own entry-point detectors for <leader>ce, by name: name = function(root, files) that
  -- returns entries. A built-in name replaces that detector, and name = false turns it off.
  entries = {},
  trace = {
    width = 58,
    max_hops = 9, -- next-hop candidates numbered 1-9
  },
  changes = {
    base = nil, -- git ref; default: merge-base with the default branch, or HEAD on it
    max_files = 60,
  },
  -- Global keymaps. Set a key to false to skip it, or keys = false to skip all.
  keys = {
    bowtie = "gag",
    trace = "gat",
    resume = "<leader>ct",
    trails = "<leader>cT",
    entries = "<leader>ce",
    changes = "<leader>cG",
    toggle = "<leader>uB",
  },
  icons = {
    focus = "󰊕",
    caller = "",
    callee = "",
    interface = "◇",
    value = "~",
    jsx = "</>",
    framework = "⚑",
    external = "",
    test = "󰙨",
    generated = "",
    note = "✎",
    here = "●",
    new = "+",
    modified = "●",
    warn = "⚠",
  },
}

---@type spoor.Opts
M.options = vim.deepcopy(M.defaults)

---@param opts? spoor.Opts|table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if opts and opts.keys == false then
    M.options.keys = {}
  end
  return M.options
end

--- Options for one language server, with `servers[name]` applied on top.
---@param client_name? string
function M.for_server(client_name)
  local o = M.options
  local s = (client_name and o.servers[client_name]) or {}
  return {
    timeout = s.timeout or o.timeout,
    depth = s.depth or o.float.depth,
    live_callers = s.live_callers ~= false,
  }
end

return M
