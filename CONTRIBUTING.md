# Contributing

Thanks for helping. spoor aims to stay small, honest and easy to read: plain Lua, no build step, no binaries.

## Development

```sh
make test      # unit + integration tests; clones mini.nvim and snacks.nvim into deps/ on first run
make e2e       # real language servers on tests/fixtures (skips the ones you don't have)
make smoke     # spoor inside real configs (no plugin manager, no snacks.nvim, plain lazy.nvim, stock LazyVim)
make lint      # stylua --check (make format fixes it)
demo/run.sh    # throwaway LazyVim with this checkout; all state stays in .tests/demo
```

Tests run headless with [mini.test](https://github.com/nvim-mini/mini.nvim). LSP behaviour is tested against an in-process fake server (`tests/helpers.lua`), so timeouts, cancellation and caching are deterministic. The e2e suite checks the same flows against gopls and vtsls/tsgo.

## Layout

- `lua/spoor/lsp.lua`: every request, with a hard timeout and group cancellation. Nothing else talks to the server directly.
- `resolve.lua` (cursor → call hierarchy item), `graph.lua` (builds the bow-tie progressively and labels edges from the source), `model.lua` (the JSON-shaped graph and trail).
- `render.lua`: pure graph → lines/highlights/row map. All layout cases are unit-tested.
- `syntax.lua`: the same-file bow-tie from tree-sitter where no server has call hierarchy. It finds functions and calls by node type name, so it has no per-language queries; keep it that way.
- `view.lua`, `live.lua`, `bowtie.lua` (float), `trace.lua`, `changes.lua`, `entries.lua`: the UI, built on `ui.lua` (`Snacks.win`/`Snacks.picker` when snacks.nvim is there, plain windows and `vim.ui.select` when it isn't).
- `frameworks.lua` and `filters.lua`: data-driven rules.

## Ground rules

- **Never block the editor.** New requests go through `lsp.request` with a group the caller cancels. Don't ask the server anything in insert mode or on a path the live panel runs on every cursor rest unless it is cached.
- **Honest labels over guesses.** If static analysis can't know something, say so in the UI (`no static callers`, `~`, `◇N`) rather than inventing an edge.
- **New frameworks live in user config.** spoor doesn't add a built-in rule per framework: `opts.frameworks` and `opts.entries` take rules and detectors with the same shape as `frameworks.lua` and `entries.lua`, and the README shows how. Fixes to the existing rules are welcome, each with a test. Rules read only the declaration and the head of the file and never call the language server; detectors use `git grep`/`git ls-files` (POSIX ERE: write `[[:space:]]`, not `\s`).
- **Any setup.** No hard dependency on snacks.nvim, LazyVim or mini.icons, and paths go through `util.relative`/`util.normalize` so Windows works.
- **Keys:** global keys must stay free in stock LazyVim and its language extras. `tests/test_setup.lua` lists the known taken keys. Check a new key against a running LazyVim before adding it.
- **State** lives only in `stdpath("state")/spoor/`. Document anything new under "Files" in the README and `doc/spoor.txt`.
- No real paths, usernames or project names in code, tests, fixtures, docs or the demo. The fixtures under `tests/fixtures` are synthetic.
- Pull requests are squash-merged, so the PR title becomes the commit. Use a conventional prefix: `feat:`, `fix:`, `docs:`, `test:`, `ci:` or `chore:`.

## Recording the demo

`vhs demo/demo.tape` re-records `demo/demo.gif` from the repository root. The tape runs `demo/run.sh` (a throwaway LazyVim on the synthetic shop repo from `demo/setup.sh`) under a temporary `HOME` (`demo/vhs-env.sh`), so no frame shows anything about your machine. It needs [VHS](https://github.com/charmbracelet/vhs), gopls and JetBrainsMono Nerd Font (`brew install --cask font-jetbrains-mono-nerd-font`). Check every frame before committing a new GIF, and keep it under about 2 MB.
