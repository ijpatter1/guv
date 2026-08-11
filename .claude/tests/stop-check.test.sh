#!/bin/bash
# Tests for .claude/hooks/stop-check.sh — the advisory Stop hook.
# Phase 5 added the manifest gate: guv ceremony is opt-in, and the manifest
# is the opt-in signal. Under plugin install the hook rides hooks.json into
# EVERY repo where the plugin is enabled, so without the gate it would nag
# repos that aren't guv projects and pre-scaffold directories about /eval and /handoff.
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

# T6 — RETIRED at [32.5], not merely moved: this was a continuous source-vs-
# artifact byte comparison, the exact guard the mirror collapse retires. Its
# property — every hook and helper ships byte-identical — is asserted once, in
# plugin.test.sh's T9, against a tree that suite BUILDS (glob-derived over
# .claude/*.sh and .claude/hooks/*.sh, so this hook is covered by existing
# rather than by being named).
#
# Retargeting it here instead would have cost consumer coverage: naming the
# plugin builder's path (it lives under the maintainer-only directory) puts a
# suite on the build's MAINTAINER_ONLY list, and this suite then silently stops
# shipping to plugin installs — the 2026-07-27 trap, where 24 shipped suites
# quietly became 23. This comment avoids that path for the same reason. The
# sync's "removed upstream: tests/stop-check.test.sh" line is what caught it.

# T7 — RETIRED with T6: it self-checked that guard's fork skip, and a probe of a
# branch that no longer exists is a guard that can only pass. plugin.test.sh's own
# fork self-check covers the suite that now owns the property.


echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
