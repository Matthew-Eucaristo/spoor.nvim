// Records the README hero: drives a real LazyVim (demo/init.lua) through `nvim --embed`,
// renders each frame with JetBrains Mono + Nerd Font symbols in headless Chrome, and
// assembles demo/hero.gif and demo/hero.png with ffmpeg. Fixture code only.
//
//   demo/capture.sh        (installs the npm deps and fonts into .tests/capture first)
import { attach } from "neovim";
import puppeteer from "puppeteer-core";
import { spawn, execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repo = process.env.SPOOR_REPO || join(dirname(fileURLToPath(import.meta.url)), "..");
const work = join(repo, ".tests", "capture");
const frames = join(work, "frames");
const fonts = join(work, "fonts");
const state = join(repo, ".tests", "demo");
const COLS = 150, ROWS = 40, FONT = 15, LINE = 19;
const chrome = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- the editor -----------------------------------------------------------
const shop = execFileSync(join(repo, "demo", "setup.sh")).toString().trim();
const env = {
  ...process.env,
  XDG_CONFIG_HOME: join(state, "config"),
  XDG_DATA_HOME: join(state, "data"),
  XDG_STATE_HOME: join(state, "state"),
  XDG_CACHE_HOME: join(state, "cache"),
  NVIM_APPNAME: "spoor-demo",
  PATH: `${process.env.HOME}/.local/share/nvim/mason/bin:${process.env.PATH}`,
};
mkdirSync(join(state, "config", "spoor-demo"), { recursive: true });
try {
  execFileSync("ln", ["-sf", join(repo, "demo", "init.lua"), join(state, "config", "spoor-demo", "init.lua")]);
} catch {}
rmSync(join(state, "state", "spoor-demo", "spoor"), { recursive: true, force: true }); // fresh trails/toggle
const proc = spawn("nvim", ["--embed", "internal/order/order.go"], { cwd: shop, env });
const nvim = attach({ proc });

// --- the grid -------------------------------------------------------------
const grid = { w: COLS, h: ROWS, cells: [], cursor: [0, 0] };
const hl = { 0: {} };
let colors = { fg: 0xc0caf5, bg: 0x222436 };
const blank = () => Array.from({ length: grid.w }, () => [" ", 0]);
const reset = () => (grid.cells = Array.from({ length: grid.h }, blank));
reset();
let flushed = 0;

nvim.on("notification", (method, args) => {
  if (method !== "redraw") return;
  for (const [name, ...calls] of args) {
    for (const a of calls) {
      switch (name) {
        case "default_colors_set":
          colors = { fg: a[0] >= 0 ? a[0] : colors.fg, bg: a[1] >= 0 ? a[1] : colors.bg };
          break;
        case "hl_attr_define":
          hl[a[0]] = a[1];
          break;
        case "grid_resize":
          grid.w = a[1];
          grid.h = a[2];
          reset();
          break;
        case "grid_clear":
          reset();
          break;
        case "grid_cursor_goto":
          grid.cursor = [a[1], a[2]];
          break;
        case "grid_line": {
          const [, row, col0, cells] = a;
          let col = col0, id = 0;
          for (const c of cells) {
            if (c.length > 1) id = c[1];
            const n = c.length > 2 ? c[2] : 1;
            for (let i = 0; i < n && col < grid.w; i++) grid.cells[row][col++] = [c[0], id];
          }
          break;
        }
        case "grid_scroll": {
          const [, top, bot, left, right, rows] = a;
          const copy = grid.cells.map((r) => r.slice());
          for (let r = top; r < bot; r++) {
            const src = r + rows;
            if (src >= top && src < bot) for (let c = left; c < right; c++) grid.cells[r][c] = copy[src][c];
          }
          break;
        }
        case "flush":
          flushed++;
          break;
      }
    }
  }
});

// --- frames ---------------------------------------------------------------
const hex = (n) => "#" + n.toString(16).padStart(6, "0");
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
function html() {
  const lines = grid.cells.map((row, r) => {
    let out = "", run = "", key = null;
    const close = () => run && (out += `<span style="${key}">${esc(run)}</span>`);
    row.forEach(([ch, id], c) => {
      const a = hl[id] || {};
      let fg = a.foreground ?? colors.fg, bg = a.background ?? colors.bg;
      if (a.reverse) [fg, bg] = [bg, fg];
      if (r === grid.cursor[0] && c === grid.cursor[1]) [fg, bg] = [colors.bg, colors.fg];
      const style = `color:${hex(fg)};background:${hex(bg)}${a.bold ? ";font-weight:700" : ""}${a.italic ? ";font-style:italic" : ""}${a.underline || a.undercurl ? ";text-decoration:underline" : ""}${a.strikethrough ? ";text-decoration:line-through" : ""}`;
      if (style !== key) {
        close();
        run = "";
        key = style;
      }
      if (ch === "") return;
      if (/^[\x20-\x7e]$/.test(ch)) run += ch;
      else {
        close();
        out += `<span class="w" style="${key}">${esc(ch)}</span>`;
        run = "";
      }
    });
    close();
    return `<div class="l">${out}</div>`;
  });
  const f = pathToFileURL(fonts).href;
  return `<!doctype html><meta charset="utf-8"><style>
@font-face{font-family:JB;src:url(${f}/jb/fonts/ttf/JetBrainsMono-Regular.ttf)}
@font-face{font-family:JB;font-weight:700;src:url(${f}/jb/fonts/ttf/JetBrainsMono-Bold.ttf)}
@font-face{font-family:JB;font-style:italic;src:url(${f}/jb/fonts/ttf/JetBrainsMono-Italic.ttf)}
@font-face{font-family:NF;src:url(${f}/sym/SymbolsNerdFontMono-Regular.ttf)}
html,body{margin:0;background:${hex(colors.bg)}}
#t{display:inline-block;padding:14px 16px;font:${FONT}px/${LINE}px JB,NF,monospace;font-variant-ligatures:none;white-space:pre}
.l{height:${LINE}px;width:${COLS}ch;overflow:hidden}
.w{display:inline-block;width:1ch;overflow:visible}
</style><div id="t">${lines.join("")}</div>`;
}

const shots = [];
let page;
async function shot(hold) {
  await settle();
  const file = join(frames, `f${String(shots.length).padStart(3, "0")}.png`);
  const page_file = join(work, "frame.html");
  writeFileSync(page_file, html());
  await page.goto(pathToFileURL(page_file).href, { waitUntil: "load" });
  await page.evaluate(() => document.fonts.ready);
  const el = await page.$("#t");
  await el.screenshot({ path: file });
  shots.push({ file, hold });
}

// wait until the screen stops changing for a moment
async function settle(quiet = 250, max = 4000) {
  const start = Date.now();
  let last = flushed, since = Date.now();
  while (Date.now() - start < max) {
    await sleep(40);
    if (flushed !== last) {
      last = flushed;
      since = Date.now();
    } else if (Date.now() - since > quiet) return;
  }
}

const lua = (code, args = []) => nvim.request("nvim_exec_lua", [code, args]);
const keys = (k) => nvim.input(k);
async function until(code, ms = 30000) {
  const start = Date.now();
  while (Date.now() - start < ms) {
    if (await lua(code)) return;
    await sleep(100);
  }
  throw new Error("timed out: " + code);
}
async function type(text, ms = 45) {
  for (const ch of text) {
    await keys(ch === "<" ? "<lt>" : ch);
    await sleep(ms);
  }
}
const panelOn = (name) => `local v = require('spoor.live').panels[vim.api.nvim_get_current_tabpage()]; return v and v:valid() and v.graph and v.graph.nodes[v.graph.focus].name == '${name}' and v.graph.status.incoming == 'done' and v.graph.status.outgoing == 'done' or false`;
const cursor = (row, col) => lua("local r, c = ... vim.api.nvim_win_set_cursor(0, { r, c })", [row, col]);
const lineOf = (pat) => lua(`local pat = ... for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do local s = l:find(pat) if s then return { i, s - 1 } end end error("no line matches " .. pat)`, [pat]);

// --- the tour -------------------------------------------------------------
rmSync(frames, { recursive: true, force: true });
mkdirSync(frames, { recursive: true });
const browser = await puppeteer.launch({ executablePath: chrome, headless: true, args: ["--allow-file-access-from-files"] });
page = await browser.newPage();
await page.setViewport({ width: 1600, height: 1000, deviceScaleFactor: 1 });

await nvim.request("nvim_ui_attach", [COLS, ROWS, { ext_linegrid: true, rgb: true }]);
await until("return #vim.lsp.get_clients({ bufnr = 0, name = 'gopls' }) > 0 and package.loaded['spoor'] ~= nil");
await sleep(2500);
await keys("<Esc>");
await shot(1400);

// 1. rest the cursor on a function: the live bow-tie appears
let [l, c] = await lineOf("^func Process");
for (let i = 1; i < l; i += 3) {
  await cursor(Math.min(i, l), 0);
  await sleep(30);
}
await cursor(l, 5);
await until(panelOn("Process"));
await shot(2600);

// 2. walk into the body, onto a call: the bow-tie follows
[l, c] = await lineOf("validate%(o%)");
await keys("j");
await sleep(150);
await cursor(l, c);
await until(panelOn("validate"));
await shot(1900);
[l, c] = await lineOf("repo%.Save");
await cursor(l, c + 5);
await until(panelOn("Save"));
await shot(1900);

// 3. gag: the float, two levels deep
[l, c] = await lineOf("^func Process");
await cursor(l, 5);
await until(panelOn("Process"));
await keys("gag");
await until("local v = require('spoor.bowtie').current; return v and v:valid() and v.graph.status.incoming == 'done' or false");
await sleep(600);
await shot(3200);
await keys("q");

// 4. gat: trace down, pick the interface, choose an implementation, leave a note
await keys("gat");
await until("local s = require('spoor.trace').state; return s.win and s.win:valid() and #s.hops > 3 or false");
await sleep(500);
await shot(2000);
const save = await lua("for _, m in pairs(require('spoor.trace').state.rendered.map) do local s = require('spoor.trace').state if m.id and s.graph.nodes[m.id].name == 'Save' then return m.hop end end");
await keys(String(save));
await sleep(900);
await shot(1600);
await keys("<C-n>");
await sleep(400);
await keys("<CR>");
await until("return #require('spoor.trace').state.trail.steps == 2");
await sleep(700);
await keys("n");
await sleep(500);
await type("rounding happens before Save?");
await shot(1200);
await keys("<CR>");
await sleep(500);
await shot(2600);
await keys("q");
await sleep(300);

// 5. <leader>cG: what did the agent change?
await keys("<Space>cG");
await until("return vim.bo.filetype == 'snacks_picker_input'", 20000);
await sleep(1500);
await shot(1600);
await keys("<C-n>"); // the new function nobody calls
await sleep(500);
await sleep(700);
await shot(3000);
await keys("<Esc>");
await sleep(300);
await keys("<Esc>");

// 6. <leader>ce: entry points
await keys("<Space>ce");
await until("return vim.bo.filetype == 'snacks_picker_input'", 20000);
await sleep(900);
await shot(2600);
await keys("<Esc>");

await browser.close();
nvim.quit();

// --- assemble -------------------------------------------------------------
const list = shots.map((s) => `file '${s.file}'\nduration ${(s.hold / 1000).toFixed(2)}`).join("\n") + `\nfile '${shots.at(-1).file}'\n`;
writeFileSync(join(work, "frames.txt"), list);
const out = join(repo, "demo");
execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", join(work, "frames.txt"),
  "-vf", "fps=10,scale=1200:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle",
  join(out, "hero.gif")]);
execFileSync("cp", [shots[1].file, join(out, "hero.png")]);
console.log(`${shots.length} frames -> demo/hero.gif, demo/hero.png`);
process.exit(0);
