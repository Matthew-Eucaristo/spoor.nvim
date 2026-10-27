-- The spec under test: the README's, pointed at this checkout unless SPOOR_URL is set.
local url = os.getenv("SPOOR_URL")
if url then
  return { url = url, name = "spoor.nvim", opts = {} }
end
return { dir = os.getenv("SPOOR_REPO"), name = "spoor.nvim", opts = {} }
