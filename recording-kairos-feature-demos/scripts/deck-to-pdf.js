// Render the Slides deck's files to one 1920x1080-per-page PDF.
//
//   node deck-to-pdf.js DECK_ROOT BLOB_MAP_JSON OUT.pdf
//
// DECK_ROOT holds project/deck.json and project/slides/<id>.html.
// BLOB_MAP_JSON maps "/_blob/<id>" to a local image path.
const { chromium } = require('playwright-core');
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');

const [root, blobMapFile, out] = process.argv.slice(2);
const deck = JSON.parse(fs.readFileSync(path.join(root, 'project/deck.json'), 'utf8'));
const blobs = JSON.parse(fs.readFileSync(blobMapFile, 'utf8'));

const arrow = (style) => {
  const get = (k) => (style.match(new RegExp(k + ':\\s*([^;]+)')) || [])[1];
  const w = parseInt(get('width') || '72', 10), h = parseInt(get('height') || '36', 10);
  const fill = get('background') || '#6D7373';
  // block arrow: shaft, then a head over the last 40% of the length
  const hx = Math.round(w * 0.6), t = Math.round(h * 0.3);
  return `<svg width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" style="flex:none"><path d="M0 ${t}H${hx}V0L${w} ${h / 2}L${hx} ${h}V${h - t}H0Z" fill="${fill}"/></svg>`;
};

const slides = deck.order.map((id) => {
  let html = fs.readFileSync(path.join(root, 'project/slides', id + '.html'), 'utf8');
  html = html.replace(/<aside>[\s\S]*?<\/aside>/g, '');
  html = html.replace(/<x-shape kind="arrow-right" style="([^"]*)"><\/x-shape>/g, (_, s) => arrow(s));
  for (const [blob, file] of Object.entries(blobs)) html = html.split(blob).join(pathToFileURL(file).href);
  return html;
}).join('\n');

const fontLinks = Object.values(deck.faces).filter((f) => f.href)
  .map((f) => `<link rel="stylesheet" href="${f.href}">`).join('\n');

const doc = `<!doctype html><html><head><meta charset="utf-8">${fontLinks}
<style>
@page { size: 1920px 1080px; margin: 0 }
* { margin: 0; box-sizing: border-box }
html, body { padding: 0; background: #fff }
section { width: 1920px; height: 1080px; position: relative; overflow: hidden; break-after: page }
h1 { font-size: 96px; font-weight: 600; line-height: 1.1 }
h2 { font-size: 64px; font-weight: 600; line-height: 1.15 }
h3 { font-size: 44px; font-weight: 600; line-height: 1.2 }
p { font-size: 32px; line-height: 1.4 }
table { border-collapse: collapse; width: 100% }
th, td { padding: 0.35em 0.6em; border-bottom: 1px solid rgba(16,42,42,0.2); text-align: left; vertical-align: top }
th { font-weight: 600 }
</style></head><body>${slides}</body></html>`;

(async () => {
  const html = path.join(path.dirname(out), '.deck-print.html');
  fs.writeFileSync(html, doc);
  const browser = await chromium.launch({
    executablePath: require('./browser-helpers').findChrome ? require('./browser-helpers').findChrome() : process.env.CHROME,
  });
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
  await page.goto(pathToFileURL(html).href, { waitUntil: 'networkidle' });
  await page.evaluate(() => document.fonts.ready);
  await page.pdf({ path: out, width: '1920px', height: '1080px', printBackground: true, preferCSSPageSize: true });
  await browser.close();
  fs.unlinkSync(html);
  console.log('wrote', out);
})().catch((e) => { console.error(e); process.exit(1); });
