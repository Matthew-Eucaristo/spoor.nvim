#!/usr/bin/env bash
# Throwaway LazyVim with spoor.nvim from this checkout. Nothing outside .tests/demo is written.
#   demo/run.sh [file]   open a file in the demo shop repo (demo/demo.tape records the README GIF)
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
state="$repo/.tests/demo"
mkdir -p "$state"
export XDG_CONFIG_HOME="$state/config" XDG_DATA_HOME="$state/data" XDG_STATE_HOME="$state/state" XDG_CACHE_HOME="$state/cache"
export NVIM_APPNAME=spoor-demo
mkdir -p "$XDG_CONFIG_HOME/spoor-demo"
ln -sf "$repo/demo/init.lua" "$XDG_CONFIG_HOME/spoor-demo/init.lua"
# reuse language servers you already have (Mason's bin dir, then $PATH)
[ -d "$HOME/.local/share/nvim/mason/bin" ] && export PATH="$HOME/.local/share/nvim/mason/bin:$PATH"
shop="$("$repo/demo/setup.sh")"
cd "$shop"
exec nvim "${@:-internal/order/order.go}"
