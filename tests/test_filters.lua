local H = require("tests.helpers")
local T = MiniTest.new_set({ hooks = { pre_case = H.reset } })
local eq = MiniTest.expect.equality

local function tags(path, root)
  return require("spoor.filters").classify(path, root or "/w/app", { read_header = false })
end

T["external: outside the project, vendor, SDKs"] = function()
  eq(tags("/usr/local/go/src/net/http/server.go").external, true)
  eq(tags("/w/app/vendor/github.com/x/y.go").external, true)
  eq(tags("/w/app/node_modules/react/index.js").external, true)
  eq(tags("/home/u/.pub-cache/hosted/pub.dev/http/lib/http.dart").external, true)
  eq(tags("/w/app/.venv/lib/python3.12/site-packages/x.py").external, true)
  eq(tags("/w/app/internal/order.go").external, nil)
end

T["generated: by name and by header"] = function()
  eq(tags("/w/app/api/order.pb.go").generated, true)
  eq(tags("/w/app/lib/model.g.dart").generated, true)
  eq(tags("/w/app/lib/model.freezed.dart").generated, true)
  eq(tags("/w/app/src/__generated__/schema.ts").generated, true)
  eq(tags("/w/app/internal/order.go").generated, nil)
  local f = require("spoor.filters")
  eq(f.has_generated_header(H.go .. "/internal/pb/order.pb.go"), true)
  eq(f.has_generated_header(H.go .. "/internal/order/order.go"), false)
end

T["tests"] = function()
  eq(tags("/w/app/order_test.go").test, true)
  eq(tags("/w/app/src/order.test.ts").test, true)
  eq(tags("/w/app/src/order.spec.tsx").test, true)
  eq(tags("/w/app/test/widget_test.dart").test, true)
  eq(tags("/w/app/tests/test_orders.py").test, true)
  eq(tags("/w/app/src/__tests__/a.js").test, true)
  eq(tags("/w/app/src/main/java/App.java").test, nil)
  eq(tags("/w/app/src/order.ts").test, nil)
end

T["hidden_reason follows options"] = function()
  local Config = require("spoor.config")
  local f = require("spoor.filters")
  Config.setup({})
  eq(f.hidden_reason({ external = true }), "external")
  eq(f.hidden_reason({ test = true }), nil)
  eq(f.hidden_reason({ external = true }, true), nil)
  Config.setup({ hide = { tests = true, external = false } })
  eq(f.hidden_reason({ test = true }), "tests")
  eq(f.hidden_reason({ external = true }), nil)
end

T["exclude patterns"] = function()
  local Config = require("spoor.config")
  Config.setup({ exclude = { "^legacy/" } })
  eq(tags("/w/app/legacy/old.go").excluded, true)
  eq(require("spoor.filters").hidden_reason({ excluded = true }), "excluded")
end

return T
