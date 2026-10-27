-- Times call hierarchy requests against a real language server.
--
--   SPOOR_BENCH_ROOT=~/code/app SPOOR_BENCH_CMD='["gopls"]' SPOOR_BENCH_FILES='["internal/a.go"]' \
--     nvim --clean -l bench/callhierarchy.lua
--
-- Prints one JSON object: per-request latencies (ms) and fan-in/fan-out counts.
-- Read-only: it opens files and asks the server questions; it never writes to the project.

local root = assert(os.getenv("SPOOR_BENCH_ROOT"), "SPOOR_BENCH_ROOT is required")
local cmd = vim.json.decode((assert(os.getenv("SPOOR_BENCH_CMD"), "SPOOR_BENCH_CMD is required")))
local files = vim.json.decode((assert(os.getenv("SPOOR_BENCH_FILES"), "SPOOR_BENCH_FILES is required")))
local per_file = tonumber(os.getenv("SPOOR_BENCH_PER_FILE") or "4")
local ft = os.getenv("SPOOR_BENCH_FT")
local out_path = os.getenv("SPOOR_BENCH_OUT")
local req_timeout = tonumber(os.getenv("SPOOR_BENCH_TIMEOUT") or "30000")
local verbose = os.getenv("SPOOR_BENCH_VERBOSE") ~= nil

local function now()
  return vim.uv.hrtime() / 1e6
end

---@return any result, number ms, string? err
local function request(client, method, params, bufnr, timeout)
  local done, res, err = false, nil, nil
  local t0 = now()
  client:request(method, params, function(e, r)
    err, res, done = e and (e.message or vim.inspect(e)) or nil, r, true
  end, bufnr)
  vim.wait(timeout or req_timeout, function()
    return done
  end, 5)
  local ms = now() - t0
  if verbose then
    io.stderr:write(("%-40s %8.0f ms%s\n"):format(method, ms, done and "" or " TIMEOUT"))
  end
  return res, ms, (not done) and "timeout" or err
end

local function walk(symbols, acc)
  for _, s in ipairs(symbols or {}) do
    if s.kind == 12 or s.kind == 6 or s.kind == 9 then
      acc[#acc + 1] = s
    end
    walk(s.children, acc)
  end
  return acc
end

local result = { cmd = cmd[1], files = #files, samples = {}, cold = {} }

vim.cmd("cd " .. vim.fn.fnameescape(root))
local client_id
for fi, rel in ipairs(files) do
  vim.cmd("edit " .. vim.fn.fnameescape(rel))
  local bufnr = vim.api.nvim_get_current_buf()
  if ft then
    vim.bo[bufnr].filetype = ft
  end
  if not client_id then
    local t0 = now()
    client_id = vim.lsp.start({ name = "bench", cmd = cmd, root_dir = root }, { bufnr = bufnr })
    vim.wait(30000, function()
      local c = vim.lsp.get_client_by_id(client_id)
      return c and c.initialized
    end, 10)
    result.cold.initialize_ms = now() - t0
  else
    vim.lsp.buf_attach_client(bufnr, client_id)
  end
  local client = assert(vim.lsp.get_client_by_id(client_id))
  local uri = vim.uri_from_bufnr(bufnr)
  local syms, sym_ms, sym_err = request(client, "textDocument/documentSymbol", { textDocument = { uri = uri } }, bufnr)
  if fi == 1 then
    result.cold.document_symbol_ms = sym_ms
  end
  local fns = walk(syms, {})
  for i = 1, math.min(per_file, #fns) do
    local s = fns[i]
    local pos = (s.selectionRange or s.location.range).start
    local params = { textDocument = { uri = uri }, position = pos }
    local items, prep_ms, prep_err = request(client, "textDocument/prepareCallHierarchy", params, bufnr)
    local sample = { name = s.name, prepare_ms = prep_ms, err = prep_err or sym_err }
    local item = items and items[1]
    if item then
      local inc, in_ms, in_err = request(client, "callHierarchy/incomingCalls", { item = item }, bufnr)
      local outc, out_ms, out_err = request(client, "callHierarchy/outgoingCalls", { item = item }, bufnr)
      sample.incoming_ms, sample.outgoing_ms = in_ms, out_ms
      sample.callers, sample.callees = inc and #inc or 0, outc and #outc or 0
      sample.err = in_err or out_err
      -- depth 2 incoming: one request per caller, as a deeper view would issue them
      local d2_t0, d2_req, d2_nodes = now(), 0, 0
      for _, call in ipairs(inc or {}) do
        local inc2 = request(client, "callHierarchy/incomingCalls", { item = call.from }, bufnr)
        d2_req, d2_nodes = d2_req + 1, d2_nodes + (inc2 and #inc2 or 0)
      end
      sample.incoming_depth2_ms, sample.incoming_depth2_requests = now() - d2_t0, d2_req
      sample.incoming_depth2_nodes = d2_nodes
      -- implementation lookups on method callees (interface fan-out badges)
      local impl_ms = {}
      for _, call in ipairs(outc or {}) do
        if call.to.kind == 6 and #impl_ms < 5 then
          local _, ms = request(client, "textDocument/implementation", {
            textDocument = { uri = call.to.uri },
            position = call.to.selectionRange.start,
          }, bufnr)
          impl_ms[#impl_ms + 1] = ms
        end
      end
      sample.implementation_ms = impl_ms
    end
    if fi == 1 and i == 1 then
      result.cold.first_bowtie = sample
    else
      result.samples[#result.samples + 1] = sample
    end
  end
end

local json = vim.json.encode(result)
if out_path then
  local f = assert(io.open(out_path, "a"))
  f:write(json, "\n")
  f:close()
else
  io.stdout:write(json, "\n")
end
vim.lsp.get_client_by_id(client_id):stop(true)
os.exit(0)
