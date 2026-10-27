-- lazy.nvim reads this file when spoor is installed, so a one-line spec is enough:
-- `{ "Matthew-Eucaristo/spoor.nvim", opts = {} }` pulls in snacks.nvim as well.
return {
  { "folke/snacks.nvim" },
  { "Matthew-Eucaristo/spoor.nvim", dependencies = { "folke/snacks.nvim" } },
}
