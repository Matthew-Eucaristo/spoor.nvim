local H = require("tests.helpers")
local T = MiniTest.new_set({ hooks = { pre_case = H.reset } })
local eq = MiniTest.expect.equality

local function match(rel, name, decl, head)
  local fw = require("spoor.frameworks")
  local rule = fw.match({ rel = rel, name = name, kind = 12, decl = decl or "", head = head or "" })
  return rule and rule.id or nil
end

T["go"] = function()
  eq(match("cmd/shop/main.go", "main", "func main() {", "package main\n"), "go.main")
  eq(match("lib/main.go", "main", "func main() {", "package lib\n"), nil)
  eq(match("x/x.go", "init", "func init() {"), "go.init")
  eq(match("x/x_test.go", "TestThing", "func TestThing(t *testing.T) {"), "go.test")
  eq(match("x/x.go", "TestThing", "func TestThing(t *testing.T) {"), nil)
  eq(
    match("server.go", "handleOrders", "func (s *Server) handleOrders(w http.ResponseWriter, r *http.Request) {"),
    "go.http"
  )
  eq(match("server.go", "ServeHTTP", "func (h H) ServeHTTP(w http.ResponseWriter, r *http.Request)"), "go.http")
  eq(match("api.go", "list", "func list(c *gin.Context) {"), "go.web")
  eq(match("api.go", "list", "func list(c echo.Context) error {"), "go.web")
  eq(match("order.go", "Process", "func Process(ctx context.Context) error {"), nil)
end

T["next.js and react"] = function()
  eq(match("app/orders/page.tsx", "OrdersPage", "export default async function OrdersPage() {"), "next.page")
  eq(
    match("src/app/(shop)/layout.tsx", "RootLayout", "export default function RootLayout({ children }) {"),
    "next.page"
  )
  eq(match("app/api/orders/route.ts", "POST", "export async function POST(request: Request) {"), "next.route")
  eq(match("app/api/orders/route.ts", "helper", "function helper() {"), nil)
  eq(match("pages/api/hello.ts", "handler", "export default function handler(req, res) {"), "next.route")
  eq(
    match(
      "app/actions.ts",
      "placeOrder",
      "export async function placeOrder(order: Order) {",
      '"use server";\n\nimport x'
    ),
    "next.action"
  )
  eq(match("app/x.ts", "save", "async function save() {\n  'use server'\n"), "next.action")
  eq(match("middleware.ts", "middleware", "export function middleware(req) {"), "next.middleware")
  eq(match("app/page.tsx", "generateMetadata", "export async function generateMetadata() {"), "next.data")
  eq(match("components/OrderList.tsx", "OrderList", "export function OrderList() {"), "react.component")
  eq(match("hooks/useCart.ts", "useCart", "export function useCart() {"), "react.hook")
  eq(match("lib/orders.ts", "priceOrder", "export function priceOrder(order: Order): Order {"), nil)
end

T["react components only speak up when nothing calls them"] = function()
  local rule = require("spoor.frameworks").match({ rel = "c/A.tsx", name = "Card", kind = 12, decl = "", head = "" })
  eq(rule.only_if_empty, true)
end

T["flutter and dart"] = function()
  eq(match("lib/home.dart", "build", "  @override\n  Widget build(BuildContext context) {"), "flutter.build")
  eq(match("lib/home.dart", "initState", "  void initState() {"), "flutter.lifecycle")
  eq(match("lib/main.dart", "main", "void main() {"), "dart.main")
  eq(match("lib/repo.dart", "fetch", "Future<void> fetch() async {"), nil)
end

T["python"] = function()
  eq(match("app/api.py", "list_orders", '@app.get("/orders")\nasync def list_orders():'), "py.route")
  eq(match("app/api.py", "create", '@router.post("/orders")\ndef create(order):'), "py.route")
  eq(match("app/views.py", "index", '@bp.route("/")\ndef index():'), "py.route")
  eq(match("app/tasks.py", "send", "@shared_task\ndef send():"), "py.task")
  eq(match("tests/test_orders.py", "test_total", "def test_total():"), "py.test")
  eq(match("app/cli.py", "main", "def main():"), "py.main")
end

T["jvm"] = function()
  eq(match("src/App.java", "main", "public static void main(String[] args) {"), "jvm.main")
  eq(match("src/OrderController.java", "list", '@GetMapping("/orders")\npublic List<Order> list() {'), "spring")
  eq(match("src/OrderTest.java", "total", "@Test\nvoid total() {"), "junit")
end

T["detect reads the declaration from the file"] = function()
  local model = require("spoor.model")
  local w = H.go_world()
  local fw = require("spoor.frameworks")
  eq(fw.detect(model.node(w.handle), H.go).id, "go.http")
  eq(fw.detect(model.node(w.process), H.go), nil)
  local main = H.item(H.go .. "/cmd/shop/main.go", "main")
  eq(fw.detect(model.node(main), H.go).id, "go.main")
  local page = H.item(H.ts .. "/app/orders/page.tsx", "OrdersPage")
  eq(fw.detect(model.node(page), H.ts).id, "next.page")
  local action = H.item(H.ts .. "/app/actions.ts", "placeOrder")
  eq(fw.detect(model.node(action), H.ts).id, "next.action")
end

T["your own rules (opts.frameworks) run before the built-in ones"] = function()
  require("spoor.config").setup({
    frameworks = {
      {
        id = "bun.fetch",
        label = "Bun · fetch handler",
        ft = { "ts" },
        match = function(c)
          return c.name == "fetch" and c.head:find("Bun%.serve") ~= nil
        end,
      },
      {
        id = "any.main",
        label = "my runtime",
        match = function(c)
          return c.name == "main"
        end,
      },
      {
        id = "broken",
        label = "throws",
        match = function()
          error("bug in a user rule")
        end,
      },
      {
        label = "no id",
        match = function()
          return true
        end,
      },
    },
  })
  eq(match("server.ts", "fetch", "fetch(req) {", "Bun.serve({\n"), "bun.fetch")
  eq(match("server.js", "fetch", "fetch(req) {", "Bun.serve({\n"), nil) -- ft limits it
  -- no ft: every file; and yours win over the built-in go.main
  eq(match("cmd/shop/main.go", "main", "func main() {", "package main\n"), "any.main")
  eq(match("main.zig", "main", "pub fn main() void {"), "any.main")
  -- a rule that errors or lacks an id is skipped; built-in rules still apply
  eq(match("x/x.go", "init", "func init() {"), "go.init")
  require("spoor.config").setup({ frameworks = false })
  eq(match("x/x.go", "init", "func init() {"), nil)
end

T["health names the rules and detectors it skips"] = function()
  require("spoor").setup({
    live = { enabled = false },
    frameworks = { { id = "half", label = "no match function" } },
    entries = { make = "not a function", npm = false },
  })
  vim.cmd("checkhealth spoor")
  local buf, out = vim.api.nvim_get_current_buf(), ""
  H.wait(function()
    out = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    return out:find("your rules", 1, true) ~= nil
  end, 3000, "health output")
  MiniTest.expect.no_equality(out:find("frameworks[1] (half) is skipped: needs a match(ctx) function", 1, true), nil)
  MiniTest.expect.no_equality(out:find("entries.make is skipped", 1, true), nil)
  eq(out:find("entries.npm", 1, true), nil)
  vim.cmd("bwipeout!")
end

return T
