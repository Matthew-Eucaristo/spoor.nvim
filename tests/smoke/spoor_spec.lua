-- The spec under test: the README's, pointed at this checkout unless SPOOR_URL is set.
-- SPOOR_SMOKE_NAME installs it under another name, as a fork would be.
local url = os.getenv("SPOOR_URL")
local name = os.getenv("SPOOR_SMOKE_NAME") or "spoor.nvim"
if url then
  return { url = url, name = name, opts = {} }
end
return { dir = os.getenv("SPOOR_REPO"), name = name, opts = {} }
