#!/bin/bash
# Tests for context-management.sh + the contextManagement manifest block ([16.2]).
#
# [16.2] gives the scaffold/onboard flow a place to RECORD the operator's
# context-wall posture (the mode CHOICE) and a deterministic surface that turns
# the three population states into the right person-visible signal. The arming
# of governors (occupancy setpoint / CLAUDE_CODE_AUTO_COMPACT_WINDOW) is NOT here
# — that is [16.4] (reconciliation) and [16.3] (the env carrier). This deliverable
# is the carrier block + the discriminator + the surfacing, per the S1 finding
# (docs/spikes/16-1-context-wall-mode.md, Q2 and the build-time watch-items).
#
# The three population paths the deliverable names (and this suite proves):
#   forced-choice  — interactive scaffold writes mode = hard-stop|continue
#   headless-unset — headless scaffold writes mode = unset → a LOUD marker surfaces
#   grandfather    — a block-LESS in-field project → a ONE-TIME migration nudge
#
# The crux the S1 review flagged (watch-item c): a fresh headless scaffold and a
# block-less in-field project must NOT be told apart by block-absence alone. The
# design makes the block's PRESENCE the scaffold-provenance signal: present-unset
# = headless (loud marker), absent = predates-the-feature (grandfather nudge).
# T-disc proves the two states diverge.
#
# Pure bash + jq, no runner. Run: bash .claude/tests/context-management.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CM="$ROOT/.claude/context-management.sh"
SCHEMA="$ROOT/.claude/project.schema.json"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# mkproj <name> [mode] — a scratch project dir with a minimal manifest. With a
# mode arg the manifest carries a contextManagement block; without one the block
# is ABSENT (the grandfather / in-field state). Echoes the manifest path.
mkproj() {
  local d="$WORK/$1"; mkdir -p "$d/.claude"
  local man="$d/.claude/project.json"
  if [ -n "${2:-}" ]; then
    printf '{"name":"%s","contextManagement":{"mode":"%s"}}\n' "$1" "$2" > "$man"
  else
    printf '{"name":"%s"}\n' "$1" > "$man"
  fi
  echo "$man"
}

# ── Guard: the helper must exist (RED until it is created) ──
if [ ! -f "$CM" ]; then
  no "context-management.sh missing: $CM"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# set-mode — the writer. Records the choice; refuses an invalid one (no silent
# default at the config layer — Q1's principle applied to the writer itself).
# ─────────────────────────────────────────────────────────────────────────────

# T1 — writes hard-stop and PRESERVES existing manifest keys (jq merge, not clobber)
MAN=$(mkproj p1)
bash "$CM" set-mode "$MAN" hard-stop >/dev/null 2>&1
[ "$(jq -r '.contextManagement.mode' "$MAN")" = "hard-stop" ] \
  && ok "set-mode hard-stop writes contextManagement.mode" \
  || no "set-mode hard-stop did not write the mode"
[ "$(jq -r '.name' "$MAN")" = "p1" ] \
  && ok "set-mode preserves existing manifest keys (merge, not overwrite)" \
  || no "set-mode clobbered the manifest"

# T2 — writes continue
MAN=$(mkproj p2)
bash "$CM" set-mode "$MAN" continue >/dev/null 2>&1
[ "$(jq -r '.contextManagement.mode' "$MAN")" = "continue" ] \
  && ok "set-mode continue writes the mode" \
  || no "set-mode continue did not write the mode"

# T3 — writes the explicit unset sentinel (the headless loud-unset state)
MAN=$(mkproj p3)
bash "$CM" set-mode "$MAN" unset >/dev/null 2>&1
[ "$(jq -r '.contextManagement.mode' "$MAN")" = "unset" ] \
  && ok "set-mode unset writes the explicit unset sentinel" \
  || no "set-mode unset did not write the sentinel"

# T4 — refuses an unknown mode, LOUDLY, and leaves the manifest unchanged. A
# silent fallback to a real mode here would be the very defect Q1 rejects.
MAN=$(mkproj p4)
BEFORE=$(cat "$MAN")
if bash "$CM" set-mode "$MAN" autopilot >/dev/null 2>&1; then
  no "set-mode accepted an invalid mode (must refuse, no silent default)"
else
  ok "set-mode refuses an unknown mode (exit non-zero)"
fi
[ "$(cat "$MAN")" = "$BEFORE" ] \
  && ok "set-mode leaves the manifest unchanged on a refused write" \
  || no "set-mode mutated the manifest despite refusing the mode"

# T5 — a missing manifest is a loud failure, never a silent no-op (Rule 15)
if bash "$CM" set-mode "$WORK/nope/.claude/project.json" hard-stop >/dev/null 2>&1; then
  no "set-mode on a missing manifest must fail loud, not succeed silently"
else
  ok "set-mode on a missing manifest fails loud"
fi

# ─────────────────────────────────────────────────────────────────────────────
# surface — the reader/discriminator. Turns the manifest state into the right
# person-visible signal (or silence). session-start.sh and /status consume it.
# ─────────────────────────────────────────────────────────────────────────────

# T6 — hard-stop is a CONFIGURED mode with nothing unconfigured to shout about: the
# occupancy meter owns the wall, so surface is silent. (continue-mode advisory is
# [16.4]'s concern — T6b–T6d below — deliberately not [16.2]'s.)
MAN=$(mkproj cfg-hard-stop hard-stop)
OUT=$(bash "$CM" surface "$MAN" 2>/dev/null)
[ -z "$OUT" ] \
  && ok "surface is silent for a configured mode (hard-stop)" \
  || no "surface should be silent for configured mode hard-stop, emitted: $OUT"

# T6b — continue WITH an operator-authored window: nothing to guide, so silent. The
# operator already set their compaction point; surface does not nag. (Settings inlined
# here — seed_settings/VAR are defined later, in the reconcile section.)
MAN=$(mkproj cfg-continue-win continue)
printf '{"env":{"CLAUDE_CODE_AUTO_COMPACT_WINDOW":"180000"}}\n' > "$(dirname "$MAN")/settings.local.json"
OUT=$(bash "$CM" surface "$MAN" 2>/dev/null)
[ -z "$OUT" ] \
  && ok "surface is silent for continue mode once a window is authored" \
  || no "surface should be silent for continue + an authored window, emitted: $OUT"

# T6c — continue with NO authored window: surface emits the ONE-TIME guidance nudge AND
# records its did-fire marker. guv never arms the window ([14.2] / the ratified [16.4]
# decision); it GUIDES the operator to author one if they want an explicit point. (The
# nudge names the env key so the guidance is actionable, not just informational.)
MAN=$(mkproj cfg-continue-bare continue)
printf '{}\n' > "$(dirname "$MAN")/settings.local.json"   # settings exist, but no window authored
GUIDE_MARKER="$(dirname "$MAN")/.context-wall-continue-guided"
OUT=$(bash "$CM" surface "$MAN" 2>/dev/null)
echo "$OUT" | grep -q "CLAUDE_CODE_AUTO_COMPACT_WINDOW" \
  && ok "surface guides the operator to author a window in bare continue mode (no auto-arm)" \
  || no "surface must guide the operator to author a window for bare continue (got: $OUT)"
[ -f "$GUIDE_MARKER" ] \
  && ok "surface records the continue-guidance did-fire marker (once-ness carrier)" \
  || no "surface must record a durable marker so the continue guidance fires once"

# T6d — continue-guidance fires ONCE: with the marker present, the second run is silent.
OUT2=$(bash "$CM" surface "$MAN" 2>/dev/null)
[ -z "$OUT2" ] \
  && ok "surface continue-guidance fires once, not every session (marker honoured)" \
  || no "continue-guidance fired twice — once-ness carrier not honoured (got: $OUT2)"

# T7 — headless loud-unset (watch-item a: the marker is actually SURFACED). The
# unset sentinel surfaces the literal 'context-wall mode UNSET' phrase the S1
# finding names — proving 'loud' means visible, not written-to-a-file-no-one-reads.
MAN=$(mkproj headless unset)
OUT=$(bash "$CM" surface "$MAN" 2>/dev/null)
echo "$OUT" | grep -q "context-wall mode UNSET" \
  && ok "surface emits the loud 'context-wall mode UNSET' marker for unset mode" \
  || no "surface must emit the UNSET marker for mode=unset (got: $OUT)"

# T8 — grandfather first run (watch-items b + c): a block-LESS manifest surfaces a
# ONE-TIME migration nudge AND records that it fired (the did-fire carrier).
MAN=$(mkproj grandfather)         # no block
MARKER="$(dirname "$MAN")/.context-wall-migration-nudged"
OUT=$(bash "$CM" surface "$MAN" 2>/dev/null)
echo "$OUT" | grep -q "context-wall mode" \
  && ok "surface emits the migration nudge for a block-less in-field project" \
  || no "surface must nudge a block-less project (got: $OUT)"
[ -f "$MARKER" ] \
  && ok "surface records the did-fire marker after nudging (once-ness carrier)" \
  || no "surface must record a durable did-fire marker so the nudge fires once"

# T9 — grandfather second run (watch-item b: second-run silence). With the marker
# present the nudge must NOT fire again — once, not every session.
OUT2=$(bash "$CM" surface "$MAN" 2>/dev/null)
[ -z "$OUT2" ] \
  && ok "surface is silent on the second run (nudge fires once, not every session)" \
  || no "migration nudge fired twice — once-ness carrier not honoured (got: $OUT2)"

# T-disc — the discriminator (watch-item c). A fresh headless scaffold (block
# present, mode=unset) and a block-less in-field project must land on DIFFERENT
# paths. Block-absence ALONE must not mean 'headless'. This is the crux the S1
# review flagged; the two states are asserted to diverge, not merely 'each works'.
UNSET_MAN=$(mkproj disc-unset unset)
ABSENT_MAN=$(mkproj disc-absent)     # block absent
UNSET_OUT=$(bash "$CM" surface "$UNSET_MAN" 2>/dev/null)
ABSENT_OUT=$(bash "$CM" surface "$ABSENT_MAN" 2>/dev/null)
# present-unset → the UNSET marker (and NOT the grandfather nudge)
echo "$UNSET_OUT" | grep -q "UNSET" \
  && ok "discriminator: block-present-unset → the loud UNSET marker" \
  || no "discriminator: present-unset must surface the UNSET marker (got: $UNSET_OUT)"
# block-absent → the nudge (and NOT the UNSET marker) — proves they don't collapse
if echo "$ABSENT_OUT" | grep -q "UNSET"; then
  no "discriminator collapsed: a block-less project surfaced the UNSET marker (got: $ABSENT_OUT)"
else
  echo "$ABSENT_OUT" | grep -q "context-wall mode" \
    && ok "discriminator: block-absent → the grandfather nudge, NOT the UNSET marker" \
    || no "discriminator: block-absent must surface the migration nudge (got: $ABSENT_OUT)"
fi

# T-empty — a PRESENT block with no mode ({}) is still "scaffolded" (present), so
# jq's `// "unset"` resolves it to the loud-unset path — it must NOT be mistaken for
# a block-LESS in-field project. Pins the present-but-empty discriminator branch: a
# hand-written or partial manifest must surface UNSET, never silently grandfather.
EMPTY_MAN="$WORK/empty/.claude/project.json"; mkdir -p "$(dirname "$EMPTY_MAN")"
printf '{"name":"empty","contextManagement":{}}\n' > "$EMPTY_MAN"
OUT=$(bash "$CM" surface "$EMPTY_MAN" 2>/dev/null)
echo "$OUT" | grep -q "context-wall mode UNSET" \
  && ok "surface treats a present-but-empty block as loud-unset (not grandfather)" \
  || no "present block with no mode must surface UNSET, not the grandfather nudge (got: $OUT)"
[ ! -f "$(dirname "$EMPTY_MAN")/.context-wall-migration-nudged" ] \
  && ok "present-but-empty block does NOT write the grandfather marker (it's not block-less)" \
  || no "present-but-empty block must not take the block-absent grandfather path"

# T-renudge — watch-item b's degradation half (Rule 15). The did-fire marker write
# is best-effort (`: > "$MARKER" || true`). If it CANNOT be written, the nudge must
# RE-fire on the next run (never silently swallow itself) and surface must never
# crash. Force the write to fail by making the .claude dir read-only; skip cleanly
# if the env still allows the write (running as root bypasses the mode bits) rather
# than claim a false pass.
RN_MAN=$(mkproj renudge)          # block-less → grandfather path
RN_DIR="$(dirname "$RN_MAN")"
chmod a-w "$RN_DIR" 2>/dev/null || true
OUT=$(bash "$CM" surface "$RN_MAN" 2>/dev/null); RC=$?
if [ -f "$RN_DIR/.context-wall-migration-nudged" ]; then
  echo "  ~ skipped re-nudge test (env allows write to a read-only dir; failure path unreachable)"
  chmod u+w "$RN_DIR" 2>/dev/null || true
else
  { [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "context-wall mode"; } \
    && ok "surface re-nudges and exits 0 when the did-fire marker can't be written (best-effort)" \
    || no "a failed marker write must re-nudge and never crash (rc=$RC, out=$OUT)"
  OUT2=$(bash "$CM" surface "$RN_MAN" 2>/dev/null); RC2=$?
  { [ "$RC2" -eq 0 ] && echo "$OUT2" | grep -q "context-wall mode"; } \
    && ok "the nudge RE-fires next run when the marker still can't be written (never swallowed)" \
    || no "an unwritable marker must re-nudge next run, not silently go quiet (rc=$RC2, out=$OUT2)"
  chmod u+w "$RN_DIR" 2>/dev/null || true   # restore so the trap cleanup can rm it
fi

# T10 — surface degrades silently on a missing or unparseable manifest (Rule 15:
# a surfacing helper never blocks; absent/garbage in → nothing out, exit 0).
OUT=$(bash "$CM" surface "$WORK/nope/.claude/project.json" 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && ok "surface degrades silently on a missing manifest (exit 0, no output)" \
  || no "surface must degrade silently on a missing manifest (rc=$RC, out=$OUT)"
BADMAN="$WORK/bad/.claude/project.json"; mkdir -p "$(dirname "$BADMAN")"
printf '{ this is not json' > "$BADMAN"
OUT=$(bash "$CM" surface "$BADMAN" 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && ok "surface degrades silently on an unparseable manifest (exit 0, no output)" \
  || no "surface must degrade silently on a malformed manifest (rc=$RC, out=$OUT)"

# ─────────────────────────────────────────────────────────────────────────────
# schema — the block is schema-declared with a constrained mode enum, so a
# manifest cannot carry an unrecognised posture and additionalProperties is shut.
# ─────────────────────────────────────────────────────────────────────────────

# T11 — the schema declares contextManagement.mode as an enum of exactly the
# three population values, additionalProperties:false (mirrors the occupancy block).
jq -e '.properties.contextManagement.properties.mode.enum
       | sort == (["continue","hard-stop","unset"] | sort)' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema declares contextManagement.mode enum = {hard-stop, continue, unset}" \
  || no "schema must declare the contextManagement.mode enum with the three values"
jq -e '.properties.contextManagement.additionalProperties == false' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema shuts additionalProperties on the contextManagement block" \
  || no "contextManagement block must set additionalProperties:false (mirror occupancy)"

# ─────────────────────────────────────────────────────────────────────────────
# elicitation doors — the prose half (Rule 12: asking a human is judgment-mediated,
# so it lives in skill prose, not the deterministic helper). The discriminator
# (T-disc above) holds ONLY IF every door that writes a fresh manifest also writes
# the contextManagement block — else a fresh project surfaces no block and the
# grandfather path mistakes it for a pre-feature one. The helper cannot enforce
# that the skills call it, so these grep-assertions are the guard: each fresh-
# manifest door must carry BOTH the interactive forced choice AND the headless
# unset sentinel, both routed through set-mode. A door that silently drops the
# elicitation is exactly the masquerade the discriminator can't catch — this is
# what would fail when business logic (the door prose) drifts (Rule 8).
# ─────────────────────────────────────────────────────────────────────────────
DOORS="
init-project:$ROOT/.claude/skills/init-project/SKILL.md
onboard:$ROOT/.claude/skills/onboard/SKILL.md
scaffold:$ROOT/maintainers/plugin-src/skills/scaffold/SKILL.md
"
for entry in $DOORS; do
  name="${entry%%:*}"; file="${entry#*:}"
  if [ ! -f "$file" ]; then
    # The scaffold door's source lives in maintainers/plugin-src/ — code-repo ONLY,
    # never synced into a control plane or a consumer install. When that whole tree
    # is absent we're running outside the code repo (e.g. the dogfooding plane's
    # synced copy), so the door legitimately isn't here: skip honestly, don't fail.
    # The canonical battery runs from roots.code where the tree IS present, so the
    # real guard still runs there (and still FAILS if the tree exists but the door
    # is gone — a genuine regression, not this not-the-code-repo case).
    if [ "$name" = "scaffold" ] && [ ! -d "$ROOT/maintainers/plugin-src" ]; then
      echo "  ~ skipped $name door guard (maintainers/plugin-src absent — not the code repo)"
      continue
    fi
    no "elicitation door $name: skill file missing ($file)"
    continue
  fi
  # the interactive forced choice — the two real modes offered, no silent default
  grep -q 'set-mode .claude/project.json <hard-stop|continue>' "$file" \
    && ok "$name elicits the interactive forced choice (set-mode <hard-stop|continue>)" \
    || no "$name must offer the interactive forced choice via set-mode <hard-stop|continue>"
  # the headless loud-unset path — the explicit sentinel, never a guessed mode
  grep -q 'set-mode .claude/project.json unset' "$file" \
    && ok "$name elicits the headless loud-unset path (set-mode … unset)" \
    || no "$name must write the explicit unset sentinel on the headless path"
  # the no-silent-default principle stated in the prose (forces the choice)
  grep -qi 'force the choice' "$file" \
    && ok "$name states the no-silent-default principle (force the choice)" \
    || no "$name must instruct the operator to force the choice (no silent default)"
done

# ─────────────────────────────────────────────────────────────────────────────
# surface consumers — watch-item a names TWO loud surfaces (session-start AND
# status). session-start.sh is wired deterministically (a hook; covered by the
# session-hooks suite). /status is agent-mediated prose, so its wiring is a prose
# assertion: the door copy promises the marker surfaces "in the status report",
# and the only thing keeping that promise true is the status skill actually
# calling surface. A door that promises a surface the build never wired is the
# false-legibility defect 003 exists to kill — so guard the second surface here.
# ─────────────────────────────────────────────────────────────────────────────
STATUS_SKILL="$ROOT/.claude/skills/status/SKILL.md"
if [ ! -f "$STATUS_SKILL" ]; then
  no "status skill missing ($STATUS_SKILL) — cannot verify the second surface"
else
  grep -q 'context-management.sh surface' "$STATUS_SKILL" \
    && ok "/status wires the second watch-item-a surface (invokes surface)" \
    || no "/status must invoke surface — the door copy promises it surfaces 'in the status report'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# reconcile — the meter ↔ auto-compaction arm/disarm ([16.4]). The mode chosen in
# the manifest selects EXACTLY ONE authoritative governor (spike Q3); reconcile
# drives the [16.3] carrier to match. The [14.2] doctrine is load-bearing, taken to
# its ratified conclusion ([16.4] continue-arm decision: GUIDE, don't auto-arm):
# reconcile NEVER arms the compaction window on the operator's behalf — not the
# blessed validated_reference, not even on a [1m] --model run. In continue mode an
# operator-authored window is PRESERVED; absent one the window stays UNSET (the
# model's native auto-compaction default governs) and `surface` guides the operator
# to author one. hard-stop WITHDRAWS the window (value-free); unset/absent are no-ops
# (a hand-deployed setpoint like guv-guv's own live 250000 must survive — format-survival).
# ─────────────────────────────────────────────────────────────────────────────
VAR='CLAUDE_CODE_AUTO_COMPACT_WINDOW'
CARRIER="$ROOT/.claude/auto-compact-carrier.sh"
SETPOINT="$ROOT/.claude/compaction-setpoint.sh"
win_of() { jq -r --arg k "$VAR" '.env[$k] // empty' "$1" 2>/dev/null; }
# Seed a settings.local.json beside a manifest: a window value (or "" for none) plus
# an optional extra jq filter to add other settings (env vars, permissions). Echoes path.
seed_settings() { # <manifest> <window|""> [extra-jq-filter]
  local s; s="$(dirname "$1")/settings.local.json"; local filt="${3:-.}"
  if [ -n "$2" ]; then
    jq -nc --arg k "$VAR" --arg w "$2" "{env:{(\$k):\$w}} | $filt" > "$s"
  else
    jq -nc "{} | $filt" > "$s"
  fi
  echo "$s"
}

if [ ! -f "$CARRIER" ] || [ ! -f "$SETPOINT" ]; then
  # Both ship as .claude/*.sh and run from roots.code in the battery; an absent pair
  # means we're outside the code repo (e.g. a partial sync) — skip honestly, never
  # claim a false pass. The canonical battery runs where both are present.
  echo "  ~ skipped reconcile tests (auto-compact-carrier/compaction-setpoint absent — not the code repo)"
else
  M1M='claude-opus-4-8[1m]'

  # R1 — continue + a [1m] model + an explicit --model: the window stays UNSET. The
  # ratified [16.4] continue-arm decision is GUIDE, don't auto-arm — guv NEVER places a
  # window on the operator's behalf, not even the setpoint-blessed value, not even when
  # handed the [1m] model that would bless one. The operator authors the window; surface
  # (T6c) guides them to. reconcile itself arms nothing.
  MAN=$(mkproj r1 continue); S=$(seed_settings "$MAN" "")
  bash "$CM" reconcile "$MAN" --model "$M1M" >/dev/null 2>&1
  [ -z "$(win_of "$S")" ] \
    && ok "reconcile continue + [1m] + --model: leaves the window UNSET (guide, don't auto-arm)" \
    || no "reconcile continue must never auto-arm, even with an explicit --model (got=$(win_of "$S"))"

  # R1b — continue, NO model: the window stays UNSET. The doctrine forbids fabricating a
  # value; a standard model's recommend is 'optional' (leave unset). No blessed value →
  # nothing placed. (This is the dead-letter-AVOIDANCE counterpart: continue never
  # leaves the meter armed, but it also never invents the compaction window.)
  MAN=$(mkproj r1b continue); S=$(seed_settings "$MAN" "")
  bash "$CM" reconcile "$MAN" >/dev/null 2>&1
  [ -z "$(win_of "$S")" ] \
    && ok "reconcile continue, no model: leaves the window UNSET (never fabricates a value)" \
    || no "reconcile continue with no model must not invent a window (got=$(win_of "$S"))"

  # R1c — continue + an OPERATOR-AUTHORED window: preserved, even with a [1m] model. The
  # human's setpoint wins; reconcile never clobbers a hand-placed window with the blessed one.
  MAN=$(mkproj r1c continue); S=$(seed_settings "$MAN" "222222")
  bash "$CM" reconcile "$MAN" --model "$M1M" >/dev/null 2>&1
  [ "$(win_of "$S")" = "222222" ] \
    && ok "reconcile continue preserves an operator-authored window (the human's setpoint wins)" \
    || no "reconcile must preserve an authored window, not overwrite with the blessed value (got=$(win_of "$S"))"

  # R2 — hard-stop: WITHDRAW the window, preserving every OTHER setting (other env vars,
  # permissions). The meter owns the wall; a lingering window would pre-empt it.
  MAN=$(mkproj r2 hard-stop)
  S=$(seed_settings "$MAN" "250000" '.env.OTHER="keep" | .permissions={allow:["Bash"]}')
  bash "$CM" reconcile "$MAN" >/dev/null 2>&1
  { [ -z "$(win_of "$S")" ] \
      && [ "$(jq -r '.env.OTHER // empty' "$S")" = "keep" ] \
      && [ "$(jq -r '.permissions.allow[0] // empty' "$S")" = "Bash" ]; } \
    && ok "reconcile hard-stop: withdraws the window, preserves other env + permissions" \
    || no "reconcile hard-stop must strip ONLY the window key (win=$(win_of "$S") other=$(jq -r '.env.OTHER // empty' "$S"))"

  # R3 — unset: a NO-OP. A hand-deployed window survives untouched (the carrier never
  # strips what it never placed — guv-guv's own live 250000 is exactly this case).
  MAN=$(mkproj r3 unset); S=$(seed_settings "$MAN" "250000")
  bash "$CM" reconcile "$MAN" >/dev/null 2>&1
  [ "$(win_of "$S")" = "250000" ] \
    && ok "reconcile unset: no-op — a hand-deployed window survives (250000)" \
    || no "reconcile unset must not touch a hand-deployed window (got=$(win_of "$S"))"

  # R4 — absent block: a NO-OP too (format-survival). A pre-feature project keeps its
  # hand-deployed setpoint; reconcile never strips a window on a project that never opted in.
  MAN=$(mkproj r4); S=$(seed_settings "$MAN" "250000")   # no contextManagement block
  bash "$CM" reconcile "$MAN" >/dev/null 2>&1
  [ "$(win_of "$S")" = "250000" ] \
    && ok "reconcile absent block: no-op — format-survival preserves a hand-deployed window" \
    || no "reconcile on a block-less project must not strip the window (got=$(win_of "$S"))"

  # R5 — the round-trip with the operator's window: in continue mode reconcile PRESERVES
  # the human-authored window (guv never arms, but never strips an authored one either —
  # even on a [1m] --model run); flip to hard-stop and reconcile WITHDRAWS it. Authored
  # arm → disarm; exactly one governor at a time. Under the ratified guide-don't-auto-arm
  # decision the window is operator-authored, so the round-trip starts from a seeded one.
  MAN=$(mkproj r5 continue); S=$(seed_settings "$MAN" "333333")
  bash "$CM" reconcile "$MAN" --model "$M1M" >/dev/null 2>&1
  AFTER_ARM=$(win_of "$S")
  bash "$CM" set-mode "$MAN" hard-stop >/dev/null 2>&1
  bash "$CM" reconcile "$MAN" >/dev/null 2>&1
  AFTER_DISARM=$(win_of "$S")
  { [ "$AFTER_ARM" = "333333" ] && [ -z "$AFTER_DISARM" ]; } \
    && ok "reconcile round-trip: continue preserves the operator's window, hard-stop withdraws it (one governor at a time)" \
    || no "reconcile round-trip must preserve then withdraw the authored window (armed=$AFTER_ARM disarmed=$AFTER_DISARM)"

  # R6 — a missing manifest: clean no-op, exit 0 (Rule 15 — a reconcile helper never
  # blocks; absent in → nothing done, no crash).
  bash "$CM" reconcile "$WORK/nope/.claude/project.json" >/dev/null 2>&1; RC=$?
  [ "$RC" -eq 0 ] \
    && ok "reconcile degrades cleanly on a missing manifest (exit 0, no-op)" \
    || no "reconcile must exit 0 on a missing manifest (rc=$RC)"

  # R7 — hard-stop over a MALFORMED settings.local.json (a non-object .env): the carrier's
  # require_mergeable_settings raises a Rule-15 `die 4` refusal — a DESIGNED loud stop that
  # protects the unmergeable file. reconcile must honor all three properties at once:
  #   (a) NEVER block the session — it exits 0 (the `|| exit 0` governs reconcile's exit
  #       code, never propagating the carrier's failure as a session block);
  #   (b) NEVER clobber the file — the carrier refused before any write, so it survives
  #       byte-identical;
  #   (c) NOT swallow the loud stop — reconcile drops the carrier's `2>&1`, so the refusal
  #       reaches a direct caller's stderr instead of vanishing.
  # This is the Important-finding regression: the earlier `2>&1` silently ate the carrier's
  # designed loud refusal. (`2>&1 >/dev/null` captures stderr, discards stdout — so the
  # carrier's message lands in $ERR and the suite itself stays stderr-clean.)
  MAN=$(mkproj r7 hard-stop); S=$(seed_settings "$MAN" "" '.env="not-an-object"')
  BEFORE=$(cat "$S")
  ERR=$(bash "$CM" reconcile "$MAN" 2>&1 >/dev/null); RC=$?
  AFTER=$(cat "$S")
  { [ "$RC" -eq 0 ] && [ "$BEFORE" = "$AFTER" ] && printf '%s' "$ERR" | grep -qi 'refus'; } \
    && ok "reconcile hard-stop over malformed settings: never blocks (exit 0), never clobbers, surfaces the carrier's loud refusal (not swallowed)" \
    || no "reconcile must pass the carrier's loud refusal through without blocking or clobbering (rc=$RC clobbered=$([ "$BEFORE" = "$AFTER" ] && echo no || echo yes) err=$ERR)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
