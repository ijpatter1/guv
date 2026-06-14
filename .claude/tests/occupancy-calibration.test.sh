#!/bin/bash
# Tests for .claude/hooks/occupancy-meter.sh — the [10.6] occupancy DEFAULT
# CALIBRATION. Sibling to occupancy-meter.test.sh, which covers the [9.2] meter
# invariants; this suite covers ONLY the recalibration of the shipped default.
#
# THE BUG ([9.2] regression, feedback occdefault): the shipped default was a fixed
# 120000-token absolute. On a 1M-context model that is ~12% occupancy, so the meter
# tripped EVERY turn — the degradation fired as the normal path instead of the
# boundary. [10.6] makes the shipped default CONTEXT-WINDOW AWARE: derived from the
# model's context window where that signal is available to the hook (the transcript's
# latest assistant turn carries message.model), otherwise a DOCUMENTED window-relative
# fallback. A 1M-window model then meters at a sensible occupancy, not every turn.
#
# These assertions encode WHY (Rule 8): the every-turn-firing bug is a regression
# guard (a large-window model at low occupancy must NOT trip the default); a
# small-window model still meters where expected; an explicit project.json setpoint
# still overrides the derived default; below-threshold stays silent; and the
# calibration basis is present in the doc header.
# Pure bash + jq, no test runner. Stderr-clean for well-formed input (the battery
# fails any suite that writes to stderr).
# Run: bash .claude/tests/occupancy-calibration.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/.claude/hooks/occupancy-meter.sh"
SCHEMA="$ROOT/.claude/project.schema.json"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Build a throwaway "project" dir: a manifest (optionally with an explicit
# threshold), an empty docs/sessions, and a transcript whose latest assistant turn
# reports the given occupancy AND model id. The model id is the window signal the
# hook derives the default from. Echoes the project dir.
#   mk_project <occupancy_tokens> <threshold|""> <model|"">
mk_project() {
  local occ="$1" thr="$2" model="$3"
  local d; d=$(mktemp -d "$WORK/proj.XXXXXX")
  mkdir -p "$d/.claude" "$d/docs/sessions"
  if [ -n "$thr" ]; then
    jq -nc --argjson t "$thr" '{name:"x",language:"shell",roots:{control:".",code:"."},commands:{},scaffoldCheck:"true",ceremony:"phased",occupancy:{threshold:$t}}' > "$d/.claude/project.json"
  else
    jq -nc '{name:"x",language:"shell",roots:{control:".",code:"."},commands:{},scaffoldCheck:"true",ceremony:"phased"}' > "$d/.claude/project.json"
  fi
  local half=$((occ / 2)) rest=$((occ - occ / 2))
  {
    jq -nc '{type:"user",message:{content:"hi"}}'
    if [ -n "$model" ]; then
      jq -nc --argjson a "$half" --argjson b "$rest" --arg m "$model" \
        '{type:"assistant",timestamp:"2026-06-14T00:01:00Z",message:{model:$m,usage:{input_tokens:$a,output_tokens:7,cache_read_input_tokens:$b,cache_creation_input_tokens:0}}}'
    else
      jq -nc --argjson a "$half" --argjson b "$rest" \
        '{type:"assistant",timestamp:"2026-06-14T00:01:00Z",message:{usage:{input_tokens:$a,output_tokens:7,cache_read_input_tokens:$b,cache_creation_input_tokens:0}}}'
    fi
  } > "$d/transcript.jsonl"
  echo "$d"
}

feed() {
  local d="$1" active="${2:-false}"
  local input
  input=$(jq -nc --arg c "$d" --arg t "$d/transcript.jsonl" --argjson a "$active" \
    '{hook_event_name:"Stop",cwd:$c,transcript_path:$t,stop_hook_active:$a}')
  printf '%s' "$input" | OCCUPANCY_DATE=2026-06-14 bash "$HOOK" 2>/dev/null
}

artifact() { ls "$1"/docs/sessions/session-*.md 2>/dev/null | head -1; }

# ── ACCEPTANCE 1: large-window fixture does NOT trip at low occupancy (the bug) ──

# C1 — the every-turn-firing regression guard. A 1M-window model (the [1m] marker)
# at 120000 tokens occupancy — the OLD fixed default, ~12% of a 1M window — must NOT
# degrade under the NEW window-aware default and NO explicit setpoint. Under the old
# constant default this fired; the calibrated default leaves headroom.
P=$(mk_project 120000 "" "claude-opus-4-8[1m]")
OUT=$(feed "$P"); RC=$?
ART=$(artifact "$P")
[ $RC -eq 0 ] && [ -z "$OUT" ] && [ -z "$ART" ] \
  && ok "1M-window model at 120000 tokens (~12%) stays SILENT under the calibrated default (every-turn-firing bug fixed)" \
  || no "the 1M-window low-occupancy fixture must NOT trip the meter (rc=$RC out='$OUT' art='$ART')"

# C1b — but the large window still HAS a boundary: occupancy genuinely deep into a
# 1M window (900000 tokens) DOES degrade under the derived default. The fix raises
# the bar, it does not disable the meter.
P=$(mk_project 900000 "" "claude-opus-4-8[1m]")
OUT=$(feed "$P"); ART=$(artifact "$P")
[ -n "$ART" ] \
  && ok "1M-window model at 900000 tokens DOES degrade (the calibrated default still gates near the wall)" \
  || no "a 1M-window model deep into its window must still trip the derived default"

# ── ACCEPTANCE 2: a small-window fixture still meters where expected ──

# C2 — a standard ~200k-window model at 160000 tokens (~80% of its window) is past
# the 3/4 calm-handoff point and DOES degrade under the derived default. Contrast
# with the 1M model: at 160000 the 1M model would still be silent (~16%), so the
# decision differs by model — proving derivation from the window, not one global
# constant.
P=$(mk_project 160000 "" "claude-sonnet-4-5")
OUT=$(feed "$P"); ART=$(artifact "$P")
[ -n "$ART" ] \
  && ok "200k-window model at 160000 tokens (~80%) DOES degrade — small window meters where expected" \
  || no "a small-window model past its calm point must trip the derived default"

# C2c — the SAME 160000 occupancy on a 1M-window model stays silent (~16%): the only
# difference is the model id, so this isolates the window-derivation as the cause of
# the differing decision (the small window meters, the wide one does not, at one
# occupancy).
P=$(mk_project 160000 "" "claude-opus-4-8[1m]")
OUT=$(feed "$P"); ART=$(artifact "$P")
[ -z "$OUT" ] && [ -z "$ART" ] \
  && ok "the same 160000 occupancy stays silent on a 1M-window model (window derivation is the cause)" \
  || no "a 1M-window model at 160000 (~16%) must stay silent — the window must drive the difference"

# C2d — the map is MARKER-ONLY, not id-list recognition. A model id that carries no
# [1m] marker takes the STANDARD window even if its name might suggest a big model:
# the same 160000 occupancy that stays silent on a [1m]-marked id (C2c) DOES degrade
# on an unmarked id, because unmarked → standard 200k window → 150000 default. This
# pins the honest map the header documents (only [1m] widens the window) and would
# fail if the case ever silently grew id-list recognition without proving the width.
P=$(mk_project 160000 "" "claude-opus-4-8")
OUT=$(feed "$P"); ART=$(artifact "$P")
[ -n "$ART" ] \
  && ok "an unmarked model id (no [1m]) takes the STANDARD window and degrades at 160000 — the map is marker-only, not id-list recognition" \
  || no "an unmarked id must map to the standard window (160000 ~80% of 200k must trip); the map must not silently widen without the [1m] marker (art='$ART')"

# C2b — the same small-window model well below its calm point stays silent: 40000
# tokens (~20% of a 200k window) is nowhere near the wall.
P=$(mk_project 40000 "" "claude-sonnet-4-5")
OUT=$(feed "$P"); ART=$(artifact "$P")
[ -z "$OUT" ] && [ -z "$ART" ] \
  && ok "200k-window model at 40000 tokens (~20%) stays silent (below the calm point)" \
  || no "a small-window model well below its window must stay silent"

# ── ACCEPTANCE 3: an explicit project.json setpoint overrides the derived default ──

# C3 — a person who sets occupancy.threshold gets EXACTLY that, ignoring the model
# window. 50000 explicit threshold on a 1M-window model trips at 60000 occupancy
# (which the derived 1M default would have left silent) — the manifest wins.
P=$(mk_project 60000 50000 "claude-opus-4-8[1m]")
OUT=$(feed "$P"); ART=$(artifact "$P")
[ -n "$ART" ] \
  && ok "explicit occupancy.threshold overrides the derived default (the setpoint stays person-overridable)" \
  || no "an explicit project.json threshold must override the window-derived default (art='$ART')"

# ── ACCEPTANCE 4: below-threshold stays silent (unchanged [9.2] behaviour) ──

# C4 — silent-below-threshold survives the recalibration: with an explicit high
# setpoint, an occupancy under it produces nothing — no artifact, no output, exit 0.
P=$(mk_project 100000 500000 "claude-opus-4-8[1m]")
OUT=$(feed "$P"); RC=$?
ART=$(artifact "$P")
[ $RC -eq 0 ] && [ -z "$OUT" ] && [ -z "$ART" ] \
  && ok "below-threshold stays silent under the new default (the [9.2] invariant survives)" \
  || no "the meter must still be silent below threshold (rc=$RC out='$OUT' art='$ART')"

# ── ACCEPTANCE 5: documented window-relative FALLBACK when no model signal ──

# C5 — when the transcript carries occupancy but NO model id (older transcript, or a
# model the map doesn't know), the hook does NOT fabricate a window: it falls back to
# the DOCUMENTED window-relative default. That fallback gates at a finite point —
# an occupancy far above any standard window (3,000,000 tokens) degrades.
P=$(mk_project 3000000 "" "")
OUT=$(feed "$P"); ART=$(artifact "$P")
[ -n "$ART" ] \
  && ok "no model signal -> documented window-relative fallback still gates (an extreme occupancy degrades)" \
  || no "absent a model signal the hook must fall back to a documented default, not go silent forever"

# C5b — and that documented fallback default is the schema-published one, and the
# two do not drift: the hook's coded fallback equals project.schema.json's default
# (one shipped fallback, two places). Extract both and compare.
SCHEMA_DEFAULT=$(jq -r '.properties.occupancy.properties.threshold.default // empty' "$SCHEMA" 2>/dev/null)
HOOK_DEFAULT=$(grep -oE 'DEFAULT_THRESHOLD=[0-9]+' "$HOOK" | head -1 | grep -oE '[0-9]+')
[ -n "$SCHEMA_DEFAULT" ] && [ -n "$HOOK_DEFAULT" ] && [ "$SCHEMA_DEFAULT" = "$HOOK_DEFAULT" ] \
  && ok "schema fallback default ($SCHEMA_DEFAULT) and hook fallback default ($HOOK_DEFAULT) agree (no drift)" \
  || no "the schema-documented fallback must equal the hook's coded fallback (schema=$SCHEMA_DEFAULT hook=$HOOK_DEFAULT)"

# C5c — the calibrated default is NOT the old fixed 120000 absolute: the bug was that
# value. A fallback still equal to 120000 would mean nothing was recalibrated.
[ -n "$HOOK_DEFAULT" ] && [ "$HOOK_DEFAULT" != "120000" ] \
  && ok "the shipped fallback default is no longer the buggy 120000 (recalibrated)" \
  || no "the default is still 120000 — the [10.6] recalibration did not happen (hook=$HOOK_DEFAULT)"

# ── ACCEPTANCE 6: the calibration basis is present in the doc header ──

# C6 — the meter doc header records the calibration RATIONALE: that the default is
# window-relative / derived from the model window, naming the [10.6] basis. grep is
# case-insensitive on the load-bearing terms so a reword survives but a missing
# rationale fails.
HEADER=$(sed -n '1,55p' "$HOOK")
echo "$HEADER" | grep -qiE 'window-relative|window.aware|context.window' \
  && echo "$HEADER" | grep -qiE 'calibrat|derive|fraction|relative' \
  && echo "$HEADER" | grep -qF '10.6' \
  && ok "the meter doc header records the window-relative calibration basis and names [10.6]" \
  || no "the doc header must record the calibration rationale (window-relative default, [10.6] basis)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
