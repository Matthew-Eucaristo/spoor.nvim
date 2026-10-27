# Contributing

Thanks for helping. spoor aims to stay small, honest and easy to read: plain Lua, no build step, no binaries.

## Development

```sh
make test      # unit + integration tests; clones mini.nvim and snacks.nvim into deps/ on first run
make e2e       # real language servers on tests/fixtures (skips the ones you don't have)
make smoke     # spoor inside real configs (no plugin manager, plain lazy.nvim, stock LazyVim)
make lint      # stylua --check (make format fixes it)
demo/run.sh    # throwaway LazyVim with this checkout; all state stays in .tests/demo
```

Tests run headless with [mini.test](https://github.com/nvim-mini/mini.nvim). LSP behaviour is tested against an in-process fake server (`tests/helpers.lua`), so timeouts, cancellation and caching are deterministic. The e2e suite checks the same flows against gopls and vtsls/tsgo.

## Layout

- `lua/spoor/lsp.lua`: every request, with a hard timeout and group cancellation. Nothing else talks to the server directly.
- `resolve.lua` (cursor → call hierarchy item), `graph.lua` (builds the bow-tie progressively and labels edges from the source), `model.lua` (the JSON-shaped graph and trail).
- `render.lua`: pure graph → lines/highlights/row map. All layout cases are unit-tested.
- `view.lua`, `live.lua`, `bowtie.lua` (float), `trace.lua`, `changes.lua`, `entries.lua`: the UI, built on `Snacks.win` and `Snacks.picker`.
- `frameworks.lua` and `filters.lua`: data-driven rules.

## Ground rules

- **Never block the editor.** New requests go through `lsp.request` with a group the caller cancels. Don't ask the server anything in insert mode or on a path the live panel runs on every cursor rest unless it is cached.
- **Honest labels over guesses.** If static analysis can't know something, say so in the UI (`no static callers`, `~`, `◇N`) rather than inventing an edge.
- **A framework is one rule.** Add an entry to `M.rules` in `frameworks.lua` with a test in `tests/test_frameworks.lua`. Rules read only the declaration and the head of the file. They never call the language server.
- **A new entry-point kind is one detector** in `entries.lua`, using `git grep`/`git ls-files` (POSIX ERE: write `[[:space:]]`, not `\s`), plus a test.
- **Keys:** global keys must stay free in stock LazyVim and its language extras. `tests/test_setup.lua` lists the known taken keys. Check a new key against a running LazyVim before adding it.
- **State** lives only in `stdpath("state")/spoor/`. Document anything new under "Files" in the README and `doc/spoor.txt`.
- No real paths, usernames or project names in code, tests, fixtures, docs or the demo. The fixtures under `tests/fixtures` are synthetic.
- Pull requests are squash-merged, so the PR title becomes the commit. Use a conventional prefix: `feat:`, `fix:`, `docs:`, `test:`, `ci:` or `chore:`.

## Recording the demo

`vhs demo/demo.tape` re-records `demo/demo.gif` from the repository root. The tape runs `demo/run.sh` (a throwaway LazyVim on the synthetic shop repo from `demo/setup.sh`) under a temporary `HOME` (`demo/vhs-env.sh`), so no frame shows anything about your machine. It needs [VHS](https://github.com/charmbracelet/vhs), gopls and JetBrainsMono Nerd Font (`brew install --cask font-jetbrains-mono-nerd-font`). Check every frame before committing a new GIF, and keep it under about 2 MB.
