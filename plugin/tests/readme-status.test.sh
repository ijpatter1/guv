#!/bin/bash
# Tests for .claude/update-readme-status.sh — the in-place README status-block updater.
# Pure bash + awk, no test runner. Run: bash .claude/tests/readme-status.test.sh
set -u

HELPER="$(cd "$(dirname "$0")/.." && pwd)/update-readme-status.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

readme_with_markers() {
  cat > "$WORK/R.md" <<'EOF'
# My Project

> One-liner.

<!-- STATUS:START (generated) -->

_Status: not yet scaffolded._

<!-- STATUS:END -->

## Quick start

Run the tests.
EOF
}

# T1 — replaces block content; preserves surrounding prose and the markers
readme_with_markers
printf '%s\n' "**Phase 2 — Ingestion** · 6/9 deliverables · session-2026-06-10-003" \
  | bash "$HELPER" "$WORK/R.md"
grep -q "Phase 2 — Ingestion" "$WORK/R.md" && ok "new status content injected" || no "status not injected"
grep -q "not yet scaffolded" "$WORK/R.md" && no "old status content should be gone" || ok "old status content removed"
grep -q "# My Project" "$WORK/R.md" && ok "prose above block preserved" || no "prose above lost"
grep -q "## Quick start" "$WORK/R.md" && ok "prose below block preserved" || no "prose below lost"
[ "$(grep -c 'STATUS:START' "$WORK/R.md")" = 1 ] && [ "$(grep -c 'STATUS:END' "$WORK/R.md")" = 1 ] && ok "both markers preserved exactly once" || no "markers not preserved"

# T2 — idempotent-ish: a second update replaces again (no accumulation)
printf '%s\n' "**Phase 3 — Serving** · 1/4 deliverables" | bash "$HELPER" "$WORK/R.md"
grep -q "Phase 3 — Serving" "$WORK/R.md" && ok "second update replaces" || no "second update failed"
grep -q "Phase 2 — Ingestion" "$WORK/R.md" && no "prior status should be gone" || ok "prior status replaced, not appended"
[ "$(grep -c 'STATUS:START' "$WORK/R.md")" = 1 ] && ok "no marker duplication after re-run" || no "markers duplicated"

# T3 — multi-line body: every line lands between the markers
readme_with_markers
printf '%s\n%s\n' "line one" "line two" | bash "$HELPER" "$WORK/R.md"
grep -q "line one" "$WORK/R.md" && grep -q "line two" "$WORK/R.md" && ok "multi-line body injected" || no "multi-line body lost"

# T4 — no markers: file left byte-for-byte unchanged (don't clobber a consumer README)
printf '# Plain README\n\nNo markers here.\n' > "$WORK/plain.md"
cp "$WORK/plain.md" "$WORK/plain.orig"
printf '%s\n' "should not appear" | bash "$HELPER" "$WORK/plain.md"
cmp -s "$WORK/plain.md" "$WORK/plain.orig" && ok "no-marker README untouched" || no "no-marker README was modified"
grep -q "should not appear" "$WORK/plain.md" && no "content leaked into markerless README" || ok "no content leaked"

# T5 — START but no END: untouched (don't drop the rest of the file)
printf '# R\n<!-- STATUS:START -->\nold\nmore prose\n' > "$WORK/half.md"
cp "$WORK/half.md" "$WORK/half.orig"
printf '%s\n' "new" | bash "$HELPER" "$WORK/half.md"
cmp -s "$WORK/half.md" "$WORK/half.orig" && ok "START-only (no END) left untouched" || no "START-only file was mangled"

# T5b — a status body that itself contains the literal "STATUS:END" must not truncate
# the block (body lines are printed verbatim, not re-matched against the END pattern).
readme_with_markers
printf '%s\n%s\n' "mentions STATUS:END in prose" "second line after it" | bash "$HELPER" "$WORK/R.md"
grep -q "second line after it" "$WORK/R.md" && ok "body containing 'STATUS:END' doesn't truncate the block" || no "body with marker-text truncated the block"
grep -q "## Quick start" "$WORK/R.md" && ok "prose after block survives a marker-text body" || no "prose after lost on marker-text body"

# T6 — missing file: exit 0, no error
( bash "$HELPER" "$WORK/nope.md" ); [ $? -eq 0 ] && ok "missing file: exit 0" || no "missing file should exit 0"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
