#!/usr/bin/env bash
# Records demo/hero.gif and demo/hero.png. Needs node, ffmpeg, Google Chrome, gopls.
# npm packages and fonts (JetBrains Mono, Nerd Font symbols) go to .tests/capture.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$repo/.tests/capture"
mkdir -p "$work/fonts"
cd "$work"
[ -d node_modules/neovim ] || { npm init -y >/dev/null; npm i --silent neovim@5 puppeteer-core@24; }
if [ ! -d fonts/sym ]; then
  curl -sSL -o fonts/sym.zip https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/NerdFontsSymbolsOnly.zip
  unzip -q -o fonts/sym.zip -d fonts/sym
fi
if [ ! -d fonts/jb ]; then
  curl -sSL -o fonts/jb.zip https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip
  unzip -q -o fonts/jb.zip -d fonts/jb
fi
cp "$repo/demo/capture.mjs" "$work/capture.mjs"
SPOOR_REPO="$repo" node "$work/capture.mjs"
