# Changelog

## 1.1.0 - 2026-10-27

- The live bow-tie is now a card next to the cursor by default, like an always-on hover (`live.layout = "cursor"`). It sits above the cursor line (below near the top), never takes focus, steps aside for hover, signature and diagnostic floats, and hides while you type. `live.layout = "bottom"` brings back the panel.
- `gag` previews: moving through the bow-tie shows each function's code in the code window; `<CR>` goes there, `<Esc>` puts the window back. Buffers opened only to preview are not listed and are wiped again.
- `<C-v>`, `<C-s>` and `<C-t>` in the float keep the bow-tie open in a vertical split, a bottom split or a new tab, where `<CR>` goes to the node and the view stays.
- The float sits at the bottom of the screen so the previewed code stays visible.
- `:q` in the last code window also closes a trail or a pinned bow-tie, so Neovim quits even when no live view is showing.

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
