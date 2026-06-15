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
  # sums classes, not just input_tokens.
  local h r
  h=$((sburn / 2)); r=$((sburn - sburn / 2))
  {
    jq -nc --argjson t "$iextra" \
      '{schema:"guv.meter.v1",session:"session-2026-06-14-001",deliverable_ids:["9.0"],tokens:{input:$t,output:0,cache_read:0,cache_creation:0},perf:{}}'
    jq -nc --argjson a "$h" --argjson b "$r" \
      '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.3"],tokens:{input:$a,output:0,cache_read:$b,cache_creation:0},perf:{}}'
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
