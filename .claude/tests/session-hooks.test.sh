#!/bin/bash
# Tests for the [8.3] §3.3 session/render automation hooks:
#   - .claude/hooks/session-start.sh        (SessionStart: route + frontier injection)
#   - .claude/hooks/render-on-status-edit.sh (PostToolUse: status render on tracker edit)
#
# Both are CONVENIENCE surfaces (never a dependency) and must NEVER block: a
# SessionStart hook that exits 2 blocks the session from starting, and a
# PostToolUse hook fires after the tool already ran. So the load-bearing
# invariant pinned throughout is exit 0 on every rung — phased, non-phased,
# pre-scaffold, MALFORMED, helpers-absent. The hooks resolve their sibling
# shared-lib scripts from $0's dir (plugin mode) or one level up (project mode);
# fixtures symlink the real scripts so that resolution is exercised for real.
#
# stderr is captured on every invocation (this suite runs under the empty-stderr
# gate): a hook that swallows a helper's stderr keeps the gate green.
# Pure bash + jq, no test runner. Run: bash .claude/tests/session-hooks.test.sh
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# This suite asserts project-mode hook wiring, so it is MAINTAINER-ONLY: the
# plugin install has no .claude/settings.json (only the derived hooks.json), so
# the suite cannot run in the reconstructed plugin layout. The literal path below
# is what the build's MAINTAINER_ONLY filter keys on to keep it out of the
# shipped set (same convention as occupancy-meter.test.sh). The hooks themselves
# ship and are exercised in plugin layout by plugin.test.sh's parity + byte
# checks; the route/resolver behavior is exercised by the shipped route suite.
SETTINGS="$CLAUDE_DIR/settings.json"   # i.e. .claude/settings.json (project-mode only)
SS_HOOK="$CLAUDE_DIR/hooks/session-start.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# mkproj <name> [ceremony] — a fixture project whose .claude/ symlinks the real
# router, resolver, and SessionStart hook, so sibling resolution runs for real
# from the fixture cwd. A manifest is written unless ceremony="" (pre-scaffold).
mkproj() {
  local d="$WORK/$1" ceremony="${2:-phased}"
  mkdir -p "$d/.claude/hooks" "$d/docs"
  ln -s "$CLAUDE_DIR/route.sh"         "$d/.claude/route.sh"
  ln -s "$CLAUDE_DIR/resolve-ready.sh" "$d/.claude/resolve-ready.sh"
  ln -s "$SS_HOOK"                     "$d/.claude/hooks/session-start.sh"
  if [ -n "$ceremony" ]; then
    cat > "$d/.claude/project.json" <<JSON
{ "name": "fx", "language": "node", "roots": { "control": ".", "code": "." },
  "commands": { "test": null }, "scaffoldCheck": "test -f .scaffolded",
  "ceremony": "$ceremony" }
JSON
  fi
  printf '%s\n' "$d"
}

# tracker <dir> <kind> — write a tracker of the requested shape.
tracker() {
  local d="$1" kind="$2"
  case "$kind" in
    open) cat > "$d/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Build

- ✅ **[6.1]** Done `[deps: none]`
- ⬜ **[6.2]** Open `[deps: 6.1]`
MD
      ;;
    malformed) cat > "$d/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Build

- ⬜ **[6.2]** Open `[deps: 9.9]`
MD
      ;;
  esac
  [ -f "$d/docs/PHASE_STATUS.md" ] && cp "$d/docs/PHASE_STATUS.md" "$d/docs/REQUIREMENTS.md"
  touch "$d/.scaffolded"
}

# run <dir> — invoke the SessionStart hook from the fixture cwd with a synthetic
# payload on stdin. Sets OUT / ERR / RC.
run() {
  local d="$1" errf; errf=$(mktemp)
  OUT=$( cd "$d" && printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' \
         | bash .claude/hooks/session-start.sh 2>"$errf" ); RC=$?
  ERR=$(cat "$errf"); rm -f "$errf"
}

# ── 0. ships and is executable ───────────────────────────────────────────────
[ -f "$SS_HOOK" ] && ok "session-start.sh ships in .claude/hooks/" \
  || no "session-start.sh missing"

# ── 1. phased project: injects the door + frontier as the SessionStart envelope ─
P=$(mkproj phased-open); tracker "$P" open
run "$P"
[ "$RC" -eq 0 ] && ok "phased: exit 0" || no "phased should exit 0 (rc=$RC; err=$ERR)"
[ -z "$ERR" ] && ok "phased: stderr clean (helper stderr swallowed)" \
  || no "phased: stderr must be clean, got: $ERR"
echo "$OUT" | jq -e . >/dev/null 2>&1 \
  && ok "phased: output is a single valid JSON document" \
  || no "phased: output must be valid JSON, got: $OUT"
[ "$(echo "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" = "SessionStart" ] \
  && ok "phased: envelope carries hookEventName=SessionStart (the camelCase output key)" \
  || no "phased: hookSpecificOutput.hookEventName must be SessionStart"
CTX=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
echo "$CTX" | grep -q 'door=next' \
  && ok "phased: additionalContext surfaces the routed door (door=next)" \
  || no "phased: additionalContext must surface door=, got: $CTX"
echo "$CTX" | grep -q 'serial=6.2' \
  && ok "phased: additionalContext surfaces the resolver frontier (serial=6.2)" \
  || no "phased: additionalContext must surface the frontier, got: $CTX"

# ── 2. MUST NOT BLOCK: a MALFORMED tracker still exits 0 (never exit 2) ───────
M=$(mkproj phased-malformed); tracker "$M" malformed
run "$M"
[ "$RC" -eq 0 ] \
  && ok "MALFORMED tracker: exit 0 — a SessionStart hook must never block the session" \
  || no "MALFORMED tracker must still exit 0 (got rc=$RC), or it blocks session start"
[ -z "$ERR" ] && ok "MALFORMED: stderr clean (resolver's exit-5 message swallowed)" \
  || no "MALFORMED: stderr must be clean, got: $ERR"
# The frontier is unavailable (resolver refused), so it is NOT surfaced; the
# router's reason may still appear, but nothing fabricated.
CTXM=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
echo "$CTXM" | grep -q 'serial=' \
  && no "MALFORMED: a refused frontier must not be surfaced (found serial=)" \
  || ok "MALFORMED: no fabricated frontier surfaced (stale/broken state not presented)"

# ── 3. task ceremony: surfaces the door, no frontier (no tracker to resolve) ──
T=$(mkproj task-proj task)
run "$T"
[ "$RC" -eq 0 ] && ok "task ceremony: exit 0" || no "task ceremony should exit 0 (rc=$RC)"
CTXT=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
echo "$CTXT" | grep -q 'door=task' \
  && ok "task ceremony: additionalContext surfaces door=task" \
  || no "task ceremony: should surface door=task, got: $CTXT"

# ── 4. greenfield (no manifest): the router still resolves it (init-project) ──
# A no-manifest dir is greenfield, not an error: route.sh routes it to
# init-project, and surfacing that at session-open is useful (it tells a fresh
# repo to scaffold). The hook must surface it, exit 0, never block.
GF=$(mkproj greenfield "")   # helpers symlinked, but no manifest written
run "$GF"
[ "$RC" -eq 0 ] && ok "greenfield: exit 0" || no "greenfield must exit 0 (got rc=$RC)"
CTXG=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
echo "$CTXG" | grep -q 'door=init-project' \
  && ok "greenfield (no manifest): surfaces door=init-project (scaffold-here routing)" \
  || no "greenfield: should surface door=init-project, got: $CTXG"

# ── 5. helpers absent: the genuine nothing-to-surface rung — clean exit 0 ─────
# When the sibling scripts can't be resolved (a stripped or broken install),
# there is nothing to gather; the hook injects nothing and still exits 0.
BARE="$WORK/bare"; mkdir -p "$BARE/.claude/hooks"
ln -s "$SS_HOOK" "$BARE/.claude/hooks/session-start.sh"   # hook only, no route/resolver
run "$BARE"
[ "$RC" -eq 0 ] && ok "helpers absent: exit 0 (no crash, no block)" \
  || no "helpers absent must exit 0 (got rc=$RC)"
[ -z "$OUT" ] \
  && ok "helpers absent: injects nothing (no fabricated context)" \
  || no "helpers absent should inject nothing, got: $OUT"

# ── 6. settings.json wires the hook on the SessionStart event ────────────────
SS_WIRED=$(jq -r '.hooks.SessionStart[]? | select(any(.hooks[]?.command; test("session-start\\.sh")))' "$SETTINGS" 2>/dev/null)
[ -n "$SS_WIRED" ] \
  && ok "settings.json wires session-start.sh on the SessionStart event (project mode)" \
  || no "settings.json SessionStart must wire session-start.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
