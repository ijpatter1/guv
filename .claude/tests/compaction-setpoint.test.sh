#!/bin/bash
# .claude/tests/compaction-setpoint.test.sh
# [14.2] — the compaction setpoint: engage proactive compaction at a calibrated
# window on a local extended-context (1M) model by deploying
# CLAUDE_CODE_AUTO_COMPACT_WINDOW via the settings `env` block, with the window
# DERIVED from the [13.2] context-sizing / [13.3] occupancy×turns quality zone and
# a Rule-15 degrade (manual/handoff) when window-setting cannot fire. These tests
# encode the intent (Rule 8), not just the surface:
#   - `recommend` DERIVES a window band deterministically (Rule 12) from the model
#     window + the [13.3] quality-zone setpoint (working_set = setpoint × 0.4), so the
#     deployed value is grounded, not a magic number — and the band CONTAINS the
#     dogfood-validated 250000 on the 1M model; the [13.3]→band coupling is LIVE, not
#     dormant — when working_set exceeds the 2× anchor it DRIVES the ceiling (R7);
#   - a model window too small to host the anti-thrash floor is a NAMED loud stop, never
#     a degenerate sub-floor band emitted as recommend=deploy (R8/C8, Rule 10/15);
#   - on a standard (≤ standard-window) model `recommend` degrades to `optional` —
#     the model already auto-compacts at its boundary, so a larger window is inert
#     (the [14.1] lever-a finding), and the active path is the model default + manual;
#   - `check` VERIFIES a deployed setpoint (Rule 9): in-band → ok; ABSENT → the
#     designed manual/handoff degrade is active (NOT a failure, exit 0, Rule 15);
#     malformed or out-of-band → a NAMED loud stop (Rule 10/15);
#   - settings.local.json overrides settings.json (the proven deploy surface);
#   - root resolves from --root / $CLAUDE_PROJECT_DIR, never the payload cwd (finding e);
#   - jq absent → a NAMED loud stop (a check that cannot read its inputs cannot verify).
# Pure bash + jq, no test runner. Run: bash .claude/tests/compaction-setpoint.test.sh
set -u

CSP="$(cd "$(dirname "$0")/.." && pwd)/compaction-setpoint.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap '[ "$FAIL" -eq 0 ] && rm -rf "$WORK" || echo "  (fixtures kept at $WORK)"' EXIT

# Run the script, capturing stdout, exit code, and stderr separately so a deliberate
# loud-stop test does not leak stderr into the strict-stderr battery gate.
# args: [bindir-for-restricted-PATH] -- arg...
run() {
  local bin="" errf; errf=$(mktemp)
  if [ "$1" = "--bin" ]; then bin="$2"; shift 2; fi
  [ "${1:-}" = "--" ] && shift   # separator between run's own flags and the script args
  if [ -n "$bin" ]; then
    OUT=$( PATH="$bin" bash "$CSP" "$@" 2>"$errf" ); RC=$?
  else
    OUT=$( bash "$CSP" "$@" 2>"$errf" ); RC=$?
  fi
  ERR=$(cat "$errf"); rm -f "$errf"
}

# Extract a key=value field from the recommend/check output.
field() { printf '%s' "$OUT" | sed -n "s/^$1=//p" | head -1; }

# Write a manifest fixture carrying an occupancy.threshold (the [13.3] setpoint).
# args: root threshold
write_manifest() {
  mkdir -p "$1/.claude"
  jq -n --argjson t "$2" '{name:"fix", ceremony:"phased", occupancy:{threshold:$t}}' \
    > "$1/.claude/project.json"
}

# Deploy a CLAUDE_CODE_AUTO_COMPACT_WINDOW value into a settings file's env block.
# args: root filename value   (value "" → write an env block WITHOUT the key)
deploy() {
  mkdir -p "$1/.claude"
  if [ -n "$3" ]; then
    jq -n --arg v "$3" '{env:{CLAUDE_CODE_AUTO_COMPACT_WINDOW:$v}}' > "$1/.claude/$2"
  else
    jq -n '{env:{}}' > "$1/.claude/$2"
  fi
}

echo "── recommend ─────────────────────────────────────────────────────────────────"

# R1: extended model → deploy, band floored at one standard window, CONTAINS 250000.
run -- recommend --model 'claude-opus-4-8[1m]'
[ "$RC" -eq 0 ] && ok "recommend/extended: exit 0" || no "recommend/extended: rc=$RC err=$ERR"
[ "$(field mode)" = "extended" ] && ok "recommend/extended: mode=extended (the [1m] window detected)" || no "recommend/extended: mode=$(field mode)"
[ "$(field recommend)" = "deploy" ] && ok "recommend/extended: recommend=deploy (proactive compaction CONFIRMED on 1M, [14.1] lever-a)" || no "recommend/extended: recommend=$(field recommend)"
[ "$(field window_low)" = "200000" ] && ok "recommend/extended: window_low=200000 (one standard window — the anti-thrash floor)" || no "recommend/extended: window_low=$(field window_low)"
LO=$(field window_low); HI=$(field window_high)
[ -n "$LO" ] && [ -n "$HI" ] && [ "$LO" -le 250000 ] && [ "$HI" -ge 250000 ] && ok "recommend/extended: the dogfood-validated 250000 falls inside the derived band [$LO,$HI]" || no "recommend/extended: 250000 not in band [$LO,$HI]"

# R2: the [13.3] derivation is REAL — working_set = setpoint × 0.4 informs window_high.
run -- recommend --window 1000000 --setpoint 800000
[ "$(field working_set)" = "320000" ] && ok "recommend: working_set=320000 derived as setpoint(800000) × 0.4 (the [13.3] quality-zone link)" || no "recommend: working_set=$(field working_set) (expected 320000)"
[ "$(field window_high)" = "400000" ] && ok "recommend: window_high=400000 (2× standard window ≥ working_set)" || no "recommend: window_high=$(field window_high)"

# R3: standard model → optional (the model auto-compacts at its boundary; window inert).
run -- recommend --window 200000
[ "$RC" -eq 0 ] && ok "recommend/standard: exit 0" || no "recommend/standard: rc=$RC err=$ERR"
[ "$(field mode)" = "standard" ] && ok "recommend/standard: mode=standard" || no "recommend/standard: mode=$(field mode)"
[ "$(field recommend)" = "optional" ] && ok "recommend/standard: recommend=optional (degrade — model default already compacts at the boundary)" || no "recommend/standard: recommend=$(field recommend)"
printf '%s' "$OUT" | grep -qi "boundary" && ok "recommend/standard: basis names the model's auto-compact boundary (the [14.1] lever-a degrade)" || no "recommend/standard: basis should name the boundary (out=$OUT)"

# R4: malformed --window → NAMED loud stop, non-zero (never fabricate a band).
run -- recommend --window notanumber
[ "$RC" -ne 0 ] && ok "recommend/bad-window: non-zero exit on a non-integer window" || no "recommend/bad-window: expected non-zero (rc=$RC)"
printf '%s' "$ERR" | grep -qi "window" && ok "recommend/bad-window: loud stop NAMES the bad window (Rule 10)" || no "recommend/bad-window: stderr should name it (err=$ERR)"

# R5: no manifest/setpoint → DEFAULT_CEILING fallback (a documented default, not a stop).
EMPTY="$WORK/empty"; mkdir -p "$EMPTY/.claude"
run -- recommend --window 1000000 --root "$EMPTY"
[ "$RC" -eq 0 ] && ok "recommend/no-setpoint: exit 0 (absent quality-zone setpoint degrades to the documented default, Rule 15)" || no "recommend/no-setpoint: rc=$RC err=$ERR"
[ "$(field working_set)" = "60000" ] && ok "recommend/no-setpoint: working_set=60000 from DEFAULT_CEILING(150000) × 0.4" || no "recommend/no-setpoint: working_set=$(field working_set) (expected 60000)"

# R6: occupancy.threshold is READ from the manifest via --root (the [13.3] link is wired).
M="$WORK/manifest"; write_manifest "$M" 500000
run -- recommend --window 1000000 --root "$M"
[ "$(field quality_setpoint)" = "500000" ] && ok "recommend: quality_setpoint=500000 read from the manifest occupancy.threshold" || no "recommend: quality_setpoint=$(field quality_setpoint) (expected 500000)"
[ "$(field working_set)" = "200000" ] && ok "recommend: working_set tracks the manifest setpoint (500000 × 0.4 = 200000)" || no "recommend: working_set=$(field working_set) (expected 200000)"

# R7: Rule-8 pin on the [13.3] coupling. R2/R6 only check the INTERMEDIATE working_set;
# they would still pass if the working_set were severed from the band. Here the setpoint
# is chosen so working_set (440000) EXCEEDS the 2× anchor (400000) and must DRIVE
# window_high — if the coupling is cut, window_high stays 400000 and this fails (so the
# test can actually catch a regression of the [13.3]→band link, not just its inputs).
run -- recommend --window 2000000 --setpoint 1100000
[ "$(field working_set)" = "440000" ] && ok "recommend/coupling: working_set=440000 (1100000 × 0.4)" || no "recommend/coupling: working_set=$(field working_set) (expected 440000)"
[ "$(field window_high)" = "440000" ] && ok "recommend/coupling: window_high=440000 — the [13.3] working_set LIFTS the ceiling above the 400000 anchor (the coupling is live, not dormant)" || no "recommend/coupling: window_high=$(field window_high) (expected 440000 — working_set must drive the ceiling here)"

# R8: an extended model whose 3/4 cap cannot host the anti-thrash floor (200000 < cap)
# → NAMED loud stop, never a degenerate sub-floor band emitted as recommend=deploy
# (Rule 10/15). --window 250000 → cap=187500 < 200000.
run -- recommend --window 250000
[ "$RC" -ne 0 ] && ok "recommend/too-small: non-zero — a model window too small to host the floor is a loud stop" || no "recommend/too-small: expected non-zero (rc=$RC out=$OUT)"
printf '%s' "$ERR" | grep -q "200000" && ok "recommend/too-small: loud stop names the anti-thrash floor (200000)" || no "recommend/too-small: stderr should name the floor (err=$ERR)"
printf '%s' "$OUT" | grep -q "recommend=deploy" && no "recommend/too-small: must NOT emit recommend=deploy for a degenerate band" || ok "recommend/too-small: no false recommend=deploy emitted"

echo "── check ─────────────────────────────────────────────────────────────────────"

# C1: a deployed in-band setpoint on an extended model → status=ok, exit 0.
OK="$WORK/ok"; deploy "$OK" settings.local.json 250000
run -- check --root "$OK" --model 'claude-opus-4-8[1m]'
[ "$RC" -eq 0 ] && ok "check/in-band: exit 0" || no "check/in-band: rc=$RC err=$ERR"
[ "$(field setpoint)" = "250000" ] && ok "check/in-band: setpoint=250000 read from the deployed env block" || no "check/in-band: setpoint=$(field setpoint)"
[ "$(field status)" = "ok" ] && ok "check/in-band: status=ok (250000 inside the derived band)" || no "check/in-band: status=$(field status)"

# C2: NO deployed setpoint → the designed manual/handoff degrade is active (exit 0).
NONE="$WORK/none"; mkdir -p "$NONE/.claude"
run -- check --root "$NONE" --model 'claude-opus-4-8[1m]'
[ "$RC" -eq 0 ] && ok "check/absent: exit 0 (absence is the DESIGNED degrade, not a failure — Rule 15)" || no "check/absent: rc=$RC err=$ERR"
[ "$(field setpoint)" = "unset" ] && ok "check/absent: setpoint=unset" || no "check/absent: setpoint=$(field setpoint)"
[ "$(field status)" = "degrade-active" ] && ok "check/absent: status=degrade-active" || no "check/absent: status=$(field status)"
printf '%s' "$OUT" | grep -qi "manual" && ok "check/absent: names the manual/handoff degrade path (the written Rule-15 rung)" || no "check/absent: should name the degrade path (out=$OUT)"

# C3: malformed deployed setpoint (non-integer) → NAMED loud stop, non-zero.
BAD="$WORK/bad"; deploy "$BAD" settings.local.json abc
run -- check --root "$BAD" --model 'claude-opus-4-8[1m]'
[ "$RC" -ne 0 ] && ok "check/malformed: non-zero on a non-integer deployed setpoint" || no "check/malformed: expected non-zero (rc=$RC)"
printf '%s' "$ERR" | grep -qi "integer\|numeric\|malformed" && ok "check/malformed: loud stop names the malformed value (Rule 10)" || no "check/malformed: stderr should name it (err=$ERR)"

# C4: out-of-band (below the anti-thrash floor) → NAMED loud stop naming the band.
LOW="$WORK/low"; deploy "$LOW" settings.local.json 50000
run -- check --root "$LOW" --model 'claude-opus-4-8[1m]'
[ "$RC" -ne 0 ] && ok "check/out-of-band: non-zero on a thrash-low window (50000 < the 200000 floor)" || no "check/out-of-band: expected non-zero (rc=$RC)"
printf '%s' "$ERR" | grep -q "200000" && ok "check/out-of-band: loud stop names the band floor (200000)" || no "check/out-of-band: stderr should name the band (err=$ERR)"

# C5: settings.local.json overrides settings.json (the local deploy wins).
PREC="$WORK/prec"; deploy "$PREC" settings.json 999999; deploy "$PREC" settings.local.json 250000
run -- check --root "$PREC" --model 'claude-opus-4-8[1m]'
[ "$(field setpoint)" = "250000" ] && ok "check/precedence: settings.local.json (250000) overrides settings.json (999999)" || no "check/precedence: setpoint=$(field setpoint) (expected 250000)"
[ "$(field source)" = "settings.local.json" ] && ok "check/precedence: source=settings.local.json named" || no "check/precedence: source=$(field source)"

# C6: jq absent → NAMED loud stop (cannot read JSON inputs → cannot verify).
BIN="$WORK/bin"; mkdir -p "$BIN"
for t in cat sed bash; do ln -s "$(command -v $t)" "$BIN/$t" 2>/dev/null; done
run --bin "$BIN" -- check --root "$OK" --model 'claude-opus-4-8[1m]'
[ "$RC" -ne 0 ] && ok "check/no-jq: non-zero (a check that cannot read its JSON inputs cannot verify)" || no "check/no-jq: expected non-zero (rc=$RC)"
printf '%s' "$ERR" | grep -qi "jq" && ok "check/no-jq: loud stop names jq" || no "check/no-jq: stderr should name jq (err=$ERR)"

# C7: finding (e) — root resolves from CLAUDE_PROJECT_DIR when --root is absent, never cwd.
ENV="$WORK/envroot"; deploy "$ENV" settings.local.json 250000
OUT=$( CLAUDE_PROJECT_DIR="$ENV" bash "$CSP" check --model 'claude-opus-4-8[1m]' 2>/dev/null ); RC=$?
[ "$(field setpoint)" = "250000" ] && ok "check/finding-e: resolved root from \$CLAUDE_PROJECT_DIR (read the deployed 250000)" || no "check/finding-e: setpoint=$(field setpoint) (expected 250000)"

# C8: the degenerate-band guard is SHARED — check on a too-small model window also loud-stops
# (rather than verifying against a sub-floor band). --window 250000 → cap=187500 < 200000.
TOOSMALL="$WORK/toosmall"; deploy "$TOOSMALL" settings.local.json 220000
run -- check --root "$TOOSMALL" --window 250000
[ "$RC" -ne 0 ] && ok "check/too-small: non-zero — a model window too small to host the floor is a loud stop, not a verdict" || no "check/too-small: expected non-zero (rc=$RC out=$OUT)"
printf '%s' "$ERR" | grep -q "200000" && ok "check/too-small: loud stop names the anti-thrash floor (200000)" || no "check/too-small: stderr should name the floor (err=$ERR)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
