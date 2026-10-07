// Helpers for a recorded browser take with Playwright.
//
//   const { startTake } = require('./browser-helpers');
//   const t = await startTake({ out: 'clip', record: true });   // record:false = dry run
//   await t.page.goto(url);
//   await t.beat('login');
//   await t.typeInto(t.page.locator('#password'), 'secret');
//   await t.click(t.page.getByRole('button', { name: 'Sign In' }));
//   await t.shot('after-login');          // dry runs only
//   await t.finish();                     // writes <out>/browser.webm, browser.start, browser.beats.txt
//
// Headless video has no pointer, so a fake cursor is drawn and glides to each
// element before it is clicked. Needs playwright-core (npm i playwright-core)
// and a Chromium: CHROME env, else the newest Playwright cache under
// ~/.cache/ms-playwright.
const { chromium } = require('playwright-core');
const fs = require('fs');
const path = require('path');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function findChrome() {
  if (process.env.CHROME) return process.env.CHROME;
  const root = path.join(process.env.HOME, '.cache/ms-playwright');
  const dirs = fs.existsSync(root) ? fs.readdirSync(root).filter((d) => /^chromium-\d+$/.test(d)).sort() : [];
  for (const d of dirs.reverse()) {
    const p = path.join(root, d, 'chrome-linux64/chrome');
    if (fs.existsSync(p)) return p;
  }
  throw new Error('no Chromium found: set CHROME=/path/to/chrome');
}

const CURSOR = `
(() => {
  const mk = () => {
    if (document.getElementById('__demo_cursor')) return;
    const c = document.createElement('div');
    c.id = '__demo_cursor';
    c.innerHTML = '<svg width="28" height="28" viewBox="0 0 24 24"><path d="M4 2l16 9-7 2-3 7z" fill="#111" stroke="#fff" stroke-width="1.5" stroke-linejoin="round"/></svg>';
    Object.assign(c.style, { position: 'fixed', left: '50vw', top: '50vh', zIndex: 2147483647,
      pointerEvents: 'none', transition: 'left .6s ease, top .6s ease', filter: 'drop-shadow(0 1px 2px rgba(0,0,0,.4))' });
    document.documentElement.appendChild(c);
  };
  window.__demoMove = (x, y) => { mk(); const c = document.getElementById('__demo_cursor'); c.style.left = x + 'px'; c.style.top = y + 'px'; };
  if (document.readyState !== 'loading') mk(); else document.addEventListener('DOMContentLoaded', mk);
})();`;

async function startTake({ out, record = true, width = 1440, height = 900, colorScheme = 'light' }) {
  fs.mkdirSync(out, { recursive: true });
  const browser = await chromium.launch({ executablePath: findChrome() });
  const opts = { viewport: { width, height }, deviceScaleFactor: 1, colorScheme };
  if (record) opts.recordVideo = { dir: out, size: { width, height } };
  const ctx = await browser.newContext(opts);
  await ctx.addInitScript(CURSOR);
  const page = await ctx.newPage();
  const t0 = Date.now();
  fs.writeFileSync(path.join(out, 'browser.start'), String(t0));
  const beats = [];
  let shots = 0;

  const t = {
    page,
    sleep,
    beat(what) {
      const s = (Date.now() - t0) / 1000;
      beats.push(`${String(Math.floor(s / 60)).padStart(2, '0')}:${(s % 60).toFixed(1).padStart(4, '0')}  ${what}`);
      console.log(`[web ${s.toFixed(1)}s] ${what}`);
    },
    async click(loc, pause = 700) {
      await loc.waitFor({ state: 'visible', timeout: 30000 });
      await loc.scrollIntoViewIfNeeded();
      const b = await loc.boundingBox();
      await page.evaluate(([x, y]) => window.__demoMove(x, y), [b.x + b.width / 2, b.y + b.height / 2]);
      await sleep(800);
      await loc.click();
      await sleep(pause);
    },
    async typeInto(loc, text, delay = 80) {
      await t.click(loc, 300);
      await loc.pressSequentially(text, { delay });
      await sleep(400);
    },
    async shot(name) {
      if (!record) await page.screenshot({ path: path.join(out, `${String(++shots).padStart(2, '0')}-${name}.png`) });
    },
    // Resolve on the first locator that appears; returns its label.
    // Always list the failure states too, and wait on text that only
    // appears at the end (a status line), never on a static label.
    async waitForAny(states, timeout = 30 * 60 * 1000) {
      return Promise.race(Object.entries(states).map(([label, loc]) =>
        loc.first().waitFor({ timeout }).then(() => label)));
    },
    async finish() {
      fs.writeFileSync(path.join(out, 'browser.beats.txt'), beats.join('\n') + '\n');
      const video = page.video();
      await ctx.close();
      await browser.close();
      if (video) fs.renameSync(await video.path(), path.join(out, 'browser.webm'));
    },
  };
  return t;
}

module.exports = { startTake, sleep, findChrome };
