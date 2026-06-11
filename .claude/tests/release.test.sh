#!/bin/bash
# Tests for the guv release surfaces — Phase 5 D3 (versioning + feedback drain).
# Guards the personal-marketplace manifest, version/CHANGELOG coherence, and the
# documented release flow:
#   - .claude-plugin/marketplace.json at the REPO root (the marketplace is the
#     repo; the plugin manifest lives at plugin/.claude-plugin/): valid JSON,
#     name/owner/plugins, the guv entry with relative source ./plugin
#   - CHANGELOG.md: topmost release version equals the plugin manifest version
#     (a version bump IS a release — they cannot drift); the first release's
#     notes carry the Phase 2 and Phase 3 migration notes
#   - maintainers/RELEASING.md: the semver bump policy, the two go-public
#     criteria, the feedback-drain graduation step, and the worked example
# Live marketplace behavior (claude plugin marketplace add / install) needs a
# real session: covered by dogfood runs and the Phase 5 UAT, not here.
# Pure bash + jq, no test runner required.
# Run: bash .claude/tests/release.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SELF="$ROOT/.claude/tests/$(basename "$0")"   # absolute — $0-relative re-invocation breaks if a cd ever lands in the main shell
MP="$ROOT/.claude-plugin/marketplace.json"
PJ="$ROOT/plugin/.claude-plugin/plugin.json"
CL="$ROOT/CHANGELOG.md"
REL="$ROOT/maintainers/RELEASING.md"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# Maintainer release machinery — a consumer fork that deleted maintainers/ or
# the generated plugin/ + .claude-plugin/ (both deletions the README documents)
# has no release flow to guard; skip cleanly, never as a failure. Same pattern
# as plugin.test.sh. The env seams exist so the fork-skip self-check (T10) can
# exercise this path from the canonical repo.
BUILD="${RELEASE_BUILD_SCRIPT:-$ROOT/maintainers/build-plugin.sh}"
PLUGIN_TREE="${RELEASE_PLUGIN_TREE:-$ROOT/plugin}"
if [ ! -f "$BUILD" ] || [ ! -d "$PLUGIN_TREE" ]; then
  echo "  - maintainers/ or plugin/ absent (consumer fork) — release-surface guards skip"
  echo ""
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

# changelog_version <file> -> version of the topmost release heading (## 0.1.0 …).
# Factored so T6's positive control can prove the extractor extracts (a detector
# that silently matches nothing would make the coherence check vacuous).
changelog_version() {
  grep -m1 -oE '^## v?[0-9]+\.[0-9]+\.[0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

# T1 — marketplace manifest exists at the repo root and is valid JSON
if [ -f "$MP" ] && jq -e . "$MP" >/dev/null 2>&1; then
  ok "marketplace.json exists at the repo root and is valid JSON"
else
  no "marketplace manifest missing or invalid: $MP"
fi

# T2 — marketplace identity: name, owner, a non-empty plugins array
jq -e '.name and .owner.name and (.plugins | type == "array" and length >= 1)' "$MP" >/dev/null 2>&1 \
  && ok "marketplace carries name, owner.name, and a non-empty plugins array" \
  || no "marketplace identity fields missing (name / owner.name / plugins[])"

# T3 — the guv entry's name matches the plugin manifest (one plugin, no drift)
MP_NAME=$(jq -r '.plugins[0].name // empty' "$MP" 2>/dev/null)
PJ_NAME=$(jq -r '.name // empty' "$PJ" 2>/dev/null)
[ -n "$MP_NAME" ] && [ "$MP_NAME" = "$PJ_NAME" ] \
  && ok "marketplace plugin name matches the plugin manifest ($MP_NAME)" \
  || no "marketplace plugin name ($MP_NAME) != plugin manifest name ($PJ_NAME)"

# T4 — relative source ./plugin, and the directory it names exists
SRC_PATH=$(jq -r '.plugins[0].source // empty' "$MP" 2>/dev/null)
[ "$SRC_PATH" = "./plugin" ] && [ -d "$ROOT/plugin" ] \
  && ok "plugin source is the relative ./plugin and the directory exists" \
  || no "plugin source should be ./plugin within this repo (got: ${SRC_PATH:-none})"

# T5 — the listing description carries the category tagline
jq -r '.plugins[0].description // empty' "$MP" 2>/dev/null | grep -q "control plane for Claude Code" \
  && ok "listing description carries the category term" \
  || no "listing description should carry 'control plane for Claude Code'"

# T6 — CHANGELOG's topmost release version equals the plugin manifest version
CL_VER=$(changelog_version "$CL")
PJ_VER=$(jq -r '.version // empty' "$PJ" 2>/dev/null)
if [ -n "$CL_VER" ] && [ "$CL_VER" = "$PJ_VER" ]; then
  ok "CHANGELOG top release ($CL_VER) matches plugin version ($PJ_VER)"
else
  no "CHANGELOG top release (${CL_VER:-none}) must match plugin version (${PJ_VER:-none})"
fi

# T6b — positive control: the extractor extracts, and the comparison can fail.
# A planted fixture proves changelog_version isn't silently returning nothing.
FIX=$(mktemp)
printf '# Changelog\n\n## 9.9.9 — never\n\n- planted\n' > "$FIX"
[ "$(changelog_version "$FIX")" = "9.9.9" ] \
  && ok "positive control: extractor reads a planted version" \
  || no "positive control failed: extractor did not read the planted 9.9.9"
[ "$(changelog_version "$FIX")" != "$PJ_VER" ] \
  && ok "positive control: a mismatched version is distinguishable" \
  || no "positive control failed: planted 9.9.9 should not equal the plugin version"
rm -f "$FIX"

# T7 — the first release's notes carry both migration notes
grep -q '@\.claude/RULES\.md' "$CL" 2>/dev/null \
  && ok "CHANGELOG carries the Phase 2 migration note (dead RULES.md import)" \
  || no "CHANGELOG must carry the Phase 2 note: delete the dead @.claude/RULES.md import"
grep -q 'isolation tier' "$CL" 2>/dev/null \
  && ok "CHANGELOG carries the Phase 3 migration note (tier-neutral Enforcement)" \
  || no "CHANGELOG must carry the Phase 3 note: tier-neutral Enforcement rewrite"

# T8 — RELEASING.md records the bump policy and the two go-public criteria
if [ -f "$REL" ]; then
  ok "RELEASING.md exists"
else
  no "maintainers/RELEASING.md missing"
fi
for word in patch minor major; do
  grep -qi "\b$word\b" "$REL" 2>/dev/null \
    && ok "bump policy mentions $word" \
    || no "bump policy must define when $word bumps"
done
grep -q 'survived a Claude Code minor version' "$REL" 2>/dev/null \
  && ok "go-public criterion (a): format survival recorded" \
  || no "go-public criterion (a) missing: plugin format survived a CC minor version"
grep -q 'external project' "$REL" 2>/dev/null \
  && ok "go-public criterion (b): external install recorded" \
  || no "go-public criterion (b) missing: at least one external project installed it"

# T9 — RELEASING.md documents the drain's release half and the worked example
grep -q 'on the release that ships the fix' "$REL" 2>/dev/null \
  && ok "graduation step: entries flip on the release that ships the fix" \
  || no "RELEASING.md must document the graduation step of the feedback drain"
WID=$(awk '/^## Worked example/,0' "$REL" 2>/dev/null | grep -m1 -oE '[0-9TZ:-]+Z-[0-9]+')
if [ -n "$WID" ]; then
  ok "worked example cites an entry id ($WID)"
  # The same id must appear in the release notes — an id fabricated in one doc
  # won't accidentally be fabricated identically in the other (the entry itself
  # lives in the consumer control plane, outside this repo's reach).
  grep -q "$WID" "$CL" 2>/dev/null \
    && ok "worked-example id appears in the CHANGELOG too (cross-doc coherence)" \
    || no "the drained entry id ($WID) should appear in the release notes"
else
  no "RELEASING.md must carry the worked example with a real entry id"
fi

# T10 — fork-skip self-check: with an indicator absent the suite exits 0 AND
# the output shows the skip fired (exit 0 alone would also pass if the skip
# block were deleted — the suite passes whole in the canonical repo — making
# this self-check vacuous)
if [ -z "${RELEASE_TEST_INNER:-}" ]; then
  INNER=$(RELEASE_TEST_INNER=1 RELEASE_BUILD_SCRIPT="$ROOT/nonexistent-build.sh" bash "$SELF" 2>&1)
  if [ $? -eq 0 ] && echo "$INNER" | grep -q "guards skip"; then
    ok "suite visibly skips in a consumer fork (build script absent)"
  else
    no "suite must exit 0 and visibly skip when maintainers/build-plugin.sh is absent"
  fi
  INNER=$(RELEASE_TEST_INNER=1 RELEASE_PLUGIN_TREE="$ROOT/nonexistent-plugin" bash "$SELF" 2>&1)
  if [ $? -eq 0 ] && echo "$INNER" | grep -q "guards skip"; then
    ok "suite visibly skips in a fork that deleted plugin/"
  else
    no "suite must exit 0 and visibly skip when plugin/ is absent"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
