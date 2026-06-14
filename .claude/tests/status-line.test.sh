#!/bin/bash
# Tests for .claude/status-line.sh — composes the one-line README status from
# resolve-ready.sh --json output (the text sibling of render-status.sh). It
# consumes the resolver JSON and ONLY that JSON (the A-001 one-parser decision);
# the line is phase + completed/total, deterministic and grep-checkable. This is
# what lets the §3.3 render hooks refresh the README block without an agent
# hand-writing the line.
# Pure bash + jq, no test runner. Run: bash .claude/tests/status-line.test.sh
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$CLAUDE_DIR/status-line.sh"
RESOLVER="$CLAUDE_DIR/resolve-ready.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# Real resolver JSON from a GRAMMAR tracker (1 of 2 done) — the suite exercises
# the real producer→consumer path, not a hand-built island.
cat > "$WORK/open.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Build

- ✅ **[6.1]** Done `[deps: none]`
- ⬜ **[6.2]** Open `[deps: 6.1]`
MD
bash "$RESOLVER" "$WORK/open.md" --json > "$WORK/open.json" 2>/dev/null

[ -f "$SCRIPT" ] && ok "status-line.sh ships" || no "status-line.sh missing"

# ── GRAMMAR: **Phase N** · done/total ────────────────────────────────────────
LINE=$(bash "$SCRIPT" "$WORK/open.json" 2>/dev/null)
[ "$LINE" = "**Phase 6** · 1/2 deliverables" ] \
  && ok "GRAMMAR: composes '**Phase N** · done/total deliverables'" \
  || no "expected '**Phase 6** · 1/2 deliverables', got: $LINE"

# stdin (-) form equals the file-arg form
LINE2=$(bash "$SCRIPT" - < "$WORK/open.json" 2>/dev/null)
[ "$LINE2" = "$LINE" ] && ok "stdin (-) form equals the file-arg form" \
  || no "stdin form must equal file form (got: $LINE2)"

# happy path is silent on stderr (keeps the hooks' empty-stderr gate green)
ERR=$(bash "$SCRIPT" "$WORK/open.json" 2>&1 >/dev/null)
[ -z "$ERR" ] && ok "happy path: stderr clean" || no "stderr must be clean, got: $ERR"

# ── LEGACY tracker: the LEGACY-mode line ─────────────────────────────────────
cat > "$WORK/legacy.md" <<'MD'
# Phase Status Tracker

## Phase 1

- ✅ First thing
- ⬜ Second thing
MD
bash "$RESOLVER" "$WORK/legacy.md" --json > "$WORK/legacy.json" 2>/dev/null
LLINE=$(bash "$SCRIPT" "$WORK/legacy.json" 2>/dev/null)
echo "$LLINE" | grep -q 'LEGACY tracker' \
  && ok "LEGACY: composes the LEGACY-mode line (no phase grammar to count against)" \
  || no "LEGACY line wrong: $LLINE"

# ── all-complete (phase=null) branch — constructed island, deterministic ─────
cat > "$WORK/done.json" <<'JSON'
{"mode":"GRAMMAR","phase":null,"deliverables":[{"id":"6.1","status":"done"},{"id":"6.2","status":"done"}],"frontier":{"in_progress":[],"ready":[],"blocked":[],"serial":null}}
JSON
DLINE=$(bash "$SCRIPT" "$WORK/done.json" 2>/dev/null)
[ "$DLINE" = "**All phases complete** · 2/2 deliverables" ] \
  && ok "phase=null: composes the all-complete line" \
  || no "all-complete line wrong: $DLINE"

# ── fails loud, never composes off the wrong shape ───────────────────────────
echo '{"foo":1}' > "$WORK/bad.json"
bash "$SCRIPT" "$WORK/bad.json" >/dev/null 2>&1
[ $? -eq 5 ] \
  && ok "non-resolver JSON: exit 5 (never composes a line off the wrong shape)" \
  || no "non-resolver JSON must exit 5"
echo 'not json' > "$WORK/garbage.json"
bash "$SCRIPT" "$WORK/garbage.json" >/dev/null 2>&1
[ $? -eq 5 ] && ok "non-JSON: exit 5" || no "non-JSON must exit 5"

# ── usage grammar closed ─────────────────────────────────────────────────────
bash "$SCRIPT" "$WORK/nope.json" >/dev/null 2>&1
[ $? -eq 2 ] && ok "missing file: exit 2" || no "missing file must exit 2"
bash "$SCRIPT" >/dev/null 2>&1
[ $? -eq 2 ] && ok "no argument: usage exit 2" || no "no argument must exit 2"

# ── one-parser: no tracker grammar in the source (comments excluded) ──────────
TT=$(grep -nE 'PHASE_STATUS|deps:|⬜|✅|🔄|❌' "$SCRIPT" 2>/dev/null | grep -Ev '^[0-9]+:#' || true)
[ -z "$TT" ] \
  && ok "one-parser: status-line.sh carries no tracker grammar (consumes resolver JSON only)" \
  || no "status-line must not parse the tracker: $TT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
