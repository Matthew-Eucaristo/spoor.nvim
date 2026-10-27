# Changelog

## 1.2.0 - 2026-10-27

- `K` grows the card: when a hover opens at the cursor, the card turns into the full bow-tie (two levels, every row) next to it, in the largest free part of the screen. Moving on folds it back. Works with noice and plain LSP hovers, which open their windows late and without autocommands.
- Hover detection follows floats anchored to the code window (also nested ones, as noice draws them) that touch the cursor line, so sidebars like the snacks explorer never hide the card.
- Any language: where no language server has call hierarchy (marksman, ty, or no server at all), a same-file bow-tie from tree-sitter, labelled *syntax only · this file*. Functions and calls are found by node type name, so every parser works without per-language queries. The language server always wins when it can answer; `syntax = false` turns it off.
- Your own frameworks and entry points: `frameworks = { rule, ... }` and `entries = { name = detector }` take the same shape as the built-in ones; `entries = { npm = false }` turns one off.
- snacks.nvim is optional: without it spoor uses plain windows and `vim.ui.select` (pickers without previews).
- Windows: project-relative paths handle backslashes and drive letters; CI runs the tests on Windows.

## 1.1.1 - 2026-10-27

- Fix: the cursor card stayed hidden while a sidebar such as the snacks explorer was open. Only floats anchored to the cursor (hover, signature, diagnostics) make it step aside now.

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
