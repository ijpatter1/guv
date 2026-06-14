#!/bin/bash
# Tests for .claude/hooks/stop-check.sh — the advisory Stop hook.
# Phase 5 added the manifest gate: harness ceremony is opt-in, and the manifest
# is the opt-in signal. Under plugin install the hook rides hooks.json into
# EVERY repo where the plugin is enabled, so without the gate it would nag
# non-harness repos and pre-scaffold directories about /eval and /handoff.
# Also guards: the loop-prevention exit on stop_hook_active, the
# uncommitted-changes reminder, and the dual-form command names in the
# reminder text (bare for template installs, /guv:-prefixed for plugin ones).
# Pure bash + jq, no test runner required.
# Run: bash .claude/tests/stop-check.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SELF="$ROOT/.claude/tests/$(basename "$0")"   # absolute — $0-relative re-invocation breaks if a cd ever lands in the main shell
HOOK="$ROOT/.claude/hooks/stop-check.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

run_hook() { (cd "$1" && printf '%s' "$2" | bash "$HOOK") }
ACTIVE='{"stop_hook_active":true}'
INACTIVE='{"stop_hook_active":false}'

# T1 — loop prevention: stop_hook_active=true exits 0 silently, manifest or not
mkdir -p "$WORK/loop/.claude"
: > "$WORK/loop/.claude/project.json"
OUT=$(run_hook "$WORK/loop" "$ACTIVE"); RC=$?
[ $RC -eq 0 ] && [ -z "$OUT" ] \
  && ok "stop_hook_active=true -> silent exit 0 (loop prevention)" \
  || no "stop_hook_active=true must exit 0 with no output"

# T2 — manifest gate: no .claude/project.json -> stand aside silently, even
# with uncommitted changes and no handoff (the plugin enables this hook in
# every repo; ceremony reminders only belong where the manifest opted in)
mkdir -p "$WORK/nogate"
git -C "$WORK/nogate" init -q
: > "$WORK/nogate/untracked.txt"
OUT=$(run_hook "$WORK/nogate" "$INACTIVE"); RC=$?
[ $RC -eq 0 ] && [ -z "$OUT" ] \
  && ok "no manifest -> silent exit 0 (ceremony is opt-in via the manifest)" \
  || no "without .claude/project.json the hook must stand aside"

# T3 — with a manifest and uncommitted changes, the reminder fires and counts
# the files
mkdir -p "$WORK/dirty/.claude"
git -C "$WORK/dirty" init -q
: > "$WORK/dirty/.claude/project.json"
: > "$WORK/dirty/untracked.txt"
OUT=$(run_hook "$WORK/dirty" "$INACTIVE")
echo "$OUT" | jq -e '.systemMessage' >/dev/null 2>&1 \
  && echo "$OUT" | jq -r '.systemMessage' | grep -q "uncommitted" \
  && ok "manifest + uncommitted changes -> advisory reminder fires" \
  || no "reminder must fire for uncommitted changes when the manifest exists"

# T4 — the reminder names both invocation forms (bare for template installs,
# /guv: for plugin installs), and stays advisory (decision approve)
echo "$OUT" | jq -r '.systemMessage' | grep -q '/guv:eval' \
  && echo "$OUT" | jq -r '.systemMessage' | grep -q '/guv:handoff' \
  && ok "reminder names the /guv:-namespaced forms alongside the bare ones" \
  || no "reminder must carry both bare and /guv:-namespaced command forms"
[ "$(echo "$OUT" | jq -r '.decision')" = "approve" ] \
  && ok "reminder is advisory (decision: approve)" \
  || no "the hook must stay advisory"

# T5 — clean repo with a manifest and a today-handoff: no reminder at all
mkdir -p "$WORK/clean/.claude" "$WORK/clean/docs/sessions"
git -C "$WORK/clean" init -q
: > "$WORK/clean/.claude/project.json"
: > "$WORK/clean/docs/sessions/session-$(date +%Y-%m-%d)-001.md"
(cd "$WORK/clean" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
OUT=$(run_hook "$WORK/clean" "$INACTIVE"); RC=$?
[ $RC -eq 0 ] && [ -z "$OUT" ] \
  && ok "clean repo + today's handoff -> no reminder" \
  || no "nothing outstanding must mean no output"

# T6 — the plugin ships this hook byte-identical (the gate must reach plugin
# consumers, where it matters most). A template-clone fork that deleted the
# generated plugin/ (README's note) has no copy to compare — skip, not fail.
# STOPCHECK_PLUGIN_TREE is the T7 seam.
if [ -d "${STOPCHECK_PLUGIN_TREE:-$ROOT/plugin}" ]; then
  cmp -s "$HOOK" "$ROOT/plugin/scripts/stop-check.sh" \
    && ok "plugin copy of stop-check.sh byte-identical" \
    || no "plugin/scripts/stop-check.sh differs from the source hook"
else
  echo "  - plugin/ absent (template-clone fork) — byte-identity guard skips"
fi

# T7 — fork self-check: the byte-identity skip fires and shows itself
# (output-grepped — exit 0 alone would pass in the canonical repo even with
# the skip branch deleted)
if [ -z "${STOPCHECK_TEST_INNER:-}" ]; then
  INNER=$(STOPCHECK_TEST_INNER=1 STOPCHECK_PLUGIN_TREE="$ROOT/nonexistent-plugin" bash "$SELF" 2>&1)
  if [ $? -eq 0 ] && echo "$INNER" | grep -q "byte-identity guard skips"; then
    ok "byte-identity guard visibly skips in a fork that deleted plugin/"
  else
    no "suite must exit 0 and visibly skip the byte-identity guard when plugin/ is absent"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
