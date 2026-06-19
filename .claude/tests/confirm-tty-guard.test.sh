#!/bin/bash
# Tests for the non-interactive human-gate guard in the shipped confirm()
# template ([15.2]). The confirm() helper lives in .claude/skills/handoff/SKILL.md
# (handoff Step 8, shared with /manual, inherited by every generated UAT/manual
# script). It is the *human-judgment* gate — a person eyeballs something and says
# yes/no — as distinct from verify(), the *mechanical* gate that runs a command.
#
# The bug this guards against (guv's own vacuous-guard lesson turned on guv): the
# pre-fix confirm() ended in `read -p ... -n 1 -r` then `[[ $REPLY =~ ^[Nn]$ ]]`.
# With no TTY the read hits EOF, $REPLY stays empty, the [[ ]] is false, and the
# function falls through to the PASS branch — so a non-interactive run reports a
# human-judgment gate as ✓ passed with no human in the loop. A vacuous pass.
#
# What this suite pins — BEHAVIORALLY, by extracting the shipped confirm()/verify()
# definitions from SKILL.md and running them with stdin closed (no TTY):
#   - confirm() with no TTY reports the gate as SKIPPED, never ✓ passed, and does
#     NOT increment PASS (the human-judgment gate cannot auto-pass without a human)
#   - the guard fires off [ -t 0 ] (interactive terminal) AND honours an explicit
#     non-interactive env flag, so a forced-non-interactive run also SKIPs
#   - the mechanical verify() gate is UNAFFECTED by the no-TTY condition — a true
#     check still reports ✓ passed (verify() reads no human input, so the guard
#     must not touch it)
#   - the guard lives in the SHIPPED template, so every generated script inherits
#     it (the extraction below would find nothing to source otherwise)
# A pure structural grep for "[ -t 0 ]" would pass on a guard wired into the wrong
# branch; running the extracted function with stdin closed is what proves intent.
# Pure bash, no test runner required.
# Run: bash .claude/tests/confirm-tty-guard.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HANDOFF="$ROOT/.claude/skills/handoff/SKILL.md"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# T0 — the shipped template exists. Everything depends on it, so bail loudly.
if [ ! -f "$HANDOFF" ]; then
  no "handoff SKILL.md (the shipped confirm() template) is missing"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

# Extract the confirm() and verify() function bodies from the SHIPPED template.
# confirm() is defined inline in handoff SKILL.md (Step 8); verify() is referenced
# as "the same verify() pattern from /manual" and defined in the /manual SKILL.md.
# awk pulls each `name() { ... }` block from its opening line to the first line that
# is a bare "}" at column 0 (the closing brace of the function). Sourcing the
# extracted text exercises the actual shipped helper, not a copy that could drift.
extract_fn() {
  # $1 = file, $2 = function name
  awk -v fn="$2" '
    $0 ~ "^"fn"\\(\\) \\{" { grab=1 }
    grab { print }
    grab && /^\}/ && $0 !~ "^"fn"\\(\\) \\{" { exit }
  ' "$1"
}

MANUAL="$ROOT/.claude/skills/manual/SKILL.md"
CONFIRM_SRC="$(extract_fn "$HANDOFF" confirm)"
VERIFY_SRC="$(extract_fn "$MANUAL" verify)"

# T1 — the shipped template actually defines confirm() (extraction found a body).
# If this fails the guard cannot be "in the shipped template" — fail loud.
if [ -n "$CONFIRM_SRC" ] && printf '%s\n' "$CONFIRM_SRC" | grep -q '^confirm() {'; then
  ok "confirm() is defined in the shipped handoff template (every generated script inherits it)"
else
  no "could not extract confirm() from the shipped handoff template"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

# run_confirm <stdin-source> <env-prefix> — define the EXTRACTED confirm() in a
# fresh subshell, run it with the given stdin, and emit the captured output
# followed by the resulting PASS/FAIL tallies so the parent can assert on observed
# behavior. confirm() is run DIRECTLY in the shell (its stdout/stderr redirected to
# a temp file), not in a command substitution — the function mutates PASS/FAIL, and
# a $(...) subshell would discard those mutations, masking a vacuous pass as PASS=0.
run_confirm() {
  local stdin_src="$1" env_prefix="$2"
  env $env_prefix bash -c '
    set -u
    # A generated script declares all three counters; the confirm() guard folds
    # a non-interactive gate into SKIP, distinct from PASS/FAIL.
    PASS=0; FAIL=0; SKIP=0
    '"$CONFIRM_SRC"'
    t="$(mktemp)"
    confirm "Does the human-judgment thing look right?" "human gate" > "$t" 2>&1
    cat "$t"; rm -f "$t"
    printf "TALLY PASS=%s FAIL=%s SKIP=%s\n" "$PASS" "$FAIL" "$SKIP"
  ' < "$stdin_src"
}

# T2 — no TTY (stdin from /dev/null): the human gate must report SKIPPED, never
# ✓ passed, and must NOT increment PASS. This is the core of the deliverable —
# the EOF read can no longer fall through to a vacuous pass.
NOTTY_OUT="$(run_confirm /dev/null "")"
if printf '%s\n' "$NOTTY_OUT" | grep -qi 'SKIP'; then
  ok "no-TTY confirm() reports the human gate as SKIPPED"
else
  no "no-TTY confirm() must report the human gate as SKIPPED (got: $(printf '%s' "$NOTTY_OUT" | tr '\n' '|'))"
fi
if printf '%s\n' "$NOTTY_OUT" | grep -q 'PASS=0' && printf '%s\n' "$NOTTY_OUT" | grep -q 'SKIP=1'; then
  ok "no-TTY confirm() does NOT increment PASS, and tracks the gate as SKIP=1 (no vacuous human-judgment pass)"
else
  no "no-TTY confirm() must count 0 PASS and 1 SKIP (got: $(printf '%s' "$NOTTY_OUT" | grep TALLY))"
fi
# The check-mark ✓ must NOT appear for a skipped human gate — that glyph is the
# "passed" signal the pre-fix bug emitted with no human present.
if printf '%s\n' "$NOTTY_OUT" | grep -q '✓'; then
  no "no-TTY confirm() still prints ✓ (the vacuous-pass glyph) for a skipped human gate"
else
  ok "no-TTY confirm() prints no ✓ for the skipped human gate"
fi

# T3 — the explicit non-interactive env flag is a load-bearing, INDEPENDENT skip
# reason — provable WITHOUT relying on the no-TTY branch. We can isolate it cleanly:
# run confirm() with the SAME stdin a real interactive answer would use — its own
# controlling terminal, redirected from /dev/tty — so `[ -t 0 ]` is TRUE and the
# no-TTY branch is INERT. With only the env flag able to trigger SKIP, a "y" queued
# ahead would PASS if the flag were a no-op. When no controlling tty is available
# (headless CI), fall back to the structural backstop (T3b) and skip this probe
# rather than assert a result the environment can't produce.
if { : < /dev/tty; } 2>/dev/null; then
  # confirm()'s stdin is the controlling terminal, so [ -t 0 ] is TRUE and the
  # no-TTY branch is inert; only the env flag can produce a SKIP here.
  FLAG_OUT="$(env GUV_NON_INTERACTIVE=1 bash -c '
    set -u
    PASS=0; FAIL=0; SKIP=0
    '"$CONFIRM_SRC"'
    t="$(mktemp)"
    confirm "human gate under explicit flag" "human gate" > "$t" 2>&1 < /dev/tty
    cat "$t"; rm -f "$t"
    printf "TALLY PASS=%s FAIL=%s SKIP=%s\n" "$PASS" "$FAIL" "$SKIP"
  ')"
  if printf '%s\n' "$FLAG_OUT" | grep -qi 'SKIP' \
     && printf '%s\n' "$FLAG_OUT" | grep -q 'PASS=0 FAIL=0 SKIP=1'; then
    ok "with a live TTY, the explicit non-interactive env flag still forces SKIP (flag is independent of -t 0)"
  else
    no "the env flag must SKIP even with an interactive TTY present (got: $(printf '%s' "$FLAG_OUT" | tr '\n' '|'))"
  fi
else
  echo "  - no controlling /dev/tty available — env-flag-vs-TTY isolation deferred to the structural backstop (T3b)"
fi
# T3b — STRUCTURAL backstop, always runs: the env-flag clause is present in the
# shipped guard. Pairs with T3 so a refactor that drops the flag (leaving only
# [ -t 0 ]) is caught even in a headless harness where T3's live-TTY probe can't run.
if printf '%s\n' "$CONFIRM_SRC" | grep -qE 'GUV_NON_INTERACTIVE'; then
  ok "the shipped confirm() guard honours an explicit GUV_NON_INTERACTIVE flag"
else
  no "the shipped confirm() guard must honour an explicit non-interactive env flag (GUV_NON_INTERACTIVE)"
fi

# T4 — the mechanical verify() gate is UNAFFECTED by the no-TTY condition. verify()
# reads no human input; a true check must still report ✓ passed with stdin closed.
# (If verify() could not be extracted, that itself is the failure — the /manual
# template is the documented source of the verify() pattern handoff reuses.)
if [ -n "$VERIFY_SRC" ] && printf '%s\n' "$VERIFY_SRC" | grep -q '^verify() {'; then
  VERIFY_OUT="$(bash -c '
    set -u
    PASS=0; FAIL=0
    '"$VERIFY_SRC"'
    t="$(mktemp)"
    verify "true" "mechanical check" > "$t" 2>&1
    cat "$t"; rm -f "$t"
    printf "TALLY PASS=%s FAIL=%s\n" "$PASS" "$FAIL"
  ' < /dev/null)"
  if printf '%s\n' "$VERIFY_OUT" | grep -q '✓' && printf '%s\n' "$VERIFY_OUT" | grep -q 'TALLY PASS=1'; then
    ok "mechanical verify() is unaffected by no-TTY — a true check still reports ✓ passed"
  else
    no "mechanical verify() must still ✓ pass a true check with no TTY (got: $(printf '%s' "$VERIFY_OUT" | tr '\n' '|'))"
  fi
else
  no "could not extract verify() from the /manual template (the documented source of the pattern)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
