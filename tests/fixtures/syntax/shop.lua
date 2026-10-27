-- A tiny shop, for the tree-sitter (syntax only) bow-tie.
local M = {}

local function subtotal(order)
  local sum = 0
  for _, item in ipairs(order.items) do
    sum = sum + item.price
  end
  return sum
end

function M.validate(order)
  if #order.items == 0 then
    error("empty order")
  end
end

function M.process(order)
  M.validate(order)
  local total = subtotal(order)
  order.total = total
  return save(order)
end

-- process is also named in this comment and in "process", which are not uses
local handlers = { submit = M.process }

local checkout = function(order)
  return M.process(order)
end

M.process({ items = {} })

return M, handlers, checkout
