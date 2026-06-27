#!/bin/bash
# Tests for .claude/skills/status/scripts/check-citations.sh — advisory commit-citation integrity check.
# Pure bash + git, no test runner required (this template repo ships no JS suite).
# Run: bash .claude/tests/check-citations.test.sh
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/skills/status/scripts/check-citations.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A code repo with one real commit (its sibling control plane will cite it).
CODE="$WORK/code"
mkdir -p "$CODE"
git -C "$CODE" init -q
git -C "$CODE" config user.email t@t
git -C "$CODE" config user.name t
echo x > "$CODE/f"
git -C "$CODE" add f
git -C "$CODE" commit -qm init
REAL=$(git -C "$CODE" rev-parse HEAD)
STALE="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"   # 40 hex, will never resolve

# Build a control plane at $WORK/control with roots.code = $1. The control plane is
# itself a git repo with one commit, so control-plane citations can be exercised.
make_control() {
  local c="$WORK/control"
  rm -rf "$c"
  mkdir -p "$c/.claude" "$c/docs/sessions"
  jq -n --arg code "$1" \
    '{roots:{control:".",code:$code},name:"t",language:"node",commands:{},scaffoldCheck:"true",ceremony:"phased"}' \
    > "$c/.claude/project.json"
  git -C "$c" init -q
  git -C "$c" config user.email t@t
  git -C "$c" config user.name t
  git -C "$c" add -A
  git -C "$c" commit -qm "control init"
  echo "$c"
}
run() { ( cd "$1" && bash "$SCRIPT" ) 2>/dev/null; }

# T1 — single-repo no-op: roots.code="." → silent even with a stale-looking hash.
C=$(make_control ".")
printf '# Session\nCommit %s did the thing.\n' "$STALE" > "$C/docs/sessions/s1.md"
OUT=$(run "$C")
[ -z "$OUT" ] && ok "single-repo (roots.code='.'): no output, no git work" \
  || no "single-repo should be silent, got: $OUT"

# T2 — split: stale hash flagged, real hash not, artifact named.
C=$(make_control "../code")
printf '# Session\nstale %s and ok %s\n' "$STALE" "$REAL" > "$C/docs/sessions/s2.md"
OUT=$(run "$C")
echo "$OUT" | grep -q "$STALE" && ok "split: stale hash flagged" || no "split: stale hash should be flagged (got: $OUT)"
echo "$OUT" | grep -q "$REAL"  && no "split: real hash should NOT be flagged" || ok "split: resolving hash not flagged"
echo "$OUT" | grep -q "s2.md"  && ok "split: names the artifact file" || no "split: should name the artifact file"

# T2b — split: a control-plane (doc/session) commit hash is NOT flagged, even though
# it doesn't resolve in the code repo. This is the cross-repo-citation regression guard.
C=$(make_control "../code")
CTRL=$(git -C "$C" rev-parse HEAD)
printf '# Session\ndoc commit %s in control plane\n' "$CTRL" > "$C/docs/sessions/s2b.md"
OUT=$(run "$C")
echo "$OUT" | grep -q "$CTRL" && no "split: control-plane hash should NOT be flagged" || ok "split: control-plane citation not flagged"

# T3 — split, every citation resolves → silent.
C=$(make_control "../code")
printf '# Session\nonly real %s here\n' "$REAL" > "$C/docs/sessions/s3.md"
OUT=$(run "$C")
[ -z "$OUT" ] && ok "split clean: silent when all citations resolve" || no "split clean should be silent, got: $OUT"

# T4 — no docs/sessions dir → silent no-op.
C=$(make_control "../code")
rm -rf "$C/docs/sessions"
OUT=$(run "$C")
[ -z "$OUT" ] && ok "missing docs/sessions: silent" || no "missing sessions should be silent, got: $OUT"

# T5 — split but code root is not a git repo → silent no-op.
C=$(make_control "../nope")
printf 'stale %s\n' "$STALE" > "$C/docs/sessions/s5.md"
OUT=$(run "$C")
[ -z "$OUT" ] && ok "non-git code root: silent" || no "non-git code root should be silent, got: $OUT"

# T7 — all-decimal tokens are not hash candidates (feedback-entry id suffixes like
# 2026-06-10T23:11:39Z-970732268 were flagged as unresolvable commits — the false-
# positive class behind feedback entry 2026-06-10T23:11:39Z-199208882). The stale
# hex token in the SAME file must still be flagged: a positive control proving the
# scan ran and the exclusion is exactly the all-decimal class, not the whole file.
C=$(make_control "../code")
printf '# Session\nfeedback id 2026-06-10T23:11:39Z-970732268 and stale %s\n' "$STALE" > "$C/docs/sessions/s7.md"
OUT=$(run "$C")
echo "$OUT" | grep -q "970732268" \
  && no "all-decimal feedback-id suffix should NOT be flagged" \
  || ok "all-decimal token not treated as a hash candidate"
echo "$OUT" | grep -q "$STALE" \
  && ok "hex stale token in the same file still flagged (positive control)" \
  || no "positive control failed: the stale hex token should still be flagged"

# T6 — advisory: always exits 0, even with a stale citation present.
C=$(make_control "../code")
printf 'stale %s\n' "$STALE" > "$C/docs/sessions/s6.md"
( cd "$C" && bash "$SCRIPT" >/dev/null 2>&1 )
[ $? -eq 0 ] && ok "exits 0 even with a stale citation" || no "must exit 0 (advisory)"

# T8 — roots.sh resolves under the PLUGIN-CACHE layout, not only the template.
# Under a plugin-cache install check-citations.sh lives at
# <plugin>/skills/status/scripts/ while the helpers (roots.sh included) live flat
# under <plugin>/scripts/. Three levels up from the bundled script is <plugin>/ —
# a fixed "<3up>/roots.sh" misses the /scripts segment, roots.sh isn't found, and
# this advisory SILENTLY exits 0 (never runs, never flags). Build that layout and
# assert it STILL flags a stale citation in a split plane (the check actually ran).
CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUG="$WORK/plugin"
mkdir -p "$PLUG/scripts" "$PLUG/skills/status/scripts"
cp "$CLAUDE_DIR"/*.sh "$PLUG/scripts/" 2>/dev/null     # all top-level helpers incl roots.sh
cp "$SCRIPT" "$PLUG/skills/status/scripts/check-citations.sh"
PSCRIPT="$PLUG/skills/status/scripts/check-citations.sh"
C=$(make_control "../code")
printf '# Session\nstale %s under a plugin layout\n' "$STALE" > "$C/docs/sessions/s8.md"
OUT=$( cd "$C" && bash "$PSCRIPT" 2>/dev/null )
echo "$OUT" | grep -q "$STALE" \
  && ok "plugin-cache layout: roots.sh resolves, advisory still flags the stale hash" \
  || no "plugin-cache layout silently no-ops (roots.sh not found at <plugin>/scripts) — got: [$OUT]"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
