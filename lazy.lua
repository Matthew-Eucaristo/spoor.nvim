-- lazy.nvim reads this file when spoor is installed, so a one-line spec is enough:
-- `{ "Matthew-Eucaristo/spoor.nvim", opts = {} }` pulls in snacks.nvim as well. lazy.nvim
-- scopes these specs to spoor under whatever name it was installed as (forks, `dir`, `name`).
return {
  { "folke/snacks.nvim" },
}
