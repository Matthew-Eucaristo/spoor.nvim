-- Where orders go, for following a call into another file.
local M = {}

local function encode(order)
  return tostring(order.total)
end

function M.save(order)
  return encode(order)
end

function M.save_all(orders)
  for _, o in ipairs(orders) do
    M.save(o)
  end
end

local count = 0

return M, count
