#!/bin/bash
# Tests for .claude/battery-result.sh — the recorded battery verdict + its tree
# provenance (spike Prong A2, single-owner suite execution).
#
# The problem this exists for: the evaluator runs the battery by contract, the
# reviewer runs suites opportunistically, and the main session has usually just
# run one. Three actors, one shared live tree, no coordination — 1..5 batteries
# per QA pass plus the whole concurrent-QA flake class
# (friction 2026-07-21T17:00:10Z-1640628803).
#
# Single-owner is the ratified answer: ONE stage runs the battery, the others
# read its recorded result. That trade only holds if a stale result can never be
# consumed as fresh — a QA agent grading a verdict from a tree that has since
# moved is worse than no result at all, because it looks like verification. So
# every assertion below is really about ONE property: the artifact tells the
# truth about WHICH tree it describes, and refuses LOUD when it cannot.
#
# Pure bash + jq, no test runner required.
# Run: bash .claude/tests/battery-result.test.sh
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$CLAUDE_DIR/battery-result.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A plane whose roots.code points at a real git repo — the fingerprint is taken
# over the CODE repo (that is what the suites test), not the control plane.
mk_plane() {  # echoes "<plane>|<code>"
  local p c
  p=$(mktemp -d "$WORK/plane.XXXXXX")
  c=$(mktemp -d "$WORK/code.XXXXXX")
  mkdir -p "$p/.claude/metering"
  cp "$CLAUDE_DIR/roots.sh" "$p/.claude/roots.sh"
  cp "$SCRIPT" "$p/.claude/battery-result.sh"
  jq -n --arg c "$c" \
    '{name:"t",language:"shell",roots:{control:".",code:$c},commands:{},scaffoldCheck:"true",ceremony:"task"}' \
    > "$p/.claude/project.json"
  ( cd "$c" && git init -q . && git config user.email t@t && git config user.name t \
    && echo one > a.txt && git add -A && git commit -qm init )
  echo "$p|$c"
}
rec() { ( cd "$1" && shift && bash .claude/battery-result.sh record "$@" ); }
rd()  { ( cd "$1" && bash .claude/battery-result.sh read ); }

# T1 — the happy path. A recorded verdict on an unchanged tree reads back with
# its counts intact. Positive control: if this fails nothing below means anything.
IFS='|' read -r P C <<<"$(mk_plane)"
rec "$P" 0 70 2475 0 >/dev/null 2>&1
OUT=$(rd "$P" 2>&1); RC=$?
[ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '2475' && printf '%s' "$OUT" | grep -q '70' \
  && ok "an unchanged tree reads back the recorded verdict with its counts (positive control)" \
  || no "a recorded verdict on an unchanged tree must be consumable (rc=$RC out=$OUT)"

# T2 — no recording at all. The consumer must refuse, not invent a pass. An
# absent artifact is the state on a fresh clone and after any cache wipe, and
# it is indistinguishable from "the battery has not run" — which is exactly
# what it means.
IFS='|' read -r P C <<<"$(mk_plane)"
OUT=$(rd "$P" 2>&1); RC=$?
[ $RC -ne 0 ] && printf '%s' "$OUT" | grep -qiE 'no recorded|not run|absent' \
  && ok "no recorded run: refuses loud rather than reporting a verdict nobody produced" \
  || no "an absent artifact must never read as a pass (rc=$RC out=$OUT)"

# T3 — THE CORE PROPERTY. A committed change after the run moves the tree, so
# the recorded verdict no longer describes what is on disk. This is the stale-
# result failure mode named in the spike: "a stale result is consumed as fresh
# — needs the result to carry provenance or it is worse than no result".
IFS='|' read -r P C <<<"$(mk_plane)"
rec "$P" 0 70 2475 0 >/dev/null 2>&1
( cd "$C" && echo two > b.txt && git add -A && git commit -qm second )
OUT=$(rd "$P" 2>&1); RC=$?
[ $RC -ne 0 ] && printf '%s' "$OUT" | grep -qiE 'moved|stale|changed|differs' \
  && ok "a COMMIT after the run invalidates the verdict — the tree moved, so the result no longer describes it" \
  || no "a moved tree must invalidate the recorded verdict, or QA grades a run that never covered this code (rc=$RC out=$OUT)"

# T4 — the case a bare HEAD sha would MISS, and the reason this uses a
# fingerprint rather than rev-parse alone. The evaluator is invoked mid-loop
# (/guv:task step 6 runs it BEFORE the commit), so the tree it grades is
# routinely dirty. A provenance check that only compared HEAD would call this
# fresh and be wrong every single time.
IFS='|' read -r P C <<<"$(mk_plane)"
rec "$P" 0 70 2475 0 >/dev/null 2>&1
( cd "$C" && echo edited >> a.txt )   # uncommitted — HEAD is unchanged
OUT=$(rd "$P" 2>&1); RC=$?
# Must refuse for a NAMED reason. A bare rc!=0 check would pass against a script
# that does not exist at all — the vacuous-green shape this whole file is about.
[ $RC -ne 0 ] && printf '%s' "$OUT" | grep -qiE 'moved|stale|changed|differs' \
  && ok "an UNCOMMITTED edit invalidates the verdict (HEAD alone would call this fresh — the mid-loop case is always dirty)" \
  || no "a dirty-tree change must invalidate the verdict; comparing HEAD alone silently passes the most common case (rc=$RC out=$OUT)"

# T5 — untracked content. A brand-new test file is the single most likely thing
# to exist when QA runs, and it is invisible to `git diff HEAD`. If the
# fingerprint only hashed tracked changes, adding the very test under review
# would not invalidate the prior verdict.
IFS='|' read -r P C <<<"$(mk_plane)"
rec "$P" 0 70 2475 0 >/dev/null 2>&1
( cd "$C" && echo new > untracked.test.sh )
OUT=$(rd "$P" 2>&1); RC=$?
[ $RC -ne 0 ] && printf '%s' "$OUT" | grep -qiE 'moved|stale|changed|differs' \
  && ok "a new UNTRACKED file invalidates the verdict (the new test under review must not read as already-covered)" \
  || no "untracked content must count toward provenance, or adding the test being reviewed leaves the old verdict looking valid (rc=$RC out=$OUT)"

# T6 — A1/A2 interaction, and the trap that would undo both. --only records a
# verdict over a SUBSET. Consumed as a whole-tree proof it is precisely the
# vacuous green that A1's own zero-match rule exists to prevent, one level up:
# "the suite passed" would mean "one suite passed".
IFS='|' read -r P C <<<"$(mk_plane)"
rec "$P" 0 1 39 0 'bash-guard.test.sh' >/dev/null 2>&1
OUT=$(rd "$P" 2>&1); RC=$?
[ $RC -ne 0 ] && printf '%s' "$OUT" | grep -qiE 'filter|only|subset|partial' \
  && ok "a --only run is refused as a whole-tree proof and names the filter (a filtered green is not a battery green)" \
  || no "a filtered run consumed as a full verdict is a vacuous green — the exact trap A1's zero-match rule guards, one level up (rc=$RC out=$OUT)"

# T7 — a FAILING battery must still record and still read back as failing. The
# artifact is provenance, not a pass-cache: suppressing a red would make the
# single-owner trade a way to lose failures rather than a way to avoid re-runs.
IFS='|' read -r P C <<<"$(mk_plane)"
rec "$P" 1 70 2470 5 >/dev/null 2>&1
OUT=$(rd "$P" 2>&1); RC=$?
printf '%s' "$OUT" | grep -q '5' && printf '%s' "$OUT" | grep -qiE 'fail' \
  && ok "a FAILING verdict records and reads back as failing (the artifact carries provenance, it is not a pass-cache)" \
  || no "a red battery must survive the round trip — a store that only remembers greens loses failures silently (rc=$RC out=$OUT)"

# T8 — recording must not be able to lie about the tree it did not look at. A
# record taken against a plane whose code repo is unresolvable has no provenance
# to carry, so it must fail rather than write a verdict with an empty fingerprint
# (an empty fingerprint would compare equal to the next empty one and pass).
IFS='|' read -r P C <<<"$(mk_plane)"
jq '.roots.code = "/nonexistent/path/nope"' "$P/.claude/project.json" > "$P/.claude/pj.tmp" \
  && mv "$P/.claude/pj.tmp" "$P/.claude/project.json"
REC_OUT=$(rec "$P" 0 70 2475 0 2>&1); RRC=$?
OUT=$(rd "$P" 2>&1); RC=$?
# Whichever end refuses, it must SAY SO. Requiring the message keeps this from
# passing against an absent script, and pins that the refusal is a designed path
# rather than an interpreter error that happens to be nonzero.
# Discriminate on words only the REAL script emits. "battery-result" would also
# match bash's own "No such file or directory" message naming the script path,
# which is how this assertion first passed against no implementation at all.
{ [ $RRC -ne 0 ] && printf '%s' "$REC_OUT" | grep -qiE 'resolve|code repo'; } \
  || { [ $RC -ne 0 ] && printf '%s' "$OUT" | grep -qiE 'resolve|code repo'; } \
  && ok "an unresolvable code repo cannot produce a consumable verdict (no fingerprint means no provenance, not a blank one that matches everything)" \
  || no "a record with no resolvable tree must not read back as valid — an empty fingerprint matches the next empty fingerprint (record rc=$RRC/$REC_OUT read rc=$RC/$OUT)"

# T9 — the artifact belongs to the PROJECT, not to whatever directory this script
# happens to live in. This is the live topology under a plugin install: the RUNNER
# records through the plane's own copy (.claude/battery-result.sh), while the
# evaluator reads through the plugin cache, because the plugin builder rewrites
# `bash .claude/<script>.sh` to `${CLAUDE_PLUGIN_ROOT}/scripts/<script>.sh`. If the
# artifact path were resolved beside the script, those two would address different
# files and the reader would find nothing — A2 would degrade to "run the battery"
# forever, silently, on the exact installation shape guv ships.
IFS='|' read -r P C <<<"$(mk_plane)"
CACHE="$WORK/plugin-cache/scripts"; mkdir -p "$CACHE"
cp "$SCRIPT" "$CACHE/battery-result.sh"; cp "$CLAUDE_DIR/roots.sh" "$CACHE/roots.sh"
rec "$P" 0 70 2475 0 >/dev/null 2>&1                       # written by the plane's copy
OUT=$( cd "$P" && bash "$CACHE/battery-result.sh" read 2>&1 ); RC=$?   # read from the cache
[ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '2475' \
  && [ -f "$P/.claude/metering/.last-battery-result" ] \
  && [ ! -e "$CACHE/metering/.last-battery-result" ] \
  && ok "a copy running from outside the project reads the project's artifact (the plugin-install path: recorded by the plane, read from the cache)" \
  || no "the artifact must be resolved against the PROJECT, not the script's own directory — beside-the-script means the plugin-installed reader never sees what the runner wrote (rc=$RC out=$OUT)"

# ── the `fingerprint` subcommand (spike Prong B steps 4–5) ────────────────────
# The battery's hermeticity guard is a before/after fingerprint pair taken by the
# generated runner. That guard replaced the SERIAL carve, so its three failure
# modes are now the only thing standing between "a suite wrote to the live source
# tree" and nobody noticing: it must be STABLE (or every battery false-reds), it
# must be SENSITIVE (or it detects nothing), and it must FAIL LOUD AND TYPED when
# it cannot run (or the runner cannot tell "hermetic" from "unchecked").
#
# The subcommand exists so that check lives in ONE place. The runner, `record`
# and `read` all compare the same function's output; a second hand-rolled copy in
# the generated runner would drift from this one and silently stop agreeing.

# T10 — STABILITY. Two calls on an untouched tree must agree. The runner takes
# one fingerprint before the suites and one after and calls a difference a
# hermeticity breach; anything nondeterministic in here (a timestamp, an unsorted
# listing) would red every battery run and the guard would be ripped out within a
# day for crying wolf.
IFS='|' read -r P C <<<"$(mk_plane)"
FP1=$( ( cd "$P" && bash .claude/battery-result.sh fingerprint ) 2>/dev/null ); RC1=$?
FP2=$( ( cd "$P" && bash .claude/battery-result.sh fingerprint ) 2>/dev/null )
[ $RC1 -eq 0 ] && [ -n "$FP1" ] && [ "$FP1" = "$FP2" ] \
  && ok "\`fingerprint\` emits a stable non-empty value on an unchanged tree (the guard's no-false-red property)" \
  || no "\`fingerprint\` must print one stable value per tree state — an unstable one reds every battery (rc=$RC1 fp1=$FP1 fp2=$FP2)"

# T11 — SENSITIVITY, via the exact shape a leaking suite produces: a NEW UNTRACKED
# FILE dropped into the live tree (the fixture-plant that T12e, T14 and the
# ship-suite build all used to do). `git diff HEAD` cannot see it, which is why the
# fingerprint hashes untracked CONTENT — assert the property here rather than
# trusting that the internals stay that way.
printf 'planted by a leaking suite\n' > "$C/.claude-zz-leak-fixture"
FP3=$( ( cd "$P" && bash .claude/battery-result.sh fingerprint ) 2>/dev/null )
[ -n "$FP3" ] && [ "$FP3" != "$FP1" ] \
  && ok "\`fingerprint\` moves when a suite plants an untracked file in the live tree (the guard's detection property)" \
  || no "a fixture planted in the live tree must move the fingerprint — otherwise the hermeticity guard passes a leaking battery (fp1=$FP1 fp3=$FP3)"
rm -f "$C/.claude-zz-leak-fixture"

# T12 — the DESIGNED DEGRADATION signal (rule 15). Where the code repo is not a
# git repo the guard cannot run at all. It must exit 4 and print NOTHING to
# stdout, because the runner branches on exactly that to announce "hermeticity
# NOT CHECKED" instead of claiming a clean run — and a stray stdout line would be
# captured as a fingerprint and compared against the next one.
IFS='|' read -r P2 _ <<<"$(mk_plane)"
NOGIT="$WORK/not-a-repo"; mkdir -p "$NOGIT"
jq --arg c "$NOGIT" '.roots.code = $c' "$P2/.claude/project.json" > "$P2/.claude/pj.tmp" \
  && mv "$P2/.claude/pj.tmp" "$P2/.claude/project.json"
OUT=$( ( cd "$P2" && bash .claude/battery-result.sh fingerprint ) 2>/dev/null ); RC=$?
[ $RC -eq 4 ] && [ -z "$OUT" ] \
  && ok "\`fingerprint\` exits 4 with empty stdout when the code repo is not a git repo (the announced-degradation signal)" \
  || no "an unresolvable code repo must be a typed exit-4 refusal with no stdout — the runner cannot otherwise tell 'hermetic' from 'unchecked' (rc=$RC out=$OUT)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
