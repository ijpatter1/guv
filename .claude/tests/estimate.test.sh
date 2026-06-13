#!/bin/bash
# Tests for .claude/estimate.sh — the estimate sidecar helper ([9.6] of the
# plan-as-data spec / A-003 governor's meter).
#
# The sidecar is a JSON object keyed by deliverable ID (ID → integer ≥ 1)
# living BESIDE the tracker, never inside it: the tracker is evidence (what
# is), estimates are interpretation (what we guess). The two heart-of-the-
# deliverable invariants this suite defends:
#   1. estimate edits leave the tracker BYTE-IDENTICAL (asserted with cmp);
#   2. NO estimate token ever enters the tracker grammar (grep-asserted).
# The default is 1 (the harness pushes deliverables toward session-sized);
# anything above 1 is a flagged balloon.
#
# Pure bash + jq, no test runner. Run: bash .claude/tests/estimate.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"          # .claude/
SCRIPT="$SRC/estimate.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# A representative tracker fixture — the byte-identity target. A real DAG
# tracker with IDs and deps tokens, exactly the shape /replan mutates.
cat > "$WORK/tracker.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 9 — The Meter**
> Last updated: 2026-06-13, session-2026-06-13-001

---

## Phase 9 — The Meter

_Goal: meter cost at every boundary._

- ✅ **[9.1]** Session-boundary cost capture `[deps: none]` (2026-06-13, session-x)
- 🔄 **[9.6]** Estimate sidecar `[deps: 6.3]`
- ⬜ **[9.7]** Projection `[deps: 9.5, 9.6, 6.2]`
MD

fresh_sidecar() { printf '%s\n' "$WORK/$1.json"; }

# ════ T1 — default: a balloon-free harness defaults every deliverable to 1 ════
[ "$(bash "$SCRIPT" default 2>/dev/null)" = "1" ] \
  && ok "default: the shipped default estimate is 1 (session-sized)" \
  || no "default should print 1 (got: $(bash "$SCRIPT" default 2>&1))"

# An absent sidecar, and an ID absent from a present sidecar, both read the
# default — a deliverable with no ratified estimate is not an error, it is a 1.
S="$(fresh_sidecar absent)"
[ ! -f "$S" ] || rm -f "$S"
[ "$(bash "$SCRIPT" get 9.6 "$S" 2>/dev/null)" = "1" ] \
  && ok "get: absent sidecar yields the default (1), not an error" \
  || no "get on absent sidecar should yield 1 (got: $(bash "$SCRIPT" get 9.6 "$S" 2>&1))"
[ ! -f "$S" ] \
  && ok "get: a read never creates the sidecar (read is side-effect-free)" \
  || no "get must not create the sidecar file"

# ════ T2 — set records a ratified estimate; the sidecar is keyed by ID ════
S="$(fresh_sidecar t2)"; rm -f "$S"
bash "$SCRIPT" set 9.6 1 "$S" >/dev/null 2>&1 \
  && ok "set: records an estimate, creating the sidecar" || no "set 9.6 1 should succeed"
[ -f "$S" ] && ok "set: the sidecar file now exists" || no "set should create the sidecar"
[ "$(bash "$SCRIPT" get 9.6 "$S" 2>/dev/null)" = "1" ] \
  && ok "get: reads back the ratified value" || no "get 9.6 should read back 1"
# Keyed by ID: a second ID is independent, the first survives.
bash "$SCRIPT" set 9.7 3 "$S" >/dev/null 2>&1
[ "$(bash "$SCRIPT" get 9.7 "$S" 2>/dev/null)" = "3" ] && [ "$(bash "$SCRIPT" get 9.6 "$S" 2>/dev/null)" = "1" ] \
  && ok "set: keyed by ID — a new key leaves existing keys intact" || no "set must not clobber sibling keys"
# Revisable without touching plan state: re-set the same ID overwrites.
bash "$SCRIPT" set 9.6 2 "$S" >/dev/null 2>&1
[ "$(bash "$SCRIPT" get 9.6 "$S" 2>/dev/null)" = "2" ] \
  && ok "set: an estimate is revisable in place (interpretation, not evidence)" || no "re-set 9.6 should become 2"

# ════ T3 — the shape contract: object, ID keys, integer values ≥ 1 ════
S="$(fresh_sidecar t3)"; rm -f "$S"
bash "$SCRIPT" set 9.6 1 "$S" >/dev/null 2>&1
bash "$SCRIPT" set 9.7 4 "$S" >/dev/null 2>&1
bash "$SCRIPT" validate "$S" >/dev/null 2>&1 \
  && ok "validate: a well-formed sidecar passes" || no "well-formed sidecar should validate"
# A value < 1 is rejected at write time — there is no zero-session deliverable.
OUT=$(bash "$SCRIPT" set 9.6 0 "$S" 2>&1); RC=$?
[ "$RC" -ne 0 ] && ok "set: an estimate below 1 is refused (no zero-session work)" \
  || no "set 9.6 0 should be refused (rc=$RC: $OUT)"
[ "$(bash "$SCRIPT" get 9.6 "$S" 2>/dev/null)" = "1" ] \
  && ok "set: a refused write leaves the prior value intact" || no "refused set must not change the stored value"
# A non-integer is refused too.
OUT=$(bash "$SCRIPT" set 9.6 two "$S" 2>&1); RC=$?
[ "$RC" -ne 0 ] && ok "set: a non-integer estimate is refused" || no "set 9.6 two should be refused (rc=$RC)"

# validate rejects malformed sidecars: non-object, bad value type, value < 1.
echo '[1,2,3]' > "$WORK/bad-array.json"
OUT=$(bash "$SCRIPT" validate "$WORK/bad-array.json" 2>&1); RC=$?
[ "$RC" -eq 5 ] && ok "validate: a non-object sidecar exits 5 MALFORMED" || no "array sidecar should exit 5 (rc=$RC)"
echo '{"9.6":0}' > "$WORK/bad-zero.json"
OUT=$(bash "$SCRIPT" validate "$WORK/bad-zero.json" 2>&1); RC=$?
[ "$RC" -eq 5 ] && echo "$OUT" | grep -q '9.6' \
  && ok "validate: a value below 1 exits 5, naming the offending ID" || no "value-0 sidecar should exit 5 naming 9.6 (rc=$RC: $OUT)"
echo '{"9.6":"big"}' > "$WORK/bad-str.json"
OUT=$(bash "$SCRIPT" validate "$WORK/bad-str.json" 2>&1); RC=$?
[ "$RC" -eq 5 ] && ok "validate: a non-integer value exits 5 MALFORMED" || no "string-value sidecar should exit 5 (rc=$RC)"
echo '{"9.6":1.5}' > "$WORK/bad-float.json"
OUT=$(bash "$SCRIPT" validate "$WORK/bad-float.json" 2>&1); RC=$?
[ "$RC" -eq 5 ] && ok "validate: a fractional value exits 5 (sessions are whole)" || no "float-value sidecar should exit 5 (rc=$RC)"
printf 'not json' > "$WORK/bad-json.json"
OUT=$(bash "$SCRIPT" validate "$WORK/bad-json.json" 2>&1); RC=$?
[ "$RC" -eq 5 ] && ok "validate: invalid JSON exits 5 MALFORMED" || no "non-JSON sidecar should exit 5 (rc=$RC)"
# An absent sidecar validates trivially — no estimates ratified yet is legal.
OUT=$(bash "$SCRIPT" validate "$WORK/never.json" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "validate: an absent sidecar is valid (no ratifications yet)" || no "absent sidecar should validate (rc=$RC: $OUT)"

# ════ T4 — balloons: > 1 is a flagged balloon, surfaced for the confirm gate ════
S="$(fresh_sidecar t4)"; rm -f "$S"
bash "$SCRIPT" set 9.1 1 "$S" >/dev/null 2>&1
bash "$SCRIPT" set 9.6 1 "$S" >/dev/null 2>&1
bash "$SCRIPT" set 9.7 4 "$S" >/dev/null 2>&1
BALLOONS=$(bash "$SCRIPT" balloons "$S" 2>/dev/null)
echo "$BALLOONS" | grep -q '9.7' \
  && ok "balloons: an estimate above 1 is flagged" || no "9.7 (=4) should be flagged a balloon (got: $BALLOONS)"
echo "$BALLOONS" | grep -qv '9.1' || true
echo "$BALLOONS" | grep -q '9.1' \
  && no "9.1 (=1) must NOT be flagged a balloon (got: $BALLOONS)" \
  || ok "balloons: a default-1 estimate is never flagged"

# ════ T5 — THE HEART: estimate edits leave the tracker BYTE-IDENTICAL ════
# The sidecar lives beside the tracker; editing it must not touch plan state.
TR="$WORK/tracker.md"
BEFORE="$WORK/tracker.before.md"; cp "$TR" "$BEFORE"
S="$(fresh_sidecar t5)"; rm -f "$S"
bash "$SCRIPT" set 9.6 1 "$S" >/dev/null 2>&1
bash "$SCRIPT" set 9.7 2 "$S" >/dev/null 2>&1
bash "$SCRIPT" set 9.6 3 "$S" >/dev/null 2>&1   # a revision
bash "$SCRIPT" validate "$S" >/dev/null 2>&1
bash "$SCRIPT" get 9.6 "$S" >/dev/null 2>&1
cmp -s "$TR" "$BEFORE" \
  && ok "BYTE-IDENTITY: a full set/revise/validate/read cycle leaves the tracker untouched" \
  || no "the tracker changed under estimate edits — the sidecar leaked into plan state"

# ════ T6 — THE HEART: NO estimate token enters the tracker grammar ════
# Estimates never appear as a tracker token. The sidecar is the ONLY home for
# the word — grep the tracker fixture and assert it carries no estimate data.
grep -qiE 'estimate|`\[est' "$TR" \
  && no "the tracker grammar carries estimate data — [9.6]'s whole point is violated" \
  || ok "NO-TRACKER-TOKEN: the tracker grammar carries no estimate token (grep-asserted)"
# And the sidecar genuinely holds the data instead — proving it has a home.
grep -q '9.6' "$S" \
  && ok "the sidecar (not the tracker) is where the estimate lives" || no "the estimate must live in the sidecar"

# ════ T7 — set never writes to the tracker even when a tracker is co-located ════
# Defensive: a co-located tracker.md in the sidecar's directory is never a
# write target. (Guards against a future refactor pointing set at the tracker.)
TR2="$WORK/co/docs"; mkdir -p "$TR2"
cp "$WORK/tracker.md" "$TR2/PHASE_STATUS.md"
BEFORE2="$WORK/co/PHASE_STATUS.before.md"; cp "$TR2/PHASE_STATUS.md" "$BEFORE2"
S2="$WORK/co/docs/estimates.json"; rm -f "$S2"
bash "$SCRIPT" set 9.6 5 "$S2" >/dev/null 2>&1
cmp -s "$TR2/PHASE_STATUS.md" "$BEFORE2" \
  && ok "BYTE-IDENTITY: a co-located PHASE_STATUS.md is never a write target" \
  || no "set touched a co-located tracker"

# ════ T8 — usage discipline (the stderr gate: errors go to stderr, exit non-zero) ════
OUT=$(bash "$SCRIPT" 2>&1 1>/dev/null); RC=$?
[ "$RC" -eq 2 ] && [ -n "$OUT" ] && ok "usage: no subcommand exits 2 with a stderr message" || no "no-arg should exit 2 to stderr (rc=$RC)"
OUT=$(bash "$SCRIPT" frobnicate 2>&1 1>/dev/null); RC=$?
[ "$RC" -eq 2 ] && ok "usage: unknown subcommand exits 2" || no "unknown subcommand should exit 2 (rc=$RC)"
OUT=$(bash "$SCRIPT" get 2>&1 1>/dev/null); RC=$?
[ "$RC" -eq 2 ] && ok "usage: get without an ID exits 2" || no "get with no ID should exit 2 (rc=$RC)"
OUT=$(bash "$SCRIPT" set 9.6 2>&1 1>/dev/null); RC=$?
[ "$RC" -eq 2 ] && ok "usage: set without a value exits 2" || no "set with no value should exit 2 (rc=$RC)"
# Clean runs emit nothing to stderr (the stop-check gate forbids stray stderr).
S="$(fresh_sidecar t8)"; rm -f "$S"
ERR=$(bash "$SCRIPT" set 9.6 1 "$S" 2>&1 1>/dev/null)
[ -z "$ERR" ] && ok "stderr-gate: a clean set is silent on stderr" || no "clean set leaked to stderr: $ERR"
ERR=$(bash "$SCRIPT" get 9.6 "$S" 2>&1 1>/dev/null)
[ -z "$ERR" ] && ok "stderr-gate: a clean get is silent on stderr" || no "clean get leaked to stderr: $ERR"
ERR=$(bash "$SCRIPT" validate "$S" 2>&1 1>/dev/null)
[ -z "$ERR" ] && ok "stderr-gate: a clean validate is silent on stderr" || no "clean validate leaked to stderr: $ERR"

# ════ T9 — prose contracts: both generators + the mutation door wire estimates ════
PI="$SRC/commands/plan-initiative.md"
RP="$SRC/commands/replan.md"
SHAPE="$SRC/estimate.shape.md"

# Both generators emit estimates for a new plan.
grep -q 'estimate' "$PI" && ok "plan-initiative.md proposes estimates at plan time" \
  || no "plan-initiative.md must wire estimate proposal"
grep -q 'estimate.sh' "$PI" && ok "plan-initiative.md routes estimates through the helper" \
  || no "plan-initiative.md must reference estimate.sh"
grep -qi 'ratif\|confirm' "$PI" && ok "plan-initiative.md ratifies estimates in the confirm gate" \
  || no "plan-initiative.md must ratify in the same confirm gate"

# A /replan insert acquires its estimate inside the same confirmation.
grep -q 'estimate' "$RP" && ok "replan.md proposes an estimate on insert" \
  || no "replan.md must wire estimate proposal on insert"
grep -q 'estimate.sh' "$RP" && ok "replan.md routes the insert estimate through the helper" \
  || no "replan.md must reference estimate.sh"
grep -qi 'same confirm\|same confirmation\|confirm gate' "$RP" \
  && ok "replan.md acquires the estimate inside the same confirmation" \
  || no "replan.md must acquire the estimate in the same confirm gate"
# The byte-identity guarantee must be stated where the wiring lives, so a
# future editor cannot route estimates through the tracker engine by mistake.
grep -qi 'byte-identical\|never.*tracker\|not.*tracker\|sidecar' "$RP" \
  && ok "replan.md states estimates never touch the tracker" \
  || no "replan.md must state the never-the-tracker rule"

# The shape is documented in its own file.
[ -f "$SHAPE" ] && ok "the sidecar shape is documented in its own file" || no "estimate.shape.md must exist"
if [ -f "$SHAPE" ]; then
  grep -qi 'sidecar' "$SHAPE" && ok "shape doc names the sidecar" || no "shape doc must describe the sidecar"
  grep -qiE 'integer|≥ 1|>= 1|>=1' "$SHAPE" && ok "shape doc states the value constraint (integer ≥ 1)" \
    || no "shape doc must state integer ≥ 1"
  grep -qi 'never in the tracker\|never the tracker\|not in the tracker\|byte-identical\|interpretation' "$SHAPE" \
    && ok "shape doc states the tracker-is-evidence/estimates-are-interpretation line" \
    || no "shape doc must state the never-in-the-tracker rationale"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
