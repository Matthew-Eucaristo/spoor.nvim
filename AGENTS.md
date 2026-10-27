# spoor.nvim

Neovim plugin (pure Lua, Neovim ≥ 0.11, depends on snacks.nvim) for reading code: a live callers | function | callees bow-tie, trace mode with saved trails and notes, changed-symbols and entry-point pickers. No AI, no binaries, no network. Family rules: `../AGENTS.md` (publishing, no PII, noreply identity, ask before creating repos/pushing/releasing). The design report is `../research/Codebase comprehension in Neovim.md`.

## Layout
- `lua/spoor/lsp.lua`: the only place requests are sent; hard timeout (`timeout`, `cold_timeout` until a server first answers), cancellation groups.
- `resolve.lua` cursor → CallHierarchyItem (prepare at cursor, else enclosing documentSymbol). `graph.lua` progressive bow-tie build, `site_kind` (call/jsx/ref from source text), implementation badges, value references. `model.lua` JSON-shaped graph/trail (exported ids are root-relative).
- `render.lua` pure layout (tested). `view.lua` shared window; `live.lua` panel (debounce, LRU cache keyed by item + edit generation); `bowtie.lua` float; `trace.lua`; `changes.lua`; `entries.lua`; `frameworks.lua`/`filters.lua` rules; `export.lua` Mermaid/qf/JSON; `health.lua`.
- `tests/` mini.test with an in-process fake LSP (`helpers.lua`); `tests/e2e/` real gopls/vtsls/tsgo on `tests/fixtures/{go,ts}`. `bench/callhierarchy.lua` latency harness. `demo/` throwaway LazyVim (`run.sh`), demo repo (`setup.sh`), hero recorder (`capture.sh`/`capture.mjs`).

## Invariants
- Never block typing: every request has a timeout and a cancel group; live mode is debounced, skips insert mode, and doesn't re-request the same focus.
- Default keys must stay free in LazyVim 16 + extras (`<leader>uS`, `<leader>uG`, `<leader>cg` are taken). Keys: `gag gat <leader>ct <leader>cT <leader>ce <leader>cG <leader>uB`.
- Writes only `stdpath("state")/spoor/` (state.json, trails/). Only read-only git commands (listed in SECURITY.md).
- Labels must be honest: static-only footer, `◇N`, `~`, `</>`, `⚑`, "no static callers".
- An optional AI module, if ever added, consumes `current_graph()`/`current_trail()`; it never feeds the core.

## Verify
`make lint`, `make test` (CI: stable, nightly, v0.11.x on Linux; stable on macOS), `make e2e` (CI installs gopls + vtsls). For UI changes, check `demo/run.sh` and re-record with `demo/capture.sh`.
