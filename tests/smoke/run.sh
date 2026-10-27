#!/usr/bin/env bash
# Smoke-test spoor in a real config: tests/smoke/run.sh <minimal|lazy|lazyvim|pack>
#   NVIM=/path/to/nvim         Neovim to test (default: nvim)
#   SPOOR_URL=<git url>        install spoor from this URL instead of this checkout
#   SPOOR_SMOKE_HOME=<dir>     where the throwaway config lives (default: .tests/smoke/<config>-<version>)
# Everything lives under SPOOR_SMOKE_HOME; your own Neovim config is never read.
set -euo pipefail
config=${1:?usage: run.sh <minimal|lazy|lazyvim|pack>}
repo=$(cd "$(dirname "$0")/../.." && pwd)
nvim=${NVIM:-nvim}
version=$("$nvim" --version | head -1 | awk '{print $2}')
home=${SPOOR_SMOKE_HOME:-$repo/.tests/smoke/$config-$version}
mkdir -p "$home"
export XDG_CONFIG_HOME=$home/config XDG_DATA_HOME=$home/data XDG_STATE_HOME=$home/state XDG_CACHE_HOME=$home/cache
export SPOOR_REPO=$repo SPOOR_SMOKE_CONFIG=$config SPOOR_SMOKE_RESULT=$home/result
mkdir -p "$XDG_CONFIG_HOME/nvim"
cp "$repo/tests/smoke/init_$config.lua" "$XDG_CONFIG_HOME/nvim/init.lua"

if [ -z "${SPOOR_URL:-}" ]; then
  # lazy.nvim generates help tags for plugins it clones, not for a local `dir`; do it here
  "$nvim" --clean --headless -c "helptags $repo/doc" -c q
fi
if [ "$config" = lazy ] || [ "$config" = lazyvim ]; then
  "$nvim" --headless "+Lazy! sync" +qa >"$home/install.log" 2>&1 || { cat "$home/install.log"; exit 1; }
fi
if [ "$config" = pack ]; then
  # vim.pack asks before installing; answer for the user once
  "$nvim" --headless "+lua vim.wait(60000, function() return pcall(require, 'snacks') and pcall(require, 'spoor') end)" +qa \
    >"$home/install.log" 2>&1 || { cat "$home/install.log"; exit 1; }
fi

rm -f "$SPOOR_SMOKE_RESULT"
"$nvim" --headless -c "luafile $repo/tests/smoke/check.lua" >"$home/check.log" 2>&1 &
pid=$!
# :q with the panel open must exit Neovim; give it 90 s in total
for _ in $(seq 1 180); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid"
  echo "FAIL $config $version: Neovim did not exit after :q (see $home/check.log)"
  cat "$home/check.log" "$SPOOR_SMOKE_RESULT" 2>/dev/null
  exit 1
fi
wait "$pid" || true
if [ "$(head -1 "$SPOOR_SMOKE_RESULT" 2>/dev/null)" != "OK" ]; then
  echo "FAIL $config $version"
  cat "$SPOOR_SMOKE_RESULT" "$home/check.log" 2>/dev/null
  exit 1
fi
echo "ok   $config $version"
