#!/bin/bash
# .claude/hooks/occupancy-meter.sh
# Stop hook — the occupancy meter and threshold handoff ([9.2]; closes register T8).
#
# the context window is a cache over state that lives on disk; the handoff exists so that losing the cache costs nothing
#
# That rationale is the whole design. When context occupancy crosses a configured
# threshold this hook takes the DESIGNED degradation — it writes a complete handoff
# artifact (the calm path: state flushed to disk BEFORE the wall) and signals the
# session to finalize via /handoff. The context wall stops being the one improvised
# failure (A-003 Decision: occupancy crossing is a designed degradation). Below the
# threshold the meter is SILENT — no artifact, no output, no banner; a human-facing
# live meter is the supervision-era regression rejected by name, so this fires only
# at the boundary and otherwise says nothing.
#
# OCCUPANCY SIGNAL (probe + fallback, Rule 15) ───────────────────────────────────
# No live numeric occupancy field is exposed to a Claude Code hook, and there is no
# PreCompact event (verified against the hooks reference, 2026-06-13). The mechanical
# source that IS available is the transcript JSONL at .transcript_path: each
# assistant entry carries message.usage, and the latest assistant turn that
# reports usage —
#   input_tokens + cache_read_input_tokens + cache_creation_input_tokens
# is the size of the prompt the model was last sent — i.e. context occupancy in
# tokens. That is the input to a deterministic decision (occupancy ≥ threshold),
# exercised by synthetic transcript fixtures independent of any live session. When
# the signal is absent or unreadable (no transcript, no assistant usage) the hook
# takes the documented fallback rung: SILENCE — it never fabricates an occupancy
# number and never degrades on a guess.
#
# DEFAULT CALIBRATION ([10.6]) ────────────────────────────────────────────────────
# The threshold is the setpoint, but its SHIPPED DEFAULT is now window-relative, not
# a fixed absolute. A fixed 120000-token default ([9.2]) was ~12% of a 1M-context
# model's window, so the meter tripped EVERY turn — the degradation fired as the
# normal path instead of the boundary (feedback occdefault). The calibrated default
# is CONTEXT-WINDOW AWARE: where the hook can see the model (the transcript's latest
# assistant turn carries message.model), it derives the window from that model id —
# the [1m] marker → a 1,000,000-token window, every other model id (carrying no [1m]
# marker) → the standard 200,000-token Claude window — and sets the default to
# CALM_FRACTION (3/4) of that window: the calm-handoff point with headroom to flush a
# handoff before the wall, not so eager it fires constantly. With no model signal the
# default is the DOCUMENTED window-relative fallback below (3/4 of the standard
# 200000 window = DEFAULT_THRESHOLD). A person who sets occupancy.threshold still
# overrides this entirely — floor measured, ceiling tunable.
#
# SETPOINT ───────────────────────────────────────────────────────────────────────
# project.json → occupancy.threshold (a positive integer token count),
# schema-validated, person-adjustable. Absent → the window-derived default (see
# DEFAULT CALIBRATION above), falling back to DEFAULT_THRESHOLD when no model window
# is visible; absent means "use the default", NOT "off". The schema documents the
# same fallback default; the two must not drift (asserted by the suite).
#
# OUTPUT ──────────────────────────────────────────────────────────────────────────
# Crossing: exit 0 with a Stop block (decision:"block") naming the handoff and the
# occupancy, plus a systemMessage for the human. Below / no signal / re-entrant:
# silent exit 0. Stderr-clean for the well-formed JSON the runtime delivers (the
# test battery fails any suite that writes to stderr).
#
# Ships in both install modes: this script is glob-derived into plugin/scripts/ by
# build-plugin.sh, and settings.json (project mode) / the plugin hooks.json (plugin
# mode) register it on the Stop event alongside stop-check.sh — both Stop hooks run.
set -u

# Window-relative default calibration ([10.6]). The default threshold is CALM_FRACTION
# of the model's context window. Context windows are inferred from the model id the
# transcript reports; only the [1m] marker selects the wide window, every other model
# id (no [1m] marker) the standard window.
CALM_FRACTION_NUM=3        # 3/4 of the window = the calm-handoff default
CALM_FRACTION_DEN=4
STANDARD_WINDOW=200000     # the standard Claude context window (documented fallback)
WIDE_WINDOW=1000000        # 1M-context models (the [1m] marker)

# The shipped FALLBACK default threshold (tokens), used when no model window is
# visible to the hook: CALM_FRACTION of the standard window (200000 * 3 / 4 = 150000).
# A literal so the schema/hook drift guard can read it; mirrored in
# project.schema.json's occupancy.threshold.default — keep them equal (suite asserts).
DEFAULT_THRESHOLD=150000

INPUT=$(cat)

# Re-entrant Stop: a block re-triggers the Stop hook, so on the second pass stand
# down silently — never re-fire the degradation or duplicate the handoff (Rule 15:
# the quiet stop is the rung when the path is already taken).
if [ "$(echo "$INPUT" | jq -r '.stop_hook_active // false')" = "true" ]; then
  exit 0
fi

CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
[ -z "$CWD" ] && CWD="$PWD"

# ── Read occupancy AND the model id from the transcript (the mechanical source) ──
# The LATEST assistant entry's usage gives occupancy; that same entry's message.model
# gives the model id we derive the context window from. Missing file / no assistant
# usage → empty occupancy, which the guard below routes to the silent fallback rung.
OCC=""
MODEL=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  OCC=$(jq -rs '
    [ .[] | select(.type=="assistant") | .message.usage // empty ] as $u
    | if ($u | length) == 0 then empty
      else ($u | last) as $l
        | (($l.input_tokens // 0) + ($l.cache_read_input_tokens // 0) + ($l.cache_creation_input_tokens // 0))
      end
  ' "$TRANSCRIPT" 2>/dev/null)
  MODEL=$(jq -rs '
    [ .[] | select(.type=="assistant") | .message.model // empty ] as $m
    | if ($m | length) == 0 then empty else ($m | last) end
  ' "$TRANSCRIPT" 2>/dev/null)
fi

# No usable signal → silence. Never fabricate, never degrade on a guess.
case "$OCC" in
  ''|*[!0-9]*) exit 0 ;;
esac

# ── Derive the window-relative default from the model ([10.6]) ──
# Where the model id is visible, size its context window and set the default to
# CALM_FRACTION of it; otherwise keep the documented DEFAULT_THRESHOLD fallback. This
# is a deterministic id→window map, not a guess: ONLY the [1m] marker selects the wide
# window; every other model id (no [1m] marker) maps to the standard window. There is
# no id-list recognition — an unmarked id always takes the standard window, so the
# default never silently widens past what the marker proves.
DERIVED_DEFAULT="$DEFAULT_THRESHOLD"
case "$MODEL" in
  '')      : ;;                                  # no model signal → documented fallback
  *'[1m]'*) WINDOW=$WIDE_WINDOW ;;               # the 1M-context marker
  *)       WINDOW=$STANDARD_WINDOW ;;            # any other id (no [1m] marker) → standard window
esac
if [ -n "$MODEL" ]; then
  DERIVED_DEFAULT=$((WINDOW * CALM_FRACTION_NUM / CALM_FRACTION_DEN))
fi

# ── Read the threshold setpoint from the manifest (derived default if absent) ──
THRESHOLD="$DERIVED_DEFAULT"
MANIFEST="$CWD/.claude/project.json"
if [ -f "$MANIFEST" ]; then
  T=$(jq -r '.occupancy.threshold // empty' "$MANIFEST" 2>/dev/null)
  case "$T" in
    ''|*[!0-9]*) : ;;            # absent or non-integer → keep the shipped default
    *) THRESHOLD="$T" ;;
  esac
fi

# ── The decision: below threshold the meter is silent ──
[ "$OCC" -lt "$THRESHOLD" ] && exit 0

# ════════════════════════════════════════════════════════════════════════════════
# DESIGNED DEGRADATION — occupancy ≥ threshold. Flush state to disk, then finalize.
# ════════════════════════════════════════════════════════════════════════════════

# Write a COMPLETE handoff artifact (the /handoff template skeleton a finalizer
# fills). The cache lives on disk now; losing the context window costs nothing.
DATE="${OCCUPANCY_DATE:-$(date +%Y-%m-%d)}"
SESS_DIR="$CWD/docs/sessions"
mkdir -p "$SESS_DIR" 2>/dev/null
# Next zero-padded sequence for the day (so a same-day crossing doesn't clobber).
N=1
while [ -e "$(printf '%s/session-%s-%03d.md' "$SESS_DIR" "$DATE" "$N")" ]; do
  N=$((N + 1))
done
ARTIFACT=$(printf '%s/session-%s-%03d.md' "$SESS_DIR" "$DATE" "$N")

cat > "$ARTIFACT" <<EOF
# Session Handoff — ${DATE}-$(printf '%03d' "$N")

**Date:** ${DATE}
**Trigger:** occupancy meter — context occupancy (${OCC} tokens) crossed the configured threshold (${THRESHOLD}). This is the designed degradation (a calm handoff before the context wall), not a session you ended deliberately. Complete the sections below via /handoff (/guv:handoff under the plugin) before the window fills.

## Completed This Session

<!-- What was built, commit hash(es), tests added, notable decisions. Fill from the transcript and git log before context is lost. -->

## In Progress

<!-- Anything started but not finished: what it is, current state, where to pick up (file + function). -->

## Blocked

<!-- Anything that can't proceed and why. -->

## Issues & Technical Debt

<!-- Unresolved issues, severity, source, where they live. -->

## Next Steps

<!-- The logical next work in priority order. -->

## Session Notes

<!-- Architecture decisions, patterns established, gotchas. -->

---
_Auto-stub written by the occupancy meter at the threshold crossing. The context window is a cache over state that lives on disk; this handoff is that state, so losing the cache costs nothing._
EOF

# Signal the session to finalize calmly (block the bare stop, name why). The human
# sees the systemMessage; the agent sees the reason and routes to /handoff.
REASON="Occupancy meter: context occupancy (${OCC} tokens) crossed the threshold (${THRESHOLD}). A complete handoff stub was written to ${ARTIFACT} — the designed degradation. Finalize it via /handoff (/guv:handoff under the plugin) rather than letting the context wall end the session."
jq -nc \
  --arg r "$REASON" \
  --arg sm "Context occupancy threshold crossed (${OCC} ≥ ${THRESHOLD}). Handoff stub written to ${ARTIFACT}; finalize with /handoff before the context wall." \
  '{decision:"block", reason:$r, systemMessage:$sm, hookSpecificOutput:{hookEventName:"Stop"}}'

exit 0
