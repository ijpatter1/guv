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

# T6 — a CONFIGURED mode surfaces nothing here. The choice is made; there is no
# unconfigured state to shout about. (advisory reporting in continue mode is
# [16.4]'s concern, deliberately not [16.2]'s.)
for m in hard-stop continue; do
  MAN=$(mkproj "cfg-$m" "$m")
  OUT=$(bash "$CM" surface "$MAN" 2>/dev/null)
  [ -z "$OUT" ] \
    && ok "surface is silent for a configured mode ($m)" \
    || no "surface should be silent for configured mode $m, emitted: $OUT"
done

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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
