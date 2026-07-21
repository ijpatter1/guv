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
  ln -s "$CLAUDE_DIR/route.sh"              "$d/.claude/route.sh"
  ln -s "$CLAUDE_DIR/resolve-ready.sh"      "$d/.claude/resolve-ready.sh"
  ln -s "$CLAUDE_DIR/context-management.sh" "$d/.claude/context-management.sh"
  ln -s "$SS_HOOK"                          "$d/.claude/hooks/session-start.sh"
  if [ -n "$ceremony" ]; then
    # A CONFIGURED context-wall posture by default, so the [16.2] surface stays
    # silent for the door/frontier/feedback fixtures — the unset and grandfather
    # paths get their own fixtures (1g/1h) that set the state explicitly.
    cat > "$d/.claude/project.json" <<JSON
{ "name": "fx", "language": "node", "roots": { "control": ".", "code": "." },
  "commands": { "test": null }, "scaffoldCheck": "test -f .scaffolded",
  "ceremony": "$ceremony", "contextManagement": { "mode": "hard-stop" } }
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

# ── 1b. friction log loaded as session-open working context ([20.7]) ──────────
# When the project carries OPEN guv-feedback entries, the hook surfaces the open
# count together with the capture posture (local-only / never phones home), so a
# session opens already aware of pending friction. The log is consumer-owned data
# in the project's .claude/feedback/; CLAUDE_PROJECT_DIR is unset here, exercising
# the cwd (`.`) fallback. 2 of the 3 entries are open (one graduated).
FB=$(mkproj fb-open); tracker "$FB" open
mkdir -p "$FB/.claude/feedback"
printf '%s\n' \
  '{"id":"t-1","ts":"2026-06-24T00:00:00Z","status":"open","severity":"minor","routing":"upstream","summary":"a","category":"friction"}' \
  '{"id":"t-2","ts":"2026-06-24T00:00:01Z","status":"graduated","severity":"minor","routing":"upstream","summary":"b","category":"friction"}' \
  '{"id":"t-3","ts":"2026-06-24T00:00:02Z","status":"open","severity":"major","routing":"local","summary":"c","category":"friction"}' \
  > "$FB/.claude/feedback/feedback.ndjson"
run "$FB"
[ "$RC" -eq 0 ] && ok "feedback: exit 0 with open entries" || no "feedback fixture should exit 0 (rc=$RC; err=$ERR)"
[ -z "$ERR" ] && ok "feedback: stderr clean" || no "feedback: stderr must be clean, got: $ERR"
CTXF=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
echo "$CTXF" | grep -q '2 open' \
  && ok "feedback: surfaces the OPEN count only (2 of 3 — graduated excluded)" \
  || no "feedback: must surface the open count (2), got: $CTXF"
{ echo "$CTXF" | grep -q 'local-only' && echo "$CTXF" | grep -q 'never phones home'; } \
  && ok "feedback: surfaces the local-only / never-phones-home posture as working context" \
  || no "feedback: must surface the local-only posture, got: $CTXF"

# ── 1c. OPTIONAL load stays quiet: no feedback log → no feedback line ─────────
# The load is optional — with no log (or none open) there is nothing to surface,
# so the hook stays silent on feedback while still surfacing door/frontier. No noise.
FBN=$(mkproj fb-none); tracker "$FBN" open   # tracker present, but no feedback log
run "$FBN"
CTXN=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
echo "$CTXN" | grep -qi 'guv-feedback' \
  && no "feedback: must NOT surface a feedback line when there is no log, got: $CTXN" \
  || ok "feedback: optional load stays quiet with no log (frontier still surfaced)"
echo "$CTXN" | grep -q 'serial=6.2' \
  && ok "feedback: the frontier still surfaces when the feedback load is quiet" \
  || no "feedback: frontier must still surface, got: $CTXN"

# ── 1d. MALFORMED feedback log degrades silently (rule 15) ────────────────────
# The designed degradation rung for the optional load: a truncated/invalid ndjson
# must NOT fabricate a count, emit stderr, or block. The jq count fails → empty →
# no feedback line; exit 0, stderr clean (jq's parse error is swallowed), and the
# door/frontier still surface. A loud stop here would block session start (exit 2);
# silence is the chosen path, not an improvised recovery.
FBM=$(mkproj fb-malformed); tracker "$FBM" open
mkdir -p "$FBM/.claude/feedback"
printf '%s\n' \
  '{"id":"t-1","ts":"2026-06-24T00:00:00Z","status":"open","severity":"minor"' \
  'not json at all' \
  > "$FBM/.claude/feedback/feedback.ndjson"
run "$FBM"
[ "$RC" -eq 0 ] && ok "malformed feedback log: exit 0 (the optional load never blocks the session)" \
  || no "malformed feedback log must exit 0 (rc=$RC; err=$ERR)"
[ -z "$ERR" ] && ok "malformed feedback log: stderr clean (jq parse error swallowed)" \
  || no "malformed feedback log: stderr must be clean, got: $ERR"
CTXMF=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
echo "$CTXMF" | grep -qi 'guv-feedback' \
  && no "malformed feedback log: must NOT fabricate a feedback line, got: $CTXMF" \
  || ok "malformed feedback log: degrades silently — no feedback line surfaced"
echo "$CTXMF" | grep -q 'serial=6.2' \
  && ok "malformed feedback log: the frontier still surfaces (the degradation is local to the load)" \
  || no "malformed feedback log: frontier must still surface, got: $CTXMF"

# ── 1e. CLAUDE_PROJECT_DIR anchors the log when cwd is OFF the project root ────
# The PRIMARY [19.4] anchor path: the consumer-owned log is read from
# CLAUDE_PROJECT_DIR, never the session cwd. 1b pinned the cwd FALLBACK (var unset →
# `.`); here the var points at the project while the session runs from an UNRELATED
# off-root cwd that carries its OWN decoy log with a DIFFERENT count. Surfacing the
# project's "2 open" (not the decoy's 1) proves the anchor wins over cwd — the exact
# off-root failure [19.4] fixed (a $BASE/cwd-anchored read would find the wrong log).
FBA=$(mkproj fb-anchored); tracker "$FBA" open
mkdir -p "$FBA/.claude/feedback"
printf '%s\n' \
  '{"id":"a-1","ts":"2026-06-24T00:00:00Z","status":"open","severity":"minor","routing":"upstream","summary":"x","category":"friction"}' \
  '{"id":"a-2","ts":"2026-06-24T00:00:01Z","status":"open","severity":"minor","routing":"upstream","summary":"y","category":"friction"}' \
  > "$FBA/.claude/feedback/feedback.ndjson"
OFFROOT="$WORK/offroot-cwd"; mkdir -p "$OFFROOT/.claude/feedback"
# DECOY at the cwd: a 1-open log. A read that wrongly used cwd (the [19.4] bug)
# would surface "1 open" from here instead of the project's "2 open".
printf '%s\n' \
  '{"id":"decoy","ts":"2026-06-24T00:00:09Z","status":"open","severity":"minor","routing":"local","summary":"decoy","category":"friction"}' \
  > "$OFFROOT/.claude/feedback/feedback.ndjson"
errf=$(mktemp)
OUTA=$( cd "$OFFROOT" && printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' \
        | CLAUDE_PROJECT_DIR="$FBA" bash "$FBA/.claude/hooks/session-start.sh" 2>"$errf" ); RCA=$?
ERRA=$(cat "$errf"); rm -f "$errf"
[ "$RCA" -eq 0 ] && ok "anchored: exit 0 from an off-root cwd" \
  || no "anchored fixture must exit 0 (rc=$RCA; err=$ERRA)"
[ -z "$ERRA" ] && ok "anchored: stderr clean" || no "anchored: stderr must be clean, got: $ERRA"
CTXA=$(echo "$OUTA" | jq -r '.hookSpecificOutput.additionalContext // ""')
echo "$CTXA" | grep -q '2 open' \
  && ok "anchored: log read via CLAUDE_PROJECT_DIR, not cwd (project's 2 open beats the cwd decoy's 1)" \
  || no "anchored: must read the log via CLAUDE_PROJECT_DIR (the off-root anchor), got: $CTXA"
echo "$CTXA" | grep -q 'local-only' \
  && ok "anchored: the posture surfaces on the primary anchor path too" \
  || no "anchored: posture must surface, got: $CTXA"

# ── 1f. singular pluralization: exactly ONE open entry reads "entry", not "entries" ─
# The count copy has a singular branch (FB_W="entry" at FB_OPEN -eq 1) — and one open
# entry is the COMMON case, not an edge. Pin it so the user-facing pluralization can't
# rot: a lone open entry must render "1 open local friction entry" (singular noun).
FB1=$(mkproj fb-one); tracker "$FB1" open
mkdir -p "$FB1/.claude/feedback"
printf '%s\n' \
  '{"id":"s-1","ts":"2026-06-24T00:00:00Z","status":"open","severity":"minor","routing":"upstream","summary":"solo","category":"friction"}' \
  > "$FB1/.claude/feedback/feedback.ndjson"
run "$FB1"
CTX1=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
echo "$CTX1" | grep -q '1 open local friction entry' \
  && ok "feedback: a single open entry uses the SINGULAR copy ('1 open local friction entry')" \
  || no "feedback: one open entry must read '… 1 open local friction entry …' (singular), got: $CTX1"

# ── 1g. headless loud-unset marker surfaced at session-open ([16.2]) ──────────
# A fresh HEADLESS scaffold writes contextManagement.mode=unset (no human to make
# the forced choice) and must SURFACE a loud 'context-wall mode UNSET' marker —
# watch-item a: 'loud' means a person sees it, so it has to reach additionalContext,
# not merely sit in the manifest. Put the fixture in the unset state, assert the
# marker surfaces, exit 0, stderr clean (the surface is read-mostly, never blocks).
UNSETP=$(mkproj cw-unset); tracker "$UNSETP" open
tmp=$(mktemp); jq '.contextManagement.mode = "unset"' "$UNSETP/.claude/project.json" > "$tmp" && mv "$tmp" "$UNSETP/.claude/project.json"
run "$UNSETP"
[ "$RC" -eq 0 ] && ok "context-wall unset: exit 0 (the surface never blocks the session)" \
  || no "context-wall unset must exit 0 (rc=$RC; err=$ERR)"
[ -z "$ERR" ] && ok "context-wall unset: stderr clean" || no "context-wall unset: stderr must be clean, got: $ERR"
CTXU=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
echo "$CTXU" | grep -q 'context-wall mode UNSET' \
  && ok "context-wall unset: the loud UNSET marker reaches session-open context (watch-item a)" \
  || no "context-wall unset: the UNSET marker must surface in additionalContext, got: $CTXU"
echo "$CTXU" | grep -q 'serial=' \
  && ok "context-wall unset: composes with the frontier (both surface, neither crowds out the other)" \
  || no "context-wall unset: the frontier must still surface alongside the marker, got: $CTXU"

# ── 1h. grandfather migration nudge: surfaced ONCE at session-open ([16.2]) ────
# A block-LESS in-field project (predates the feature) is grandfathered to today's
# behavior and nudged ONCE — non-blocking, not every session (watch-item b). Build
# the block-less state (delete the default block), then run TWICE: the first run
# surfaces the nudge and records the did-fire marker; the second is silent on it.
# It must surface the NUDGE, not the UNSET marker — the discriminator (watch-item
# c) must hold at the hook too, not just in the helper unit test.
GRANDP=$(mkproj cw-grandfather); tracker "$GRANDP" open
tmp=$(mktemp); jq 'del(.contextManagement)' "$GRANDP/.claude/project.json" > "$tmp" && mv "$tmp" "$GRANDP/.claude/project.json"
run "$GRANDP"
CTXG1=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
echo "$CTXG1" | grep -q 'context-wall mode is now available' \
  && ok "context-wall grandfather: the migration nudge surfaces on the first session-open" \
  || no "context-wall grandfather: first run must surface the nudge, got: $CTXG1"
echo "$CTXG1" | grep -q 'UNSET' \
  && no "context-wall grandfather: a block-less project must NOT surface the UNSET marker (discriminator collapsed at the hook)" \
  || ok "context-wall grandfather: surfaces the nudge, NOT the UNSET marker (discriminator holds at the hook)"
run "$GRANDP"   # second session-open — the once-ness carrier must now silence it
CTXG2=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
echo "$CTXG2" | grep -q 'context-wall mode is now available' \
  && no "context-wall grandfather: the nudge fired again on the second run (once-ness broken)" \
  || ok "context-wall grandfather: the nudge fires ONCE — silent on the second session-open (watch-item b)"
echo "$CTXG2" | grep -q 'serial=' \
  && ok "context-wall grandfather: the frontier still surfaces on the second run (only the nudge is once)" \
  || no "context-wall grandfather: frontier must still surface on run 2, got: $CTXG2"
[ "$RC" -eq 0 ] && ok "context-wall grandfather: exit 0 on both runs" || no "context-wall grandfather must exit 0 (rc=$RC)"

# ── 1i. session-start RECONCILES the governors to the chosen mode ([16.4]) ─────
# The surface SHOWS the posture; reconcile ACTS on it. In hard-stop mode the meter
# owns the wall, so a STALE auto-compaction window left from a prior continue choice
# must be WITHDRAWN on session open or it would pre-empt the meter (two governors
# both armed — the very thing "exactly one authoritative threshold" forbids). This
# proves the hook actually drives the [16.3] carrier end-to-end — not merely that
# reconcile works in isolation (context-management's R-suite covers that). The
# carrier + setpoint siblings must be reachable from the fixture for reconcile to
# act, so symlink them in (the default fixtures omit them, which is why reconcile is
# a clean no-op there — itself the never-blocks guarantee).
RW=$(mkproj cw-reconcile-wire)          # default fixture carries mode=hard-stop
ln -s "$CLAUDE_DIR/auto-compact-carrier.sh" "$RW/.claude/auto-compact-carrier.sh"
ln -s "$CLAUDE_DIR/compaction-setpoint.sh"  "$RW/.claude/compaction-setpoint.sh"
# Seed a STALE window in settings.local.json, exactly as a prior continue choice left it.
printf '{"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"250000"},"permissions":{"allow":["Bash"]}}\n' \
  > "$RW/.claude/settings.local.json"
run "$RW"
WIN_AFTER=$(jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW // empty' "$RW/.claude/settings.local.json" 2>/dev/null)
PERM_AFTER=$(jq -r '.permissions.allow[0] // empty' "$RW/.claude/settings.local.json" 2>/dev/null)
[ "$RC" -eq 0 ] && [ -z "$WIN_AFTER" ] \
  && ok "session-start reconciles: hard-stop mode WITHDRAWS a stale auto-compaction window on session open (the meter owns the wall)" \
  || no "session-start must drive the carrier to withdraw the stale window in hard-stop mode (rc=$RC win_after=$WIN_AFTER)"
[ "$PERM_AFTER" = "Bash" ] \
  && ok "session-start reconcile: withdraws ONLY the window — other settings (permissions) survive" \
  || no "reconcile must strip only the window key, not other settings (perm_after=$PERM_AFTER)"

# 1i-b — reconcile NEVER blocks the session: even when the carrier sibling is ABSENT
# (the default fixtures, a partial install), session-start exits 0 with the frontier
# still surfaced. The reconcile wiring is a convenience, never a dependency (rule 15).
NOC=$(mkproj cw-reconcile-nocarrier); tracker "$NOC" open   # no carrier symlinked
printf '{"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"250000"}}\n' > "$NOC/.claude/settings.local.json"
run "$NOC"
WIN_NOC=$(jq -r '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW // empty' "$NOC/.claude/settings.local.json" 2>/dev/null)
CTXNOC=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
{ [ "$RC" -eq 0 ] && [ -z "$ERR" ]; } \
  && ok "session-start reconcile: absent carrier → clean exit 0, stderr clean (never blocks)" \
  || no "absent carrier must degrade to a clean exit 0 (rc=$RC err=$ERR)"
{ [ "$WIN_NOC" = "250000" ] && echo "$CTXNOC" | grep -q 'serial='; } \
  && ok "session-start reconcile: absent carrier touches nothing (window untouched) and the frontier still surfaces" \
  || no "absent carrier must no-op without touching settings or suppressing the frontier (win=$WIN_NOC)"

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

# ── 4. greenfield (no manifest): the router still resolves it (init) ──
# A no-manifest dir is greenfield, not an error: route.sh routes it to
# init, and surfacing that at session-open is useful (it tells a fresh
# repo to scaffold). The hook must surface it, exit 0, never block.
GF=$(mkproj greenfield "")   # helpers symlinked, but no manifest written
run "$GF"
[ "$RC" -eq 0 ] && ok "greenfield: exit 0" || no "greenfield must exit 0 (got rc=$RC)"
CTXG=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
echo "$CTXG" | grep -q 'door=init' \
  && ok "greenfield (no manifest): surfaces door=init (scaffold-here routing)" \
  || no "greenfield: should surface door=init, got: $CTXG"

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

# ════════════════════════════════════════════════════════════════════════════
# render-on-status-edit.sh — PostToolUse render hook (status.html + README block)
# ════════════════════════════════════════════════════════════════════════════
RENDER_HOOK="$CLAUDE_DIR/hooks/render-on-status-edit.sh"
[ -f "$RENDER_HOOK" ] && ok "render-on-status-edit.sh ships in .claude/hooks/" \
  || no "render-on-status-edit.sh missing"

# mkrender <name> — fixture with the render chain + wrapper symlinked, a GRAMMAR
# tracker (1 of 2 done), and a README carrying the STATUS markers. Returns the dir.
mkrender() {
  local d="$WORK/$1" s
  mkdir -p "$d/.claude/hooks" "$d/docs"
  for s in resolve-ready render-status status-line update-readme-status; do
    ln -s "$CLAUDE_DIR/$s.sh" "$d/.claude/$s.sh"
  done
  ln -s "$RENDER_HOOK" "$d/.claude/hooks/render-on-status-edit.sh"
  cat > "$d/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Build

- ✅ **[6.1]** Done `[deps: none]`
- ⬜ **[6.2]** Open `[deps: 6.1]`
MD
  cp "$d/docs/PHASE_STATUS.md" "$d/docs/REQUIREMENTS.md"
  printf '# Fx\n\n<!-- STATUS:START -->\nold status\n<!-- STATUS:END -->\n\ntail\n' > "$d/README.md"
  printf '%s\n' "$d"
}

# fire <dir> <file_path> — run the render hook with a PostToolUse payload naming
# <file_path>. Sets RC / ERR.
fire() {
  local d="$1" fp="$2" errf; errf=$(mktemp)
  ( cd "$d" && printf '%s' "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$fp\"}}" \
    | bash .claude/hooks/render-on-status-edit.sh ) 2>"$errf"; RC=$?
  ERR=$(cat "$errf"); rm -f "$errf"
}

# ── R1: a tracker edit renders status.html AND refreshes the README block ─────
R=$(mkrender render-fire)
fire "$R" "docs/PHASE_STATUS.md"
[ "$RC" -eq 0 ] && ok "tracker edit: exit 0" || no "tracker edit should exit 0 (rc=$RC; err=$ERR)"
[ -z "$ERR" ] && ok "tracker edit: stderr clean (chain stderr swallowed)" \
  || no "tracker edit stderr not clean: $ERR"
{ [ -f "$R/status.html" ] && head -1 "$R/status.html" | grep -q '<!DOCTYPE html>'; } \
  && ok "tracker edit: status.html rendered (doctype present)" \
  || no "tracker edit must render status.html"
grep -q '\*\*Phase 6\*\* · 1/2 deliverables' "$R/README.md" \
  && ok "tracker edit: README block refreshed from resolver state (Phase 6 · 1/2)" \
  || no "tracker edit must refresh the README block"
grep -q 'old status' "$R/README.md" \
  && no "tracker edit: stale README content must be replaced (found 'old status')" \
  || ok "tracker edit: stale README content replaced"

# ── R2: an edit to any other file does NOT render (matcher is tracker-only) ───
R2=$(mkrender render-skip)
fire "$R2" "src/app.js"
[ "$RC" -eq 0 ] && ok "non-tracker edit: exit 0" || no "non-tracker edit should exit 0 (rc=$RC)"
[ ! -f "$R2/status.html" ] \
  && ok "non-tracker edit: no render (status.html not created)" \
  || no "non-tracker edit must NOT render"
grep -q 'old status' "$R2/README.md" \
  && ok "non-tracker edit: README left untouched" \
  || no "non-tracker edit must leave the README untouched"

# ── R3: stale beats broken — a MALFORMED tracker leaves the prior status.html ─
R3=$(mkrender render-stale)
printf 'SENTINEL-PRIOR-RENDER\n' > "$R3/status.html"
cat > "$R3/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

## Phase 6 — Build

- ⬜ **[6.2]** Open `[deps: 9.9]`
MD
fire "$R3" "docs/PHASE_STATUS.md"
[ "$RC" -eq 0 ] && ok "malformed tracker: exit 0 (a render failure never errors the tool)" \
  || no "malformed tracker should exit 0 (rc=$RC)"
grep -q 'SENTINEL-PRIOR-RENDER' "$R3/status.html" \
  && ok "malformed tracker: stale beats broken — prior status.html preserved" \
  || no "a malformed render must not clobber the prior status.html"

# ── R4: no tracker file at the cwd → stand aside cleanly ──────────────────────
R4=$(mkrender render-notracker); rm -f "$R4/docs/PHASE_STATUS.md"
fire "$R4" "docs/PHASE_STATUS.md"
{ [ "$RC" -eq 0 ] && [ ! -f "$R4/status.html" ]; } \
  && ok "no tracker at cwd: exit 0, nothing rendered" \
  || no "absent tracker must stand aside (rc=$RC)"

# ── R5: settings.json wires the render hook on PostToolUse, additively ────────
RH_WIRED=$(jq -r '.hooks.PostToolUse[]? | select(any(.hooks[]?.command; test("render-on-status-edit\\.sh")))' "$SETTINGS" 2>/dev/null)
[ -n "$RH_WIRED" ] \
  && ok "settings.json wires render-on-status-edit.sh on PostToolUse (project mode)" \
  || no "settings.json PostToolUse must wire render-on-status-edit.sh"
AF_WIRED=$(jq -r '.hooks.PostToolUse[]? | select(any(.hooks[]?.command; test("auto-format\\.sh")))' "$SETTINGS" 2>/dev/null)
[ -n "$AF_WIRED" ] \
  && ok "settings.json keeps auto-format on PostToolUse (render hook added, not swapped)" \
  || no "auto-format must remain wired on PostToolUse"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
