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
# EVERY manifest key the gate READS must be declared in the schema. Both granularities
# are additionalProperties:false, so a key the gate reads and the schema omits makes any
# manifest that sets it INVALID — the feature's own activation switch rejected by the
# document that defines what may be set. That is not hypothetical: harvest_basis shipped
# read-but-undeclared and left the live control-plane manifest schema-invalid. The key
# list is DERIVED from the gate, never enumerated here, so the next read cannot drift
# past this the same way.
GATE_KEYS=$(grep -oE '\.budgets\.(initiative|session)\.[a-z_]+' "$GATE" 2>/dev/null | sort -u)
[ -n "$GATE_KEYS" ] \
  && ok "the gate reads at least one budgets.* manifest key (the drift guard has a subject)" \
  || no "expected the gate to read budgets.* keys from the manifest — guard cannot run"
for k in $GATE_KEYS; do
  KG=$(printf '%s' "$k" | cut -d. -f3)
  KP=$(printf '%s' "$k" | cut -d. -f4)
  jq -e --arg g "$KG" --arg p "$KP" '.properties.budgets.properties[$g].properties[$p]' "$SCHEMA" >/dev/null 2>&1 \
    && ok "schema declares budgets.$KG.$KP (the gate reads it)" \
    || no "the gate reads budgets.$KG.$KP but the schema omits it — additionalProperties:false makes any manifest setting it INVALID"
done
# The gate's accepted-value set and the schema's enum must name the SAME units. If they
# drift, the gate either reports MALFORMED for a value the schema blesses, or silently
# accepts one no manifest may legally hold. The MALFORMED banner's "legal values:" line
# is what an operator is told to write, so that line is the surface checked.
BASIS_ENUM=$(jq -r '.properties.budgets.properties.initiative.properties.harvest_basis.enum[]?' "$SCHEMA" 2>/dev/null)
[ -n "$BASIS_ENUM" ] \
  && ok "schema constrains budgets.initiative.harvest_basis to an enum (a typo'd unit is caught)" \
  || no "budgets.initiative.harvest_basis must declare an enum — an unconstrained string admits any unit"
LEGAL_LINE=$(grep -E 'legal values:' "$GATE" 2>/dev/null)
for v in $BASIS_ENUM; do
  case "$LEGAL_LINE" in
    *"$v"*) ok "the gate's legal-values line names the schema unit '$v' (operator can act on it)" ;;
    *)      no "schema blesses harvest_basis '$v' but the gate never names it as legal" ;;
  esac
  grep -qE "^ *''\|.*${v}.*\)" "$GATE" 2>/dev/null \
    && ok "the gate accepts schema unit '$v' without reporting it MALFORMED" \
    || no "the gate would report the schema-legal unit '$v' as MALFORMED"
done
# [28.5] The DENOMINATION axis gets the same enum/legal-values coupling as the vintage
# axis above, and for the same reason: the MALFORMED banner's "legal values:" line is the
# only place an operator is told what to write, so a drift between it and the schema
# hands them a value the schema rejects (or the gate rejects a value the schema blesses).
DENOM_ENUM=$(jq -r '.properties.budgets.properties.initiative.properties.denomination.enum[]?' "$SCHEMA" 2>/dev/null)
[ -n "$DENOM_ENUM" ] \
  && ok "[28.5] schema constrains budgets.initiative.denomination to an enum (a typo'd denomination is caught)" \
  || no "[28.5] budgets.initiative.denomination must declare an enum — an unconstrained string admits any denomination"
for v in $DENOM_ENUM; do
  case "$LEGAL_LINE" in
    *"$v"*) ok "[28.5] the gate's legal-values line names the schema denomination '$v' (operator can act on it)" ;;
    *)      no "[28.5] schema blesses denomination '$v' but the gate never names it as legal" ;;
  esac
  grep -qE "^ *''\|.*${v}.*\)" "$GATE" 2>/dev/null \
    && ok "[28.5] the gate accepts schema denomination '$v' without reporting it MALFORMED" \
    || no "[28.5] the gate would report the schema-legal denomination '$v' as MALFORMED"
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
# Same, but keeps a declared harvest basis alongside the computed ceiling — the foreseen
# tests need a budget derived from the live projection AND a declared unit, and the plain
# helper replaces the whole budgets object.
set_init_budget_basis() { jq --argjson b "$2" --arg hb "$3" '.budgets = {initiative:{tokens:$b, harvest_basis:$hb}}' "$1/.claude/project.json" > "$1/.b" && mv "$1/.b" "$1/.claude/project.json"; }
# Same again for the [28.5] denomination axis. Deliberately sets NO harvest_basis: the
# projection fixture's lone entry carries no basis either, so the vintage axis stays
# silent and anything the foreseen menu says about units is the denomination axis alone.
set_init_budget_denom() { jq --argjson b "$2" --arg dn "$3" '.budgets = {initiative:{tokens:$b, denomination:$dn}}' "$1/.claude/project.json" > "$1/.b" && mv "$1/.b" "$1/.claude/project.json"; }
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

# And the same for EVERY headline the gate can emit, not only the two that happened to be
# written down. The gate's own exit comment names this reader — "a person at the
# extend/harvest/kill decision, WRITING THE HANDOFF that carries it forward" — so a
# declaration the handoff never captures reaches the live session and dies there, while
# the burn and forecast figures it qualifies get recorded without it. The headline list is
# DERIVED from the gate, never enumerated here: a new banner must be picked up by the
# session-close path in the same commit that adds it, which is exactly what did not happen
# when the setpoint-unit and malformed-marker checks shipped.
GATE_HEADLINES=$(grep -oE '\[budget-gate\] [A-Z][A-Z]+( [A-Z]+)*' "$GATE" 2>/dev/null | sed 's/\[budget-gate\] //' | sort -u)
[ -n "$GATE_HEADLINES" ] \
  && ok "[15.6] the gate's emitted headlines are discoverable (the handoff drift guard has a subject)" \
  || no "[15.6] could not extract any [budget-gate] headline from the gate — the handoff coverage guard cannot run"
HL_MISS=""
printf '%s\n' "$GATE_HEADLINES" | while IFS= read -r hl; do
  [ -n "$hl" ] || continue
  grep -q "$hl" "$HANDOFF_SKILL" 2>/dev/null || printf '%s\n' "$hl"
done > "$WORK/.hl_miss"
HL_MISS=$(tr '\n' ' ' < "$WORK/.hl_miss" | sed 's/ *$//')
[ -z "$HL_MISS" ] \
  && ok "[15.6] every headline the gate can emit is named in the handoff's session-close capture list" \
  || no "[15.6] the gate emits headlines the handoff never captures:$HL_MISS — each qualifies the burn/forecast figures the artifact does record, so omitting it writes a measurement the gate refused to call one"

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

# ── HARVEST UNIT HAZARD, kind=mixed: the gate discloses when its comparison is invalid ──
# harvest_basis was written by the meter and read by NOTHING, which is the phantom-
# HEADROOM mirror of a phantom breach. Pre-dedupe entries counted usage once per
# transcript LINE instead of once per API response (~2.5x over; measured 2.31–2.88x
# all-class, where a single ~2.55x deflator fits every reconstructed entry to ±13% —
# so what refuses conversion here is the lost transcripts, not the arithmetic, [28.4]),
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
printf '%s' "$V1OUT" | grep -q 'hazard: *mixed' \
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
printf '%s' "$V4OUT" | grep -q 'hazard: *mixed' \
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
printf '%s' "$V5OUT" | grep -q 'hazard: *mixed' \
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
printf '%s' "$V6OUT" | grep -q 'hazard: *mixed' \
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
printf '%s' "$V7OUT" | grep -q 'hazard: *mixed' \
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
printf '%s' "$V8OUT" | grep -q 'hazard: *mixed' \
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
printf '%s' "$V10OUT" | grep -q 'hazard: *mixed' \
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
printf '%s' "$V11OUT" | grep -q 'hazard: *mixed' \
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
  && ! printf '%s' "$V14ENT" | grep -q 'budgets.initiative.harvest_basis' \
  && printf '%s' "$V14EXT" | grep -q 'budgets.initiative.harvest_basis' \
  && ok "[9.1] the standing banner is terse at entry and full at exit (${V14ELINES} vs ${V14XLINES} lines) — the remedy prose is paid for where it is acted on" \
  || no "[9.1] a banner that never clears must not re-inject its full prose into every session's context; entry carries the warning, exit carries the remedy (entry=${V14ELINES}L exit=${V14XLINES}L)"

# V14b — but the trim is never silence. Whatever the boundary, the operator gets the
# header, the vintages WITH their subtotals, and the burn those subtotals describe.
# Without this, "make entry terse" has no floor and degrades to dropping the entry
# disclosure altogether — which is the original [9.1] defect restored at one boundary.
V14MISS=""
for probe in 'HARVEST UNIT HAZARD' 'vintages in window:' 'per_response (1 entry, 500 tokens)' 'initiative burn:' 'initiative setpoint:'; do
  printf '%s' "$V14ENT" | grep -q "$probe" || V14MISS="$V14MISS '$probe'"
done
[ -z "$V14MISS" ] \
  && ok "[9.1] the entry banner still carries the full profile — header, both vintages with subtotals, burn and setpoint" \
  || no "[9.1] the terse entry form dropped part of the profile:$V14MISS — trimming the explanation must never trim the evidence (out='$V14ENT')"

# V14c — and the entry form still tells the reader what to DO, which is the only thing
# an agent mid-session can act on. A profile with no instruction invites exactly the
# use the banner exists to prevent: treating a mixed total as a measurement.
#
# The onward pointer names the SESSION-EXIT GATE and nothing else. It used to also cite
# .claude/metering-log.md, which does not carry what was promised there — no remedy, no
# statement of the cases the banner cannot cover — and cites a setpoint superseded on
# 2026-07-26. A pointer to a doc that lacks the thing it is cited for costs the reader a
# detour and returns a stale number, so it is gone rather than patched: the exit gate
# prints the full statement, and that is the one place it is guaranteed current.
printf '%s' "$V14ENT" | grep -q 'not a measurement' \
  && printf '%s' "$V14ENT" | grep -qi 'session-exit gate' \
  && ok "[9.1] the entry banner names the hazard and points at where the full statement lives" \
  || no "[9.1] the entry form must still say the figure is not a measurement and where to read the rest, or it is a number with no warning attached (out='$V14ENT')"

# V14d — and that pointer resolves. A cited destination that does not carry the statement
# is worse than no citation: it spends the reader's attention and hands back a stale
# figure, which is how the superseded 4,741,208,137 setpoint stayed quotable after
# 2026-07-26. Pin the promise against the artifact rather than trusting the prose.
printf '%s' "$V14EXT" | grep -qi 'phantom headroom' \
  && printf '%s' "$V14EXT" | grep -q 'budgets.initiative.tokens' \
  && ok "[9.1] the exit gate the entry banner points at actually carries the remedy and the direction" \
  || no "[9.1] the entry banner's onward pointer must resolve to the full statement — citing a destination that lacks it is the defect the metering-log.md pointer had (out='$V14EXT')"

# ── HARVEST UNIT HAZARD, kind=mismatch: the case a vintage scan structurally cannot see ──
# V4/V5 pin that a SINGLE-vintage window stays silent, and that is right as far as it
# goes: with one unit in the window there is nothing MIXED to disclose. But the gate
# compares that burn to a setpoint, and a setpoint records no unit — so a window that
# is uniformly pre-dedupe, measured against a ceiling chosen post-dedupe, is exactly as
# invalid a comparison as a mixed one and prints NOTHING. The old exit banner conceded
# this in prose ("it reads the burn's vintages, never the setpoint's") and left it
# there, which makes the hazard a paragraph rather than a check.
#
# It is not hypothetical: initiative 004's live window opened as ONE pre-dedupe entry
# (186,946,906) measured against a setpoint harvested in that same pre-dedupe vintage,
# so the two sides agreed on vintage by accident and the gate could not say so.
# budgets.initiative.harvest_basis is the missing half — a person declaring the unit
# their setpoint was chosen in, so the gate can compare units instead of inferring one.
#
# Both halves of the original sentence here were WRONG and are struck ([28.4], 2026-07-28):
# it called the setpoint "re-denominated post-fix" — the manifest declares
# harvest_basis "pre-dedupe", and the post-fix framing is the same error corrected in
# CLAUDE.md and metering-log.md — and its 18.7%/3-4% figures were a one-entry snapshot
# that the log outgrew (the live window is now four bounded entries, 454,159,830, 45.4%
# of the cost-weighted ceiling). A live-log figure does not belong in a permanent
# comment; the shape of the hazard does.

# V15 — the live 004 shape. A uniformly pre-dedupe window against a post-dedupe
# setpoint is disclosed, WITHIN BUDGET, exit 0, manifest untouched. Same argument as
# V1: the breach path already talks; it is the quiet path that was lying.
P=$(mk_project '{"initiative":{"tokens":100000000,"harvest_basis":"per_response"}}' 0 0)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
         tokens:{input:4000,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",perf:{}}' \
  > "$P/.claude/metering/metering.ndjson"
V15MANIF=$(cat "$P/.claude/project.json")
V15OUT=$(gate "$P" exit); V15RC=$?
printf '%s' "$V15OUT" | grep -q 'hazard: *mismatch' \
  && printf '%s' "$V15OUT" | grep -q 'pre-dedupe' \
  && printf '%s' "$V15OUT" | grep -q 'per_response' \
  && [ $V15RC -eq 0 ] \
  && [ "$V15MANIF" = "$(cat "$P/.claude/project.json")" ] \
  && ok "[9.1] a single-vintage burn measured against a setpoint declared in the OTHER unit is disclosed — within budget, exit 0, manifest byte-identical" \
  || no "[9.1] the gate compared a pre-dedupe burn to a post-dedupe ceiling and said nothing — this is the live 004 case, and single-vintage silence is what hides it (rc=$V15RC out='$V15OUT')"

# V16 — and it names the direction, which is NOT the same direction as the mixed
# banner's. A pre-dedupe burn read against a post-dedupe ceiling is INFLATED against
# that ceiling: the gate over-reports consumption and would stop early — a phantom
# BREACH, the conservative failure. Printing "phantom headroom" here would be exactly
# backwards and would push the operator to extend a budget they have barely touched.
printf '%s' "$V15OUT" | grep -qi 'phantom breach' \
  && printf '%s' "$V15OUT" | grep -qi 'overstate' \
  && ok "[9.1] a pre-dedupe burn under a post-dedupe ceiling is named as OVERSTATED (phantom breach), not as headroom" \
  || no "[9.1] the mismatch disclosure must name which way THIS mismatch runs — the direction is opposite to the mixed banner's, and naming it wrong sends the operator to extend a budget they have hardly spent (out='$V15OUT')"

# V17 — the opposite polarity, and the dangerous one. A post-dedupe burn under a
# ceiling chosen pre-dedupe UNDER-reports: the ceiling admits ~2.5x more real work than
# it was meant to. Without this test V16 passes against a banner that hardcodes one
# direction, which is the same defect as hardcoding no direction.
P=$(mk_project '{"initiative":{"tokens":100000000,"harvest_basis":"pre-dedupe"}}' 0 0)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
         tokens:{input:4000,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}' \
  > "$P/.claude/metering/metering.ndjson"
V17OUT=$(gate "$P" exit)
printf '%s' "$V17OUT" | grep -q 'hazard: *mismatch' \
  && printf '%s' "$V17OUT" | grep -qi 'phantom headroom' \
  && ok "[9.1] a post-dedupe burn under a pre-dedupe ceiling is named as PHANTOM HEADROOM — the opposite polarity, reported as such" \
  || no "[9.1] the disclosure hardcoded one direction; a ceiling chosen in the inflated unit admits ~2.5x more real work and must be called out as headroom, not as an overstatement (out='$V17OUT')"

# V18 — units AGREE: silent. Without this, V15/V17 pass against a banner that fires
# whenever the marker is present at all, which would make declaring the basis a
# permanent alarm and teach the operator to ignore it.
P=$(mk_project '{"initiative":{"tokens":100000000,"harvest_basis":"per_response"}}' 0 0)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
         tokens:{input:4000,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}' \
  > "$P/.claude/metering/metering.ndjson"
V18OUT=$(gate "$P" exit)
printf '%s' "$V18OUT" | grep -q 'hazard: *mismatch' \
  && no "[9.1] the mismatch banner fired on a window whose unit MATCHES the declared setpoint basis — that is the state every healthy project is in" \
  || ok "[9.1] no mismatch disclosure when the burn's unit and the declared setpoint basis agree"

# V19 — the marker ABSENT stays silent, which is the ratified default (2026-07-26) and
# the reason this is a check rather than a nag. The gate genuinely cannot tell what unit
# an undeclared setpoint was chosen in, and a banner that fires for every project that
# never set the field is not a warning — the same principle V4 pins. Declaring the basis
# is what buys the check; the marker is opt-in.
P=$(mk_project '{"initiative":{"tokens":100000000}}' 0 0)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
         tokens:{input:4000,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",perf:{}}' \
  > "$P/.claude/metering/metering.ndjson"
V19OUT=$(gate "$P" exit)
printf '%s' "$V19OUT" | grep -q 'hazard: *mismatch' \
  && no "[9.1] the mismatch banner fired with no declared setpoint basis — an undeclared unit is unknown, and inventing a comparison against it is the guess this whole section exists to refuse" \
  || ok "[9.1] no mismatch disclosure when budgets.initiative.harvest_basis is absent — the check is opt-in, bought by declaring the basis"

# V20 — an UNRECOGNIZED basis value is named loudly and degrades to undeclared. This is
# the failure that would otherwise be silent and expensive: "per-response" (hyphen) never
# equals any vintage the scan emits, so the banner would fire forever, and the operator's
# fix for a permanent mismatch alarm is to re-denominate a setpoint that was already
# correct. A typo must read as a malformed manifest, not as evidence about units.
P=$(mk_project '{"initiative":{"tokens":100000000,"harvest_basis":"per-response"}}' 0 0)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
         tokens:{input:4000,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",perf:{}}' \
  > "$P/.claude/metering/metering.ndjson"
V20MANIF=$(cat "$P/.claude/project.json")
V20OUT=$(gate "$P" exit); V20RC=$?
printf '%s' "$V20OUT" | grep -q 'per-response' \
  && printf '%s' "$V20OUT" | grep -q 'per_response' \
  && ! printf '%s' "$V20OUT" | grep -q 'hazard: *mismatch' \
  && [ $V20RC -eq 0 ] \
  && [ "$V20MANIF" = "$(cat "$P/.claude/project.json")" ] \
  && ok "[9.1] an unrecognized harvest_basis is named with the legal values and degrades to undeclared — never a standing mismatch alarm off a typo" \
  || no "[9.1] a malformed setpoint basis must be reported as malformed and then ignored; treating it as a real unit produces a permanent banner whose only obvious remedy is to move a correct setpoint (rc=$V20RC out='$V20OUT')"

# V21 — the legacy-SERIES gap in the vintage subtotals. V10 covers the legacy branch
# with ONE entry, where the delta equals the raw value, so it cannot tell a differenced
# subtotal from a raw one. A multi-entry runtime_session can: cumulative 40000 then
# 100000 contributes 40000 + 60000 = 100000 of burn, while a raw sum reads 140000. If
# the scan reports 140000 the operator gets a vintage subtotal 40% larger than the burn
# it is supposed to explain — V9b's reconciliation broken on exactly the entry shape
# most likely to be pre-fix.
P=$(mk_project '{"initiative":{"tokens":100000000}}' 0 0)
{
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-14-001",runtime_session:"rt-9",
           tokens:{input:40000,output:0,cache_read:0,cache_creation:0},perf:{}}'
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",runtime_session:"rt-9",
           tokens:{input:100000,output:0,cache_read:0,cache_creation:0},perf:{}}'
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
           tokens:{input:100,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
} > "$P/.claude/metering/metering.ndjson"
V21OUT=$(gate "$P" exit)
printf '%s' "$V21OUT" | grep -q 'pre-dedupe (2 entries, 100000 tokens)' \
  && ok "[9.1] a legacy runtime_session SERIES reports its DIFFERENCED subtotal (100000), not the raw cumulative sum (140000)" \
  || no "[9.1] the vintage subtotal for a multi-entry legacy series must reconcile to the differenced burn — a raw sum inflates the pre-dedupe subtotal above the burn it explains (out='$V21OUT')"

# V22 — a DEGRADED harvest (harvest_basis:null → "unknown") mismatches a declared
# setpoint too, but supports NO claim about direction. V12 already pins that an
# explicit null must not be folded into "pre-dedupe"; the same discipline has to hold
# one layer up, or the direction line converts an unrecorded unit into a confident
# "phantom headroom" and states an inference as evidence. Undetermined is the honest
# answer and the operator can act on it — it says the error's size is unknown, which
# is different from saying it is small.
P=$(mk_project '{"initiative":{"tokens":100000000,"harvest_basis":"per_response"}}' 0 0)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
         tokens:{input:4000,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",harvest_basis:null,perf:{}}' \
  > "$P/.claude/metering/metering.ndjson"
V22OUT=$(gate "$P" exit)
printf '%s' "$V22OUT" | grep -q 'hazard: *mismatch' \
  && printf '%s' "$V22OUT" | grep -qi 'UNDETERMINED' \
  && ! printf '%s' "$V22OUT" | grep -qi 'phantom headroom' \
  && ! printf '%s' "$V22OUT" | grep -qi 'phantom breach' \
  && ok "[9.1] an unknown burn vintage against a declared setpoint is disclosed with the direction UNDETERMINED, claiming neither polarity" \
  || no "[9.1] a degraded harvest records no unit, so no direction can be derived from it — naming one anyway is the guess V12 refuses, restated at the setpoint layer (out='$V22OUT')"

# V23 — the two banners are MUTUALLY EXCLUSIVE, which is a design claim and therefore
# needs a check rather than a comment. A mixed window satisfies "not equal to the
# declared basis" trivially — it equals no single basis — so without the count guard
# both fire and the operator reads two headline declarations for one defect, each
# prescribing a different remedy. The mixed banner subsumes this case: a burn in no
# single unit cannot be re-denominated to match a setpoint, it has to be understood
# first.
P=$(mk_project '{"initiative":{"tokens":100000000,"harvest_basis":"per_response"}}' 0 0)
{
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.1"],
           tokens:{input:4000,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",perf:{}}'
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
           tokens:{input:100,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
} > "$P/.claude/metering/metering.ndjson"
V23OUT=$(gate "$P" exit)
printf '%s' "$V23OUT" | grep -q 'hazard: *mixed' \
  && ! printf '%s' "$V23OUT" | grep -q 'hazard: *mismatch' \
  && ok "[9.1] a mixed window raises the MIXED banner only — the setpoint-unit check defers rather than stacking a second headline on one defect" \
  || no "[9.1] both vintage banners fired for one window; a mixed burn matches no single declared basis by construction, so the count guard is what keeps this from double-reporting with two different remedies (out='$V23OUT')"

# V24 — THE CRITICAL. The anti-EXTEND qualifier on the FORESEEN OVERRUN menu must fire on
# a MISMATCH window too, not only a mixed one. V13 pins it for the mixed case; this pins
# the case that was structurally unreachable, because the qualifier was gated on N > 1
# while the mismatch banner required N == 1 — mutually exclusive BY CONSTRUCTION. The
# consequence is the live 004 shape: an operator who has just correctly re-denominated
# their ceiling DOWN reads a banner saying the burn is not a measurement, and twelve lines
# later a menu leading with EXTEND off that same inflated figure. Both halves of the
# original finding, not just the headline.
PF24=$(mk_proj 10000000)   # a tracker + estimates, so the projection returns a real CTC
CTC24=$(proj_ctc "$PF24")
set_init_budget_basis "$PF24" $(( 10001000 + CTC24 / 2 )) per_response   # burn < budget < burn + CTC
V24OUT=$(gate "$PF24" exit); V24RC=$?
printf '%s' "$V24OUT" | grep -q 'hazard: *mismatch' \
  && printf '%s' "$V24OUT" | grep -qi 'FORESEEN OVERRUN' && [ "$V24RC" -eq 0 ] \
  && printf '%s' "$V24OUT" | grep -q 'EXTEND is the wrong first move' \
  && ok "[9.1] a FORESEEN OVERRUN drawn from a UNIT-MISMATCHED record warns off EXTEND — the qualifier reaches the case it was written for" \
  || no "[9.1] the foreseen menu led with EXTEND on a mismatched record: the qualifier was gated on a mixed window while the banner required a uniform one, so it could never fire here — this is the live 004 shape and EXTEND is the one move waiting cannot undo (rc=$V24RC out='$V24OUT')"

# V25 — and the direction the qualifier argues is the direction the banner named. On this
# shape (inflated burn, correct ceiling) EXTEND is wrong because the BURN is overstated;
# on the opposite polarity it is wrong because the CEILING is. A qualifier that gives the
# same reason for both is not reading the evidence, and the reason is what an operator
# acts on once they have decided not to extend.
printf '%s' "$V24OUT" | grep -qi 'BURN side is inflated' \
  && ok "[9.1] the anti-EXTEND qualifier names WHICH side is inflated, so the operator knows what to fix rather than only what to avoid" \
  || no "[9.1] the qualifier warned off EXTEND without naming the inflated side — on this polarity the ceiling is already correct, and an operator told only 'not EXTEND' re-denominates a setpoint that was right (out='$V24OUT')"

# V26 — no initiative SETPOINT, no mismatch banner. The headline asserts that "the burn
# and the setpoint are denominated in different harvest units"; with no ceiling there is
# no setpoint to be denominated at all, so the headline states a comparison that does not
# exist and remedy 1 points at a field nobody has set. A session-only budget is a real
# configuration, not a corner case.
P=$(mk_project '{"session":{"tokens":100000000},"initiative":{"harvest_basis":"per_response"}}' 0 0)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
         tokens:{input:4000,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",perf:{}}' \
  > "$P/.claude/metering/metering.ndjson"
V26OUT=$(gate "$P" exit)
printf '%s' "$V26OUT" | grep -q 'hazard: *mismatch' \
  && no "[9.1] the mismatch banner fired with no initiative setpoint — it asserts a setpoint is mis-denominated when none exists, and its remedy names a field the project never set (out='$V26OUT')" \
  || ok "[9.1] no mismatch disclosure without an initiative setpoint — there is no comparison to be mis-denominated"

# V27 — the MIXED banner reads the declared basis too. Reusing V23's fixture (mixed window,
# basis declared per_response): the ceiling is declared to be in the TRUE unit, so the
# inflated portion of the burn overstates against it — a phantom BREACH. The banner used
# to hardcode "the likeliest direction is PHANTOM HEADROOM", which is the exact opposite,
# and it inherits every mismatch case the moment one post-fix entry lands and the window
# stops being uniform. Printing the backwards direction there sends the operator to extend
# a budget they have barely touched — the same failure V16 pins on the sibling banner.
printf '%s' "$V23OUT" | grep -qi 'phantom breach' \
  && ! printf '%s' "$V23OUT" | grep -qi 'likeliest direction is PHANTOM HEADROOM' \
  && ok "[9.1] the mixed banner DERIVES its direction from the declared setpoint basis rather than assuming headroom" \
  || no "[9.1] the mixed banner named a direction its own manifest refutes: with the ceiling declared in the post-fix unit the mixed burn OVERSTATES, and this banner takes over from the mismatch one as soon as a window stops being uniform (out='$V23OUT')"

# V28 — the headline must not out-claim the body. With a DEGRADED harvest the body
# correctly reports the direction as undetermined (V22), but "denominated in different
# harvest units" asserts the two units are KNOWN to differ — a stronger claim than an
# unrecorded unit can support, made in the half of the banner most readers act on.
P=$(mk_project '{"initiative":{"tokens":100000000,"harvest_basis":"per_response"}}' 0 0)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
         tokens:{input:4000,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",harvest_basis:null,perf:{}}' \
  > "$P/.claude/metering/metering.ndjson"
V28OUT=$(gate "$P" exit)
V28HEAD=$(printf '%s\n' "$V28OUT" | grep 'HARVEST UNIT HAZARD')
printf '%s' "$V28HEAD" | grep -qi 'UNRECORDED' \
  && ! printf '%s' "$V28HEAD" | grep -q 'denominated in different harvest units' \
  && ok "[9.1] an unrecorded burn vintage is headlined as UNRECORDED, not as a known unit difference the record cannot support" \
  || no "[9.1] the headline claimed the units are known to differ while the body said the direction is undetermined — an unrecorded unit is not a known-different unit, and the headline is the half that gets acted on (head='$V28HEAD')"

# V29 — WAIT is a first-class rung, not the absence of a remedy. On the phantom-breach
# polarity the ceiling is ALREADY correct and the burn is the stale side, which decays on
# its own as post-fix entries land. Both "fix it" moves damage a working state: re-
# denominating raises a ceiling that was right, and correcting the marker writes a
# falsehood. The banner is standing — it re-prints at every boundary until the window
# changes — so a menu whose every option is wrong is a standing instruction to break
# something. Rule 15: the designed path here is to wait, and it has to be named.
V29OUT=$(gate "$PF24" exit)
# "First rung" is checked by ORDER, not merely by presence: a menu that lists WAIT last,
# under two moves that both damage a correct state, has named it without recommending it.
V29WAIT=$(printf '%s\n' "$V29OUT" | grep -n 'WAIT' | head -1 | cut -d: -f1)
V29REDEN=$(printf '%s\n' "$V29OUT" | grep -n 'RE-DENOMINATE' | head -1 | cut -d: -f1)
[ -n "$V29WAIT" ] && [ -n "$V29REDEN" ] && [ "$V29WAIT" -lt "$V29REDEN" ] \
  && ok "[9.1] the phantom-breach remedy names WAIT as the FIRST rung, above re-denominate — the ceiling is already right and the burn side self-corrects" \
  || no "[9.1] the mismatch menu offered only re-denominate/correct-the-marker on a polarity where BOTH corrupt a correct state; the right action is to wait for post-fix entries, and a standing banner that never says so is a standing instruction to break a working setpoint (out='$V29OUT')"

# V30 — the forecast discloses its own basis. projection.sh emits claim/n/observed_weight
# precisely so an n=0 read is legible, and this gate — the ONLY consumer that prints a
# forecast to a person — read the spine and the range and never the basis. A modeled
# number and a measured one are indistinguishable once both are just digits, and the
# extend/harvest/accept call is made off those digits. On the live plane the projection
# rides 0 observed sessions and pure structural constants.
printf '%s' "$V24OUT" | grep -qi 'forecast basis:' \
  && printf '%s' "$V24OUT" | grep -qi 'MODELED' \
  && ok "[9.1] a forecast built from zero observed sessions says so — the projection's basis reaches the person deciding on it" \
  || no "[9.1] the foreseen overrun printed a cost-to-complete with no indication it is modeled rather than measured; projection.sh discloses n and claim, and the gate never reads them (out='$V24OUT')"

# V31 — the mismatch banner's decision-relevant NUMBERS are pinned, not just its prose.
# The mixed banner's equivalents carry assertions (V9/V9b); deleting these three lines
# from the mismatch banner left the whole suite green, which means the profile a person
# actually reads was unguarded while five tests guarded the paragraphs around it.
V31MISS=""
for probe in 'burn window:' 'initiative burn:' 'initiative setpoint:' 'setpoint basis:'; do
  printf '%s' "$V24OUT" | grep -q "$probe" || V31MISS="$V31MISS '$probe'"
done
[ -z "$V31MISS" ] \
  && ok "[9.1] the mismatch banner carries its numeric profile — window, burn, setpoint, declared basis" \
  || no "[9.1] the mismatch profile dropped:$V31MISS — the prose is guarded and the numbers it describes are not (out='$V24OUT')"

# V32 — MALFORMED wins the kind field when another hazard is also present, and the
# evidence for that other hazard survives the precedence. While a malformed marker
# stands the setpoint-unit check is OFF, and a check believed to be running is worse
# than one known to be off — so the instrument's state outranks the reading's. What
# precedence must NOT do is swallow the mixed window's evidence: the vintages still
# print, so the operator repairing the marker can see what they will be comparing.
P=$(mk_project '{"initiative":{"tokens":100000000,"harvest_basis":"per-response"}}' 0 0)
{
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.1"],
           tokens:{input:4000,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",perf:{}}'
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
           tokens:{input:100,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
} > "$P/.claude/metering/metering.ndjson"
V32OUT=$(gate "$P" exit)
printf '%s' "$V32OUT" | grep -q 'hazard: *malformed' \
  && ! printf '%s' "$V32OUT" | grep -q 'hazard: *mixed' \
  && printf '%s' "$V32OUT" | grep -q 'pre-dedupe' \
  && printf '%s' "$V32OUT" | grep -q 'per_response' \
  && ok "[9.1] a malformed marker outranks the mixed kind and keeps both vintages on the profile — the instrument's state is reported without hiding the reading's" \
  || no "[9.1] the malformed marker was outranked (the setpoint-unit check is then silently OFF, the one state worse than a wrong reading) or its precedence swallowed the vintage evidence (out='$V32OUT')"

# V33 — the mismatch banner pays its explanation once, where it is acted on. Same standing
# cost the mixed banner is trimmed for: nothing clears this until the window itself
# changes, and hooks/session-start.sh pipes the gate's whole stdout into every session's
# additionalContext. The direction and the remedy are identical every time; the profile
# and the warning are what an agent mid-session needs.
V33ENT=$(gate "$PF24" entry)
V33ELINES=$(printf '%s\n' "$V33ENT" | wc -l | tr -d ' ')
V33XLINES=$(printf '%s\n' "$V29OUT" | wc -l | tr -d ' ')
[ "$V33ELINES" -lt "$V33XLINES" ] \
  && printf '%s' "$V33ENT" | grep -q 'hazard: *mismatch' \
  && printf '%s' "$V33ENT" | grep -q 'not a measurement' \
  && ! printf '%s' "$V33ENT" | grep -q 'WAIT' \
  && ok "[9.1] the mismatch banner is terse at entry and full at exit (${V33ELINES} vs ${V33XLINES} lines) — profile and warning at both, remedy where it is acted on" \
  || no "[9.1] the mismatch banner re-injects its full remedy prose into every session's context; it never clears, so that is a standing charge against the work the disclosure protects (entry=${V33ELINES}L exit=${V33XLINES}L)"

# ── TORN METERING LINES: a corrupt line must not switch the gate off ──────────────
# The gate's ONLY hard stop is the actual-burn breach. The burn read used to slurp the
# whole log (`jq -rs`) with stderr redirected, so ONE unparseable line — a torn append
# from a writer killed mid-write, which an append-only log is exactly the shape to
# produce — failed the entire parse. The empty result then fell through the non-numeric
# guard to INITIATIVE_BURN=0, and the gate exited 0 in silence: a real breach switched
# off, indistinguishable from within-budget. Fail-open on the one path that must fail
# loud. The fix is the per-line `fromjson?` rung the lineage read 100 lines above
# already takes — the blast radius decides how much a corrupt line may cost.
#
# V34 — a torn line beside a breaching entry still stops. This is the whole defect: the
# fixture breaches by 5x, and pre-fix the gate said nothing at all.
P=$(mk_project '{"initiative":{"tokens":100000}}' 0 0)
{
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
           tokens:{input:500000,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
  printf '{"schema":"guv.meter.v1","session":"session-2026-06-15-001","tok'
} > "$P/.claude/metering/metering.ndjson"
V34OUT=$(gate "$P" exit); V34RC=$?
[ $V34RC -eq 3 ] \
  && printf '%s' "$V34OUT" | grep -q 'budget-gate] BREACH' \
  && printf '%s' "$V34OUT" | grep -q '500000 tokens' \
  && ok "[9.3] a torn log line drops that LINE, not the whole read — the breach beside it still stops (rc 3), where a slurp exited 0 in silence" \
  || no "[9.3] one unparseable line switched the gate's only hard stop off; a fail-open breach looks exactly like within-budget, which is the worst shape a governor can take (rc=$V34RC out='$V34OUT')"

# V35 — and the drop is ANNOUNCED. Skipping the line silently trades a fail-open for a
# quiet under-count: the burn still prints, still looks like a measurement, and is now a
# floor of unknown depth. The count is what makes it a floor rather than a number.
printf '%s' "$V34OUT" | grep -q 'TORN METERING LINES' \
  && printf '%s' "$V34OUT" | grep -q '1 line(s)' \
  && printf '%s' "$V34OUT" | grep -qi 'floor' \
  && ok "[9.3] the dropped line is announced with its count and the burn is called a FLOOR — a silent skip is a quiet under-count wearing a measurement's clothes" \
  || no "[9.3] the gate absorbed a torn line without saying so; every figure below it is then an under-count presented as a measurement (out='$V34OUT')"

# V36 — a clean log announces nothing. Without this, V35 passes against a notice that
# fires unconditionally, and the standing-banner cost this suite polices elsewhere
# (V14/V33) is paid at every boundary of every session for nothing.
P=$(mk_project '{"initiative":{"tokens":100000000}}' 1000 1000)
V36OUT=$(gate "$P" exit)
printf '%s' "$V36OUT" | grep -q 'TORN METERING LINES' \
  && no "[9.3] the torn-line notice fired on a log with no torn lines — a warning that always fires is not a warning (out='$V36OUT')" \
  || ok "[9.3] no torn-line notice when every log line parses"

# V37 — the vintage scan takes the same rung as the burn sum it describes. Both read the
# log through contrib_jq; fixing only the sum would leave the scan slurping, so a torn
# line would blank the vintages and silently switch the unit disclosure off — the same
# fail-open one layer over, and invisible because silence is what "no hazard" looks like.
P=$(mk_project '{"initiative":{"tokens":100000000}}' 1000 1000)
{
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.2"],
           tokens:{input:500,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
  printf '{"schema":"guv.meter.v1","tok'
} >> "$P/.claude/metering/metering.ndjson"
V37OUT=$(gate "$P" exit)
printf '%s' "$V37OUT" | grep -q 'hazard: *mixed' \
  && printf '%s' "$V37OUT" | grep -q 'pre-dedupe' \
  && printf '%s' "$V37OUT" | grep -q 'per_response' \
  && ok "[9.1] a torn line does not blank the vintage scan — the unit disclosure survives the same corruption the burn sum does" \
  || no "[9.1] the vintage scan still slurps: one torn line emptied it, switching the unit disclosure off silently while the burn beside it kept printing (out='$V37OUT')"

# ── [28.5] THE DENOMINATION AXIS: WHAT UNIT IS THE CEILING *IN*? ─────────────────
# The vintage axis above answers "how was this reading HARVESTED". It cannot reach a
# second, independent way burn and setpoint fail to be comparable: the number's
# DENOMINATION. The gate sums burn as a RAW four-class count (input + output +
# cache_read + cache_creation, unweighted) — that is a code constant, not a log field.
# A ceiling, though, is a bare integer, and a person may well have chosen it in
# cost-weighted tokens (base-input-equivalents: cache_read at 0.1x, cache_creation 2x,
# output 5x). Measured on guv's own record the two differ by 2.93x–6.81x across the whole
# log (3.9x–6.8x on [28.5]'s three named sessions) — and the ratio moves with each session's
# output and cache mix, which is why the remedy DISCLOSES and never converts: a divisor
# would have to be invented. This is NOT the vintage axis's reason — there a single ~2.55x
# deflator does fit (±13% across 18 reconstructed entries), and what refuses conversion is
# the lost pre-fix transcripts, not the arithmetic ([28.4]).
# Nothing in the manifest could express this, so the mismatch was undetectable by
# construction.
#
# A uniformly post-fix log with a matching declared basis — so the VINTAGE axis is
# silent and every assertion below is attributable to the denomination axis alone.
mk_denom_log() {
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-14-001",deliverable_ids:["9.0"],
           tokens:{input:1000,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.3"],
           tokens:{input:1000,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
}

# V38 — a cost_weighted ceiling against raw burn RAISES, and says so in its own words.
# The case is drawn from guv's own 004 setpoint, whose numerator reproduces only under a
# cost weighting while the gate sums raw — every boundary compared the two in silence.
# (guv's own manifest DOES declare it, as of 2026-07-27 and by operator direction — the
# reproduction is strong, though it remains inference about intent rather than a recovered
# record of one. This fixture predates that and stands on its own either way.)
P=$(mk_project '{"initiative":{"tokens":100000000,"harvest_basis":"per_response","denomination":"cost_weighted"}}' 0 0)
mk_denom_log > "$P/.claude/metering/metering.ndjson"
V38OUT=$(gate "$P" exit); V38RC=$?
printf '%s' "$V38OUT" | grep -q 'DENOMINATION' \
  && printf '%s' "$V38OUT" | grep -q 'cost_weighted' \
  && printf '%s' "$V38OUT" | grep -qi 'raw' \
  && [ $V38RC -eq 0 ] \
  && ok "[28.5] a cost_weighted setpoint against raw burn raises the denomination banner and exits 0 (a declaration, not a stop)" \
  || no "[28.5] a ceiling denominated in cost-weighted tokens was compared against a raw four-class burn with nothing said — a 3.9-6.8x error the manifest could not express (rc=$V38RC out='$V38OUT')"

# V39 — the kind field states BOTH axes, POSITIVELY. This was an inverted grep for
# `hazard: *mixed`, which passes on empty output and so could not tell "reported
# distinctly" from "no banner at all" — it passed against the pre-implementation gate.
# Worse, the state it silently blessed was `hazard: none` printed under a title ending in
# HAZARD, because the field carried UNIT_HAZARD alone. That field was total over its old
# state space and partial over the new one, and for any project whose meter only ever ran
# post-[9.1] the vintage axis is silent by construction — so `none` was the ONLY reading a
# denomination hazard could ever produce. Assert the positive text.
printf '%s' "$V38OUT" | grep -q 'hazard: *none (harvest) / mismatch (denomination)' \
  && printf '%s' "$V38OUT" | grep -q 'SETPOINT DENOMINATION HAZARD' \
  && ! printf '%s' "$V38OUT" | grep -q 'HARVEST UNIT HAZARD' \
  && ok "[28.5] the kind field names BOTH axes' states, so a denomination hazard never reports 'hazard: none' under a title ending in HAZARD" \
  || no "[28.5] the kind field does not carry the denomination axis; a live hazard reports itself as no hazard, and the handoff transcribes that into the record (out='$V38OUT')"

# V40 — raw_tokens declared: SILENT. The burn IS a raw count, so this is the matching
# case, and a banner that fires for a correct declaration is not a warning. Same log and
# same ceiling as V38, so the only difference is the declared denomination.
P=$(mk_project '{"initiative":{"tokens":100000000,"harvest_basis":"per_response","denomination":"raw_tokens"}}' 0 0)
mk_denom_log > "$P/.claude/metering/metering.ndjson"
V40OUT=$(gate "$P" exit); V40RC=$?
[ $V40RC -eq 0 ] && [ -z "$V40OUT" ] \
  && ok "[28.5] a raw_tokens setpoint matches the burn's own unit and is silent end to end" \
  || no "[28.5] the denomination check fired on a setpoint declared in the same unit the gate sums — it would then fire for every correctly-declared project (rc=$V40RC out='$V40OUT')"

# V41 — ABSENT means the check is OFF, never an assumed unit. Absent is the state of
# every project that predates the field, so guessing here would fire a 3.9x warning at
# ceilings that are perfectly well denominated. Paired with V38 on an identical fixture:
# the silence is the DECLARATION's doing, not the fixture's.
P=$(mk_project '{"initiative":{"tokens":100000000,"harvest_basis":"per_response"}}' 0 0)
mk_denom_log > "$P/.claude/metering/metering.ndjson"
V41OUT=$(gate "$P" exit); V41RC=$?
[ $V41RC -eq 0 ] && [ -z "$V41OUT" ] \
  && ok "[28.5] an undeclared denomination leaves the check OFF and silent — absent is not an assumed unit" \
  || no "[28.5] the gate inferred a denomination nobody declared; every pre-field project then gets a hazard banner for a ceiling that may be perfectly correct (rc=$V41RC out='$V41OUT')"

# V42 — an out-of-enum value reports MALFORMED and names the legal set, rather than
# guessing which unit was meant. "cost-weighted" (hyphen) is the realistic typo, and the
# hyphenated form is legal on the OTHER axis, so a guesser has every excuse to accept it.
P=$(mk_project '{"initiative":{"tokens":100000000,"harvest_basis":"per_response","denomination":"cost-weighted"}}' 0 0)
mk_denom_log > "$P/.claude/metering/metering.ndjson"
V42OUT=$(gate "$P" exit)
printf '%s' "$V42OUT" | grep -q 'MALFORMED' \
  && printf '%s' "$V42OUT" | grep -q 'cost-weighted' \
  && printf '%s' "$V42OUT" | grep -q 'raw_tokens' \
  && ok "[28.5] a denomination outside the enum reports MALFORMED and names the legal values — the check is off and says so" \
  || no "[28.5] an illegal denomination was guessed at rather than reported; a check believed to be running is worse than one known to be off (out='$V42OUT')"

# V43 — BOTH axes fire at once, and neither swallows the other. This is the case that
# forces two state variables: the live 004 manifest is a mixed vintage window AND a
# cost-weighted ceiling, and one variable can hold only one state. Folding denomination
# into the vintage hazard would silently drop whichever lost the precedence — the same
# failure V32 polices on the malformed/mixed pair.
P=$(mk_project '{"initiative":{"tokens":100000000,"harvest_basis":"pre-dedupe","denomination":"cost_weighted"}}' 0 0)
{
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-14-001",deliverable_ids:["9.0"],
           tokens:{input:1000,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",perf:{}}'
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.3"],
           tokens:{input:1000,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
} > "$P/.claude/metering/metering.ndjson"
V43OUT=$(gate "$P" exit)
printf '%s' "$V43OUT" | grep -q 'hazard: *mixed (harvest) / mismatch (denomination)' \
  && printf '%s' "$V43OUT" | grep -q 'cost_weighted' \
  && printf '%s' "$V43OUT" | grep -q 'pre-dedupe' \
  && ok "[28.5] a mixed harvest window AND a cost_weighted ceiling both report — two independent axes, two states, neither swallowed" \
  || no "[28.5] one axis suppressed the other; the live 004 manifest sits in exactly this state, so the dropped half is the one nobody would learn about (out='$V43OUT')"

# V43b — BOTH headlines are emitted when both axes fire, not one demoted to a comma
# clause. The [15.6] drift guard keys the handoff's capture list on headline STRINGS, so a
# title that never appears in output is a banner the session record never learns to carry.
# On a project sitting in both states the denomination axis is the one that never decays,
# which makes it precisely the wrong one to leave nameless.
printf '%s' "$V43OUT" | grep -q 'budget-gate\] HARVEST UNIT HAZARD' \
  && printf '%s' "$V43OUT" | grep -q 'budget-gate\] SETPOINT DENOMINATION HAZARD' \
  && ok "[28.5] both headlines are emitted when both axes fire — each is greppable by the handoff capture guard" \
  || no "[28.5] one axis fired without ever printing its headline; the handoff's capture list is keyed by headline string, so that banner is structurally absent from the record (out='$V43OUT')"

# V43c — and the two directions are RECONCILED rather than left to contradict. Each
# paragraph is correct on its own axis and they point OPPOSITE ways (the vintage ceiling
# is in the inflated unit; the denomination ceiling is the smaller side), and both name
# budgets.initiative.tokens — the SAME integer — as the remedy. An operator reading either
# alone moves that number the wrong way in a known direction. Reconciling is not
# converting: no net direction is claimed, only the destination both axes agree on.
printf '%s' "$V43OUT" | grep -q 'POINT OPPOSITE WAYS' \
  && printf '%s' "$V43OUT" | grep -qi 'no net direction' \
  && printf '%s' "$V43OUT" | grep -qi 'raw per-response tokens' \
  && ok "[28.5] when both axes fire the banner reconciles them — opposite directions named, no net direction claimed, one destination both satisfy" \
  || no "[28.5] the two axes' remedies contradict on the same integer with nothing reconciling them; whichever paragraph the operator reads first decides which way they move it (out='$V43OUT')"

# V44 — DISCLOSES, NEVER CONVERTS. The measured ratio is 3.9x-6.8x depending on session
# shape, so any single divisor the gate applied would be fabricated. The proof is that
# the figures are byte-identical to the ones printed with no hazard at all: same log,
# same ceiling, only the declaration differs. A gate that "helpfully" normalized either
# side would move a number here — and moving the setpoint is the one thing the machinery
# never does.
P=$(mk_project '{"initiative":{"tokens":100000000,"harvest_basis":"pre-dedupe"}}' 0 0)
{
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-14-001",deliverable_ids:["9.0"],
           tokens:{input:1000,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",perf:{}}'
  jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-15-001",deliverable_ids:["9.3"],
           tokens:{input:1000,output:0,cache_read:0,cache_creation:0},
           slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}'
} > "$P/.claude/metering/metering.ndjson"
V44OUT=$(gate "$P" exit)
V44BASE=$(printf '%s\n' "$V44OUT" | grep -E 'initiative (burn|setpoint):')
V44DECL=$(printf '%s\n' "$V43OUT" | grep -E 'initiative (burn|setpoint):')
[ -n "$V44BASE" ] && [ "$V44BASE" = "$V44DECL" ] \
  && printf '%s' "$V43OUT" | grep -q '100000000 tokens' \
  && ok "[28.5] declaring cost_weighted moves no number — the ceiling and the burn print exactly as they do undeclared (disclosure, never conversion)" \
  || no "[28.5] the gate converted a figure across denominations; the measured ratio spans 3.9x-6.8x by session shape, so whatever divisor it used was invented (base='$V44BASE' declared='$V44DECL')"

# V45 — THE DIRECTION, and it is the opposite of the vintage axis's. Which side is the
# smaller one decides the whole remedy, and the first draft of this banner shipped the two
# halves contradicting each other: "the CEILING is the smaller side, so the burn OVERSTATES
# against it and the headroom it appears to leave is not there." Overstated burn stops the
# gate EARLY (a phantom breach — wasteful); absent headroom is the gate stopping LATE (a
# phantom headroom — a budget quietly overrun). Re-derived against guv's own record: the
# gate reads 40.8% consumed where the ceiling's own unit puts it at 6-10%, so the error is
# unambiguously the conservative one. An operator who reads "the headroom is not there"
# does the dangerous thing on a safe signal — descopes real work to fit a ceiling nothing
# has actually approached. Assert the correct direction positively AND the inverted clause's
# absence, because both halves were present in one paragraph and each reads plausible alone.
printf '%s' "$V38OUT" | grep -q 'PHANTOM BREACH' \
  && printf '%s' "$V38OUT" | grep -q 'OVERSTATES' \
  && printf '%s' "$V38OUT" | grep -qi 'stops early\|will pause on a setpoint the real work has not reached' \
  && ! printf '%s' "$V38OUT" | grep -qi 'headroom it appears to' \
  && ! printf '%s' "$V38OUT" | grep -q 'PHANTOM HEADROOM' \
  && ok "[28.5] the denomination banner names the error as a PHANTOM BREACH — overstated burn, an early stop — and never as vanished headroom" \
  || no "[28.5] the banner's direction is self-contradictory: overstated burn and missing headroom are opposite errors with opposite remedies, and the reader acts on whichever clause they reach first (out='$V38OUT')"

# V46 — the direction has to reach the MENU, not just the banner. The extend/harvest/accept
# choice is made off the FORESEEN OVERRUN block, and the vintage axis already learned this
# the hard way (V24: a qualifier that could never fire in the case it was written for). The
# denomination axis arrives at the same menu with the OPPOSITE polarity, so inheriting the
# vintage advice would be worse than silence — that text argues the ceiling is in the
# inflated unit. Here the ceiling is the SMALLER side, so the trap is HARVEST: descoping
# real work to fit a ceiling only the units make look close.
PF45=$(mk_proj 10000000)   # lone entry, no harvest_basis declared -> vintage axis silent
CTC45=$(proj_ctc "$PF45")
set_init_budget_denom "$PF45" $(( 10001000 + CTC45 / 2 )) cost_weighted
V46OUT=$(gate "$PF45" exit); V46RC=$?
printf '%s' "$V46OUT" | grep -qi 'FORESEEN OVERRUN' && [ "$V46RC" -eq 0 ] \
  && printf '%s' "$V46OUT" | grep -q 'HARVEST is the wrong first move' \
  && printf '%s' "$V46OUT" | grep -q 'OVERSTATED' \
  && ! printf '%s' "$V46OUT" | grep -q 'EXTEND is the wrong first move' \
  && ok "[28.5] a foreseen overrun read off a cost_weighted ceiling warns off HARVEST — the denomination axis carries its own polarity to the menu, not the vintage axis's" \
  || no "[28.5] the foreseen menu gave no denomination qualifier, or gave the vintage one: on this axis the overrun is overstated and HARVEST is the trap, so inherited advice sends the operator to descope work against a ceiling nothing has reached (rc=$V46RC out='$V46OUT')"

# V47 — MALFORMED with no ceiling set must not assert a ceiling. `malformed` deliberately
# does not require a setpoint (an unreadable declaration is a manifest defect worth naming
# either way — the vintage axis argues the same at its own derivation), which puts the
# banner in reach of a project whose only setpoint is per-session. Prose that says "the
# ceiling above is in the wrong unit" would then describe a number the output never printed,
# and the `initiative setpoint:` row says so plainly two lines up. The mismatch paragraph is
# the one that asserts a definite ceiling, so its absence here is the check.
P=$(mk_project '{"initiative":{"denomination":"cost-weighted"},"session":{"tokens":100000000}}' 0 0)
mk_denom_log > "$P/.claude/metering/metering.ndjson"
V47OUT=$(gate "$P" exit); V47RC=$?
printf '%s' "$V47OUT" | grep -q 'SETPOINT DENOMINATION HAZARD' \
  && printf '%s' "$V47OUT" | grep -q 'MALFORMED' \
  && printf '%s' "$V47OUT" | grep -q 'initiative setpoint: *<none set' \
  && ! printf '%s' "$V47OUT" | grep -q 'The CEILING is therefore the SMALLER side' \
  && [ "$V47RC" -eq 0 ] \
  && ok "[28.5] a malformed denomination with no initiative ceiling names the defect without asserting a ceiling the output itself reports as unset" \
  || no "[28.5] the malformed prose described a ceiling that does not exist; the operator is sent to re-denominate a setpoint they never set, and the row two lines above says <none set> (rc=$V47RC out='$V47OUT')"

# ── V48 — the withdrawn no-divisor framing must not creep back into shipped prose ──
# [28.4] withdrew the framing that the [9.1] error is shape-dependent and therefore
# admits no deflator: measured all-class inflation is 2.31–2.88x, and one ~2.55x
# deflator fits 18 reconstructed entries to ±13%.
#
# That withdrawal has now been published incompletely TWICE, the same way both times.
# Round one left it standing in the gate header, the gate's MIXNOTE and the schema.
# Round two (2026-07-27) struck exactly the four literal strings a reviewer had
# enumerated and left THREE more — including the operator-facing `mismatch` banner,
# which printed the claim and its retraction 34 lines apart in one `exit` run. The
# defect both times was scoping the fix to the STRINGS someone listed instead of to
# the CLAIM. So this pin does two things the old one could not:
#   1. it scans every core file that carries the prose, not the three that happened
#      to be named, and it flattens newlines first so a claim that WRAPS across two
#      lines is still caught (the survivor did exactly that);
#   2. it asserts on the gate's ACTUAL OUTPUT for the banner that regressed, because
#      that is the surface that reaches a person, and on THREE site-specific positive
#      needles rather than one whole-file check — the old anti-vacuity grep passed
#      when either withdrawal site was deleted outright, since either one satisfied
#      it alone.
#
# The needles are ASSEMBLED at runtime on purpose: spelled out, they would match this
# assertion's own text and the pin would fail on itself (measured — the first version
# of this block did exactly that).
#
# NOTE the two axes are NOT symmetric. On the DENOMINATION axis "a divisor would have
# to be invented" remains TRUE — the raw/cost-weighted ratio really does move with
# session shape (2.93–6.81x measured). What is withdrawn is the VINTAGE-axis claim,
# and, separately, any statement that the two axes refuse a divisor for one shared
# reason. Both are pinned. The control plane's spike doc carries the claim too, but a
# consumer install has no control plane, so it is corrected by hand and not scanned.
V48=""
N_DIV="no single divisor conver""ts"
N_SYM="exactly as on the vintage ax""is"
N_PAR="the same reason the harvest-vintage ax""is"
N_SHAPE="varies with the shape of the ""work"
# EVERY needle is matched against the FLATTENED file, never line by line. This is not
# defensive dressing: both surviving instances wrapped mid-clause ("… the same reason /
# the harvest-vintage axis …", "… varies with the shape of the / work"), and a
# line-oriented grep silently missed both. Measured — the first draft of this pin used
# `grep -qF` per line and went GREEN on the very tree that was shipping the claim.
for f in "$GATE" "$SCHEMA" "$0" "$ROOT/.claude/metering-log.md" "$ROOT/.claude/emit-metrics.shape.md"; do
  b=$(basename "$f")
  [ -f "$f" ] || { V48="$V48 $b:MISSING"; continue; }
  flat=$(tr '\n' ' ' < "$f" | tr -s ' ')
  printf '%s' "$flat" | grep -qF "$N_DIV"   && V48="$V48 $b:no-divisor-claim"
  printf '%s' "$flat" | grep -qF "$N_SYM"   && V48="$V48 $b:vintage-parity"
  printf '%s' "$flat" | grep -qF "$N_SHAPE" && V48="$V48 $b:unqualified-shape-dependence"
  printf '%s' "$flat" | grep -qF "$N_PAR"   && V48="$V48 $b:axis-parity"
done
# The withdrawal statements are pinned as OUTPUT below, never as source prose. Pinning
# a COMMENT makes that comment undeletable, and a suite that freezes prose is why this
# file grew faster than the behavior it covers. mk_denom_log gives
# a uniformly post-fix window with a matching declared basis, so the vintage axis stays
# silent and everything asserted here is attributable to the denomination axis alone.
V48P=$(mk_project '{"initiative":{"tokens":100000000,"harvest_basis":"per_response","denomination":"cost_weighted"}}' 0 0)
mk_denom_log > "$V48P/.claude/metering/metering.ndjson"
V48OUT=$(gate "$V48P" exit)
V48FLAT=$(printf '%s' "$V48OUT" | tr '\n' ' ' | tr -s ' ')
printf '%s' "$V48OUT" | grep -q 'DENOMINATION'                        || V48="$V48 output:no-denomination-banner"
printf '%s' "$V48FLAT" | grep -qF "$N_PAR"                            && V48="$V48 output:axis-parity"
printf '%s' "$V48FLAT" | grep -qF 'Evidence there, arithmetic here'   || V48="$V48 output:withdrawal-not-printed"
[ -z "$V48" ] \
  && ok "[28.4] the withdrawn shape-dependence and axis-parity claims are absent from every core file that carries the prose AND from the mismatch banner's live output" \
  || no "[28.4] the withdrawn no-divisor claim is still shipped, or a withdrawal was deleted ($V48) — the repo carries both a claim and its retraction, and the mismatch banner is operator-facing output"

# ── V49 — the reconciliation reaches the MENU, at BOTH boundaries, exactly once ──
# The extend/harvest/accept call is made off the FORESEEN OVERRUN menu, not the banner,
# and the menu prints at ENTRY too — where the banner states no remedy at all. The other
# half of the pin is that it must appear ONCE: there were two versions of this text, and
# at exit both printed in the same output. Counts, not presence — a presence check
# passes on a duplicate.
V49=""
PF49=$(mk_proj 10000000)
# a second, post-fix entry makes the window MIXED on the vintage axis while the declared
# ceiling below keeps the denomination axis live — the live 004 manifest's own shape, and
# the only shape in which the two remedies contradict.
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-16-001",deliverable_ids:["13.5"],
         tokens:{input:1000,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}' \
  >> "$PF49/.claude/metering/metering.ndjson"
CTC49=$(proj_ctc "$PF49")
jq --argjson b "$(( 10002000 + CTC49 / 2 ))" \
   '.budgets = {initiative:{tokens:$b, harvest_basis:"pre-dedupe", denomination:"cost_weighted"}}' \
   "$PF49/.claude/project.json" > "$PF49/.b" && mv "$PF49/.b" "$PF49/.claude/project.json"
# `grep -c` counts LINES, not occurrences, so each needle is chosen to sit on one line of
# its own block; the flattened form is used for the wrapped ones.
n_of() { printf '%s' "$2" | tr '\n' ' ' | tr -s ' ' | grep -o "$1" | wc -l | tr -d ' '; }
for B in entry exit; do
  O=$(gate "$PF49" "$B")
  printf '%s' "$O" | grep -q 'FORESEEN OVERRUN' || { V49="$V49 $B:no-menu"; continue; }
  # the brief reconciliation rides the menu at BOTH boundaries, once
  [ "$(n_of 'RE-DERIVED in that unit' "$O")" = 1 ] || V49="$V49 $B:brief=$(n_of 'RE-DERIVED in that unit' "$O")"
  # and there is no SECOND, longer copy anywhere in the same output
  [ "$(n_of 'BOTH AXES ARE LIVE' "$O")" = 1 ] || V49="$V49 $B:copies=$(n_of 'BOTH AXES ARE LIVE' "$O")"
  # and the second axis's headline sentence is POINTED AT from the first, not restated:
  # appended verbatim it was the first two lines an operator read, the same sentence twice.
  h=$(n_of 'the setpoint is declared cost_weighted while burn is summed as a raw token count' "$O")
  [ "$h" = 1 ] || V49="$V49 $B:headline=$h"
done
[ -z "$V49" ] \
  && ok "[28.5] with both axes live the reconciliation rides the FORESEEN OVERRUN menu at entry AND exit, exactly once per run, with the second headline pointed at rather than restated" \
  || no "[28.5] the reconciliation is missing from the surface the extend/harvest/accept call is made from, or it printed twice in one run ($V49) — a duplicated correction is the noise the banner exists to remove"

# V50 — a MALFORMED harvest marker silences the reconciliation. The reconciler exists to
# resolve two remedies that name the same integer in opposite directions; the malformed arm
# names no remedy for the setpoint at all (it sends the operator to fix the MARKER), so
# there is no second direction to reconcile. Firing it there tells an operator both axes
# have narrowed their advice when one of them has explicitly declined to give any — and it
# contradicts the malformed arm two paragraphs above it in the same output.
V50=""
PF50=$(mk_proj 10000000)
jq -nc '{schema:"guv.meter.v1",session:"session-2026-06-16-001",deliverable_ids:["13.5"],
         tokens:{input:1000,output:0,cache_read:0,cache_creation:0},
         slice_basis:"per_deliverable",harvest_basis:"per_response",perf:{}}' \
  >> "$PF50/.claude/metering/metering.ndjson"
CTC50=$(proj_ctc "$PF50")
# identical to V49's fixture except the declared harvest basis is OUT OF ENUM
jq --argjson b "$(( 10002000 + CTC50 / 2 ))" \
   '.budgets = {initiative:{tokens:$b, harvest_basis:"per-response", denomination:"cost_weighted"}}' \
   "$PF50/.claude/project.json" > "$PF50/.b" && mv "$PF50/.b" "$PF50/.claude/project.json"
for B in entry exit; do
  O=$(gate "$PF50" "$B")
  printf '%s' "$O" | grep -q 'hazard: *malformed' || { V50="$V50 $B:not-malformed"; continue; }
  # TWO preconditions, not one. The malformed check confirms the arm under test fired; this
  # one confirms the surface the assertions below READ. At entry the banner emits no
  # reconciler by design, so the menu is the only site an entry-boundary copy could ride —
  # without this guard both count==0 checks pass against output that never printed a menu,
  # and V50 goes green on a gate whose whole forecast block was suppressed.
  printf '%s' "$O" | grep -q 'FORESEEN OVERRUN' || { V50="$V50 $B:no-menu"; continue; }
  [ "$(n_of 'BOTH AXES ARE LIVE' "$O")" = 0 ] || V50="$V50 $B:long=$(n_of 'BOTH AXES ARE LIVE' "$O")"
  [ "$(n_of 'RE-DERIVED in that unit' "$O")" = 0 ] || V50="$V50 $B:brief=$(n_of 'RE-DERIVED in that unit' "$O")"
done
[ -z "$V50" ] \
  && ok "[28.5] a malformed harvest marker silences the reconciliation — the arm that refuses a setpoint remedy is not credited with having given one" \
  || no "[28.5] the reconciliation fired against a malformed marker ($V50) — it tells the operator to RE-DERIVE the setpoint while the banner above it says to fix the marker instead"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
