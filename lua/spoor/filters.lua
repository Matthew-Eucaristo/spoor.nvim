--- Noise classification: external (vendor, SDKs, outside the project), generated, tests.
local Config = require("spoor.config")
local util = require("spoor.util")

local M = {}

-- Matched against the full path.
M.external_patterns = {
  "/node_modules/",
  "/vendor/",
  "/%.pub%-cache/",
  "/site%-packages/",
  "/dist%-packages/",
  "/go/pkg/mod/",
  "/libexec/src/", -- GOROOT on Homebrew
  "/flutter/packages/",
  "/flutter/bin/cache/",
  "/typeshed",
  "/%.venv/",
  "/%.dart_tool/",
}

-- Matched against the project-relative path.
M.generated_patterns = {
  "%.pb%.go$",
  "%.pb%.gw%.go$",
  "_gen%.go$",
  "_generated%.go$",
  "%.g%.dart$",
  "%.freezed%.dart$",
  "%.gr%.dart$",
  "%.mocks%.dart$",
  "%.generated%.%a+$",
  "_pb2%.py$",
  "_pb2_grpc%.py$",
  "%.d%.ts$",
  "^generated/",
  "/generated/",
  "/__generated__/",
}

M.test_patterns = {
  "_test%.go$",
  "%.test%.[jt]sx?$",
  "%.spec%.[jt]sx?$",
  "_test%.dart$",
  "^tests?/",
  "/tests?/",
  "/__tests__/",
  "/test_[^/]*%.py$",
  "^test_[^/]*%.py$",
  "_test%.py$",
  "/src/test/",
  "Test%.java$",
  "Test%.kt$",
}

---@type table<string, boolean>
local header_cache = {}

--- Go and many generators mark output with "Code generated ... DO NOT EDIT." near the top.
---@param path string
function M.has_generated_header(path)
  local cached = header_cache[path]
  if cached ~= nil then
    return cached
  end
  local generated = false
  for _, line in ipairs(util.read_lines(path, 5)) do
    if
      line:find("Code generated .* DO NOT EDIT")
      or line:find("@generated")
      or line:find("GENERATED CODE %- DO NOT MODIFY")
    then
      generated = true
      break
    end
  end
  header_cache[path] = generated
  return generated
end

function M.clear_cache()
  header_cache = {}
end

local function any(s, patterns)
  for _, p in ipairs(patterns) do
    if s:find(p) then
      return true
    end
  end
  return false
end

--- Tags for a path: { external = bool, generated = bool, test = bool, excluded = bool }.
---@param path string absolute path
---@param root? string project root
---@param opts? {read_header?: boolean}
function M.classify(path, root, opts)
  local rel, inside = util.relative(path, root)
  local tags = {}
  if not inside or any(path, M.external_patterns) then
    tags.external = true
  end
  if
    any(rel, M.generated_patterns)
    or (inside and (not opts or opts.read_header ~= false) and M.has_generated_header(path))
  then
    tags.generated = true
  end
  if any(rel, M.test_patterns) then
    tags.test = true
  end
  if any(rel, Config.options.exclude or {}) then
    tags.excluded = true
  end
  return tags
end

--- The reason a node is hidden under the current filters, or nil when it is shown.
---@param tags table<string, boolean>
---@param show_all? boolean
---@return string?
function M.hidden_reason(tags, show_all)
  if show_all then
    return nil
  end
  local hide = Config.options.hide
  if tags.excluded then
    return "excluded"
  end
  if hide.external and tags.external then
    return "external"
  end
  if hide.generated and tags.generated then
    return "generated"
  end
  if hide.tests and tags.test then
    return "tests"
  end
end

return M
