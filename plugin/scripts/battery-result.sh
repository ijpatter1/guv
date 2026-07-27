#!/bin/bash
# .claude/battery-result.sh — the recorded battery verdict and its tree provenance
# (spike Prong A2: one owner of suite execution per QA pass).
#
# THE PROBLEM. The evaluator runs the battery by contract, the reviewer runs
# suites opportunistically, and the main session has usually just run one. Three
# actors, one shared live tree, no coordination — 1..5 batteries per QA pass at
# ~800s each, plus the entire concurrent-QA flake class (friction
# 2026-07-21T17:00:10Z-1640628803, where concurrent agents false-red each other
# by fighting over live-tree fixtures).
#
# THE TRADE. Exactly ONE stage runs the battery; the others read its recorded
# result. That is only safe if a stale result can never be consumed as fresh —
# a QA agent grading a verdict from a tree that has since moved is WORSE than no
# result at all, because it looks like verification. So the artifact carries a
# fingerprint of the exact tree it was run against, and this script refuses loud
# when that fingerprint no longer matches.
#
# WHY A FINGERPRINT AND NOT `rev-parse HEAD`. The evaluator is invoked mid-loop
# (/guv:task step 6 runs it BEFORE the commit), so the tree it grades is
# routinely dirty. A HEAD-only check would call every one of those runs fresh
# and be wrong every time. The fingerprint therefore spans HEAD, the tracked
# diff, and untracked file CONTENT — the last because a brand-new test file is
# the single most likely thing to exist when QA runs, and it is invisible to
# `git diff HEAD`.
#
# Usage:
#   battery-result.sh record <rc> <suites> <passed> <failed> \
#                            [<only-pattern>] [<fingerprint>] [<apass>] [<afail>]
#   battery-result.sh read
#   battery-result.sh fingerprint
#
# `fingerprint` exposes the same tree hash `record` and `read` compare, so the
# generated runner's HERMETICITY GUARD can call it instead of hand-rolling a
# second copy. The runner takes one before the suites and one after: a difference
# means a suite left a write in the live source tree. Note the wording — the guard
# compares before against after, so it catches writes that PERSIST, not writes
# that happen and are cleaned up; hermeticity itself is provided by the suite
# author. (maintainers/BATTERY-HERMETICITY.md carries the full accounting; an
# earlier version of this comment claimed the stronger property.) The guard is a
# residue backstop, added by spike Prong B alongside making the two carved suites
# hermetic — the carve itself still runs, on a separate scheduling argument (see
# SERIAL_SET in the generator).
#
# WHY `record` TAKES A FINGERPRINT. Left to itself it would hash the tree a THIRD
# time, after the guard's AFTER hash and after aggregation, so a tree edited in
# that window would be recorded under a state no suite ran against — and `read`
# would then call it VERIFIED. The runner passes the guard's own AFTER hash so the
# recorded provenance is exactly the hash the guard compared. Omitted or empty
# falls back to computing one (a direct caller with no guard around it).
#
# WHY ASSERTION COUNTS ARE SEPARATE FROM `passed`/`failed`. Those two are SUITE
# counts — that is what the runner has at the top level. Recording only those made
# every downstream QA report describe a 2,468-assertion battery as "71 passing", a
# 35x understatement (guv eval, 2026-07-27). The runner now also sums the per-suite
# `Results: N passed, M failed` lines and passes the totals; they record as null
# when any suite did not report one, because a partial sum presented as a total is
# the same class of error in a smaller size.
#
# Exit codes for `read` — chosen so the natural `if ... read; then` idiom means
# "there is a VERIFIED GREEN", which is the conservative reading:
#   0  provenance verified, recorded battery was green
#   1  provenance verified, recorded battery FAILED
#   3  refused — no usable provenance (absent, moved, or filtered). Run the battery.
#   4  the code repo could not be resolved
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The artifact belongs to the PROJECT, so its path is cwd-relative — the same
# "cwd is the project root" contract meter.sh, guv-cmd.sh and roots.sh carry, and
# the one the generated runner already relies on to resolve roots.code.
#
# NOT beside this script. Under a plugin install the two ends run from different
# directories: the runner records through the plane's own .claude/ copy, while the
# evaluator reads through the plugin cache (the builder rewrites
# `bash .claude/<script>.sh` to `${CLAUDE_PLUGIN_ROOT}/scripts/<script>.sh`). A
# $HERE-relative path would give them two different files, and the reader would
# refuse forever against an artifact that was written all along.
ART=".claude/metering/.last-battery-result"

die() { echo "battery-result: $1" >&2; exit "${2:-3}"; }

# shellcheck source=/dev/null
. "$HERE/roots.sh" 2>/dev/null || die "roots.sh not found beside this script" 4
CODE=$(roots_code_path 2>/dev/null) \
  || die "could not resolve a code repo from the manifest" 4
git -C "$CODE" rev-parse --verify HEAD >/dev/null 2>&1 \
  || die "could not resolve a code repo at '$CODE' (not a git repo, or no commits)" 4

hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum
  else cksum   # last resort: weaker, but a CHANGING value is all this needs
  fi | cut -d' ' -f1
}

# A stable hash of the code repo's exact content state. Untracked files are
# hashed by CONTENT, not merely listed: listing names alone would let an edit to
# the very test under review slip past unnoticed.
fingerprint() {
  {
    git -C "$CODE" rev-parse HEAD
    git -C "$CODE" status --porcelain
    git -C "$CODE" diff HEAD
    ( cd "$CODE" && git ls-files --others --exclude-standard -z \
        | LC_ALL=C sort -z \
        | while IFS= read -r -d '' f; do
            printf '%s ' "$f"; { cat -- "$f" 2>/dev/null || true; } | hash_stdin
          done )
  } 2>/dev/null | hash_stdin
}

CMD="${1:-}"; shift 2>/dev/null || true

case "$CMD" in
  record)
    [ $# -ge 4 ] || die "record needs <rc> <suites> <passed> <failed> [<only-pattern>] [<fingerprint>] [<apass>] [<afail>]" 2
    rc="$1"; suites="$2"; passed="$3"; failed="$4"
    only="${5:-}"; fp_in="${6:-}"; apass="${7:-}"; afail="${8:-}"
    # Prefer the CALLER's fingerprint. When the runner supplies one it is the
    # hermeticity guard's AFTER hash, and using it is the whole point: recomputing
    # here would describe a tree one aggregation pass LATER than the one the suites
    # actually ran against, and `read` would stamp that VERIFIED. Falling back to
    # computing one keeps a direct caller (no guard around it) working.
    fp="$fp_in"
    [ -n "$fp" ] || fp=$(fingerprint)
    # An empty fingerprint must never be written: it would compare equal to the
    # next empty one and read back as valid provenance over nothing at all.
    [ -n "$fp" ] || die "refusing to record a verdict with an empty fingerprint (could not read the code repo's state)" 4
    # Assertion totals record as a PAIR or not at all. A lone `assertions_passed`
    # would be read alongside a null failed count as "and nothing failed", which is
    # a claim nobody made.
    if [ -z "$apass" ] || [ -z "$afail" ]; then apass=""; afail=""; fi
    mkdir -p "$(dirname "$ART")" || die "could not create $(dirname "$ART")" 4
    jq -nc \
      --argjson rc "$rc" --argjson suites "$suites" \
      --argjson passed "$passed" --argjson failed "$failed" \
      --arg fp "$fp" --arg sha "$(git -C "$CODE" rev-parse HEAD)" \
      --arg only "$only" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg apass "$apass" --arg afail "$afail" \
      '{schema:"guv.battery.v1",rc:$rc,suites:$suites,passed:$passed,failed:$failed,
        assertions_passed:(if $apass=="" then null else ($apass|tonumber) end),
        assertions_failed:(if $afail=="" then null else ($afail|tonumber) end),
        sha:$sha,fingerprint:$fp,filtered:(if $only=="" then null else $only end),recorded:$ts}' \
      > "$ART" || die "could not write $ART" 4
    echo "battery-result: recorded ($passed of $suites suites passed${apass:+, $apass assertions passed, $afail failed}) against $(git -C "$CODE" rev-parse --short HEAD)${only:+ [filtered: $only]}"
    ;;

  read)
    [ -f "$ART" ] || die "no recorded battery run — nothing has been recorded for this project yet. Run the battery." 3
    rc=$(jq -r '.rc // empty' "$ART" 2>/dev/null)
    suites=$(jq -r '.suites // empty' "$ART" 2>/dev/null)
    passed=$(jq -r '.passed // empty' "$ART" 2>/dev/null)
    failed=$(jq -r '.failed // empty' "$ART" 2>/dev/null)
    sha=$(jq -r '.sha // empty' "$ART" 2>/dev/null)
    fp=$(jq -r '.fingerprint // empty' "$ART" 2>/dev/null)
    only=$(jq -r '.filtered // empty' "$ART" 2>/dev/null)
    ts=$(jq -r '.recorded // empty' "$ART" 2>/dev/null)
    # Optional and additive — an artifact written before assertion totals existed
    # reads back empty here and reports "not recorded" rather than zero.
    apass=$(jq -r '.assertions_passed // empty' "$ART" 2>/dev/null)
    afail=$(jq -r '.assertions_failed // empty' "$ART" 2>/dev/null)
    # A torn or unparseable artifact is a REFUSAL, never a pass. Same shape as the
    # [15.1] gate: a failed read must not be indistinguishable from a good one.
    { [ -n "$rc" ] && [ -n "$fp" ] && [ -n "$passed" ]; } \
      || die "the recorded run is unreadable or incomplete — treating it as absent. Run the battery." 3
    # A --only run is a verdict over a SUBSET. Consumed as a whole-tree proof it
    # is exactly the vacuous green A1's zero-match rule prevents, one level up:
    # "the suite passed" would silently mean "one suite passed".
    [ -z "$only" ] \
      || die "the recorded run was FILTERED to '$only' — a partial run is not a whole-tree proof. Run the full battery." 3
    now=$(fingerprint)
    [ "$now" = "$fp" ] \
      || die "the tree has MOVED since the recorded run (recorded at $sha, fingerprint differs) — that verdict does not describe the current code. Run the battery." 3
    echo "battery-result: VERIFIED — provenance matches the current tree"
    echo "  recorded:   $ts"
    echo "  tree:       $sha"
    # Two units, labelled. `passed`/`failed` have always been SUITE counts; naming
    # them without the noun is how "71 passing" got reported for a battery of
    # ~2,468 assertions.
    echo "  suites:     $suites total — $passed passed, $failed failed"
    if [ -n "$apass" ]; then
      echo "  assertions: $apass passed, $afail failed"
    else
      echo "  assertions: NOT RECORDED by this run — quote the suite counts above as suites, not as tests"
    fi
    [ "$rc" = "0" ] && [ "$failed" = "0" ] && exit 0
    echo "  verdict:   the recorded battery FAILED (rc=$rc)"
    exit 1
    ;;

  fingerprint)
    # Stdout is the fingerprint and nothing else — the caller captures it whole.
    # An empty hash is refused for the same reason `record` refuses one: it would
    # compare equal to the next empty hash and read as "nothing changed" over a
    # tree nobody managed to inspect.
    fp=$(fingerprint)
    [ -n "$fp" ] || die "could not fingerprint the code repo's state" 4
    printf '%s\n' "$fp"
    ;;

  *)
    echo "usage: battery-result.sh record <rc> <suites> <passed> <failed> [<only-pattern>]" >&2
    echo "       battery-result.sh read" >&2
    echo "       battery-result.sh fingerprint" >&2
    exit 2
    ;;
esac
