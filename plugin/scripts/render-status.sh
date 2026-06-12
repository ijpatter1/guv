#!/bin/bash
# .claude/render-status.sh
# Deterministic render of status.json as one self-contained HTML page
# ([6.5] of the plan-as-data spec, post-A-001 wording).
#
# Usage:
#   bash .claude/render-status.sh [status.json-path]   # HTML on stdout
#   # default input: ./status.json — produce it first:
#   #   bash .claude/resolve-ready.sh [tracker-path] --json > status.json
#   # publish by redirecting:  ... | or  > status.html
#
# This script consumes resolve-ready.sh --json output ONLY — it never parses
# the tracker (the A-001 one-parser decision: the resolver is the grammar's
# single implementation, and every other reader of plan state consumes its
# JSON). Absent or malformed input refuses loud pointing at the producer;
# there is no fallback path of any kind. The output is explicitly a VIEW:
# zero machine consumers, never a source, no persistence, no write-back —
# rebuilt whole on each run, never line-merged.
#
# The bash half is deliberately thin: validate the input, normalize it with
# jq -c, escape `</` so embedded text can never close the data island early,
# and emit one HTML document — JSON data island, vanilla JS rendering
# client-side, hand-rolled SVG laid out by topological layers. No framework,
# no CDN, no build step, no server; the file opens from disk. LEGACY input
# (no IDs, empty deps) renders as a plain ordered list — there are no edges
# to draw and none are invented.
# Exit: 0 rendered · 2 usage or missing jq · 4 no input file ·
#       5 input is not valid status JSON (problem named on stderr)
set -u

INPUT="status.json"
USAGE="usage: bash .claude/render-status.sh [status.json-path]   (HTML on stdout)"
case "${1:-}" in
  "") ;;
  -?*)
    echo "error: unknown argument '$1' — $USAGE" >&2
    exit 2
    ;;
  *) INPUT="$1" ;;
esac
# The grammar has exactly one position — anything past it refuses loud
# rather than being silently ignored (the allow-list IS the grammar).
if [ "$#" -gt 1 ]; then
  echo "error: unexpected argument '$2' — $USAGE" >&2
  exit 2
fi

# jq is the one dependency, guarded loud: without this a missing jq could
# emit a half-rendered page under exit 0 — a stale or empty view is worse
# than none.
if ! command -v jq >/dev/null 2>&1; then
  echo "error: render-status.sh requires jq (validates and embeds the status JSON)" >&2
  exit 2
fi

if [ ! -f "$INPUT" ]; then
  echo "error: no status JSON at '$INPUT' — produce it first: bash .claude/resolve-ready.sh [tracker-path] --json > '$INPUT'" >&2
  exit 4
fi

if ! jq -e . "$INPUT" >/dev/null 2>&1; then
  echo "error: '$INPUT' is not valid JSON — this renderer consumes resolve-ready.sh --json output only" >&2
  exit 5
fi

# Shape gate: the fields the renderer depends on, each named when absent.
# (Shape, not provenance — the contract is documented beside the tracker
# grammar in the phase-docs skill.)
SHAPE_ERR=$(jq -r '
  [ (if (.mode == "GRAMMAR" or .mode == "LEGACY") then empty else "mode" end),
    (if (.deliverables | type) == "array" then empty else "deliverables" end),
    (if (.frontier | type) == "object" then empty else "frontier" end),
    (if (.generated | type) == "string" then empty else "generated" end)
  ] | join(", ")' "$INPUT" 2>/dev/null)
if [ -n "$SHAPE_ERR" ]; then
  echo "error: '$INPUT' does not carry the status.json shape (missing or invalid: $SHAPE_ERR) — produce it with resolve-ready.sh --json" >&2
  exit 5
fi

# Normalize (jq -c: one canonical line, deterministic for identical input)
# and escape `</` -> `<\/` — valid JSON either way, and the only sequence
# that could close the island's <script> element early.
DATA=$(jq -c . "$INPUT" | sed 's|</|<\\/|g')

cat <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Plan status</title>
<style>
  :root { color-scheme: light; }
  body { margin: 0; font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; color: #1d2129; background: #fafafa; }
  header { padding: 16px 24px 8px; border-bottom: 1px solid #e0e0e0; background: #fff; }
  h1 { margin: 0 0 4px; font-size: 20px; }
  #meta { margin: 0; color: #616161; font-size: 12px; }
  #frontier { padding: 10px 24px; background: #fff; border-bottom: 1px solid #e0e0e0; font-size: 13px; }
  #frontier span.lbl { color: #616161; margin-right: 4px; }
  #frontier span.grp { margin-right: 18px; }
  main { padding: 16px 24px 32px; }
  .error { padding: 12px 16px; margin: 16px 0; border: 2px solid #c62828; background: #ffebee; color: #b71c1c; font-weight: 600; }
  #legend { margin: 4px 0 12px; font-size: 12px; color: #616161; }
  #legend .chip { display: inline-block; margin-right: 14px; padding: 1px 8px; border-radius: 4px; border: 2px solid transparent; }
  /* status vocabulary — done | in_progress | todo | descoped (words, never markers) */
  .status-done        { background: #e8f5e9; border-color: #2e7d32; color: #1b5e20; }
  .status-in_progress { background: #fff8e1; border-color: #f9a825; color: #8d6e00; }
  .status-todo        { background: #f5f5f5; border-color: #9e9e9e; color: #424242; }
  .status-descoped    { background: #ffebee; border-color: #c62828; color: #b71c1c; text-decoration: line-through; }
  .is-ready           { box-shadow: 0 0 0 3px #1565c0; }
  /* SVG node/edge styling mirrors the chip vocabulary */
  svg .node rect.status-done        { fill: #e8f5e9; stroke: #2e7d32; }
  svg .node rect.status-in_progress { fill: #fff8e1; stroke: #f9a825; }
  svg .node rect.status-todo        { fill: #f5f5f5; stroke: #9e9e9e; }
  svg .node rect.status-descoped    { fill: #ffebee; stroke: #c62828; }
  svg .node.is-descoped text { text-decoration: line-through; fill: #b71c1c; }
  svg .node rect { stroke-width: 2; }
  svg .node rect.is-ready { stroke: #1565c0; stroke-width: 4; }
  svg .node text { font: 600 13px -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; fill: #1d2129; }
  svg .edge { fill: none; stroke: #b0bec5; stroke-width: 1.5; }
  svg .node.hl rect { stroke-width: 4; }
  svg .edge.hl { stroke: #1d2129; stroke-width: 2.5; }
  .phase-list h2 { font-size: 15px; margin: 20px 0 6px; }
  .phase-list li { margin: 6px 0; }
  .phase-list .chip { font-size: 11px; padding: 0 6px; margin-left: 8px; border-radius: 4px; border: 1px solid; white-space: nowrap; }
  .phase-list ol, ol.legacy { padding-left: 28px; }
  ol.legacy li { margin: 6px 0; }
</style>
</head>
<body>
<header>
  <h1>Plan status</h1>
  <p id="meta"></p>
</header>
<div id="frontier"></div>
<main id="root"></main>
<script type="application/json" id="status-data">
HTML_HEAD
printf '%s\n' "$DATA"
cat <<'HTML_TAIL'
</script>
<script>
(function () {
  'use strict';
  var root = document.getElementById('root');

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }

  function fail(msg) {
    root.insertBefore(el('div', 'error', msg), root.firstChild);
  }

  var data;
  try {
    data = JSON.parse(document.getElementById('status-data').textContent);
  } catch (e) {
    fail('The embedded status JSON failed to parse: ' + e.message);
    return;
  }

  document.getElementById('meta').textContent =
    'mode ' + data.mode +
    (data.phase !== null && data.phase !== undefined ? ' · phase ' + data.phase : '') +
    ' · generated ' + data.generated;

  // Frontier strip — field for field what the resolver reported.
  (function () {
    var f = data.frontier || {};
    var strip = document.getElementById('frontier');
    function grp(label, value) {
      var g = el('span', 'grp');
      g.appendChild(el('span', 'lbl', label));
      g.appendChild(el('span', '', value));
      strip.appendChild(g);
    }
    grp('in progress:', (f.in_progress || []).join(', ') || '—');
    grp('ready:', (f.ready || []).join(', ') || '—');
    grp('blocked:', (f.blocked || []).map(function (b) {
      return b.id + ' ← ' + b.blocked_by;
    }).join(', ') || '—');
    grp('serial:', f.serial === null || f.serial === undefined ? '—' : String(f.serial));
  })();

  try {
    if (data.mode === 'LEGACY') renderLegacy(data); else renderDag(data);
  } catch (e) {
    fail('Render failed: ' + e.message);
  }

  // LEGACY: no IDs, empty deps — a plain ordered list in document order.
  // There are no edges to draw, and none are invented.
  function renderLegacy(data) {
    var list = document.createElement('ol');
    list.className = 'legacy';
    data.deliverables.forEach(function (d) {
      var li = el('li', 'status-' + d.status);
      li.appendChild(el('span', '', d.text));
      list.appendChild(li);
    });
    root.appendChild(list);
  }

  function renderDag(data) {
    var SVG_NS = 'http://www.w3.org/2000/svg';
    var items = data.deliverables;
    var byId = {};
    items.forEach(function (d) { byId[d.id] = d; });
    var ready = {};
    (data.frontier.ready || []).forEach(function (id) { ready[id] = true; });

    // Topological layer = longest dependency chain beneath the node. The
    // resolver guarantees acyclicity (it exits 5 on cycles); the visiting
    // guard turns hand-fed cyclic JSON into a loud banner, not a hung page.
    var memo = {}, visiting = {};
    function depth(id) {
      if (memo[id] !== undefined) return memo[id];
      if (visiting[id]) throw new Error('dependency cycle at ' + id);
      visiting[id] = true;
      var best = 0;
      (byId[id].deps || []).forEach(function (p) {
        if (byId[p]) best = Math.max(best, depth(p) + 1);
      });
      delete visiting[id];
      memo[id] = best;
      return best;
    }
    var layers = [];
    items.forEach(function (d) {
      var n = depth(d.id);
      (layers[n] = layers[n] || []).push(d);   // document order within a layer
    });

    // Hand-rolled geometry: layers as columns, document order as rows.
    var NW = 96, NH = 34, CGAP = 70, RGAP = 16, M = 24;
    var rows = 0;
    layers.forEach(function (l) { rows = Math.max(rows, l.length); });
    var width = M * 2 + layers.length * NW + (layers.length - 1) * CGAP;
    var height = M * 2 + rows * NH + (rows - 1) * RGAP;
    var pos = {};
    layers.forEach(function (layer, li) {
      layer.forEach(function (d, ri) {
        pos[d.id] = { x: M + li * (NW + CGAP), y: M + ri * (NH + RGAP) };
      });
    });

    var svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('viewBox', '0 0 ' + width + ' ' + height);
    svg.setAttribute('width', width);
    svg.setAttribute('height', height);
    svg.setAttribute('role', 'img');

    // Edges first (under the nodes), one per declared dependency.
    var edges = [];
    items.forEach(function (d) {
      (d.deps || []).forEach(function (p) {
        if (!byId[p]) return;
        var a = pos[p], b = pos[d.id];
        var path = document.createElementNS(SVG_NS, 'path');
        var x1 = a.x + NW, y1 = a.y + NH / 2, x2 = b.x, y2 = b.y + NH / 2;
        var mx = (x1 + x2) / 2;
        path.setAttribute('d', 'M' + x1 + ' ' + y1 + ' C' + mx + ' ' + y1 +
          ' ' + mx + ' ' + y2 + ' ' + x2 + ' ' + y2);
        path.setAttribute('class', 'edge');
        path.dataset.from = p;
        path.dataset.to = d.id;
        svg.appendChild(path);
        edges.push(path);
      });
    });

    var nodeEls = {};
    items.forEach(function (d) {
      var p = pos[d.id];
      var g = document.createElementNS(SVG_NS, 'g');
      g.setAttribute('class', 'node' + (d.status === 'descoped' ? ' is-descoped' : ''));
      var rect = document.createElementNS(SVG_NS, 'rect');
      rect.setAttribute('x', p.x); rect.setAttribute('y', p.y);
      rect.setAttribute('width', NW); rect.setAttribute('height', NH);
      rect.setAttribute('rx', 6);
      rect.setAttribute('class', 'status-' + d.status + (ready[d.id] ? ' is-ready' : ''));
      var label = document.createElementNS(SVG_NS, 'text');
      label.setAttribute('x', p.x + NW / 2); label.setAttribute('y', p.y + NH / 2 + 5);
      label.setAttribute('text-anchor', 'middle');
      label.textContent = d.id;
      var title = document.createElementNS(SVG_NS, 'title');
      title.textContent = d.text;
      g.appendChild(title); g.appendChild(rect); g.appendChild(label);
      svg.appendChild(g);
      nodeEls[d.id] = g;
      g.addEventListener('mouseenter', function () { highlight(d.id, true); });
      g.addEventListener('mouseleave', function () { highlight(d.id, false); });
    });

    // Blocked chains traceable: hovering a node lights its transitive
    // dependency closure — every ancestor node and every edge between them.
    function ancestors(id, acc) {
      (byId[id].deps || []).forEach(function (p) {
        if (byId[p] && !acc[p]) { acc[p] = true; ancestors(p, acc); }
      });
      return acc;
    }
    function highlight(id, on) {
      var chain = ancestors(id, {}); chain[id] = true;
      Object.keys(chain).forEach(function (n) {
        if (nodeEls[n]) nodeEls[n].classList.toggle('hl', on);
      });
      edges.forEach(function (e) {
        if (chain[e.dataset.to] && chain[e.dataset.from]) e.classList.toggle('hl', on);
      });
    }

    var legend = el('div', '', '');
    legend.id = 'legend';
    [['status-done', 'done'], ['status-in_progress', 'in progress'],
     ['status-todo', 'todo'], ['status-descoped', 'descoped'],
     ['status-todo is-ready', 'ready frontier']].forEach(function (pair) {
      legend.appendChild(el('span', 'chip ' + pair[0], pair[1]));
    });
    root.appendChild(legend);
    root.appendChild(svg);

    // Per-phase detail: the full deliverable text beside the graph, grouped
    // by the phase boundaries the JSON carries.
    var detail = el('div', 'phase-list');
    (data.phases || []).forEach(function (ph) {
      detail.appendChild(el('h2', '', 'Phase ' + ph));
      var list = document.createElement('ol');
      items.forEach(function (d) {
        if (d.phase !== ph) return;
        var li = el('li', '');
        li.appendChild(el('span', '', d.text));
        var chip = el('span', 'chip status-' + d.status + (ready[d.id] ? ' is-ready' : ''),
          d.status.replace('_', ' ') + (ready[d.id] ? ' · ready' : ''));
        li.appendChild(chip);
        list.appendChild(li);
      });
      detail.appendChild(list);
    });
    root.appendChild(detail);
  }
})();
</script>
</body>
</html>
HTML_TAIL
