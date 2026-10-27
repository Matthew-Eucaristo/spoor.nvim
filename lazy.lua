-- lazy.nvim reads this file when spoor is installed, so a one-line spec is enough:
-- `{ "Matthew-Eucaristo/spoor.nvim", opts = {} }` pulls in snacks.nvim as well.
-- spoor is referred to by name only, so forks and `url = ...` installs keep their source.
return {
  { "folke/snacks.nvim" },
  { "spoor.nvim", dependencies = { "folke/snacks.nvim" } },
}
