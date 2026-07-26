#!/bin/bash
# Tests for .claude/budget-gate.sh — budget setpoints and the escalation path ([9.3]).
#
# Invariant (the tension gate): optional budgets live in project.json at two
# granularities — initiative and session — schema-validated. ABSENT MEANS
# UNLIMITED: a governor with no setpoint spins free, so an absent budget gates
# NOTHING, anywhere. The gate runs at session ENTRY and EXIT, comparing BURN
# (summed from the [9.1] metering log) to the chosen budget, and raises a
# decision gate ON TENSION ONLY — within budget it is SILENT (no green banner,
# no per-session recap). A BREACH pauses and escalates with work PRESERVED and
# surfaces the burn profile; the choice (extend / harvest / kill) is the
# person's. The MACHINERY NEVER RAISES A SETPOINT — a headless breach stays
# paused, loud, state intact (Rule 15: designed degradation, loud stop; the
# machine never improvises a higher ceiling). Budget edits are commits to
# project.json — its history is the provenance — and budgets have NO STORAGE
# outside project.json.
#
# Burn is mechanical, never agent-reported: it is summed from the metering log
# the [9.1] meter appends. The gate's decision is therefore an INPUT-driven,
# unit-testable function exercised here by SYNTHETIC manifest + metering-log
# fixtures, independent of any live session.
#
# These assertions encode WHY (Rule 8): absent gates nothing; a breach pauses +
# preserves + surfaces burn; the gate raises at entry on tension; within budget
# is silent end to end; no code path mutates a budget (grep-asserted); budgets
# have no storage outside project.json; the setpoint is schema-validated.
# Pure bash + jq, no test runner. Stderr-clean for well-formed input (the
# battery fails any suite that writes to stderr).
# Run: bash .claude/tests/budget-gate.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/.claude/budget-gate.sh"
SCHEMA="$ROOT/.claude/project.schema.json"
SS_HOOK="$ROOT/.claude/hooks/session-start.sh"
HANDOFF_SKILL="$ROOT/.claude/skills/handoff/SKILL.md"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Build a throwaway "project" dir: a manifest carrying the given budgets JSON (or
# none — absent means unlimited), and a metering log whose entries sum to the
# given session burn and initiative (cumulative) burn. Burn is expressed in
# tokens — the mechanical evidence the [9.1] log carries (dollars stay null on
# the current rung). Echoes the project dir.
#   mk_project <budgets_json|""> <session_burn> <initiative_extra_burn>
# session_burn lands on entries tagged with the current session; the
# initiative_extra_burn lands on entries from a PRIOR session, so the initiative
# (cumulative) total is session_burn + initiative_extra_burn.
mk_project() {
  local budgets="$1" sburn="$2" iextra="$3"
  local d; d=$(mktemp -d "$WORK/proj.XXXXXX")
  mkdir -p "$d/.claude/metering" "$d/docs/sessions"
  if [ -n "$budgets" ]; then
    jq -nc --argjson b "$budgets" \
      '{name:"x",language:"shell",roots:{control:".",code:"."},commands:{},scaffoldCheck:"true",ceremony:"task",budgets:$b}' \
      > "$d/.claude/project.json"
  else
    jq -nc \
      '{name:"x",language:"shell",roots:{control:".",code:"."},commands:{},scaffoldCheck:"true",ceremony:"task"}' \
      > "$d/.claude/project.json"
  fi
  # A current session artifact (so the gate knows which session is "this one"),
  # and a prior one for the cumulative initiative total.
  printf '# handoff\n' > "$d/docs/sessions/session-2026-06-15-001.md"
  printf '# handoff\n' > "$d/docs/sessions/session-2026-06-14-001.md"
  # Metering log: one prior-session entry carrying iextra burn, one current-
  # session entry carrying sburn. tokens split across classes to prove the gate
  # sums classes, not just input_tokens. Entries carry the post-[13.6]
  # slice_basis:"per_deliverable" — bounded per-session slices, summed directly
  # (the go-forward shape the slice-aware burn reads; [13.5]).
  local h r
  h=$((sburn / 2)); r=$((sburn - sburn / 2))
  {
    jq -nc --argjson t "$iextra" \
      '{schema:"guv.meter.v1",session:"session-2026-06-14-001",deliverable_ids:["9.0"],tokens:{input:$t,output:0,cache_read:0,cache_creation:0},slice_basis:"per_deliverable",perf:{}}'
    jq -nc --argjson a "$h" --argjson b "$r" \
      '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.3"],tokens:{input:$a,output:0,cache_read:$b,cache_creation:0},slice_basis:"per_deliverable",perf:{}}'
  } > "$d/.claude/metering/metering.ndjson"
  echo "$d"
}

# Feed the gate at a phase (entry|exit) for a project dir. Echoes gate stdout;
# the return code is captured by the caller via $?.
#   gate <project_dir> <entry|exit>
gate() {
  local d="$1" phase="$2"
  ( cd "$d" && bash "$GATE" "$phase" ) 2>/dev/null
}

# ── ACCEPTANCE 0: the gate script exists (RED until built) ──
[ -f "$GATE" ] \
  && ok "the tension gate exists at .claude/budget-gate.sh" \
  || no "the tension gate is missing at .claude/budget-gate.sh"

# ── ACCEPTANCE 1: ABSENT BUDGET GATES NOTHING, ANYWHERE (silent, exit 0) ──
# A governor with no setpoint spins free. With NO budgets block, even an enormous
# burn produces no output and exit 0 — at BOTH entry and exit. "Absent means
# unlimited" is the load-bearing default.
P=$(mk_project "" 999999999 999999999)
for ph in entry exit; do
  OUT=$(gate "$P" "$ph"); RC=$?
  [ $RC -eq 0 ] && [ -z "$OUT" ] \
    && ok "absent budget -> gates nothing at $ph (silent, exit 0 — unlimited)" \
    || no "absent budget must gate nothing at $ph (rc=$RC out='$OUT')"
done

# ── ACCEPTANCE 2: WITHIN BUDGET IS SILENT END TO END (no green banner, no recap) ──
# A session well under its setpoint produces NOTHING at entry and NOTHING at exit
# — no green banner, no per-session recap. Silence within budget is the spec.
P=$(mk_project '{"session":{"tokens":100000}}' 10000 0)
for ph in entry exit; do
  OUT=$(gate "$P" "$ph"); RC=$?
  [ $RC -eq 0 ] && [ -z "$OUT" ] \
    && ok "within budget -> silent at $ph (no banner, no recap)" \
    || no "within budget must be silent at $ph (rc=$RC out='$OUT')"
done

# ── ACCEPTANCE 3: A BREACH FIXTURE PAUSES, PRESERVES, AND SURFACES THE BURN ──
# Session burn (150000) over the session budget (100000): the gate must raise the
# decision gate — naming the breach, surfacing the BURN PROFILE (the burn number
# and the budget it crossed), and offering the person's choices (extend / harvest
# / kill). "Pause" + "work preserved" means the gate STOPS for a decision and
# does not mutate anything; it is a loud stop, not a silent pass.
P=$(mk_project '{"session":{"tokens":100000}}' 150000 0)
OUT=$(gate "$P" exit); RC=$?
# 3a — it raises (non-empty, signals a breach / pause, not silence)
[ -n "$OUT" ] \
  && ok "breach -> the gate raises (it is not silent over budget)" \
  || no "a breach must raise the decision gate (out='$OUT')"
# 3b — it surfaces the BURN PROFILE: the burn figure and the budget crossed
echo "$OUT" | grep -q "150000" && echo "$OUT" | grep -q "100000" \
  && ok "breach surfaces the burn profile (burn 150000 vs budget 100000)" \
  || no "the breach must surface the burn profile (burn + budget); got: $OUT"
# 3c — it offers the person's escalation choices: extend / harvest / kill
echo "$OUT" | grep -qi "extend" && echo "$OUT" | grep -qi "harvest" && echo "$OUT" | grep -qi "kill" \
  && ok "breach offers the person's choices (extend / harvest / kill)" \
  || no "the breach must name extend/harvest/kill as the person's decision; got: $OUT"
# 3d — it is a PAUSE/loud stop: the breach exits non-zero (the designed
# degradation that pauses the session for a decision, never a silent exit 0).
[ "$RC" -ne 0 ] \
  && ok "breach exits non-zero (a pause for a decision, not a silent pass)" \
  || no "a breach must pause loudly (non-zero exit), got rc=$RC"
# 3e — work is PRESERVED: the gate touches no project files (the worktree the
# breach pauses over is left byte-identical). Snapshot the project tree before
# and after a breach run — nothing the gate owns may change.
P=$(mk_project '{"session":{"tokens":100000}}' 150000 0)
BEFORE=$(cd "$P" && find . -type f -exec shasum {} \; | sort)
gate "$P" exit >/dev/null 2>&1
AFTER=$(cd "$P" && find . -type f -exec shasum {} \; | sort)
[ "$BEFORE" = "$AFTER" ] \
  && ok "breach preserves work (no project file is modified by the gate)" \
  || no "the gate modified project state on a breach (work must be preserved)"

# ── ACCEPTANCE 4: THE GATE RAISES AT ENTRY ON TENSION (entry, not just exit) ──
# The same breach detected at session ENTRY raises the gate — the gate runs at
# BOTH boundaries, and entry tension (burn already over budget from prior turns)
# is surfaced before more work is done.
P=$(mk_project '{"session":{"tokens":100000}}' 150000 0)
OUT=$(gate "$P" entry); RC=$?
[ -n "$OUT" ] && [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "150000" \
  && ok "tension fixture raises the gate at ENTRY (burn surfaced before more work)" \
  || no "the gate must raise at entry on tension (rc=$RC out='$OUT')"

# ── ACCEPTANCE 5: INITIATIVE GRANULARITY (cumulative burn across the log) ──
# The initiative budget compares CUMULATIVE burn across the whole log, not just
# the current session. A within-session-budget session still breaches the
# initiative budget when the running total crosses it. session=50000 this
# session, prior session 60000 -> initiative total 110000 > initiative budget
# 100000 breaches even though the session budget (huge) is fine.
# (No calibration record in this fixture, so this is the UNWINDOWED degradation
# read; the lineage-windowed initiative read is asserted in its own section below.)
P=$(mk_project '{"initiative":{"tokens":100000},"session":{"tokens":10000000}}' 50000 60000)
OUT=$(gate "$P" exit); RC=$?
[ -n "$OUT" ] && [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "initiative" \
  && ok "initiative budget compares cumulative burn (110000 > 100000 breaches)" \
  || no "the initiative budget must compare cumulative burn across the log (rc=$RC out='$OUT')"
# 5b — and the cumulative total stays within the initiative budget -> silent.
P=$(mk_project '{"initiative":{"tokens":1000000}}' 50000 60000)
OUT=$(gate "$P" exit); RC=$?
[ $RC -eq 0 ] && [ -z "$OUT" ] \
  && ok "cumulative burn under the initiative budget -> silent" \
  || no "an initiative budget with headroom must stay silent (rc=$RC out='$OUT')"

# ── ACCEPTANCE 6: THE MACHINERY NEVER RAISES A SETPOINT (grep-asserted) ──
# No code path may mutate a budget value in project.json. The escalation is the
# PERSON's; the machine improvises no higher ceiling. Asserted across the whole
# .claude tree: nothing writes/edits the budgets block of the manifest.
# 6a — the gate itself never writes the manifest at all.
grep -nE '>[[:space:]]*"?\.?\$?\{?[A-Za-z_]*MANIFEST|sed -i.*budget|jq .*budget.*>[[:space:]]*.*project\.json' "$GATE" 2>/dev/null \
  | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*#' >/dev/null 2>&1 \
  && no "the gate writes/edits the manifest — the machinery must never raise a setpoint" \
  || ok "the gate never writes the manifest (the machinery never raises a setpoint)"
# 6b — no guv code path mutates the budgets block. Scan the .claude tree for any
# write that targets .budgets in a manifest (a sed/jq edit redirected onto
# project.json, or a += / |= on .budgets). The person edits it by hand; no script does.
BUDGET_MUTATORS=$(grep -rlnE 'budget' \
  "$ROOT/.claude/hooks" "$ROOT/.claude/skills" "$ROOT"/.claude/*.sh 2>/dev/null \
  | xargs grep -lE '(sed -i[^|]*budget)|(\.budgets[^|]*\|=)|(\.budgets[^|]*\+=)|(jq[^|]*\.budgets[^|]*>[[:space:]]*[^ ]*project\.json)' 2>/dev/null || true)
[ -z "$BUDGET_MUTATORS" ] \
  && ok "no guv code path mutates a budget value (grep-asserted across .claude)" \
  || no "these paths appear to mutate a budget value: $BUDGET_MUTATORS"

# ── ACCEPTANCE 7: BUDGETS HAVE NO STORAGE OUTSIDE project.json ──
# The only place a budget setpoint is read FROM or written TO is the manifest.
# The gate reads .budgets from project.json and from nothing else (no sidecar
# state file, no dotfile, no env-var setpoint). Asserted on the gate source: it
# references project.json for the setpoint and introduces no other budget store.
grep -qE 'project\.json' "$GATE" \
  && ok "the gate reads the setpoint from project.json" \
  || no "the gate must read the setpoint from project.json"
# no sidecar budget store is read or written (e.g. a .budget / budget-state file)
grep -nE '\.budget[-_.]?(state|store|json|cache|lock)|budget[-_]state' "$GATE" 2>/dev/null \
  | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*#' >/dev/null 2>&1 \
  && no "the gate references a budget store outside project.json (budgets have no other storage)" \
  || ok "the gate introduces no budget storage outside project.json"
# no env-var setpoint either (a budget set via the environment would be a side channel)
grep -nE '\$\{?(GUV_)?BUDGET' "$GATE" 2>/dev/null \
  | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*#' >/dev/null 2>&1 \
  && no "the gate reads a budget from an env var (a side channel — provenance must be project.json history)" \
  || ok "the gate reads no budget from the environment (no side channel)"

# ── ACCEPTANCE 8: THE SETPOINT IS SCHEMA-VALIDATED ──
# project.schema.json declares the budgets block at both granularities, closed
# (additionalProperties:false so a typo'd setpoint is caught), with integer token
# setpoints. The schema being the contract is the testable surface (no in-repo
# jsonschema validator).
BUDG_SCHEMA=$(jq -c '.properties.budgets' "$SCHEMA" 2>/dev/null)
[ -n "$BUDG_SCHEMA" ] && [ "$BUDG_SCHEMA" != "null" ] \
  && ok "schema declares the budgets block (schema-validated)" \
  || no "project.schema.json must declare the budgets block (got=$BUDG_SCHEMA)"
# both granularities present
for g in initiative session; do
  jq -e --arg g "$g" '.properties.budgets.properties[$g]' "$SCHEMA" >/dev/null 2>&1 \
    && ok "schema declares budgets.$g granularity" \
    || no "schema must declare the $g budget granularity"
done
# closed at both levels so a mistyped setpoint fails validation rather than no-ops
AP_TOP=$(jq -r '.properties.budgets.additionalProperties' "$SCHEMA" 2>/dev/null)
[ "$AP_TOP" = "false" ] \
  && ok "budgets object is additionalProperties:false (a typo'd granularity is caught)" \
  || no "the budgets object must close additionalProperties"
for g in initiative session; do
  AP=$(jq -r --arg g "$g" '.properties.budgets.properties[$g].additionalProperties' "$SCHEMA" 2>/dev/null)
  [ "$AP" = "false" ] \
    && ok "budgets.$g is additionalProperties:false (a mistyped setpoint is caught)" \
    || no "budgets.$g must close additionalProperties (got=$AP)"
done
# the token setpoint is a positive integer at both granularities
for g in initiative session; do
  T=$(jq -c --arg g "$g" '.properties.budgets.properties[$g].properties.tokens' "$SCHEMA" 2>/dev/null)
  echo "$T" | jq -e '.type=="integer" or (.type|index("integer"))' >/dev/null 2>&1 \
    && ok "budgets.$g.tokens is an integer setpoint" \
    || no "budgets.$g.tokens must be an integer (got=$T)"
done

# ── ACCEPTANCE 9: PROVENANCE IS project.json HISTORY — NO APPROVAL FLOW ──
# A budget edit is a commit; there is no approval flow and no side channel. The
# gate must not implement an approval/confirmation handshake for a budget edit
# (no "approve"/"confirm raise" path) — the doc header states the provenance.
RATIONALE_PRESENT=$(grep -ciE 'provenance|commit|project\.json history|no approval' "$GATE" 2>/dev/null)
[ "${RATIONALE_PRESENT:-0}" -ge 1 ] \
  && ok "the gate doc names the provenance model (project.json history, no approval flow)" \
  || no "the gate's doc header must state the provenance model (commit history, no approval flow)"

# ── [15.6] NO DANGLING CITATION — the gate cites no doc a fresh install lacks ──
# The gate cited docs/notes/meter-forensics.md, a CONTROL-PLANE-ONLY forensic doc a
# fresh code-repo install does NOT have — so the path citation dangles (a reader
# following it hits nothing). [15.6] requires the citation to stop dangling: either the
# doc ships in this repo, or the citation is reworded so it does not imply a non-shipped
# file. Install-agnostic check: the gate source must not carry the path unless the file
# actually ships here.
FORENSIC_DOC="$ROOT/docs/notes/meter-forensics.md"
if [ -f "$FORENSIC_DOC" ]; then
  ok "[15.6] the forensic doc ships in this repo (docs/notes/meter-forensics.md) — a path citation resolves"
else
  grep -nE 'docs/notes/meter-forensics\.md' "$GATE" >/dev/null 2>&1 \
    && no "[15.6] the gate cites docs/notes/meter-forensics.md but that file does NOT ship — the citation dangles (reword or ship the doc)" \
    || ok "[15.6] no dangling docs/notes/meter-forensics.md path citation in the gate (it does not imply a non-shipped file)"
fi
# positive control: the grep WOULD fire on a planted path line (not a dead regex).
printf 'see docs/notes/meter-forensics.md for detail\n' | grep -qE 'docs/notes/meter-forensics\.md' \
  && ok "[15.6] (positive control) the dangling-path grep catches a planted meter-forensics.md path" \
  || no "[15.6] the dangling-path grep is dead — it would pass even with a dangling citation present"

# ── DEGRADATION ROBUSTNESS (Rule 15: select a path, never invent one) ──
# A budget set but NO metering log yet (a fresh project): burn is 0, so the gate
# is silent (0 is within any positive budget). A missing log is not a breach and
# not a fabricated number.
P=$(mk_project '{"session":{"tokens":100000}}' 10000 0)
rm -f "$P/.claude/metering/metering.ndjson"
OUT=$(gate "$P" exit); RC=$?
[ $RC -eq 0 ] && [ -z "$OUT" ] \
  && ok "budget set, no metering log -> silent (burn 0, not a fabricated breach)" \
  || no "a missing metering log must degrade to silence (burn 0), got rc=$RC out='$OUT'"

# An unknown phase argument is a caller bug (loud usage error), not a route the
# gate invents (Rule 15: failure selects a path, never invents one).
P=$(mk_project '{"session":{"tokens":100000}}' 10000 0)
( cd "$P" && bash "$GATE" bogus-phase ) >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] \
  && ok "an unknown phase is a loud usage error (no invented route)" \
  || no "an unknown phase must be a loud usage error, got rc=$RC"

# A degraded metering entry (tokens:null) contributes 0 — a missing measurement is
# never a fabricated breach (the line-46 Rule-15 claim). A within-budget current
# burn plus one tokens:null entry must stay SILENT: the null entry adds nothing, so
# no breach is fabricated from a measurement that was never taken.
P=$(mk_project '{"session":{"tokens":100000}}' 10000 0)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.3"],tokens:null,perf:{}}' \
  >> "$P/.claude/metering/metering.ndjson"
OUT=$(gate "$P" exit); RC=$?
[ $RC -eq 0 ] && [ -z "$OUT" ] \
  && ok "a tokens:null metering entry contributes 0 (no fabricated breach — line-46 Rule 15)" \
  || no "a tokens:null entry must contribute 0, not fabricate a breach (rc=$RC out='$OUT')"

# ── ACCEPTANCE 10: THE TENSION GATE IS WIRED INTO BOTH SESSION BOUNDARIES ──
# The deliverable is "the tension gate runs at session entry and exit." A gate
# that no boundary invokes is an UNBACKED-INTEGRATION claim (Rule 9/10) — the doc
# header would describe an integration that does not exist. So both boundary
# surfaces — the SessionStart hook (ENTRY) and the session-close path the handoff
# skill drives (EXIT) — must actually invoke budget-gate.sh at their phase. These
# are the real wiring surfaces ([9.1]'s meter rides the same two boundaries), and
# both are in the lane footprint (NOT join-protected, NOT settings.json).
#
# 10a — ENTRY: the SessionStart hook invokes the gate at the entry phase.
[ -f "$SS_HOOK" ] \
  && ok "the SessionStart hook exists at .claude/hooks/session-start.sh" \
  || no "the SessionStart hook is missing at .claude/hooks/session-start.sh"
grep -qE 'budget-gate\.sh.*entry' "$SS_HOOK" 2>/dev/null \
  && ok "the SessionStart hook invokes budget-gate.sh at the ENTRY boundary" \
  || no "the gate is NOT wired at session entry (the header's entry claim is unbacked)"
# 10b — a SessionStart hook MUST NOT block the session: a budget-gate breach
# exits 3, but the hook must still exit 0 (a non-zero SessionStart exit blocks the
# session from starting). The breach must be SURFACED as context, never
# propagated as a blocking exit. We exercise the live hook over a BREACH fixture:
# the breach text is surfaced, and the hook still exits 0.
mk_hook_proj() {  # a fixture whose .claude symlinks the real hook + gate siblings
  local budgets="$1" sburn="$2" d
  d=$(mktemp -d "$WORK/hookproj.XXXXXX")
  mkdir -p "$d/.claude/hooks" "$d/.claude/metering" "$d/docs/sessions"
  ln -s "$GATE"                          "$d/.claude/budget-gate.sh"
  ln -s "$ROOT/.claude/route.sh"         "$d/.claude/route.sh"
  ln -s "$ROOT/.claude/resolve-ready.sh" "$d/.claude/resolve-ready.sh"
  ln -s "$SS_HOOK"                       "$d/.claude/hooks/session-start.sh"
  jq -nc --argjson b "$budgets" \
    '{name:"x",language:"shell",roots:{control:".",code:"."},commands:{},scaffoldCheck:"true",ceremony:"task",budgets:$b}' \
    > "$d/.claude/project.json"
  printf '# handoff\n' > "$d/docs/sessions/session-2026-06-15-001.md"
  jq -nc --argjson a "$sburn" \
    '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.3"],tokens:{input:$a,output:0,cache_read:0,cache_creation:0},perf:{}}' \
    > "$d/.claude/metering/metering.ndjson"
  echo "$d"
}
HP=$(mk_hook_proj '{"session":{"tokens":100000}}' 150000)
HERR=$(mktemp)
HOUT=$( cd "$HP" && printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' \
        | bash .claude/hooks/session-start.sh 2>"$HERR" ); HRC=$?
HE=$(cat "$HERR"); rm -f "$HERR"
[ "$HRC" -eq 0 ] \
  && ok "a budget breach at entry does NOT block the session (hook exits 0)" \
  || no "the SessionStart hook must exit 0 over a breach (got rc=$HRC) — a non-zero exit BLOCKS the session"
echo "$HOUT" | grep -q '150000' \
  && ok "the entry breach is SURFACED as session-open context (burn 150000 visible)" \
  || no "the entry breach must be surfaced as context, not swallowed (out='$HOUT')"
[ -z "$HE" ] \
  && ok "the entry-gate wiring is stderr-clean (no leaked gate stderr)" \
  || no "the entry-gate wiring must be stderr-clean, got: $HE"
# 10c — within budget at entry: the gate stays silent, the hook still surfaces its
# normal route/frontier context and exits 0 (the gate adds nothing when silent).
HP2=$(mk_hook_proj '{"session":{"tokens":100000}}' 10000)
HOUT2=$( cd "$HP2" && printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' \
         | bash .claude/hooks/session-start.sh 2>/dev/null ); HRC2=$?
[ "$HRC2" -eq 0 ] && { [ -z "$HOUT2" ] || ! echo "$HOUT2" | grep -qi 'breach'; } \
  && ok "within budget at entry: the gate is silent (no breach surfaced), hook exits 0" \
  || no "within budget the entry gate must add no breach context (rc=$HRC2 out='$HOUT2')"

# 10d — EXIT: the session-close path the handoff skill drives invokes the gate at
# the exit phase. The handoff SKILL.md is the documented session-close path (it is
# where [9.1]'s meter.sh capture already runs); the exit gate rides the same path.
[ -f "$HANDOFF_SKILL" ] \
  && ok "the handoff skill exists (the session-close path)" \
  || no "the handoff skill is missing at .claude/skills/handoff/SKILL.md"
grep -qE 'budget-gate\.sh.*exit' "$HANDOFF_SKILL" 2>/dev/null \
  && ok "the session-close path (handoff skill) invokes budget-gate.sh at the EXIT boundary" \
  || no "the gate is NOT wired at session exit (the header's exit claim is unbacked)"

# ════════════════════════════════════════════════════════════════════════════
# [13.5] BUDGET-GATE READS THE PROJECTION — tension on the FORECAST, not just burn
# ════════════════════════════════════════════════════════════════════════════
# A project carrying the projection's inputs (tracker + estimate sidecar), so the
# gate's [13.5] foreseen check has a LIVE projection to read. Burn lands as a bounded
# per-session slice. The caller sets the budget AFTER reading the projection's
# cost-to-complete, so the assertions are robust to the [13.3] rate constants.
#   mk_proj <session_burn>  -> echoes the dir (no budget set yet)
mk_proj() {
  local sburn="$1"
  local d; d=$(mktemp -d "$WORK/pj.XXXXXX")
  mkdir -p "$d/.claude/metering" "$d/.claude/rules" "$d/docs/sessions"
  jq -nc '{name:"x",language:"shell",roots:{control:".",code:"."},commands:{},scaffoldCheck:"true",ceremony:"phased"}' > "$d/.claude/project.json"
  printf '# handoff\n' > "$d/docs/sessions/session-2026-06-15-001.md"
  # a realistic floor so the projection's structural rate is stable
  head -c 24000 /dev/zero | tr '\0' 'x' > "$d/CLAUDE.md"
  head -c 16000 /dev/zero | tr '\0' 'y' > "$d/.claude/rules/guv-core.md"
  cat > "$d/docs/PHASE_STATUS.md" <<'MD'
# Phase Status Tracker

> **Current Phase: 13 — Operationalize**

## Phase 13 — Operationalize

- ✅ **[13.1]** done `[deps: none]`
- ⬜ **[13.4]** open `[deps: none]`
- ⬜ **[13.5]** open `[deps: none]`
MD
  bash "$ROOT/.claude/estimate.sh" set 13.4 1 "$d/docs/estimates.json" >/dev/null 2>&1
  bash "$ROOT/.claude/estimate.sh" set 13.5 1 "$d/docs/estimates.json" >/dev/null 2>&1
  jq -nc --argjson t "$sburn" \
    '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["13.4"],tokens:{input:$t,output:0,cache_read:0,cache_creation:0},slice_basis:"per_deliverable",perf:{}}' \
    > "$d/.claude/metering/metering.ndjson"
  echo "$d"
}
set_init_budget() { jq --argjson b "$2" '.budgets = {initiative:{tokens:$b}}' "$1/.claude/project.json" > "$1/.b" && mv "$1/.b" "$1/.claude/project.json"; }
# the projection's central cost-to-complete = remaining_sessions × blended rate
proj_ctc() { ( cd "$1" && bash "$ROOT/.claude/projection.sh" project 2>/dev/null ) | jq -r '(.spine.quantity.remaining_sessions // 0) * (.spine.unit_rate.blended_tokens // 0)'; }

# ── FORESEEN BREACH: projected cost-to-complete + burn exceeds the setpoint ──
# burn-to-date alone is WITHIN budget (no actual breach), but burn + projected
# cost-to-complete would exceed the initiative setpoint. The gate must DECLARE the
# foreseen breach loudly — and NOT stop (exit 0): a deliverable-budget breach is
# fuzzy (the projection is a range), a signal for a human at the boundary, never a
# mid-flight hard stop.
PF=$(mk_proj 10000000)                       # 10M burn-to-date (bounded slice)
CTC=$(proj_ctc "$PF")
set_init_budget "$PF" $(( 10000000 + CTC / 2 ))   # burn(10M) < budget < burn+CTC
FOUT=$(gate "$PF" exit); FRC=$?
echo "$FOUT" | grep -qi 'foreseen' \
  && ok "[13.5] FORESEEN: the gate declares the projected breach (burn + cost-to-complete > setpoint)" \
  || no "[13.5] the gate must declare a foreseen breach (out='$FOUT')"
[ "$FRC" -eq 0 ] \
  && ok "[13.5] FORESEEN is a DECLARATION, not a stop (exit 0 — never a mid-flight hard stop)" \
  || no "[13.5] a foreseen breach must NOT stop the session (exit 0); got rc=$FRC"
# the declaration carries the burn + the projection so a human can decide
echo "$FOUT" | grep -q "10000000" \
  && ok "[13.5] FORESEEN surfaces burn-to-date and the projection (the human's decision inputs)" \
  || no "[13.5] the foreseen declaration must surface the burn + projection (out='$FOUT')"

# ── [15.6] FORESEEN (a SIGNAL, exit 0) and BREACH (a STOP, exit 3) are
# ── DISTINGUISHABLE ON THEIR FIRST WORDS ──
# A person skimming the gate's output must tell a SIGNAL (foreseen overrun, exit 0,
# session continues) from a STOP (actual-burn breach, exit 3, the loud pause) by the
# first words of the header alone — not by reading to the end of the line. The bug
# this kills: both headers led with "[budget-gate] ... BREACH ...", so the leading
# word a skim catches was identical for the signal and the stop. The fix renames the
# FORESEEN header so its first significant word DIFFERS from the BREACH header's, and
# the word "BREACH" no longer appears in the signal (it is reserved for the stop).
#   first_words = the header line's words AFTER the [budget-gate] tag (the part a
#   person's eye lands on); compared between the two outputs.
header_words() {  # <gate output> -> the first header line's words after "[budget-gate]"
  printf '%s\n' "$1" | grep -m1 '^\[budget-gate\]' | sed -E 's/^\[budget-gate\][[:space:]]*//'
}
# An ACTUAL-burn breach fixture (exit 3) to compare against the FORESEEN signal (exit 0).
PB6=$(mk_project '{"session":{"tokens":100000}}' 150000 0)
BOUT6=$(gate "$PB6" exit); BRC6=$?
F_WORDS=$(header_words "$FOUT")     # the FORESEEN signal's leading words
B_WORDS=$(header_words "$BOUT6")    # the actual BREACH stop's leading words
# (c1) the two headers' leading words differ — a skim distinguishes signal from stop.
[ -n "$F_WORDS" ] && [ -n "$B_WORDS" ] && [ "$F_WORDS" != "$B_WORDS" ] \
  && ok "[15.6] FORESEEN and BREACH headers differ on their first words (signal vs stop, skimmable)" \
  || no "[15.6] the FORESEEN and BREACH headers must differ on their first words (foreseen='$F_WORDS' breach='$B_WORDS')"
# (c2) the FIRST word after [budget-gate] is distinct between the two (the eye's anchor).
F_FIRST=$(printf '%s' "$F_WORDS" | awk '{print $1}')
B_FIRST=$(printf '%s' "$B_WORDS" | awk '{print $1}')
[ -n "$F_FIRST" ] && [ -n "$B_FIRST" ] && [ "$F_FIRST" != "$B_FIRST" ] \
  && ok "[15.6] the FIRST word of each header differs (FORESEEN='$F_FIRST' vs BREACH='$B_FIRST')" \
  || no "[15.6] the first header word must differ between signal and stop (foreseen='$F_FIRST' breach='$B_FIRST')"
# (c3) the word "BREACH" is the STOP's alone — the signal's header line does not carry
# it AT ALL, so "BREACH" in the gate output unambiguously means the exit-3 hard stop.
# (This is the load-bearing distinction: the pre-[15.6] header read "FORESEEN BREACH",
# so a skim of the word "BREACH" could not tell the signal from the stop.)
printf '%s\n' "$F_WORDS" | grep -qi 'breach' \
  && no "[15.6] the FORESEEN signal header must NOT contain BREACH (reserved for the exit-3 stop); got '$F_WORDS'" \
  || ok "[15.6] BREACH names the STOP header alone; the FORESEEN signal header omits it"
# (c3b) and the STOP header DOES still carry BREACH (the word keeps its hard-stop meaning).
printf '%s\n' "$B_WORDS" | grep -qi 'breach' \
  && ok "[15.6] the actual-burn STOP header still leads with BREACH (its hard-stop meaning is preserved)" \
  || no "[15.6] the actual-burn breach header must still name BREACH (got '$B_WORDS')"
# (c4) the exits remain coupled to the kind: FORESEEN exits 0 (signal), BREACH exits 3 (stop).
{ [ "$FRC" -eq 0 ] && [ "$BRC6" -eq 3 ]; } \
  && ok "[15.6] the exit codes still pair with the headers (FORESEEN exit 0 signal, BREACH exit 3 stop)" \
  || no "[15.6] FORESEEN must exit 0 and BREACH exit 3 (foreseen rc=$FRC breach rc=$BRC6)"

# ── WITHIN BUDGET (even projected): silent ──
PW=$(mk_proj 10000000); CTCW=$(proj_ctc "$PW")
set_init_budget "$PW" $(( 10000000 + CTCW * 3 ))   # setpoint far above burn + CTC
WOUT=$(gate "$PW" exit); WRC=$?
[ "$WRC" -eq 0 ] && [ -z "$WOUT" ] \
  && ok "[13.5] within budget (even projected): silent (no foreseen banner, exit 0)" \
  || no "[13.5] within projected budget must be silent (rc=$WRC out='$WOUT')"

# ── NEVER AUTO-RAISES on a foreseen breach (the manifest is byte-identical) ──
PR=$(mk_proj 10000000); CTCR=$(proj_ctc "$PR"); set_init_budget "$PR" $(( 10000000 + CTCR / 2 ))
PRE=$(cd "$PR" && shasum .claude/project.json)
gate "$PR" exit >/dev/null 2>&1
POST=$(cd "$PR" && shasum .claude/project.json)
[ "$PRE" = "$POST" ] \
  && ok "[13.5] a foreseen breach raises NO setpoint (manifest byte-identical after the gate)" \
  || no "[13.5] the gate must never mutate the budget on a foreseen breach"

# ── DEGRADES when no projection is available (no tracker) ──
# A budget but NO tracker -> no projection to read; the foreseen check degrades
# silently to burn-only (no crash, no fabricated breach; Rule 15). Burn << budget.
PD=$(mk_project '{"initiative":{"tokens":100000000}}' 10000 0)   # no tracker
DOUT=$(gate "$PD" exit); DRC=$?
[ "$DRC" -eq 0 ] && [ -z "$DOUT" ] \
  && ok "[13.5] absent projection -> foreseen check degrades silently to burn-only (no crash)" \
  || no "[13.5] absent projection must degrade to burn-only silently (rc=$DRC out='$DOUT')"

# ── SLICE-AWARE burn: legacy cumulative entries are DIFFERENCED, not raw-summed ──
# [13.6] made entries bounded per-session slices; legacy (pre-[13.6]) entries are
# cumulative running totals, migrated to per-session deltas at read time. budget-gate
# (disclosed in [13.6] as not-yet-slice-aware) must read burn the same way: a session
# whose legacy cumulatives are 40000 then 100000 has burn 100000 (deltas 40000+60000),
# NOT the raw sum 140000. With a 120000 session budget the slice-aware burn (100000) is
# WITHIN -> silent; a raw sum (140000) would falsely breach.
SL=$(mk_project '{"session":{"tokens":120000}}' 0 0)
cat > "$SL/.claude/metering/metering.ndjson" <<'NDJSON'
{"schema":"guv.meter.v1","session":"session-2026-06-15-001","runtime_session":"rs1","deliverable_ids":["9.3"],"tokens":{"input":40000,"output":0,"cache_read":0,"cache_creation":0},"perf":{}}
{"schema":"guv.meter.v1","session":"session-2026-06-15-001","runtime_session":"rs1","deliverable_ids":["9.3"],"tokens":{"input":100000,"output":0,"cache_read":0,"cache_creation":0},"perf":{}}
NDJSON
SLOUT=$(gate "$SL" exit); SLRC=$?
[ "$SLRC" -eq 0 ] && [ -z "$SLOUT" ] \
  && ok "[13.5] slice-aware: legacy cumulatives are differenced (burn 100000, not raw 140000) -> within 120000, silent" \
  || no "[13.5] burn must difference legacy cumulatives, not raw-sum them (rc=$SLRC out='$SLOUT')"

# ── SLICE-AWARE burn: unbounded_cumulative entries are EXCLUDED ──
# A slice_basis:"unbounded_cumulative" entry (the [13.6] disclosed degradation) is NOT
# a per-session slice and must not count toward burn — else one cumulative snapshot
# fabricates a breach. A 10000 bounded slice + a 999999999 unbounded entry has burn
# 10000 (within a 100000 budget) -> silent; counting the unbounded entry would breach.
UB=$(mk_project '{"session":{"tokens":100000}}' 0 0)
cat > "$UB/.claude/metering/metering.ndjson" <<'NDJSON'
{"schema":"guv.meter.v1","session":"session-2026-06-15-001","deliverable_ids":["9.3"],"tokens":{"input":10000,"output":0,"cache_read":0,"cache_creation":0},"slice_basis":"per_deliverable","perf":{}}
{"schema":"guv.meter.v1","session":"session-2026-06-15-001","runtime_session":"rs2","deliverable_ids":["9.3"],"tokens":{"input":999999999,"output":0,"cache_read":0,"cache_creation":0},"slice_basis":"unbounded_cumulative","perf":{}}
NDJSON
UBOUT=$(gate "$UB" exit); UBRC=$?
[ "$UBRC" -eq 0 ] && [ -z "$UBOUT" ] \
  && ok "[13.5] slice-aware: unbounded_cumulative entries are excluded from burn (no fabricated breach)" \
  || no "[13.5] unbounded_cumulative must not count toward burn (rc=$UBRC out='$UBOUT')"

# ── SLICE-AWARE burn: a legacy runtime_session SPANNING sessions differences correctly ──
# The SESSION-scoped read must difference legacy cumulatives over the FULL series and
# THEN keep the current session's deltas — NOT filter by session first (which drops the
# baseline, so the first survivor counts its FULL cumulative, reintroducing the ~4.6×
# inflation the migration killed — observed on the live log at ~21.6×). rs1 spans a
# PRIOR session (cumulative 40000) and the CURRENT session (cumulative 100000); the
# current session's burn is the DELTA 60000, not the raw 100000. With an 80000 session
# budget, 60000 is within -> silent; the baseline-loss bug computes 100000 and breaches.
XS=$(mk_project '{"session":{"tokens":80000}}' 0 0)
cat > "$XS/.claude/metering/metering.ndjson" <<'NDJSON'
{"schema":"guv.meter.v1","session":"session-2026-06-14-001","runtime_session":"rs1","deliverable_ids":["9.3"],"tokens":{"input":40000,"output":0,"cache_read":0,"cache_creation":0},"perf":{}}
{"schema":"guv.meter.v1","session":"session-2026-06-15-001","runtime_session":"rs1","deliverable_ids":["9.3"],"tokens":{"input":100000,"output":0,"cache_read":0,"cache_creation":0},"perf":{}}
NDJSON
XSOUT=$(gate "$XS" exit); XSRC=$?
[ "$XSRC" -eq 0 ] && [ -z "$XSOUT" ] \
  && ok "[13.5] slice-aware: a cross-session legacy runtime_session differences over the FULL series (current burn 60000, not raw 100000) -> within 80000, silent" \
  || no "[13.5] cross-session legacy must difference full-series then filter (baseline-loss inflates SESSION_BURN); rc=$XSRC out='$XSOUT'"

# ── the handoff RECORDS a foreseen overrun (the acceptance: declared in the handoff) ──
# A foreseen overrun exits 0 (no stop), so it reaches the written record only if the
# session-close path captures it — like the [13.6] balloon. The handoff skill must
# document recording the gate's FORESEEN line — by the SAME header string the gate
# emits ([15.6]: the header was renamed away from "FORESEEN BREACH" so a skim
# distinguishes the signal from the exit-3 stop; the handoff's grep target moves in
# lockstep with the gate's header, or the documented call-site would dangle).
grep -qi 'FORESEEN OVERRUN' "$HANDOFF_SKILL" 2>/dev/null \
  && ok "[15.6] the handoff skill records a FORESEEN OVERRUN declaration (the call-site tracks the renamed gate header)" \
  || no "[15.6] the handoff must capture the gate's FORESEEN OVERRUN declaration by its renamed header (acceptance: declared in the session handoff)"

# ════════════════════════════════════════════════════════════════════════════
# [9.3]/[13.4] THE INITIATIVE BURN IS WINDOWED TO THE LIVE LINEAGE
# ════════════════════════════════════════════════════════════════════════════
# The initiative setpoint governs the LIVE initiative, not the whole record: a
# mature log carries every prior initiative's burn, so an unwindowed cumulative
# sum breaches any correctly forecast-derived budget the moment it is set (the
# observed failure: at an initiative open, all-time burn 5.47B spuriously
# breached a fresh forecast+15% setpoint of 4.74B with ~0 actually burned — and
# a headless run stays paused on it). The calibration record's lifecycle entries
# mark the boundary the gate reads: the live window opens at the initiative's
# opening `--at plan` forecast; a `grade` line is an initiative CLOSE, so after
# a grade with no new plan bank (between initiatives) the window opens at the
# grade; phase-boundary banks are mid-initiative snapshots and must NOT move the
# window. With NO lifecycle entry to read (pre-[13.4] record, or no calibration
# record at all) the sum degrades to the whole-log cumulative — the pre-window
# behavior, preserved as the designed degradation (Rule 15), asserted below so
# it cannot drift silently. This is the same lineage read projection.sh's
# bank-dedup slices by, and the same post-bank ts bound its close-time grade
# puts on outcomes.
#   mk_lineage <budgets_json> <hist_burn> <live_burn> — hist entry stamped
#   2026-06-01 (before every lineage stamp below), live entry 2026-06-15 (after).
mk_lineage() {
  local budgets="$1" hburn="$2" lburn="$3"
  local d; d=$(mktemp -d "$WORK/lin.XXXXXX")
  mkdir -p "$d/.claude/metering" "$d/docs/sessions"
  jq -nc --argjson b "$budgets" \
    '{name:"x",language:"shell",roots:{control:".",code:"."},commands:{},scaffoldCheck:"true",ceremony:"task",budgets:$b}' \
    > "$d/.claude/project.json"
  printf '# handoff\n' > "$d/docs/sessions/session-2026-06-15-001.md"
  {
    jq -nc --argjson t "$hburn" \
      '{schema:"guv.meter.v1",ts:"2026-06-01T00:00:00Z",session:"session-2026-06-01-001",deliverable_ids:["9.0"],tokens:{input:$t,output:0,cache_read:0,cache_creation:0},slice_basis:"per_deliverable",perf:{}}'
    jq -nc --argjson t "$lburn" \
      '{schema:"guv.meter.v1",ts:"2026-06-15T00:00:00Z",session:"session-2026-06-15-001",deliverable_ids:["24.1"],tokens:{input:$t,output:0,cache_read:0,cache_creation:0},slice_basis:"per_deliverable",perf:{}}'
  } > "$d/.claude/metering/metering.ndjson"
  echo "$d"
}
# minimal lifecycle lines — the gate reads only kind/boundary/banked_at
plan_bank()  { printf '{"schema":"guv.projection.v1","kind":"forecast","boundary":"plan","banked_at":"%s"}\n' "$1"; }
phase_bank() { printf '{"schema":"guv.projection.v1","kind":"forecast","boundary":"phase-25","banked_at":"%s"}\n' "$1"; }
grade_line() { printf '{"schema":"guv.projection.grade.v1","kind":"grade","banked_at":"%s"}\n' "$1"; }
# the windowed burn figure the breach profile surfaced (empty if no profile line)
profile_burn() { printf '%s\n' "$1" | sed -n 's/.*initiative burn:[[:space:]]*\([0-9][0-9]*\) tokens.*/\1/p' | head -1; }

# ── W1 (the observed spurious breach): history dwarfs the budget, live burn is
# tiny -> SILENT. A prior initiative's 5M is walled off by the plan bank; the
# live window holds 10000 against a 100000 setpoint — no tension, no gate.
WP1=$(mk_lineage '{"initiative":{"tokens":100000}}' 5000000 10000)
{ grade_line "2026-06-10T00:00:00Z"; plan_bank "2026-06-12T00:00:00Z"; } > "$WP1/.claude/metering/calibration.ndjson"
W1OUT=$(gate "$WP1" entry); W1RC=$?
[ "$W1RC" -eq 0 ] && [ -z "$W1OUT" ] \
  && ok "[13.4] windowed: a prior initiative's burn cannot breach a fresh setpoint (live 10000 < 100000 -> silent)" \
  || no "[13.4] the initiative burn must be windowed to the live lineage, not all-time (rc=$W1RC out='$W1OUT')"

# ── W2: the gate still gates INSIDE the window — live burn 150000 over the
# 100000 setpoint breaches (exit 3), and the profile surfaces the WINDOWED
# figure (150000), not the all-time total (5150000). Windowing must not soften
# a real overrun of the live initiative.
WP2=$(mk_lineage '{"initiative":{"tokens":100000}}' 5000000 150000)
{ grade_line "2026-06-10T00:00:00Z"; plan_bank "2026-06-12T00:00:00Z"; } > "$WP2/.claude/metering/calibration.ndjson"
W2OUT=$(gate "$WP2" exit); W2RC=$?
[ "$W2RC" -eq 3 ] && echo "$W2OUT" | grep -qi "initiative" \
  && ok "[13.4] windowed: a live-initiative overrun still breaches (150000 >= 100000, exit 3)" \
  || no "[13.4] windowing must not swallow a real live-window breach (rc=$W2RC out='$W2OUT')"
W2BURN=$(profile_burn "$W2OUT")
[ "$W2BURN" = "150000" ] \
  && ok "[13.4] the breach profile surfaces the WINDOWED burn (150000, not the all-time 5150000)" \
  || no "[13.4] the profile must carry the windowed figure 150000, got '${W2BURN:-none}'"
# the profile NAMES its window basis — a windowed figure and a degraded
# cumulative figure are different claims, and the extend/harvest/kill decision
# is made from this output alone.
echo "$W2OUT" | grep -q 'burn window:.*since the lineage boundary 2026-06-12T00:00:00Z' \
  && ok "[13.4] the breach profile names its window basis (since the plan bank)" \
  || no "[13.4] an initiative breach must disclose the window basis in the profile (out='$W2OUT')"

# ── W3: BETWEEN initiatives (a grade with no new plan bank) the window opens at
# the grade — a still-set setpoint gates burn-since-close, not the closed
# initiative's history. Closed history 5M, since-close burn 10000 < 100000 -> silent.
WP3=$(mk_lineage '{"initiative":{"tokens":100000}}' 5000000 10000)
{ plan_bank "2026-05-01T00:00:00Z"; grade_line "2026-06-10T00:00:00Z"; } > "$WP3/.claude/metering/calibration.ndjson"
W3OUT=$(gate "$WP3" entry); W3RC=$?
[ "$W3RC" -eq 0 ] && [ -z "$W3OUT" ] \
  && ok "[13.4] between initiatives the window opens at the grade (since-close 10000 < 100000 -> silent)" \
  || no "[13.4] a closed initiative's history must not breach a stale setpoint between initiatives (rc=$W3RC out='$W3OUT')"

# ── W4 (the designed degradation, Rule 15): NO calibration record -> the read
# degrades to the whole-log cumulative, exactly the pre-window behavior. 60000
# prior + 50000 live = 110000 >= 100000 -> breach. Asserted so the degradation
# cannot drift silently into "no lineage means no gating".
WP4=$(mk_lineage '{"initiative":{"tokens":100000}}' 60000 50000)
W4OUT=$(gate "$WP4" exit); W4RC=$?
[ "$W4RC" -eq 3 ] && echo "$W4OUT" | grep -qi "initiative" \
  && ok "[13.4] no calibration record -> cumulative degradation preserved (110000 >= 100000 breaches)" \
  || no "[13.4] absent lineage must degrade to the cumulative read, not to unlimited (rc=$W4RC out='$W4OUT')"
# a DEGRADED breach discloses its whole-log basis — on a mature record the
# degraded read is exactly the spurious-breach shape, so the person at the
# pause must be able to see the figure is unwindowed.
echo "$W4OUT" | grep -qi 'burn window:.*whole metering log' \
  && ok "[13.4] a degraded (cumulative) breach discloses its whole-log basis in the profile" \
  || no "[13.4] the degraded read must name its whole-log basis (out='$W4OUT')"

# ── W5: PHASE banks never move the window. Lineage: grade, plan (06-12T00), then
# a phase-25 bank (06-13). Burn after plan: 80000 (06-12T12 — BETWEEN the plan
# bank and the phase bank) + 30000 (06-15) = 110000 >= 100000 -> breach with the
# plan-anchored figure. The 80000 entry's stamp is the discriminator: an
# implementation that anchored on the LAST forecast (the phase bank, 06-13)
# would exclude it, see only 30000, and stay silent — the phase snapshot is
# mid-initiative, not an opening.
WP5=$(mk_lineage '{"initiative":{"tokens":100000}}' 5000000 30000)
cat > "$WP5/.claude/metering/metering.ndjson" <<'NDJSON'
{"schema":"guv.meter.v1","ts":"2026-06-01T00:00:00Z","session":"session-2026-06-01-001","deliverable_ids":["9.0"],"tokens":{"input":5000000,"output":0,"cache_read":0,"cache_creation":0},"slice_basis":"per_deliverable","perf":{}}
{"schema":"guv.meter.v1","ts":"2026-06-12T12:00:00Z","session":"session-2026-06-12-002","deliverable_ids":["24.1"],"tokens":{"input":80000,"output":0,"cache_read":0,"cache_creation":0},"slice_basis":"per_deliverable","perf":{}}
{"schema":"guv.meter.v1","ts":"2026-06-15T00:00:00Z","session":"session-2026-06-15-001","deliverable_ids":["24.1"],"tokens":{"input":30000,"output":0,"cache_read":0,"cache_creation":0},"slice_basis":"per_deliverable","perf":{}}
NDJSON
{ grade_line "2026-06-10T00:00:00Z"; plan_bank "2026-06-12T00:00:00Z"; phase_bank "2026-06-13T00:00:00Z"; } > "$WP5/.claude/metering/calibration.ndjson"
W5OUT=$(gate "$WP5" exit); W5RC=$?
W5BURN=$(profile_burn "$W5OUT")
[ "$W5RC" -eq 3 ] && [ "$W5BURN" = "110000" ] \
  && ok "[13.4] a phase-boundary bank does not move the window (plan-anchored burn 110000 breaches)" \
  || no "[13.4] the window must anchor on the plan bank, not the last forecast (rc=$W5RC burn='${W5BURN:-none}')"

# ── W6: the [13.5] FORESEEN check reads the WINDOWED burn — burn-to-date in the
# declaration is the live initiative's (10000000), not history-inflated
# (17000000). Pre-fix, the foreseen total double-counted closed initiatives.
PF3=$(mk_proj 0)
cat > "$PF3/.claude/metering/metering.ndjson" <<'NDJSON'
{"schema":"guv.meter.v1","ts":"2026-06-01T00:00:00Z","session":"session-2026-06-01-001","deliverable_ids":["9.0"],"tokens":{"input":7000000,"output":0,"cache_read":0,"cache_creation":0},"slice_basis":"per_deliverable","perf":{}}
{"schema":"guv.meter.v1","ts":"2026-06-15T00:00:00Z","session":"session-2026-06-15-001","deliverable_ids":["13.4"],"tokens":{"input":10000000,"output":0,"cache_read":0,"cache_creation":0},"slice_basis":"per_deliverable","perf":{}}
NDJSON
{ grade_line "2026-06-10T00:00:00Z"; plan_bank "2026-06-12T00:00:00Z"; } > "$PF3/.claude/metering/calibration.ndjson"
CTC3=$(proj_ctc "$PF3")
set_init_budget "$PF3" $(( 10000000 + CTC3 / 2 ))   # windowed burn(10M) < budget < burn+CTC
W6OUT=$(gate "$PF3" exit); W6RC=$?
echo "$W6OUT" | grep -qi 'FORESEEN' && [ "$W6RC" -eq 0 ] \
  && ok "[13.4] the foreseen check still declares on the windowed burn (signal, exit 0)" \
  || no "[13.4] the foreseen check must fire on windowed burn + cost-to-complete (rc=$W6RC out='$W6OUT')"
echo "$W6OUT" | grep -q 'burn to date:          10000000 tokens' \
  && ok "[13.4] FORESEEN burn-to-date is the windowed figure (10000000, not history-inflated 17000000)" \
  || no "[13.4] the foreseen declaration must carry the windowed burn-to-date (out='$W6OUT')"
echo "$W6OUT" | grep -q 'burn window:.*since the lineage boundary 2026-06-12T00:00:00Z' \
  && ok "[13.4] the FORESEEN declaration names its window basis too (the same decision-input rule)" \
  || no "[13.4] the foreseen declaration must disclose the window basis (out='$W6OUT')"

# ── W6b: the DEGRADED (no-lineage) foreseen declaration discloses its whole-log
# basis — W4/W8/W9 pin the degraded disclosure on the BREACH path only; this pins
# the FORESEEN path, so the two renderings of the shared basis line cannot
# silently diverge. Same fixture shape as W6 with NO calibration record: burn is
# the whole-log 17000000, and the declaration must say which claim that figure is.
PF4=$(mk_proj 0)
cat > "$PF4/.claude/metering/metering.ndjson" <<'NDJSON'
{"schema":"guv.meter.v1","ts":"2026-06-01T00:00:00Z","session":"session-2026-06-01-001","deliverable_ids":["9.0"],"tokens":{"input":7000000,"output":0,"cache_read":0,"cache_creation":0},"slice_basis":"per_deliverable","perf":{}}
{"schema":"guv.meter.v1","ts":"2026-06-15T00:00:00Z","session":"session-2026-06-15-001","deliverable_ids":["13.4"],"tokens":{"input":10000000,"output":0,"cache_read":0,"cache_creation":0},"slice_basis":"per_deliverable","perf":{}}
NDJSON
CTC4=$(proj_ctc "$PF4")
set_init_budget "$PF4" $(( 17000000 + CTC4 / 2 ))   # whole-log burn(17M) < budget < burn+CTC
W6BOUT=$(gate "$PF4" exit); W6BRC=$?
echo "$W6BOUT" | grep -qi 'FORESEEN' && [ "$W6BRC" -eq 0 ] \
  && echo "$W6BOUT" | grep -q 'burn to date:          17000000 tokens' \
  && echo "$W6BOUT" | grep -qi 'burn window:.*whole metering log' \
  && ok "[13.4] the degraded FORESEEN declaration carries the cumulative figure AND names its whole-log basis" \
  || no "[13.4] a degraded foreseen must disclose the whole-log basis with its figure (rc=$W6BRC out='$W6BOUT')"

# ── W7: under an ACTIVE window, an entry with NO ts cannot enter the initiative
# sum — a missing stamp is a missing measurement, never fabricated burn (the
# same Rule-15 rung as tokens:null). Huge un-stamped entry + tiny live burn
# under the setpoint -> silent.
WP7=$(mk_lineage '{"initiative":{"tokens":100000}}' 0 10000)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-14-001",deliverable_ids:["9.0"],tokens:{input:999999999,output:0,cache_read:0,cache_creation:0},slice_basis:"per_deliverable",perf:{}}' \
  >> "$WP7/.claude/metering/metering.ndjson"
{ grade_line "2026-06-10T00:00:00Z"; plan_bank "2026-06-12T00:00:00Z"; } > "$WP7/.claude/metering/calibration.ndjson"
W7OUT=$(gate "$WP7" exit); W7RC=$?
[ "$W7RC" -eq 0 ] && [ -z "$W7OUT" ] \
  && ok "[13.4] an un-stamped entry cannot enter a windowed sum (no fabricated breach — Rule 15)" \
  || no "[13.4] a ts-less entry must contribute 0 to a windowed initiative sum (rc=$W7RC out='$W7OUT')"

# ── W8: a lineage record with NO qualifying entry (phase banks only — no grade,
# no plan) has no boundary to read -> the SAME cumulative degradation as no
# record at all (110000 breaches), with the whole-log basis disclosed. Pins the
# record-present branch of "degrades to cumulative, never to unlimited".
WP8=$(mk_lineage '{"initiative":{"tokens":100000}}' 60000 50000)
phase_bank "2026-06-13T00:00:00Z" > "$WP8/.claude/metering/calibration.ndjson"
W8OUT=$(gate "$WP8" exit); W8RC=$?
[ "$W8RC" -eq 3 ] && echo "$W8OUT" | grep -qi 'burn window:.*whole metering log' \
  && ok "[13.4] phase-banks-only lineage -> cumulative degradation (110000 breaches, whole-log basis disclosed)" \
  || no "[13.4] a record with no grade/plan entry must degrade to the cumulative read (rc=$W8RC out='$W8OUT')"

# ── W9: a malformed banked_at stamp never windows — the whitelist rejects it and
# the read degrades to cumulative (disclosed), rather than interpolating an
# unvetted string into the burn program or fabricating a boundary.
WP9=$(mk_lineage '{"initiative":{"tokens":100000}}' 60000 50000)
printf '{"schema":"guv.projection.v1","kind":"forecast","boundary":"plan","banked_at":"yesterday-ish"}\n' \
  > "$WP9/.claude/metering/calibration.ndjson"
W9OUT=$(gate "$WP9" exit); W9RC=$?
[ "$W9RC" -eq 3 ] && echo "$W9OUT" | grep -qi 'burn window:.*whole metering log' \
  && ok "[13.4] a non-ISO banked_at fails the whitelist -> cumulative degradation, disclosed" \
  || no "[13.4] a malformed stamp must never window (rc=$W9RC out='$W9OUT')"

# ── W10: a CORRUPT calibration line (a torn append) drops alone — the intact
# grade+plan tail still windows, so one bad line cannot resurrect the spurious
# cumulative breach. Exercised through the --calibration override (the flag's
# only caller-facing test): the fixture's default calibration path is absent, so
# a broken flag OR a lost window both fail this as a cumulative breach.
WP10=$(mk_lineage '{"initiative":{"tokens":100000}}' 5000000 10000)
CAL10=$(mktemp "$WORK/cal10.XXXXXX")
{ grade_line "2026-06-10T00:00:00Z"; printf '{"torn append not json\n'; plan_bank "2026-06-12T00:00:00Z"; } > "$CAL10"
W10OUT=$( cd "$WP10" && bash "$GATE" entry --calibration "$CAL10" 2>/dev/null ); W10RC=$?
[ "$W10RC" -eq 0 ] && [ -z "$W10OUT" ] \
  && ok "[13.4] a corrupt calibration line drops alone — the window survives (silent, via --calibration)" \
  || no "[13.4] one torn line must not cost the window and resurrect the cumulative breach (rc=$W10RC out='$W10OUT')"

# ── W11: the anchor is the LAST qualifying entry in FILE ORDER — append order is
# lineage order (projection.sh's rindex convention), not max-banked_at. Lifecycle
# entries land in lifecycle order by construction, so the two only diverge on a
# hand-edited record — and then file-order fails CONSERVATIVE: the out-of-order
# older boundary (grade 06-05, appended after the plan bank 06-12) widens the
# window, pulling in the 90000 entry (06-07) a max-stamp anchor would exclude →
# burn 120000 breaches with the 06-05 basis disclosed, never a silent under-gate.
# This is the anchoring assumption's tripwire: change the convention and this
# test names the contract being renegotiated.
WP11=$(mk_lineage '{"initiative":{"tokens":100000}}' 5000000 30000)
cat > "$WP11/.claude/metering/metering.ndjson" <<'NDJSON'
{"schema":"guv.meter.v1","ts":"2026-06-01T00:00:00Z","session":"session-2026-06-01-001","deliverable_ids":["9.0"],"tokens":{"input":5000000,"output":0,"cache_read":0,"cache_creation":0},"slice_basis":"per_deliverable","perf":{}}
{"schema":"guv.meter.v1","ts":"2026-06-07T00:00:00Z","session":"session-2026-06-07-001","deliverable_ids":["9.0"],"tokens":{"input":90000,"output":0,"cache_read":0,"cache_creation":0},"slice_basis":"per_deliverable","perf":{}}
{"schema":"guv.meter.v1","ts":"2026-06-15T00:00:00Z","session":"session-2026-06-15-001","deliverable_ids":["24.1"],"tokens":{"input":30000,"output":0,"cache_read":0,"cache_creation":0},"slice_basis":"per_deliverable","perf":{}}
NDJSON
{ grade_line "2026-06-10T00:00:00Z"; plan_bank "2026-06-12T00:00:00Z"; grade_line "2026-06-05T00:00:00Z"; } > "$WP11/.claude/metering/calibration.ndjson"
W11OUT=$(gate "$WP11" exit); W11RC=$?
W11BURN=$(profile_burn "$W11OUT")
[ "$W11RC" -eq 3 ] && [ "$W11BURN" = "120000" ] \
  && echo "$W11OUT" | grep -q 'burn window:.*since the lineage boundary 2026-06-05T00:00:00Z' \
  && ok "[13.4] file-order anchoring pinned: an out-of-order qualifying append widens the window conservatively (120000 breaches, 06-05 basis disclosed)" \
  || no "[13.4] the anchor must be the file-order last qualifying entry, failing conservative (rc=$W11RC burn='${W11BURN:-none}' out='$W11OUT')"

# ── MIXED HARVEST VINTAGE: the gate discloses when its own comparison is invalid ──
# harvest_basis was written by the meter and read by NOTHING, which is the phantom-
# HEADROOM mirror of a phantom breach. Pre-dedupe entries counted usage once per
# transcript LINE instead of once per API response (~2.5x over, and shape-dependent),
# so summing them beside per_response entries yields a total in no unit at all — while
# the gate compares it to a setpoint chosen in one unit and stays SILENT, because
# silence is what within-budget looks like. This is the one case where the gate's
# silence is itself the defect.
#
# V1 — a window spanning both vintages is disclosed, and it is disclosed WITHIN BUDGET.
# That is the whole point: the breach path already talks, and it is the quiet path that
# was lying.
P=$(mk_project '{"initiative":{"tokens":100000000}}' 1000 1000)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
         tokens:{input:500,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}' \
  >> "$P/.claude/metering/metering.ndjson"
V1OUT=$(gate "$P" exit); V1RC=$?
printf '%s' "$V1OUT" | grep -q 'MIXED HARVEST VINTAGE' \
  && printf '%s' "$V1OUT" | grep -q 'pre-dedupe' \
  && printf '%s' "$V1OUT" | grep -q 'per_response' \
  && [ $V1RC -eq 0 ] \
  && ok "[9.1] a burn window spanning two harvest vintages is disclosed within budget, both vintages named" \
  || no "[9.1] mixing harvest vintages makes the burn/setpoint comparison meaningless — the gate must say so, not stay silent (rc=$V1RC out='$V1OUT')"

# V2 — and it says the direction of the error rather than merely that one exists.
# "The numbers may be off" is not actionable; "the ceiling lets more through than it
# was meant to" is.
printf '%s' "$V1OUT" | grep -qi 'phantom headroom' \
  && ok "[9.1] the disclosure names the LIKELY DIRECTION (phantom headroom), not just the existence of a mismatch" \
  || no "[9.1] a vintage disclosure that does not say which way the error runs leaves the operator no decision to make"

# V3 — DECLARATION, not a stop, and it moves nothing. The machinery never re-denominates
# a setpoint any more than it raises one: that is a person's commit.
MANIF_BEFORE=$(cat "$P/.claude/project.json")
gate "$P" exit >/dev/null 2>&1; V3RC=$?
[ "$MANIF_BEFORE" = "$(cat "$P/.claude/project.json")" ] && [ $V3RC -eq 0 ] \
  && ok "[9.1] the vintage disclosure exits 0 and leaves the manifest byte-identical (declaration, never a conversion)" \
  || no "[9.1] the gate must never re-denominate or rewrite a setpoint (rc=$V3RC)"

# V4 — a SINGLE-vintage window stays silent, so the disclosure keeps meaning something.
# Without this, V1 would pass against a banner that fires unconditionally.
P=$(mk_project '{"initiative":{"tokens":100000000}}' 1000 1000)
V4OUT=$(gate "$P" exit); V4RC=$?
printf '%s' "$V4OUT" | grep -q 'MIXED HARVEST VINTAGE' \
  && no "[9.1] the vintage disclosure fired on a single-vintage window — a warning that always fires is not a warning" \
  || ok "[9.1] no vintage disclosure when every windowed entry shares one harvest basis"

# V5 — an all-post-dedupe window is silent too. V4's fixture is all pre-dedupe, so on
# its own it cannot tell "one vintage" from "the pre-dedupe vintage specifically".
P=$(mk_project '{"initiative":{"tokens":100000000}}' 0 0)
: > "$P/.claude/metering/metering.ndjson"
for i in 1 2; do
  jq -nc --arg s "session-2026-06-15-001" \
    '{schema:"guv.meter.v1",session:$s,deliverable_ids:["9.2"],
      tokens:{input:500,output:0,cache_read:0,cache_creation:0},
      slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}' \
    >> "$P/.claude/metering/metering.ndjson"
done
V5OUT=$(gate "$P" exit)
printf '%s' "$V5OUT" | grep -q 'MIXED HARVEST VINTAGE' \
  && no "[9.1] the vintage disclosure fired on an all-per_response window" \
  || ok "[9.1] no vintage disclosure once every windowed entry is post-dedupe (the state a NEW initiative opens in)"

# V6 — the vintage scan is windowed to the live lineage, exactly like the burn sum it
# describes. A pre-dedupe entry from a CLOSED initiative is not part of the figure being
# compared, so it must not raise a disclosure about a window it does not contaminate:
# unwindowed, every mature record warns forever, and a warning that never clears is one
# the operator learns to skip past — the same silence this section exists to break.
VP6=$(mk_lineage '{"initiative":{"tokens":100000}}' 5000000 10000)
{ grade_line "2026-06-10T00:00:00Z"; plan_bank "2026-06-12T00:00:00Z"; } > "$VP6/.claude/metering/calibration.ndjson"
# retag ONLY the in-window entry as post-dedupe; the 2026-06-01 one stays pre-dedupe
jq -c 'if (.ts // "") >= "2026-06-12T00:00:00Z" then .harvest_basis = "per_response" else . end' \
  "$VP6/.claude/metering/metering.ndjson" > "$VP6/.claude/metering/m.tmp"
mv "$VP6/.claude/metering/m.tmp" "$VP6/.claude/metering/metering.ndjson"
V6OUT=$(gate "$VP6" exit)
printf '%s' "$V6OUT" | grep -q 'MIXED HARVEST VINTAGE' \
  && no "[9.1] the vintage scan reached outside the burn window — a closed initiative's vintage is not this window's problem (out='$V6OUT')" \
  || ok "[9.1] the vintage scan is windowed to the live lineage, like the burn sum it describes"

# V7 — the disclosure rides ALONGSIDE the burn outcome; it does not replace it or
# swallow the stop. The two say different things: the breach says a setpoint was
# crossed, the disclosure says the crossing is denominated in no single unit. An
# operator who sees only one of them at an extend/harvest/kill pause is deciding
# on half the picture — and if the disclosure ever pre-empted the exit 3, this
# section would have converted a stop into a declaration, which it must never do.
P=$(mk_project '{"initiative":{"tokens":1000}}' 5000 0)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
         tokens:{input:5000,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}' \
  >> "$P/.claude/metering/metering.ndjson"
V7OUT=$(gate "$P" exit); V7RC=$?
printf '%s' "$V7OUT" | grep -q 'MIXED HARVEST VINTAGE' \
  && printf '%s' "$V7OUT" | grep -q 'budget-gate] BREACH' \
  && [ $V7RC -eq 3 ] \
  && ok "[9.1] a mixed-vintage window that also breaches prints BOTH banners and still exits 3" \
  || no "[9.1] the vintage disclosure must not pre-empt or soften the actual-burn stop (rc=$V7RC out='$V7OUT')"

# V8 — the scan reads the entries the burn CONTRIBUTES FROM, not merely the ones sharing
# its ts window. burn_sum skips unbounded_cumulative entirely (the disclosed degradation,
# never a burn sample), so such an entry adds nothing to the figure — and a vintage raised
# by an entry that touched no part of the number is a false alarm about a comparison that
# was apples-to-apples all along. The fixture pins both halves at once: the 900,000-token
# unbounded entry is the ONLY pre-dedupe one and would breach the 100,000 ceiling nine
# times over if it were summed, so a silent exit 0 proves it contributed neither burn nor
# vintage. Without this, the disclosure fires on records whose burn is single-vintage.
P=$(mk_project '{"initiative":{"tokens":100000}}' 0 0)
{
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.1"],
           tokens:{input:900000,output:0,cache_read:0,cache_creation:0},
           slice_basis:"unbounded_cumulative",perf:{}}'
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
           tokens:{input:1200,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
} > "$P/.claude/metering/metering.ndjson"
V8OUT=$(gate "$P" exit); V8RC=$?
printf '%s' "$V8OUT" | grep -q 'MIXED HARVEST VINTAGE' \
  && no "[9.1] an unbounded_cumulative entry raised a vintage while contributing zero burn — the scan must select burn_sum's entry set, not just its ts window (out='$V8OUT')" \
  || { [ $V8RC -eq 0 ] \
       && ok "[9.1] an entry the burn sum skips raises no vintage about it (no banner, and no breach off its 900k)" \
       || no "[9.1] the unbounded_cumulative entry was summed into the burn — the vintage fix must not disturb burn_sum's exclusions (rc=$V8RC)"; }

# V9 — each vintage is reported with its TOKEN SUBTOTAL, not only its entry count.
# Count alone answers the wrong question and inverts the signal on a real record: the
# live 004 window holds one pre-dedupe entry of ~187M tokens, so the first post-fix
# session makes it read 1:1 by count while being ~99% pre-dedupe by burn — the
# operator would read "half converted" off a window that is barely touched. The
# fixture is lopsided on BOTH axes (2 entries / 2000 tokens vs 1 entry / 500) so
# neither number can be mistaken for the other or hard-coded from the shape.
P=$(mk_project '{"initiative":{"tokens":100000000}}' 1000 1000)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
         tokens:{input:500,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}' \
  >> "$P/.claude/metering/metering.ndjson"
V9OUT=$(gate "$P" exit)
printf '%s' "$V9OUT" | grep -q 'per_response (1 entry, 500 tokens)' \
  && printf '%s' "$V9OUT" | grep -q 'pre-dedupe (2 entries, 2000 tokens)' \
  && ok "[9.1] each vintage carries its token subtotal, so a window that is 1:1 by count and 99:1 by burn reads as the latter" \
  || no "[9.1] naming the vintages without their token weights leaves the operator unable to judge how much of the burn is inflated (out='$V9OUT')"

# V9b — and those subtotals RECONCILE to the burn printed beside them. This is the
# property that makes them trustworthy rather than merely present: the vintage scan and
# the burn sum read one shared projection of the log, so a subtotal that drifted from
# the total would mean the two had forked again — which is exactly the defect this
# section was rewritten to make structurally impossible. Summed from the banner text,
# not from the internals, so it checks what the operator actually reads.
V9SUB=$(printf '%s' "$V9OUT" | sed -n 's/.*vintages in window: *//p' \
        | grep -oE '[0-9]+ tokens' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
V9TOT=$(printf '%s' "$V9OUT" | sed -n 's/^ *initiative burn: *\([0-9]*\).*/\1/p')
[ -n "$V9TOT" ] && [ "$V9SUB" = "$V9TOT" ] \
  && ok "[9.1] the per-vintage subtotals sum to the initiative burn printed beside them ($V9SUB = $V9TOT)" \
  || no "[9.1] the vintage subtotals must reconcile to the burn they describe, or they are a second unrelated number on the same screen (subtotals=$V9SUB burn=$V9TOT)"

# V10 — the LEGACY inclusion branch. burn_sum reads three entry shapes (per_deliverable,
# since_process_start, and legacy entries carrying no slice_basis key at all), and the
# scan must cover every one of them or it under-discloses on exactly the records that
# are oldest and therefore most likely to be pre-fix. V1–V9 all use per_deliverable
# fixtures, so deleting either of the other two disjuncts left the whole suite green
# while silencing the banner on those shapes — 24 of the live log's 54 entries.
P=$(mk_project '{"initiative":{"tokens":100000000}}' 0 0)
{
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",runtime_session:"rt-1",
           tokens:{input:4000,output:0,cache_read:0,cache_creation:0},perf:{}}'
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
           tokens:{input:100,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
} > "$P/.claude/metering/metering.ndjson"
V10OUT=$(gate "$P" exit)
printf '%s' "$V10OUT" | grep -q 'MIXED HARVEST VINTAGE' \
  && printf '%s' "$V10OUT" | grep -q 'pre-dedupe (1 entry, 4000 tokens)' \
  && ok "[9.1] a LEGACY (no slice_basis) pre-dedupe entry raises its vintage and carries its differenced burn" \
  || no "[9.1] the vintage scan skipped the legacy branch — legacy entries are the oldest in any record and the likeliest to be pre-fix, so silence there is the worst place for it (out='$V10OUT')"

# V11 — the since_process_start inclusion branch, same argument. Distinct fixture value
# (7000) so a subtotal copied from V10 cannot satisfy it.
P=$(mk_project '{"initiative":{"tokens":100000000}}' 0 0)
{
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.1"],
           tokens:{input:7000,output:0,cache_read:0,cache_creation:0},
           slice_basis:"since_process_start",perf:{}}'
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
           tokens:{input:100,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
} > "$P/.claude/metering/metering.ndjson"
V11OUT=$(gate "$P" exit)
printf '%s' "$V11OUT" | grep -q 'MIXED HARVEST VINTAGE' \
  && printf '%s' "$V11OUT" | grep -q 'pre-dedupe (1 entry, 7000 tokens)' \
  && ok "[9.1] a since_process_start pre-dedupe entry raises its vintage and carries its burn" \
  || no "[9.1] the vintage scan skipped the since_process_start branch — it sums into burn, so it must be able to disclose its unit (out='$V11OUT')"

# V12 — an explicit `harvest_basis: null` is UNKNOWN, not pre-dedupe. meter.sh writes
# that on a degraded harvest: the run happened and could not record its basis, so the
# unit is unrecorded rather than old. Folding it into "pre-dedupe" would be a guess
# stated as evidence, and dropping it silently would let an entry contribute burn while
# contributing no vintage — breaking V9b's reconciliation. It must appear, named for
# what it is.
P=$(mk_project '{"initiative":{"tokens":100000000}}' 0 0)
{
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.1"],
           tokens:{input:300,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",harvest_basis:null,perf:{}}'
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
           tokens:{input:100,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
} > "$P/.claude/metering/metering.ndjson"
V12OUT=$(gate "$P" exit)
printf '%s' "$V12OUT" | grep -q 'unknown (1 entry, 300 tokens)' \
  && ok "[9.1] an explicit harvest_basis:null reads as UNKNOWN, never silently as pre-dedupe or as nothing" \
  || no "[9.1] a degraded harvest's basis must be reported as unknown — guessing it is pre-dedupe states an inference as evidence, and dropping it breaks the subtotal reconciliation (out='$V12OUT')"

# V13 — the FORESEEN OVERRUN menu must be qualified when the record is mixed, and
# specifically must warn OFF its own first option. This is the remedy loop, verified
# against the live record before it was pinned here: re-denominate 004's ceiling into
# the post-fix unit and the gate answers with a foreseen overrun whose leading offer is
# EXTEND — i.e. put the ceiling back. An operator following the menu undoes the fix.
# The standing banner above is not sufficient on its own: it explains the unit, but the
# wrong move is made at the menu, so the correction has to be at the menu.
PF9=$(mk_proj 10000000)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["13.5"],
         tokens:{input:1000,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}' \
  >> "$PF9/.claude/metering/metering.ndjson"
CTC9=$(proj_ctc "$PF9")
set_init_budget "$PF9" $(( 10001000 + CTC9 / 2 ))   # burn < budget < burn + CTC
V13OUT=$(gate "$PF9" exit); V13RC=$?
printf '%s' "$V13OUT" | grep -qi 'FORESEEN OVERRUN' && [ "$V13RC" -eq 0 ] \
  && printf '%s' "$V13OUT" | grep -q 'EXTEND is the wrong first move' \
  && ok "[9.1] a FORESEEN OVERRUN drawn from a mixed record warns off EXTEND — the option that would undo the remedy" \
  || no "[9.1] the foreseen menu leads with EXTEND, so on a mixed record it must say so inline or it walks the operator back out of the fix (rc=$V13RC out='$V13OUT')"

# V13b — and it names the consequence the operator will otherwise misread: after a
# CORRECT re-denomination the declaration keeps firing, because the burn side is still
# counted in the old unit and the log is append-only. Without this, the expected
# outcome of the remedy is indistinguishable from the remedy having failed — and the
# obvious response to "it didn't work" is to raise the ceiling again.
printf '%s' "$V13OUT" | grep -q 'rest of this initiative' \
  && ok "[9.1] the qualifier warns that a correctly re-denominated ceiling still reads as an overrun, so persistence is not read as failure" \
  || no "[9.1] a remedy whose success looks identical to its failure will be reverted — the declaration must say it persists by arithmetic (out='$V13OUT')"

# V13c — the false-positive half. A single-vintage record must NOT carry the
# qualifier: an unconditional warning would train the operator to skim past it on
# exactly the records where the forecast is trustworthy, which is how a real
# disclosure decays into boilerplate.
PF10=$(mk_proj 0)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["13.4"],
         tokens:{input:10000000,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}' \
  > "$PF10/.claude/metering/metering.ndjson"
CTC10=$(proj_ctc "$PF10")
set_init_budget "$PF10" $(( 10000000 + CTC10 / 2 ))
V13COUT=$(gate "$PF10" exit)
printf '%s' "$V13COUT" | grep -qi 'FORESEEN OVERRUN' \
  && ! printf '%s' "$V13COUT" | grep -q 'EXTEND is the wrong first move' \
  && ok "[9.1] a single-vintage FORESEEN OVERRUN carries no mixed-record qualifier (the warning stays meaningful)" \
  || no "[9.1] the qualifier must be conditional — printed on a clean record it becomes boilerplate the operator learns to skip (out='$V13COUT')"

# V14 — the banner is DEEPER at exit than at entry, and that asymmetry is the design.
# Nothing clears this banner, so it fires at both boundaries of every session for the
# rest of the initiative, and hooks/session-start.sh pipes the gate's whole stdout into
# each session's additionalContext. Re-paying the full remedy prose twice a session
# for dozens of sessions spends the work's own context to repeat a fixed instruction.
# Entry gets the actionable half (do not trust this number); exit — where a person is
# at the extend/harvest/kill decision and writing the handoff — gets all of it.
P=$(mk_project '{"initiative":{"tokens":100000000}}' 1000 1000)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
         tokens:{input:500,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}' \
  >> "$P/.claude/metering/metering.ndjson"
V14ENT=$(gate "$P" entry)
V14EXT=$(gate "$P" exit)
V14ELINES=$(printf '%s\n' "$V14ENT" | wc -l | tr -d ' ')
V14XLINES=$(printf '%s\n' "$V14EXT" | wc -l | tr -d ' ')
[ "$V14ELINES" -lt "$V14XLINES" ] \
  && ! printf '%s' "$V14ENT" | grep -q 'The remedy is one commit by a person' \
  && printf '%s' "$V14EXT" | grep -q 'The remedy is one commit by a person' \
  && ok "[9.1] the standing banner is terse at entry and full at exit (${V14ELINES} vs ${V14XLINES} lines) — the remedy prose is paid for where it is acted on" \
  || no "[9.1] a banner that never clears must not re-inject its full prose into every session's context; entry carries the warning, exit carries the remedy (entry=${V14ELINES}L exit=${V14XLINES}L)"

# V14b — but the trim is never silence. Whatever the boundary, the operator gets the
# header, the vintages WITH their subtotals, and the burn those subtotals describe.
# Without this, "make entry terse" has no floor and degrades to dropping the entry
# disclosure altogether — which is the original [9.1] defect restored at one boundary.
V14MISS=""
for probe in 'MIXED HARVEST VINTAGE' 'vintages in window:' 'per_response (1 entry, 500 tokens)' 'initiative burn:' 'initiative setpoint:'; do
  printf '%s' "$V14ENT" | grep -q "$probe" || V14MISS="$V14MISS '$probe'"
done
[ -z "$V14MISS" ] \
  && ok "[9.1] the entry banner still carries the full profile — header, both vintages with subtotals, burn and setpoint" \
  || no "[9.1] the terse entry form dropped part of the profile:$V14MISS — trimming the explanation must never trim the evidence (out='$V14ENT')"

# V14c — and the entry form still tells the reader what to DO, which is the only thing
# an agent mid-session can act on. A profile with no instruction invites exactly the
# use the banner exists to prevent: treating a mixed total as a measurement.
printf '%s' "$V14ENT" | grep -q 'not a measurement' \
  && printf '%s' "$V14ENT" | grep -qi 'metering-log.md' \
  && ok "[9.1] the entry banner names the hazard and points at where the full statement lives" \
  || no "[9.1] the entry form must still say the figure is not a measurement and where to read the rest, or it is a number with no warning attached (out='$V14ENT')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
