--- Entry points: where the program, the router or the framework starts calling
--- your code. Found with `git ls-files` / `git grep` (fast, respects .gitignore)
--- plus manifest parsing. Picking one starts a trace there.
local Config = require("spoor.config")
local util = require("spoor.util")

local M = {}

---@class spoor.Entry
---@field lang string short badge: go, next, npm, py, dart, jvm, rust, route
---@field name string
---@field file string absolute path
---@field lnum integer 1-based
---@field col? integer 0-based column for the cursor (the handler name on a route line)
---@field detail? string
---@field trace boolean start a trace when picked

---@param root string
---@param pattern string extended regex
---@param pathspec string[]
---@return {file: string, lnum: integer, text: string}[]
function M.grep(root, pattern, pathspec)
  local cmd = { "git", "grep", "-n", "-I", "--untracked", "-E", pattern, "--" }
  vim.list_extend(cmd, pathspec)
  local out = {}
  for _, l in ipairs(util.system(cmd, root) or {}) do
    local file, lnum, text = l:match("^(.-):(%d+):(.*)$")
    if file then
      out[#out + 1] = { file = file, lnum = tonumber(lnum), text = text }
    end
  end
  return out
end

---@param root string
---@return string[]
function M.files(root)
  return util.system({ "git", "ls-files", "--cached", "--others", "--exclude-standard" }, root) or {}
end

--- Next.js route for an app-router file: app/(shop)/orders/[id]/page.tsx -> /orders/[id]
---@param rel string
function M.next_route(rel)
  local dir = rel:gsub("^src/", ""):gsub("^app/?", ""):gsub("/?[^/]+$", "")
  local parts = {}
  for seg in dir:gmatch("[^/]+") do
    if not seg:match("^%(.*%)$") and not seg:match("^@") then
      parts[#parts + 1] = seg
    end
  end
  return "/" .. table.concat(parts, "/")
end

--- Handler column on a route registration line: the last identifier before ")".
---@param text string
---@return integer? col 0-based
function M.handler_col(text)
  local s = text:find("[%w_%.]+%s*%)%s*;?%s*$")
  if s then
    local ident = text:sub(s):match("^[%w_%.]+")
    local last_dot = ident:find("%.[^.]*$")
    return (s - 1) + (last_dot or 0)
  end
end

local function first_line(lines, pattern)
  for i, l in ipairs(lines) do
    if l:find(pattern) then
      return i
    end
  end
end

---@type table<string, fun(root: string, files: string[]): spoor.Entry[]>
M.detectors = {}

function M.detectors.go(root, files)
  local out = {}
  for _, hit in ipairs(M.grep(root, [[^func main\(\)]], { "*.go" })) do
    local abs = vim.fs.joinpath(root, hit.file)
    local head = util.read_lines(abs, 40)
    if first_line(head, "^package main") then
      local dir = vim.fs.dirname(hit.file)
      out[#out + 1] = {
        lang = "go",
        name = "main",
        file = abs,
        lnum = hit.lnum,
        col = 5,
        detail = dir == "." and "package main" or dir,
        trace = true,
      }
    end
  end
  local route = [=[\.(HandleFunc|Handle|GET|POST|PUT|PATCH|DELETE|Get|Post|Put|Patch|Delete|Any)\([[:space:]]*"[^"]*"]=]
  for _, hit in ipairs(M.grep(root, route, { "*.go" })) do
    local method, path = hit.text:match('%.(%w+)%(%s*"([^"]*)"')
    if method and not hit.file:find("_test%.go$") then
      local verb = (method == "HandleFunc" or method == "Handle") and "" or (method:upper() .. " ")
      out[#out + 1] = {
        lang = "route",
        name = verb .. (path ~= "" and path or "/"), -- "" is the root of a route group
        file = vim.fs.joinpath(root, hit.file),
        lnum = hit.lnum,
        col = M.handler_col(hit.text),
        detail = vim.trim(hit.text),
        trace = true,
      }
    end
  end
  return out
end

local NEXT_SPECIAL = { page = "page", layout = "layout", route = "route", middleware = "middleware", proxy = "proxy" }

function M.detectors.next(root, files)
  local out = {}
  for _, rel in ipairs(files) do
    local stem, ext = rel:match("([^/]+)%.([jt]sx?)$")
    local kind = stem and NEXT_SPECIAL[stem]
    local app = rel:find("^app/") or rel:find("^src/app/") or rel:find("/app/")
    if kind and (app or kind == "middleware" or kind == "proxy") and not rel:find("node_modules") then
      local abs = vim.fs.joinpath(root, rel)
      local lines = util.read_lines(abs, 400)
      if kind == "route" then
        for i, l in ipairs(lines) do
          local verb = l:match("^export%s+async%s+function%s+(%u+)%s*%(")
            or l:match("^export%s+function%s+(%u+)%s*%(")
            or l:match("^export%s+const%s+(%u+)%s*=")
          if verb then
            out[#out + 1] = {
              lang = "next",
              name = verb .. " " .. M.next_route(rel),
              file = abs,
              lnum = i,
              col = (l:find(verb, 1, true) or 1) - 1,
              detail = rel,
              trace = true,
            }
          end
        end
      elseif kind == "middleware" or kind == "proxy" then
        local i = first_line(lines, "^export") or 1
        out[#out + 1] = { lang = "next", name = kind, file = abs, lnum = i, detail = rel, trace = true }
      else
        local i = first_line(lines, "^export%s+default") or 1
        local fn = lines[i] and lines[i]:match("function%s+([%w_]+)")
        out[#out + 1] = {
          lang = "next",
          name = kind .. " " .. M.next_route(rel),
          file = abs,
          lnum = i,
          col = fn and (lines[i]:find(fn, 1, true) - 1) or nil,
          detail = rel,
          trace = fn ~= nil,
        }
      end
    elseif ext and rel:match("^s?r?c?/?pages/") and not stem:match("^_") then
      local abs = vim.fs.joinpath(root, rel)
      local lines = util.read_lines(abs, 400)
      local i = first_line(lines, "^export%s+default")
      if i then
        out[#out + 1] = {
          lang = "next",
          name = "page " .. rel:gsub("^s?r?c?/?pages", ""):gsub("%.[jt]sx?$", ""),
          file = abs,
          lnum = i,
          detail = rel,
          trace = false,
        }
      end
    end
  end
  return out
end

function M.detectors.npm(root, files)
  local out = {}
  for _, rel in ipairs(files) do
    if rel:match("^package%.json$") or rel:match("/package%.json$") then
      local abs = vim.fs.joinpath(root, rel)
      local lines = util.read_lines(abs, 2000)
      local ok, pkg = pcall(vim.json.decode, table.concat(lines, "\n"))
      if ok and type(pkg) == "table" then
        local function at(key)
          return first_line(lines, '"' .. vim.pesc(key) .. '"%s*:') or 1
        end
        local bins = type(pkg.bin) == "string" and { [pkg.name or "bin"] = pkg.bin }
          or (type(pkg.bin) == "table" and pkg.bin or {})
        for name, target in pairs(bins) do
          out[#out + 1] = {
            lang = "npm",
            name = "bin: " .. name,
            file = abs,
            lnum = at("bin"),
            detail = tostring(target),
            trace = false,
          }
        end
        if type(pkg.main) == "string" then
          out[#out + 1] =
            { lang = "npm", name = "main", file = abs, lnum = at("main"), detail = pkg.main, trace = false }
        end
        local scripts = type(pkg.scripts) == "table" and pkg.scripts or {}
        local names = vim.tbl_keys(scripts)
        table.sort(names)
        for _, name in ipairs(names) do
          out[#out + 1] = {
            lang = "npm",
            name = "script: " .. name,
            file = abs,
            lnum = at(name),
            detail = tostring(scripts[name]),
            trace = false,
          }
        end
      end
    end
  end
  return out
end

function M.detectors.python(root, files)
  local out = {}
  for _, hit in ipairs(M.grep(root, [[^if __name__ == .__main__.:]], { "*.py" })) do
    out[#out + 1] = {
      lang = "py",
      name = "__main__",
      file = vim.fs.joinpath(root, hit.file),
      lnum = hit.lnum,
      detail = hit.file,
      trace = false,
    }
  end
  for _, hit in
    ipairs(
      M.grep(
        root,
        [=[^[[:space:]]*@[A-Za-z_][A-Za-z0-9_]*\.(get|post|put|patch|delete|route|websocket)\(]=],
        { "*.py" }
      )
    )
  do
    local method, path = hit.text:match("%.(%w+)%(%s*[\"']([^\"']*)")
    out[#out + 1] = {
      lang = "route",
      name = ((method and method ~= "route") and (method:upper() .. " ") or "") .. (path or "?"),
      file = vim.fs.joinpath(root, hit.file),
      lnum = hit.lnum + 1, -- the decorated def is on the next line(s)
      col = 4,
      detail = vim.trim(hit.text),
      trace = true,
    }
  end
  for _, rel in ipairs(files) do
    if rel == "pyproject.toml" then
      local abs = vim.fs.joinpath(root, rel)
      local lines = util.read_lines(abs, 2000)
      local in_scripts = false
      for i, l in ipairs(lines) do
        if l:match("^%[") then
          in_scripts = l:match("^%[project%.scripts%]") ~= nil or l:match("^%[tool%.poetry%.scripts%]") ~= nil
        elseif in_scripts then
          local name, target = l:match("^%s*([%w_%-%.]+)%s*=%s*[\"']([^\"']+)[\"']")
          if name then
            out[#out + 1] =
              { lang = "py", name = "script: " .. name, file = abs, lnum = i, detail = target, trace = false }
          end
        end
      end
    end
  end
  return out
end

function M.detectors.dart(root, files)
  local out = {}
  for _, hit in ipairs(M.grep(root, [=[^(Future<void>|void|Future)?[[:space:]]*main\(]=], { "*.dart" })) do
    local abs = vim.fs.joinpath(root, hit.file)
    local lines = util.read_lines(abs, 400)
    local app = first_line(lines, "runApp%(") and " → runApp" or ""
    out[#out + 1] = {
      lang = "dart",
      name = "main" .. app,
      file = abs,
      lnum = hit.lnum,
      col = (hit.text:find("main") or 1) - 1,
      detail = hit.file,
      trace = true,
    }
  end
  return out
end

function M.detectors.jvm(root, files)
  local out = {}
  for _, hit in
    ipairs(
      M.grep(
        root,
        [=[static[[:space:]]+void[[:space:]]+main[[:space:]]*\(|^fun[[:space:]]+main[[:space:]]*\(]=],
        { "*.java", "*.kt" }
      )
    )
  do
    out[#out + 1] = {
      lang = "jvm",
      name = "main",
      file = vim.fs.joinpath(root, hit.file),
      lnum = hit.lnum,
      col = (hit.text:find("main") or 1) - 1,
      detail = hit.file,
      trace = true,
    }
  end
  for _, hit in ipairs(M.grep(root, [[@(Get|Post|Put|Patch|Delete|Request)Mapping\(]], { "*.java", "*.kt" })) do
    local verb, path = hit.text:match('@(%a+)Mapping%(%s*[%w%s=]*"([^"]*)"')
    out[#out + 1] = {
      lang = "route",
      name = ((verb and verb ~= "Request") and (verb:upper() .. " ") or "")
        .. (path or hit.text:match("@%a+Mapping") or "?"),
      file = vim.fs.joinpath(root, hit.file),
      lnum = hit.lnum,
      detail = vim.trim(hit.text),
      trace = false,
    }
  end
  return out
end

function M.detectors.rust(root, files)
  local out = {}
  for _, hit in
    ipairs(M.grep(root, [=[^(pub[[:space:]]+)?(async[[:space:]]+)?fn[[:space:]]+main[[:space:]]*\(]=], { "*.rs" }))
  do
    out[#out + 1] = {
      lang = "rust",
      name = "main",
      file = vim.fs.joinpath(root, hit.file),
      lnum = hit.lnum,
      col = (hit.text:find("main") or 1) - 1,
      detail = hit.file,
      trace = true,
    }
  end
  return out
end

M.order = { "go", "next", "dart", "python", "jvm", "rust", "npm" }

--- All entry points under a project root.
---@param root string
---@return spoor.Entry[]
function M.find(root)
  local files = M.files(root)
  local out = {}
  for _, name in ipairs(M.order) do
    local ok, found = pcall(M.detectors[name], root, files)
    if ok then
      vim.list_extend(out, found)
    end
  end
  -- program entries first, then routes, then manifests; helper scripts in docs/, examples/,
  -- generated or test code go last
  local rank = { go = 1, dart = 1, rust = 1, jvm = 1, py = 2, next = 3, route = 4, npm = 5 }
  local filters = require("spoor.filters")
  for i, e in ipairs(out) do
    e.order = i
    local rel = util.relative(e.file, root)
    local tags = filters.classify(e.file, root, { read_header = false })
    if tags.generated or tags.test or tags.excluded or rel:find("^docs?/") or rel:find("^examples?/") then
      e.rank = 10 + (rank[e.lang] or 9)
    else
      e.rank = rank[e.lang] or 9
    end
  end
  table.sort(out, function(a, b)
    local ra, rb = a.rank, b.rank
    if ra ~= rb then
      return ra < rb
    end
    return a.order < b.order
  end)
  return out
end

--- Jump to an entry; start a trace there once the language server is ready.
---@param e spoor.Entry
function M.open_entry(e)
  vim.cmd.edit(vim.fn.fnameescape(e.file))
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_buf_get_lines(bufnr, e.lnum - 1, e.lnum, false)[1] or ""
  local col = e.col or (line:find("%S") or 1) - 1
  pcall(vim.api.nvim_win_set_cursor, 0, { e.lnum, col })
  vim.cmd("normal! zz")
  if not e.trace then
    return
  end
  local lsp = require("spoor.lsp")
  local trace = require("spoor.trace")
  if lsp.client(bufnr) then
    return trace.start_at_cursor()
  end
  vim.api.nvim_create_autocmd("LspAttach", {
    buffer = bufnr,
    once = true,
    callback = function()
      vim.defer_fn(trace.start_at_cursor, 50)
    end,
  })
end

local BADGE_HL = {
  go = "SpoorName",
  next = "SpoorFramework",
  npm = "SpoorBadge",
  py = "SpoorName",
  dart = "SpoorName",
  jvm = "SpoorName",
  rust = "SpoorName",
  route = "SpoorFramework",
}

--- Entry-point picker (<leader>ce).
function M.open()
  local root = util.root(0, require("spoor.lsp").client(0))
  local found = M.find(root)
  if #found == 0 then
    return util.notify("No entry points found (needs a git repository)", vim.log.levels.WARN)
  end
  local items = {}
  for _, e in ipairs(found) do
    items[#items + 1] = {
      text = e.lang .. " " .. e.name .. " " .. (e.detail or ""),
      file = e.file,
      pos = { e.lnum, e.col or 0 },
      entry = e,
    }
  end
  Snacks.picker.pick({
    source = "spoor_entries",
    title = "Entry points",
    items = items,
    format = function(item)
      local e = item.entry
      local rel = util.relative(e.file, root)
      return {
        { ("%-6s"):format(e.lang), BADGE_HL[e.lang] or "SpoorDim" },
        { (e.trace and Config.options.icons.framework or " ") .. " ", "SpoorFramework" },
        { ("%-34s"):format(util.truncate(e.name, 34)), "SpoorFocus" },
        { (" %s:%d"):format(rel, e.lnum), "SpoorLoc" },
        { e.detail and e.detail ~= rel and ("  " .. util.truncate(e.detail, 50)) or "", "SpoorDim" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        M.open_entry(item.entry)
      end
    end,
  })
end

return M
