// maintainers/render-smoke.js — dev-only DOM-stub smoke check for
// render-status.sh's client-side JS. NOT part of the shipped suite (the
// guv's runtime deps stay bash + jq; the suite's node --check covers
// syntax, this covers execution). Stubs the small DOM surface the renderer
// uses, executes the in-page script against real render output, and asserts
// the rendered tree: node/edge counts and a hover cycle in GRAMMAR mode, the
// ordered list (and no SVG) in LEGACY mode, and that no error banner fired.
// Usage:
//   bash .claude/resolve-ready.sh [tracker] --json > s.json
//   bash .claude/render-status.sh s.json > s.html
//   node maintainers/render-smoke.js s.html GRAMMAR   # or LEGACY
// EMPTY mode (hand-fed shape-valid JSON with zero deliverables) asserts the
// loud no-deliverables banner fires instead of broken geometry.
'use strict';
const fs = require('fs');
const [, , htmlPath, mode] = process.argv;
const html = fs.readFileSync(htmlPath, 'utf8');

const island = html.match(/<script type="application\/json" id="status-data">\n(.*)\n<\/script>/);
const code = html.match(/<\/script>\n<script>\n([\s\S]*)\n<\/script>\n<\/body>/);
if (!island || !code) { console.error('FAIL: could not extract island or script'); process.exit(1); }

function mkel(tag, ns) {
  const cls = new Set();
  let ownText = '';
  const el = {
    tagName: tag, ns: ns || null, children: [], attrs: {}, dataset: {},
    listeners: {},
    // recursive, like the real DOM — so strip/banner content is assertable
    get textContent() { return ownText + el.children.map(c => c.textContent).join(' '); },
    set textContent(v) { ownText = String(v); },
    setAttribute(k, v) { el.attrs[k] = String(v); if (k === 'class') { cls.clear(); String(v).split(/\s+/).filter(Boolean).forEach(c => cls.add(c)); } },
    appendChild(c) { el.children.push(c); return c; },
    insertBefore(c) { el.children.unshift(c); return c; },
    addEventListener(t, f) { el.listeners[t] = f; },
    classList: {
      toggle(c, on) { on ? cls.add(c) : cls.delete(c); },
      contains(c) { return cls.has(c); },
    },
    get className() { return [...cls].join(' '); },
    set className(v) { cls.clear(); String(v).split(/\s+/).filter(Boolean).forEach(c => cls.add(c)); },
    get firstChild() { return el.children[0] || null; },
  };
  let _id = '';
  Object.defineProperty(el, 'id', { get: () => _id, set: v => { _id = v; } });
  return el;
}

const root = mkel('main'), meta = mkel('p'), frontier = mkel('div'), data = mkel('script');
data.textContent = island[1].replace(/<\\\//g, '</');
const documentStub = {
  getElementById: id => ({ root, meta, frontier, 'status-data': data }[id]),
  createElement: t => mkel(t),
  createElementNS: (ns, t) => mkel(t, ns),
};

new Function('document', code[1])(documentStub);

function walk(el, fn) { fn(el); el.children.forEach(c => walk(c, fn)); }
const counts = {};
walk(root, e => { counts[e.tagName] = (counts[e.tagName] || 0) + 1; });
const errors = [];
walk(root, e => { if (e.className.includes('error')) errors.push(e.textContent); });
if (mode === 'EMPTY') {
  if (errors.length && /no deliverables/.test(errors.join(' '))) {
    console.log('OK EMPTY: loud no-deliverables banner fired, no geometry drawn');
    process.exit(0);
  }
  console.error('FAIL: expected the no-deliverables banner (got: ' + (errors.join(' | ') || 'no banner') + ')');
  process.exit(1);
}
if (errors.length) { console.error('FAIL: error banner rendered: ' + errors.join(' | ')); process.exit(1); }

const islandData = JSON.parse(data.textContent);
if (mode === 'GRAMMAR') {
  const n = islandData.deliverables.length;
  const edgeCount = islandData.deliverables.reduce((a, d) => a + d.deps.length, 0);
  if ((counts.g || 0) !== n) { console.error(`FAIL: expected ${n} nodes, got ${counts.g || 0}`); process.exit(1); }
  if ((counts.path || 0) !== edgeCount) { console.error(`FAIL: expected ${edgeCount} edges, got ${counts.path || 0}`); process.exit(1); }
  if ((counts.svg || 0) !== 1) { console.error('FAIL: expected one svg'); process.exit(1); }
  // exercise the hover chain-highlight on every node
  walk(root, e => { if (e.listeners.mouseenter) { e.listeners.mouseenter(); e.listeners.mouseleave(); } });
  if (!/ready:/.test(frontier.textContent)) { console.error('FAIL: frontier strip not populated (no ready: group)'); process.exit(1); }
  console.log(`OK GRAMMAR: svg=1 nodes=${counts.g} edges=${counts.path} hover-cycle clean; meta="${meta.textContent}"; frontier="${frontier.textContent}"`);
} else {
  if (counts.svg) { console.error('FAIL: LEGACY must not draw a DAG'); process.exit(1); }
  if ((counts.ol || 0) !== 1) { console.error('FAIL: expected one ordered list'); process.exit(1); }
  if ((counts.li || 0) !== islandData.deliverables.length) { console.error('FAIL: list item count mismatch'); process.exit(1); }
  if (!/next:/.test(frontier.textContent)) { console.error('FAIL: LEGACY strip must show the next: signal'); process.exit(1); }
  console.log(`OK LEGACY: ol=1 li=${counts.li} svg=0; meta="${meta.textContent}"; frontier="${frontier.textContent}"`);
}
