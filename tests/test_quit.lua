-- Quitting must work from every window while spoor's panels are open (a QuitPre handler that
-- closes the current window makes Neovim abandon the quit).
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function quit(where, cmd)
  local res = vim
    .system({
      vim.v.progpath,
      "--headless",
      "--noplugin",
      "-u",
      _G.SPOOR_ROOT .. "/tests/minimal_init.lua",
      "-c",
      "luafile " .. _G.SPOOR_ROOT .. "/tests/scripts/quit.lua",
    }, { env = { SPOOR_REPO = _G.SPOOR_ROOT, WHERE = where, CMD = cmd }, text = true })
    :wait(15000)
  return res.code
end

for _, case in ipairs({
  { "trace", "qa!" },
  { "trace", "qa" },
  { "trace", "wqa" },
  { "panel", "qa" },
  { "code", "q" },
  { "code+trail", "q" },
  { "code+trail", "wq" },
  { "code", "qa" },
}) do
  T[("%s from the %s window exits"):format(case[2], case[1])] = function()
    eq(quit(case[1], case[2]), 0)
  end
end

return T
