-- Times the tree-sitter (syntax only) bow-tie on a generated 5k-line file.
--
--   nvim --clean -l bench/syntax.lua            (Lua; SPOOR_BENCH_LINES=5000)
--   SPOOR_BENCH_FILE=path/to/big.c nvim --clean -l bench/syntax.lua
--
-- Prints one JSON object of milliseconds: the first build (parse + index), a build in an
-- already indexed buffer, and the same after an edit (incremental parse + re-index).
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(repo)
vim.cmd("filetype on")

local function now()
  return vim.uv.hrtime() / 1e6
end

local file = os.getenv("SPOOR_BENCH_FILE")
if not file then
  local want = tonumber(os.getenv("SPOOR_BENCH_LINES") or "5000")
  local lines = { "local M = {}" }
  local n = math.floor(want / 8)
  for i = 1, n do
    vim.list_extend(lines, {
      ("function M.f%d(x)"):format(i),
      ("  local y = M.f%d(x) + helper(x)"):format(math.max(i - 1, 1)),
      "  if y > 1 then",
      ("    y = y + M.f%d(y)"):format((i * 7) % n + 1),
      "  end",
      "  -- a comment about f1",
      "  return y",
      "end",
    })
  end
  lines[#lines + 1] = "return M"
  file = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(lines, file)
end

vim.cmd.edit(vim.fn.fnameescape(file))
local buf = vim.api.nvim_get_current_buf()
local count = vim.api.nvim_buf_line_count(buf)
local syntax = require("spoor.syntax")
require("spoor.config").setup({})

local function build(row)
  local t0, g = now(), nil
  local done = false
  syntax.at(buf, { row, 11 }, function(r)
    g, done = r, true
  end)
  vim.wait(10000, function()
    return done
  end, 1)
  return now() - t0, g
end

local function median(xs)
  table.sort(xs)
  return xs[math.ceil(#xs / 2)]
end

local first, g = build(1)
local cached = {}
for i = 1, 9 do
  cached[i] = build(math.floor(count * i / 10))
end
local edited = {}
for i = 1, 5 do
  vim.api.nvim_buf_set_lines(buf, count - 1, count - 1, false, { "-- edit " .. i })
  edited[i] = build(math.floor(count / 2))
end
local edges = g and #g.edges or 0
io.stdout:write(vim.json.encode({
  nvim = tostring(vim.version()),
  lines = count,
  edges_at_first_focus = edges,
  first_ms = math.floor(first * 10) / 10,
  cached_median_ms = math.floor(median(cached) * 10) / 10,
  cached_max_ms = math.floor(math.max(unpack(cached)) * 10) / 10,
  after_edit_median_ms = math.floor(median(edited) * 10) / 10,
}) .. "\n")
