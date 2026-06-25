#!/bin/bash
# Tests for auto-compact-carrier.sh — the [16.3] auto-compaction env carrier.
#
# [16.2] records the operator's context-wall MODE in the manifest's
# contextManagement block. compaction-setpoint.sh ([14.2]) already DERIVES a window
# band (`recommend`) and VERIFIES a deployed value (`check`) — but nothing WRITES
# CLAUDE_CODE_AUTO_COMPACT_WINDOW into settings.local.json; deploy was a manual
# human edit. [16.3] is that missing WRITER, and it is MODE-GATED (the S1 finding's
# Q3, docs/spikes/16-1-context-wall-mode.md):
#
#   continue  → the window is PRESENT  (auto-compaction armed across the wall)
#   hard-stop → the window is ABSENT   (the occupancy setpoint owns the wall — the
#               window must never linger and pre-empt it: "exactly one authoritative
#               threshold")
#   unset / no contextManagement block → NO-OP (no mode chosen → nothing to carry;
#               and critically, a block-LESS in-field project's HAND-deployed window
#               is left untouched — the carrier must not strip a pre-feature
#               project's setpoint)
#
# The acceptance bar (REQUIREMENTS [16.3]): "the carrier round-trips under `continue`
# and is absent under `hard-stop`", and "the scaffolded `.gitignore` covers it so it
# never surfaces as untracked". This suite proves both, plus the merge/preserve
# contract, the no-guessed-value loud refusals (Rule 15), and that the carrier's
# output is the exact shape compaction-setpoint.sh `check` reads back.
#
# BOUNDARY (Rule 4): the carrier PLACES an operator-authored window value; it never
# INVENTS one (the [14.2] doctrine) and never band-checks it (that is `check`'s lane).
# The meter↔compaction RECONCILIATION (deriving the model-aware window, demoting the
# meter, the warn-band warning) is [16.4] — not here.
#
# Pure bash + jq, no runner. Run: bash .claude/tests/auto-compact-carrier.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CARRIER="$ROOT/.claude/auto-compact-carrier.sh"
CSP="$ROOT/.claude/compaction-setpoint.sh"
VAR='CLAUDE_CODE_AUTO_COMPACT_WINDOW'
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# mkproj <name> [mode] — a scratch project dir with a minimal manifest. With a mode
# arg the manifest carries a contextManagement block; without one the block is
# ABSENT (the grandfather / in-field state). Echoes the manifest path. The carrier
# defaults its settings target to settings.local.json beside the manifest.
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
# settings_path <manifest> — where the carrier writes by default.
settings_path() { echo "$(dirname "$1")/settings.local.json"; }
# window_of <settings> — the deployed window value, or empty if absent/missing.
window_of() { [ -f "$1" ] && jq -r ".env.$VAR // empty" "$1" 2>/dev/null || true; }
# run_bounded <secs> <cmd...> — run a command under a wall-clock cap so a REGRESSED
# hang (a flag-parse that spins instead of refusing) fails the suite loudly with rc
# 124 rather than stalling the whole battery. Degrades to a direct call where no
# timeout tool is installed (the fix guarantees a prompt return regardless).
run_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}

# ── Guard: the helper must exist (RED until it is created) ──
if [ ! -f "$CARRIER" ]; then
  no "auto-compact-carrier.sh missing: $CARRIER"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# continue — deploy the window (the armed state)
# ─────────────────────────────────────────────────────────────────────────────

# T1 — continue deploys the window as a STRING, CREATING settings.local.json when
# absent (settings.local.json is not pre-scaffolded — the carrier lays it down).
MAN=$(mkproj t1 continue); S=$(settings_path "$MAN")
[ -f "$S" ] && no "T1 precondition: settings.local.json should not pre-exist"
bash "$CARRIER" apply "$MAN" --window 250000 >/dev/null 2>&1
[ "$(window_of "$S")" = "250000" ] \
  && ok "continue deploys $VAR=250000 into a freshly-created settings.local.json" \
  || no "continue did not deploy the window (got: '$(window_of "$S")')"
# the value must be a JSON string (env vars are strings; the proven-firing shape)
[ "$(jq -r ".env.$VAR | type" "$S" 2>/dev/null)" = "string" ] \
  && ok "the deployed window is a JSON string (matches the proven-firing env shape)" \
  || no "the deployed window is not a string"

# ─────────────────────────────────────────────────────────────────────────────
# THE ROUND-TRIP — continue(present) → hard-stop(absent) → continue(present)
# (the acceptance bar verbatim: "round-trips under continue and is absent under
# hard-stop")
# ─────────────────────────────────────────────────────────────────────────────

# T2 — round-trip: no stale state survives a mode flip in either direction.
MANC=$(mkproj t2c continue); MANH=$(mkproj t2h hard-stop)
SC=$(settings_path "$MANC")
bash "$CARRIER" apply "$MANC" --window 250000 >/dev/null 2>&1   # continue → present
present1=$(window_of "$SC")
# flip to hard-stop against the SAME settings file → the window must be withdrawn
bash "$CARRIER" apply "$MANH" --settings "$SC" >/dev/null 2>&1  # hard-stop → absent
absent=$(window_of "$SC")
# flip back to continue → present again
bash "$CARRIER" apply "$MANC" --settings "$SC" --window 300000 >/dev/null 2>&1
present2=$(window_of "$SC")
{ [ "$present1" = "250000" ] && [ -z "$absent" ] && [ "$present2" = "300000" ]; } \
  && ok "round-trip: continue→present (250000), hard-stop→absent, continue→present (300000)" \
  || no "round-trip failed (present1='$present1' absent='$absent' present2='$present2')"

# ─────────────────────────────────────────────────────────────────────────────
# merge / preserve — the carrier touches ONLY the one key
# ─────────────────────────────────────────────────────────────────────────────

# T3 — continue MERGES: pre-existing permissions + another env var are preserved.
MAN=$(mkproj t3 continue); S=$(settings_path "$MAN")
printf '{"permissions":{"allow":["Read"]},"env":{"OTHER_VAR":"keep"}}\n' > "$S"
bash "$CARRIER" apply "$MAN" --window 250000 >/dev/null 2>&1
{ [ "$(window_of "$S")" = "250000" ] \
  && [ "$(jq -r '.env.OTHER_VAR' "$S")" = "keep" ] \
  && [ "$(jq -r '.permissions.allow[0]' "$S")" = "Read" ]; } \
  && ok "continue merges — preserves existing permissions and other env vars" \
  || no "continue clobbered existing settings keys"

# T4 — hard-stop strips SURGICALLY: only the window key is removed.
MAN=$(mkproj t4 hard-stop); S=$(settings_path "$MAN")
printf '{"permissions":{"allow":["Read"]},"env":{"OTHER_VAR":"keep","%s":"250000"}}\n' "$VAR" > "$S"
bash "$CARRIER" apply "$MAN" >/dev/null 2>&1
{ [ -z "$(window_of "$S")" ] \
  && [ "$(jq -r '.env.OTHER_VAR' "$S")" = "keep" ] \
  && [ "$(jq -r '.permissions.allow[0]' "$S")" = "Read" ]; } \
  && ok "hard-stop strips only the window — preserves other env vars and permissions" \
  || no "hard-stop did not strip surgically"

# ─────────────────────────────────────────────────────────────────────────────
# the no-op states — hard-stop never creates a file; unchosen modes leave the file
# alone (so a pre-feature project's hand-deployed setpoint is never stripped)
# ─────────────────────────────────────────────────────────────────────────────

# T5 — hard-stop NEVER creates a settings file (absence is the correct state).
MAN=$(mkproj t5 hard-stop); S=$(settings_path "$MAN")
bash "$CARRIER" apply "$MAN" >/dev/null 2>&1
[ ! -f "$S" ] \
  && ok "hard-stop with no settings file is a clean no-op (does not create an empty file)" \
  || no "hard-stop created a settings file just to express absence"

# T6 — unset is a NO-OP: a pre-existing window is left untouched (the loud-unset
# surface is [16.2]'s job; the full arm/disarm reconciliation is [16.4]'s).
MAN=$(mkproj t6 unset); S=$(settings_path "$MAN")
printf '{"env":{"%s":"999999"}}\n' "$VAR" > "$S"
bash "$CARRIER" apply "$MAN" >/dev/null 2>&1
[ "$(window_of "$S")" = "999999" ] \
  && ok "unset is a no-op — leaves an existing window untouched" \
  || no "unset mutated the settings file (got: '$(window_of "$S")')"

# T7 — block-ABSENT (grandfather / pre-feature) is a NO-OP: a hand-deployed window
# is NOT stripped. (Self-protection: running the carrier against a pre-feature
# project like guv-guv's own manifest must not remove its live 250000 setpoint.)
MAN=$(mkproj t7); S=$(settings_path "$MAN")   # no mode arg → no contextManagement block
printf '{"env":{"%s":"250000"}}\n' "$VAR" > "$S"
bash "$CARRIER" apply "$MAN" >/dev/null 2>&1
[ "$(window_of "$S")" = "250000" ] \
  && ok "block-absent grandfather is a no-op — a pre-feature project's hand-deployed window survives" \
  || no "the carrier stripped a pre-feature project's hand-deployed window (got: '$(window_of "$S")')"

# ─────────────────────────────────────────────────────────────────────────────
# loud refusals — the carrier PLACES an authored value, never a guessed one
# (Rule 15); a malformed input is a NAMED stop, not a silent best-effort.
# ─────────────────────────────────────────────────────────────────────────────

# T8 — continue WITHOUT --window is a loud refusal, and writes NOTHING.
MAN=$(mkproj t8 continue); S=$(settings_path "$MAN")
bash "$CARRIER" apply "$MAN" >/dev/null 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && [ ! -f "$S" ]; } \
  && ok "continue without --window refuses loudly and writes no carrier (no guessed setpoint)" \
  || no "continue without --window did not refuse (rc=$rc, file exists: $([ -f "$S" ] && echo yes || echo no))"

# T9 — a malformed --window (not a positive integer) is a loud refusal.
MAN=$(mkproj t9 continue); S=$(settings_path "$MAN")
bash "$CARRIER" apply "$MAN" --window "abc" >/dev/null 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && [ ! -f "$S" ]; } \
  && ok "a non-integer --window refuses loudly (a malformed value is not a window)" \
  || no "a malformed --window was accepted (rc=$rc)"

# T9b — 0 and a leading-zero window are refused: the message promises a POSITIVE
# integer, and a leading zero risks an octal misread downstream — the carrier's
# contract must match its own message.
for badwin in 0 0250000; do
  MAN=$(mkproj "twin-$badwin" continue); S=$(settings_path "$MAN")
  bash "$CARRIER" apply "$MAN" --window "$badwin" >/dev/null 2>&1
  rc=$?
  { [ "$rc" -ne 0 ] && [ ! -f "$S" ]; } \
    && ok "--window '$badwin' refused (zero / leading-zero is not a positive window)" \
    || no "--window '$badwin' was accepted (rc=$rc)"
done

# T9c — a flag with NO following value refuses loudly and does NOT hang. `shift 2`
# on a one-element arg list leaves the flag in place, so an unguarded loop spins
# forever — a hang is the one outcome Rule 15 forbids (neither result nor loud stop).
MAN=$(mkproj t9c continue); S=$(settings_path "$MAN")
run_bounded 10 bash "$CARRIER" apply "$MAN" --window >/dev/null 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ ! -f "$S" ]; } \
  && ok "a trailing --window with no value refuses loudly without hanging" \
  || no "a trailing --window with no value did not refuse cleanly (rc=$rc; 124=hung/timed out)"
# the same guard protects --settings (the other value-taking flag) — and like the
# --window sibling above, the loud refusal writes nothing (it dies at the arg-guard
# before any settings path is computed), so assert the no-file clause symmetrically.
run_bounded 10 bash "$CARRIER" apply "$MAN" --settings >/dev/null 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ ! -f "$S" ]; } \
  && ok "a trailing --settings with no value refuses loudly without hanging" \
  || no "a trailing --settings with no value did not refuse cleanly (rc=$rc; 124=hung)"

# T9d — a settings file that is valid JSON but whose .env is NOT an object is a
# NAMED loud stop, never a cryptic jq error or a clobber. (T11 covers malformed
# JSON; this covers well-formed-but-wrong-shape — the merge `.env + {…}` can't run.)
MAN=$(mkproj t9d continue); S=$(settings_path "$MAN")
printf '{"env":"oops"}\n' > "$S"
before=$(cat "$S")
bash "$CARRIER" apply "$MAN" --window 250000 >/dev/null 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && [ "$(cat "$S")" = "$before" ]; } \
  && ok "a non-object .env is refused with a named stop, not merged into or clobbered" \
  || no "the carrier mishandled a non-object .env (rc=$rc)"

# T10 — a missing manifest is a loud die.
bash "$CARRIER" apply "$WORK/does-not-exist/project.json" --window 250000 >/dev/null 2>&1
[ $? -ne 0 ] \
  && ok "a missing manifest dies loudly (the mode is read from it)" \
  || no "a missing manifest did not die"

# T11 — an EXISTING but INVALID-JSON settings file is NOT clobbered (Rule 15: look
# before you overwrite; refuse rather than silently destroy hand-edited content).
MAN=$(mkproj t11 continue); S=$(settings_path "$MAN")
printf 'this is not json {{{\n' > "$S"
before=$(cat "$S")
bash "$CARRIER" apply "$MAN" --window 250000 >/dev/null 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && [ "$(cat "$S")" = "$before" ]; } \
  && ok "an invalid existing settings.local.json is refused, not clobbered" \
  || no "the carrier clobbered or accepted an invalid settings file (rc=$rc)"

# ─────────────────────────────────────────────────────────────────────────────
# integration — the carrier's output is exactly what compaction-setpoint.sh reads
# ─────────────────────────────────────────────────────────────────────────────

# T12 — deploy via the carrier, then VERIFY via compaction-setpoint.sh `check`:
# the verifier reads the carrier's settings.local.json and reports the window
# in-band (status=ok). Proves the two agree on the deploy shape and surface.
if [ -f "$CSP" ]; then
  MAN=$(mkproj t12 continue); D=$(dirname "$(dirname "$MAN")")
  bash "$CARRIER" apply "$MAN" --window 250000 >/dev/null 2>&1
  out=$(bash "$CSP" check --window 1000000 --root "$D" 2>/dev/null)
  { echo "$out" | grep -q '^status=ok$' \
    && echo "$out" | grep -q '^source=settings.local.json$' \
    && echo "$out" | grep -q '^setpoint=250000$'; } \
    && ok "compaction-setpoint.sh check reads the carrier's deploy as in-band (status=ok, 250000)" \
    || no "the carrier's output was not consumable by compaction-setpoint.sh check (got: $out)"
else
  echo "  ~ skipped check-integration (compaction-setpoint.sh absent: $CSP)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# the scaffolded .gitignore covers the carrier file (never surfaces as untracked)
# ─────────────────────────────────────────────────────────────────────────────

# T13 — the scaffold .gitignore template (build-plugin.sh copies $ROOT/.gitignore
# verbatim into the shipped shell) covers .claude/settings.local.json, so a fresh
# scaffold never surfaces the carried window as untracked. Portable across the code
# repo and the dogfooding control plane — both are guv-governed and carry the entry.
# In the PLUGIN-RECONSTRUCTION layout (build-plugin's run-plugin-tests.sh rebuilds a
# .claude/ tree at $WORK with no top-level scaffold .gitignore) there is nothing to
# assert against, so this SKIPS there — the assertion still runs for real in the
# canonical battery. A skip, never a fail: a missing scaffold template is "not this
# layout's concern", not a coverage failure (mirrors the compaction-setpoint skip).
if [ -f "$ROOT/.gitignore" ]; then
  grep -qE '(^|/)\.claude/settings\.local\.json$' "$ROOT/.gitignore" \
    && ok "the scaffolded .gitignore covers .claude/settings.local.json (carrier never untracked)" \
    || no "the scaffolded .gitignore does not cover .claude/settings.local.json"
else
  echo "  ~ skipped .gitignore-coverage check (no $ROOT/.gitignore — plugin-reconstruction layout carries no scaffold template to assert against)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
