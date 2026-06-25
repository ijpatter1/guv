#!/bin/bash
# Tests for .claude/hooks/occupancy-meter.sh — the occupancy meter and threshold
# handoff ([9.2]).
#
# Invariant (the designed degradation, register thread T8): a Stop hook watches
# context occupancy; when occupancy crosses the configured threshold it triggers
# the CALM path — a complete handoff artifact written before the context wall —
# and signals the session to finalize. BELOW threshold the meter is SILENT: no
# artifact, no output, no banner. The threshold is a project.json setpoint with a
# shipped default, person-adjustable.
#
# There is NO live numeric occupancy field exposed to a Claude Code hook, and no
# PreCompact event exists (verified against the hooks reference, 2026-06-13). The
# mechanical source that IS available is the transcript JSONL at .transcript_path:
# each assistant entry carries message.usage, and the LATEST assistant turn's
# (input_tokens + cache_read_input_tokens + cache_creation_input_tokens) is the
# size of the prompt the model was sent — i.e. context occupancy in tokens. The
# hook's decision is therefore an INPUT-driven, unit-testable function exercised
# here by SYNTHETIC transcript fixtures, independent of any live session — exactly
# the fixture-based acceptance.
#
# These assertions encode WHY (Rule 8): the degradation fires above threshold and
# is silent below, the threshold reads from project.json and is schema-validated,
# and the cache rationale is present verbatim in the doc header.
# Pure bash + jq, no test runner. Stderr-clean for well-formed input (the battery
# fails any suite that writes to stderr).
# Run: bash .claude/tests/occupancy-meter.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/.claude/hooks/occupancy-meter.sh"
SCHEMA="$ROOT/.claude/project.schema.json"
SETTINGS="$ROOT/.claude/settings.json"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Build a throwaway "project" dir: a manifest with the given threshold (or none),
# an empty docs/sessions, and a transcript whose latest assistant turn reports the
# given context-token occupancy. Echoes the project dir.
#   mk_project <occupancy_tokens> <threshold|"">
mk_project() {
  local occ="$1" thr="$2"
  local d; d=$(mktemp -d "$WORK/proj.XXXXXX")
  mkdir -p "$d/.claude" "$d/docs/sessions"
  if [ -n "$thr" ]; then
    jq -nc --argjson t "$thr" '{name:"x",language:"node",roots:{control:".",code:"."},commands:{},scaffoldCheck:"true",ceremony:"phased",occupancy:{threshold:$t}}' > "$d/.claude/project.json"
  else
    jq -nc '{name:"x",language:"node",roots:{control:".",code:"."},commands:{},scaffoldCheck:"true",ceremony:"phased"}' > "$d/.claude/project.json"
  fi
  # Transcript: a user line, an early assistant turn (small), then the LATEST
  # assistant turn carrying the occupancy we want read. Split across input + cache
  # fields so the test proves all three are summed, not just input_tokens.
  local half=$((occ / 2)) rest=$((occ - occ / 2))
  {
    jq -nc '{type:"user",message:{content:"hi"}}'
    jq -nc '{type:"assistant",timestamp:"2026-06-13T00:00:00Z",message:{usage:{input_tokens:10,output_tokens:5,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}'
    jq -nc --argjson a "$half" --argjson b "$rest" '{type:"assistant",timestamp:"2026-06-13T00:01:00Z",message:{usage:{input_tokens:$a,output_tokens:7,cache_read_input_tokens:$b,cache_creation_input_tokens:0}}}'
  } > "$d/transcript.jsonl"
  echo "$d"
}

# Feed the Stop-hook input JSON for a project dir, with a fixed date/sequence seam
# so the artifact path is deterministic. Echoes hook stdout.
#   feed <project_dir> [stop_hook_active]
feed() {
  local d="$1" active="${2:-false}" sid="${3:-}"
  local input
  input=$(jq -nc --arg c "$d" --arg t "$d/transcript.jsonl" --argjson a "$active" --arg s "$sid" \
    '{hook_event_name:"Stop",cwd:$c,transcript_path:$t,stop_hook_active:$a}
     + (if $s == "" then {} else {session_id:$s} end)')
  printf '%s' "$input" | OCCUPANCY_DATE=2026-06-13 bash "$HOOK" 2>/dev/null
}

# Add a contextManagement.mode to an existing project's manifest ([16.4]).
set_mode() {
  local man="$1/.claude/project.json" t
  t=$(mktemp); jq --arg m "$2" '.contextManagement.mode = $m' "$man" > "$t" && mv "$t" "$man"
}

# Rewrite a project's transcript so the latest assistant turn reports <occ> tokens
# ([16.4] — to move occupancy across a band within ONE project: warn-band → wall).
set_occ() {
  local d="$1" occ="$2"
  local half=$((occ / 2)) rest=$((occ - occ / 2))
  {
    jq -nc '{type:"user",message:{content:"hi"}}'
    jq -nc --argjson a "$half" --argjson b "$rest" '{type:"assistant",timestamp:"2026-06-13T00:02:00Z",message:{usage:{input_tokens:$a,output_tokens:7,cache_read_input_tokens:$b,cache_creation_input_tokens:0}}}'
  } > "$d/transcript.jsonl"
}

# The single handoff artifact written into a project's docs/sessions (if any).
artifact() { ls "$1"/docs/sessions/session-*.md 2>/dev/null | head -1; }

# ── ACCEPTANCE 1: threshold-crossing fixture produces a COMPLETE handoff artifact ──

# T1 — occupancy (150000) at/over threshold (120000) writes a handoff artifact.
P=$(mk_project 150000 120000)
OUT=$(feed "$P"); RC=$?
ART=$(artifact "$P")
[ $RC -eq 0 ] && [ -n "$ART" ] && [ -f "$ART" ] \
  && ok "occupancy ≥ threshold -> a handoff artifact is written (the calm path)" \
  || no "crossing the threshold must write a handoff artifact (rc=$RC, art=$ART)"

# T1b — the artifact is COMPLETE, not a stub: it carries the handoff section
# skeleton a finalizer fills (the /handoff template's load-bearing headings), so
# "complete handoff artifact" means a usable structure, not an empty file.
if [ -n "$ART" ] && [ -f "$ART" ]; then
  miss=""
  for h in "# Session Handoff" "## Completed This Session" "## In Progress" "## Next Steps"; do
    grep -qF "$h" "$ART" || miss="$miss [$h]"
  done
  [ -z "$miss" ] \
    && ok "the handoff artifact is complete (carries the handoff section skeleton)" \
    || no "the artifact is missing handoff sections:$miss"
else
  no "no artifact to check for completeness"
fi

# T1c — the degradation is the CALM path, not a panic: the hook signals the
# session to finalize (Stop decision block + a reason that names the handoff and
# the occupancy), rather than silently dying. Encodes WHY it fired.
if [ -n "$OUT" ]; then
  DEC=$(echo "$OUT" | jq -r '.decision // empty' 2>/dev/null)
  RSN=$(echo "$OUT" | jq -r '.reason // .systemMessage // empty' 2>/dev/null)
  [ "$DEC" = "block" ] && echo "$RSN" | grep -qi 'handoff' && echo "$RSN" | grep -qiE 'occupanc|threshold|context' \
    && ok "crossing emits a Stop block that names the handoff and the occupancy (calm finalize, not panic)" \
    || no "the crossing output must block the stop and name the handoff + occupancy (dec=$DEC, reason=$RSN)"
else
  no "crossing the threshold must emit hook output directing finalization"
fi

# ── ACCEPTANCE 2: below-threshold fixture produces NOTHING (the meter is silent) ──

# T2 — occupancy (50000) below threshold (120000): no artifact, no output, exit 0.
P=$(mk_project 50000 120000)
OUT=$(feed "$P"); RC=$?
ART=$(artifact "$P")
[ $RC -eq 0 ] && [ -z "$OUT" ] && [ -z "$ART" ] \
  && ok "occupancy < threshold -> silent: no artifact, no output, exit 0" \
  || no "below threshold the meter must be silent (rc=$RC, out='$OUT', art='$ART')"

# T2b — exactly at the boundary minus one is still below (the crossing is ≥, a
# strict-vs-not regression flips this). 119999 < 120000 -> silent.
P=$(mk_project 119999 120000)
OUT=$(feed "$P"); ART=$(artifact "$P")
[ -z "$OUT" ] && [ -z "$ART" ] \
  && ok "one token below threshold is still below -> silent (boundary is ≥)" \
  || no "occupancy just under the threshold must stay silent"

# ── ACCEPTANCE 3: threshold configurable (the project.json setpoint) ──

# T3 — the SAME occupancy that was silent under a high threshold degrades under a
# low one: the decision genuinely reads the configured setpoint, not a constant.
P=$(mk_project 80000 60000)
OUT=$(feed "$P"); ART=$(artifact "$P")
[ -n "$ART" ] \
  && ok "lowering the threshold to 60000 degrades the same 80000 occupancy (setpoint drives the decision)" \
  || no "the threshold must be read from project.json, not hardcoded"

# T3b — absent setpoint falls back to the SHIPPED DEFAULT, not to 'off'. An
# occupancy above any sane default (10,000,000 tokens) degrades with no setpoint
# present — proving a default exists and gates.
P=$(mk_project 10000000 "")
OUT=$(feed "$P"); ART=$(artifact "$P")
[ -n "$ART" ] \
  && ok "no setpoint -> the shipped default still gates (an extreme occupancy degrades)" \
  || no "an absent setpoint must fall back to the shipped default threshold"

# ── ACCEPTANCE 4: the threshold setpoint is SCHEMA-VALIDATED ──

# T4 — project.schema.json declares occupancy.threshold (a positive integer), so a
# manifest carrying it validates and the surface is explicit manifest. Asserted
# structurally on the schema (the manifest has no jsonschema validator in-repo;
# the schema being the contract is the testable surface).
THR_SCHEMA=$(jq -c '.properties.occupancy.properties.threshold' "$SCHEMA" 2>/dev/null)
[ -n "$THR_SCHEMA" ] && [ "$THR_SCHEMA" != "null" ] \
  && echo "$THR_SCHEMA" | jq -e '.type=="integer" or (.type|index("integer"))' >/dev/null 2>&1 \
  && ok "schema declares occupancy.threshold as an integer setpoint (schema-validated)" \
  || no "project.schema.json must declare occupancy.threshold as an integer (schema=$THR_SCHEMA)"

# T4b — additionalProperties stays closed: a typo'd key under occupancy is caught
# by the schema (the manifest is additionalProperties:false at the top, and the
# occupancy object must be too, or a misspelled setpoint silently does nothing).
AP=$(jq -r '.properties.occupancy.additionalProperties' "$SCHEMA" 2>/dev/null)
[ "$AP" = "false" ] \
  && ok "occupancy object is additionalProperties:false (a typo'd setpoint is caught, not ignored)" \
  || no "the occupancy object must close additionalProperties so a mistyped setpoint fails validation"

# T4c — the schema ships a documented DEFAULT for the threshold that AGREES with
# the hook's coded fallback (the 'shipped default' is one number, in two places
# that must not drift). Extract the hook's default and compare.
SCHEMA_DEFAULT=$(jq -r '.properties.occupancy.properties.threshold.default // empty' "$SCHEMA" 2>/dev/null)
HOOK_DEFAULT=$(grep -oE 'DEFAULT_THRESHOLD=[0-9]+' "$HOOK" | head -1 | grep -oE '[0-9]+')
[ -n "$SCHEMA_DEFAULT" ] && [ -n "$HOOK_DEFAULT" ] && [ "$SCHEMA_DEFAULT" = "$HOOK_DEFAULT" ] \
  && ok "schema default ($SCHEMA_DEFAULT) and hook default ($HOOK_DEFAULT) agree (one shipped default, no drift)" \
  || no "the schema-documented default must equal the hook's coded default (schema=$SCHEMA_DEFAULT hook=$HOOK_DEFAULT)"

# ── ACCEPTANCE 5: the cache rationale present VERBATIM in the doc header ──

# T5 — the mechanism's doc header (in the hook itself) carries the rationale line
# byte-for-byte. grep -F so a single altered character fails.
RATIONALE='the context window is a cache over state that lives on disk; the handoff exists so that losing the cache costs nothing'
grep -qF "$RATIONALE" "$HOOK" \
  && ok "the cache rationale line is present verbatim in the hook's doc header" \
  || no "the verbatim cache rationale line must appear in the mechanism's doc header"

# ── DESIGNED-DEGRADATION ROBUSTNESS (Rule 15: select a path, never invent one) ──

# T6 — loop guard: a re-entrant Stop (stop_hook_active=true) exits 0 silently and
# writes NOTHING, even over threshold — a block on the second pass would loop, and
# a second artifact would duplicate the handoff. The fallback rung is a quiet stop.
P=$(mk_project 150000 120000)
OUT=$(feed "$P" true); RC=$?
ART=$(artifact "$P")
[ $RC -eq 0 ] && [ -z "$OUT" ] && [ -z "$ART" ] \
  && ok "stop_hook_active=true -> silent exit 0, no artifact (loop guard)" \
  || no "a re-entrant stop must not re-fire the degradation (rc=$RC out='$OUT' art='$ART')"

# T7 — missing/absent occupancy signal (no transcript file, or no assistant usage
# in it) takes the documented fallback rung: silence, never a fabricated number
# and never a panic. An unreadable signal must not spuriously degrade.
P=$(mk_project 150000 120000)
rm -f "$P/transcript.jsonl"   # signal source gone
OUT=$(feed "$P"); RC=$?
ART=$(artifact "$P")
[ $RC -eq 0 ] && [ -z "$OUT" ] && [ -z "$ART" ] \
  && ok "absent occupancy signal -> silent (no fabricated occupancy, no spurious degradation)" \
  || no "a missing transcript must degrade to silence, not to a false threshold-cross"

# T7b — a transcript with NO assistant-usage entries (only a user line) is also
# 'no signal' -> silent. Distinguishes 'occupancy 0' (would be silent anyway)
# from 'no measurement' both landing on the safe rung.
P=$(mk_project 150000 120000)
jq -nc '{type:"user",message:{content:"hi"}}' > "$P/transcript.jsonl"
OUT=$(feed "$P"); ART=$(artifact "$P")
[ -z "$OUT" ] && [ -z "$ART" ] \
  && ok "transcript with no assistant usage -> silent (no measurement is not a crossing)" \
  || no "an unmeasurable transcript must stay silent"

# ── STOP-CHECK COEXISTENCE + WIRING (preserve the existing Stop hook) ──

# T8 — the meter is a SEPARATE script from stop-check.sh (it does not replace the
# advisory Stop hook; both run on the Stop event).
[ -f "$ROOT/.claude/hooks/stop-check.sh" ] && [ -f "$HOOK" ] && [ "$HOOK" != "$ROOT/.claude/hooks/stop-check.sh" ] \
  && ok "occupancy-meter.sh ships alongside stop-check.sh (the existing Stop hook is preserved)" \
  || no "the meter must be its own hook and not replace stop-check.sh"

# T9 — settings.json wires occupancy-meter.sh on the Stop event (project install
# mode), AND the pre-existing hooks survive: bash-guard, single-writer,
# auto-format, stop-check are all still registered.
OM_WIRED=$(jq -r '.hooks.Stop[]? | select(any(.hooks[]?.command; test("occupancy-meter\\.sh")))' "$SETTINGS" 2>/dev/null)
[ -n "$OM_WIRED" ] \
  && ok "settings.json wires occupancy-meter.sh on the Stop event (project mode)" \
  || no "settings.json Stop must wire occupancy-meter.sh"
for keep in bash-guard single-writer auto-format stop-check; do
  jq -e --arg k "$keep" '[.. | objects | .command? // empty] | any(test($k))' "$SETTINGS" >/dev/null 2>&1 \
    && ok "preserved existing hook: $keep" \
    || no "the existing $keep hook must remain registered in settings.json"
done

# ── MODE-AWARE RECONCILIATION ([16.4]) — which governor owns the wall ──
# The chosen context-wall mode (the [16.2] contextManagement block) decides whether
# the occupancy hard-stop is authoritative. Read LIVE on each Stop. These encode the
# two regression guards the deliverable names: the silent-DEAD-LETTER bug (continue
# mode must not let the meter hard-stop, racing the auto-compaction window) and the
# AMBUSH bug (hard-stop mode must pre-signal at the warn-band, not silently then stop).

# M1 — continue mode: the meter STANDS DOWN above threshold (the dead-letter guard).
# Auto-compaction owns the wall; the meter must NOT hard-stop, or the two race and the
# meter is silently dead-lettered. Occupancy 150000 >> 120000, yet no block, no artifact.
P=$(mk_project 150000 120000); set_mode "$P" continue
OUT=$(feed "$P"); RC=$?; ART=$(artifact "$P")
[ $RC -eq 0 ] && [ -z "$OUT" ] && [ -z "$ART" ] \
  && ok "continue mode: the meter stands down above the setpoint (no hard-stop, no artifact) — the silent-dead-letter bug guarded" \
  || no "continue mode must demote the meter to advisory: no hard-stop above threshold (rc=$RC out='$OUT' art='$ART')"

# M2 — hard-stop mode: the meter is ARMED — crossing the setpoint still hard-stops.
P=$(mk_project 150000 120000); set_mode "$P" hard-stop
OUT=$(feed "$P"); ART=$(artifact "$P")
DEC=$(echo "$OUT" | jq -r '.decision // empty' 2>/dev/null)
[ "$DEC" = "block" ] && [ -n "$ART" ] \
  && ok "hard-stop mode: the meter is armed — crossing the setpoint hard-stops to /handoff (one authoritative threshold)" \
  || no "hard-stop mode must keep the meter armed (dec=$DEC art=$ART)"

# M3 — absent block (grandfather): in the warn-band but below the setpoint → SILENT.
# Format-survival: a pre-feature project's behavior is unchanged — no warn-band (that
# is a hard-stop-MODE feature), hard-stop only at the setpoint. 100000 ≥ 80%·120000.
P=$(mk_project 100000 120000)
OUT=$(feed "$P" false "sess-grand"); ART=$(artifact "$P")
[ -z "$OUT" ] && [ -z "$ART" ] \
  && ok "absent block (grandfather): no warn-band, silent below the setpoint — format-survival, today's behavior unchanged" \
  || no "an absent contextManagement block must not introduce a warn-band (out='$OUT')"

# M4 — unset mode (headless loud-unset): arm NEITHER governor. Above threshold the
# meter stands down — a hard-stop here would be the very ambush the mode choice prevents.
P=$(mk_project 150000 120000); set_mode "$P" unset
OUT=$(feed "$P"); ART=$(artifact "$P")
[ -z "$OUT" ] && [ -z "$ART" ] \
  && ok "unset mode: arm neither — the meter stands down (the UNSET marker is the honest surface, not a surprise hard-stop)" \
  || no "unset mode must arm neither governor (out='$OUT' art='$ART')"

# M5 — hard-stop warn-band: a one-shot approach warning FIRES (the ambush guard, Q4).
# Occupancy 100000 is in [96000,120000): a loud, non-blocking advisory that names the
# wall and /handoff — decision approve (NOT block), no artifact written yet.
P=$(mk_project 100000 120000); set_mode "$P" hard-stop
OUT=$(feed "$P" false "sess-A"); ART=$(artifact "$P")
DEC=$(echo "$OUT" | jq -r '.decision // empty' 2>/dev/null)
SM=$(echo "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null)
# Advisory, NOT a block: a warn-band that blocked would be the ambush in reverse (a
# premature hard-stop at 80%). The signal is decision:"approve" — the codebase's
# non-blocking Stop-advisory convention (stop-check.sh), not a bare omitted decision.
[ "$DEC" = "approve" ] && [ -n "$SM" ] && [ -z "$ART" ] && echo "$SM" | grep -qi 'wall' && echo "$SM" | grep -qi 'handoff' \
  && ok "hard-stop warn-band: a one-shot approach warning fires (decision:approve, names the wall + /handoff, no block) — the ambush bug guarded" \
  || no "the warn-band must fire an advisory (decision:approve) approach warning, not a hard-stop (dec=$DEC art=$ART sm=$SM)"

# M6 — the warn-band fires ONCE per session, then SILENT (a warning, not a live gauge —
# the supervision-era regression rejected by name). Same session_id twice: 1st warns, 2nd silent.
P=$(mk_project 100000 120000); set_mode "$P" hard-stop
OUT1=$(feed "$P" false "sess-B"); OUT2=$(feed "$P" false "sess-B")
[ -n "$OUT1" ] && [ -z "$OUT2" ] \
  && ok "the warn-band warning fires ONCE per session then falls silent (a warning, not a per-turn gauge)" \
  || no "the warn-band must fire once per session, not every Stop (out1='$OUT1' out2='$OUT2')"

# M7 — a NEW session re-warns: the marker is session-scoped, so each fresh approach to
# the wall gets its honest pre-signal (a different session_id warns again).
OUT3=$(feed "$P" false "sess-C")
[ -n "$OUT3" ] \
  && ok "a new session re-warns at the warn-band (the did-fire marker is session-scoped, not once-ever)" \
  || no "a new session must get its own approach warning (out3='$OUT3')"

# M8 — below the warn-band, hard-stop mode is SILENT (no regression to a live gauge).
# 90000 < 96000 (80% of 120000).
P=$(mk_project 90000 120000); set_mode "$P" hard-stop
OUT=$(feed "$P" false "sess-D"); ART=$(artifact "$P")
[ -z "$OUT" ] && [ -z "$ART" ] \
  && ok "below the warn-band: hard-stop mode is silent (no live below-threshold readout)" \
  || no "below the warn-band the meter must stay silent (out='$OUT')"

# M9 — the full ladder: warn-band (warn) → silence → setpoint (hard-stop). The approach
# warning must NOT suppress the eventual hard-stop. Warn once, then occupancy rises past
# the setpoint in the SAME session → the hard-stop still fires.
P=$(mk_project 100000 120000); set_mode "$P" hard-stop
_=$(feed "$P" false "sess-E")          # warns at the warn-band
set_occ "$P" 150000                     # occupancy now crosses the setpoint
OUT=$(feed "$P" false "sess-E"); ART=$(artifact "$P")
DEC=$(echo "$OUT" | jq -r '.decision // empty' 2>/dev/null)
[ "$DEC" = "block" ] && [ -n "$ART" ] \
  && ok "the warn-band warning does not suppress the wall: crossing the setpoint still hard-stops (warn → silence → hard-stop)" \
  || no "after the warn-band warning the setpoint crossing must still hard-stop (dec=$DEC art=$ART)"

# M10 — a PRESENT-but-empty contextManagement block ({}) stands the meter DOWN, just
# as continue/unset do — NOT armed like an absent block. This pins surface-consistency:
# context-management.sh surface shouts "UNSET — neither governor armed" for a present-
# but-empty block; if the meter then hard-stopped, that surface would be a lie. Block
# PRESENCE (not mode value) is the discriminator: present-empty = scaffolded-no-posture
# = stand down; only a truly absent block grandfathers to the armed default.
P=$(mk_project 150000 120000)
MAN="$P/.claude/project.json"; T=$(mktemp); jq '.contextManagement = {}' "$MAN" > "$T" && mv "$T" "$MAN"
OUT=$(feed "$P"); ART=$(artifact "$P")
[ -z "$OUT" ] && [ -z "$ART" ] \
  && ok "present-but-empty contextManagement block: meter stands down (matches surface's UNSET — no armed-default ambush)" \
  || no "a present-but-empty block must stand the meter down, not arm it like an absent block (out='$OUT' art='$ART')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
