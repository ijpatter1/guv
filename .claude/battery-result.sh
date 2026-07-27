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
# and be wrong every time. The fingerprint therefore hashes WORKING-TREE CONTENT
# — every tracked and untracked non-ignored file — including untracked files,
# because a brand-new test file is the single most likely thing to exist when QA
# runs and it is invisible to `git diff HEAD`.
#
# And NOT HEAD *at all*: the first cut hashed HEAD + `status --porcelain` +
# `diff HEAD`, which made a no-op commit look like a moved tree and killed a
# verdict that was still exactly true. The full account is on `fingerprint()`
# below. Two questions live here and only one of them is this file's: the RECORD
# asks "does this verdict still describe these bytes" (content), the runner's
# GUARD asks "did the suites disturb the tree" (content *and* HEAD, checked
# separately over there).
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
# every downstream QA report describe a ~2,500-assertion battery as "71 passing", a
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

# A stable hash of the code repo's exact WORKING-TREE CONTENT — the bytes the
# suites ran against, and nothing else.
#
# CONTENT ONLY, deliberately: no HEAD, no `status --porcelain`, no `diff HEAD`.
# The first cut hashed all three and the result died at the commit boundary —
# committing byte-identical content moved `rev-parse HEAD` and emptied the
# porcelain, so `read` refused a verdict that was still exactly true. That is the
# normal QA order (run the battery, commit, review the commit), and both QA
# reviewers hit it minutes apart on 2026-07-27 reviewing the commit that shipped
# this. HEAD could not simply be dropped, which is the trap worth naming: `git
# diff HEAD` is RELATIVE to HEAD, so the pair reconstructed content from a moving
# pointer and each was load-bearing for the other. Hashing the files themselves is
# absolute. T11d/T11e in the suite pin both directions.
#
# Paths come from --cached AND --others, so the set is "what is here and not
# ignored" rather than "what the index knows". A tracked file deleted in the
# working tree is skipped by the -f test, which is the same contribution it makes
# after the deletion is committed — deletions move the hash exactly once, at the
# delete, not again at the commit. Untracked files are hashed by CONTENT, not
# merely listed: listing names alone would let an edit to the very test under
# review slip past unnoticed.
#
# THE EXECUTABLE BIT IS PART OF THE STATE, not just the bytes. `feedback-log.test.sh`
# asserts `[ -x ... ]` on a live source file, so a `chmod -x` between battery and
# read turns a green record into a description of a tree whose battery is now red.
# The first cut waved this off with "the next battery reds on its own" — which
# inverts the artifact's whole purpose, since the next battery is precisely what
# does NOT get run once a verdict is readable (guv eval, 2026-07-27). Taken from
# the filesystem, not `git ls-files -s`: the index carries a mode too, but reading
# it there would make `git add` move the hash and break the commit-boundary
# property above. `-x` is working-tree state and survives staging.
#
# THE ONE THING THIS DELIBERATELY DOES NOT SEE — and it is NOT as narrow as the
# first cut claimed. That version said "the index. Staging changes no byte the
# battery reads." That is FALSE, and the same eval caught it: `docs-sweep.test.sh`
# greps with `git grep`, which takes its FILE SET from the index, so `git add` of an
# untracked file changes what that suite examines without changing any byte. The
# honest statement of the limit: this hash answers "are these the same bytes", and
# a suite whose result depends on TRACKEDNESS rather than content is outside what
# the record can promise. It cannot be closed here — including the index would make
# the ordinary `git add -A && git commit` invalidate every verdict, which is the
# exact defect this function was rewritten to fix. It is closed at the other end or
# not at all (align such a suite's file set with this one's, e.g. `git grep
# --untracked`); until then it is a WRITTEN limit, pinned by T11f, not a surprise.
# The mid-run case is separate and covered: a suite that stages or commits is
# caught by the runner's own porcelain and HEAD checks, because the GUARD asks "did
# the suites disturb the tree" while the RECORD asks "does this verdict still
# describe these bytes" — and only the second question is this function's.
#
# ONE STREAM, NOT ONE HASH PER FILE. The first cut forked `shasum` per file and cost
# 17.06s over ~300 files against 0.23s for the algorithm it replaced — a 75x
# regression, paid twice per battery by the guard and once per QA read, inside the
# excursion whose premise is that the battery costs too much (guv eval, 2026-07-27).
# Streaming path, mode and content into a single hash measures **3.1s** on the same
# tree: still above the composite it replaced (that one read git's own plumbing and
# never touched an untracked byte), but ~1% of a battery instead of ~2%, and the
# remaining cost is one `cat` fork per file. Stopping here is deliberate — the
# fork-free options (`tar` streaming, `git ls-files -s`) either fold in mtime or
# read the INDEX, and reading the index would break the commit-boundary property
# above. Fields are NUL-delimited so no path or content can forge a boundary.
fingerprint() {
  ( cd "$CODE" 2>/dev/null || exit
    git ls-files -z --cached --others --exclude-standard \
      | LC_ALL=C sort -zu \
      | while IFS= read -r -d '' f; do
          [ -f "$f" ] || continue
          if [ -x "$f" ]; then printf '%s\0x\0' "$f"; else printf '%s\0-\0' "$f"; fi
          cat -- "$f" 2>/dev/null || true
          printf '\0'
        done
  ) 2>/dev/null | hash_stdin
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
    # The advice is aimed at the EVALUATOR, which is the one caller with standing to
    # run the battery. It has to name its own audience, because the reviewer's
    # contract forbids exactly what it says (guv review, 2026-07-27) — and because
    # `record` is only ever called by the maintainer-only generated runner, so a
    # consumer install has no recorder and this message is that project's PERMANENT
    # state, not a step it has yet to take.
    [ -f "$ART" ] || die "no recorded battery run — nothing has been recorded for this project yet. If you are the evaluator, run the battery. If you are the product reviewer, this is expected and is NOT a finding: most projects have no recorder at all, and you do not run the battery yourself — take test state from the evaluator's report." 3
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
    # ~2,500 assertions. Kept deliberately round: the exact count moves every time a
    # test lands, and a content-only fingerprint makes correcting a comment exactly as
    # verdict-invalidating as correcting code — so a precise figure here buys a
    # re-run's worth of battery to stay true, and buys it again next week.
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
    echo "usage: battery-result.sh record <rc> <suites> <passed> <failed> \\" >&2
    echo "                                 [<only-pattern>] [<fingerprint>] [<apass>] [<afail>]" >&2
    echo "       battery-result.sh read" >&2
    echo "       battery-result.sh fingerprint" >&2
    exit 2
    ;;
esac
