# Changelog

## 1.0.0 - 2026-10-27

First release.

- Live bow-tie panel: callers | function | callees, following the cursor (debounced, cancelled, cached, never in insert mode), toggled with `<leader>uB` (persisted).
- `gag` float with two levels per side, re-rooting and history.
- Trace mode (`gat`): numbered next hops, implementation choice on interfaces, notes, quickfix and Mermaid export, per-project trails you can resume (`<leader>ct`, `<leader>cT`).
- Changed symbols since the branch point (`<leader>cG`) with bow-tie previews and `⚠ 0 callers` on new functions nothing calls.
- Entry points (`<leader>ce`): Go, Next.js, npm, Python, Dart/Flutter, JVM, Rust.
- Honest edges: `◇N` interface fan-out, `~` value uses, `</>` JSX, `⚑` framework-invoked roots; vendor, generated and test filters.
- Per-server defaults measured on real projects; dartls finds callers on demand.
- Install with lazy.nvim (spoor's `lazy.lua` brings in snacks.nvim), `vim.pack`, or the plain packpath.
- Tested in CI on Neovim 0.11.7, stable and nightly, inside a bare config, plain lazy.nvim and stock LazyVim.
