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
# generated runner. It did NOT replace the SERIAL carve — the carve still runs, on
# a measured scheduling argument (guv 2089cc9); the guard took over the safety
# argument only, and only for RESIDUE (a plant-and-clean write leaves before ==
# after and passes it — see the BATTERY-HERMETICITY audit's third limit, and
# T11j2 in setup-control-plane.test.sh). That audit's path is deliberately NOT
# spelled out here: build-plugin.sh partitions maintainer-only suites by grepping
# the whole file — comments included — against MAINTAINER_ONLY, whose first
# alternative is the maintainer directory's name with a trailing slash. Writing
# that token in a comment silently unships this consumer suite. Verified twice
# while writing this very comment: each time the builder DELETED
# plugin/tests/battery-result.test.sh, and ship-suite.test.sh derives the same
# rule from the same source, so nothing red-lights.
#
# Within that scope its three failure modes are what stand between "a suite left a
# write in the live source tree" and nobody noticing: it must be STABLE (or every
# battery false-reds), it must be SENSITIVE (or it detects nothing), and it must
# FAIL LOUD AND TYPED when it cannot run (or the runner cannot tell "hermetic"
# from "unchecked").
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

# T11b — the discriminator T11 is NOT. T11 creates a new file, and `git status
# --porcelain` reports that on its own — so T11 passes even if the fingerprint only
# LISTED untracked names and never hashed their content. The half of the design the
# header comment spends seven lines defending was therefore untested (guv eval,
# 2026-07-27). This is the case that separates them: EDIT an untracked file that
# already existed. Its porcelain line is byte-identical before and after ("?? path"),
# so only content hashing can move the fingerprint.
FP3B=$( ( cd "$P" && bash .claude/battery-result.sh fingerprint ) 2>/dev/null )
printf 'the suite under review, now with a second assertion\n' > "$C/.claude-zz-leak-fixture"
FP3C=$( ( cd "$P" && bash .claude/battery-result.sh fingerprint ) 2>/dev/null )
[ -n "$FP3C" ] && [ "$FP3C" != "$FP3B" ] \
  && ok "\`fingerprint\` moves when an EXISTING untracked file's CONTENT changes (porcelain shows the same '?? path' either way — this is what proves content is hashed, not just names)" \
  || no "editing an untracked file must move the fingerprint: without content hashing, changing the very test under review leaves the prior verdict reading as valid (fp=$FP3B -> $FP3C)"
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

# ── `record` takes the guard's fingerprint (guv eval, 2026-07-27) ─────────────
# The runner takes an AFTER fingerprint, then aggregates, then records. Left to
# recompute its own, `record` would hash the tree a THIRD time — one aggregation
# pass and one census later — so a tree edited in that window would be recorded
# under a state no suite ran against, and `read` would stamp it VERIFIED. The
# runner passes its AFTER hash in; these two pin that the value is USED.

# T13 — a supplied fingerprint is STORED, not silently replaced. Discriminating by
# construction: the value handed in cannot match the tree, so if `record` ignored
# it and recomputed, `read` would verify. A refusal is the only outcome that proves
# the argument reached the artifact.
IFS='|' read -r P C <<<"$(mk_plane)"
rec "$P" 0 70 2475 0 "" "deadbeefdeadbeefdeadbeefdeadbeef" >/dev/null 2>&1
OUT=$(rd "$P" 2>&1); RC=$?
[ $RC -ne 0 ] && printf '%s' "$OUT" | grep -qiE 'moved|differs' \
  && ok "\`record\` stores the fingerprint it is GIVEN (a supplied hash that does not describe the tree must refuse on read — proof the guard's AFTER hash is not being discarded)" \
  || no "a supplied fingerprint must reach the artifact; recomputing it here re-opens the window between the guard's AFTER hash and the write, in which an edit is recorded as tested (rc=$RC out=$OUT)"

# T13b — and the honest path still verifies, so T13 is refusing for the right
# reason rather than because any sixth argument breaks recording.
IFS='|' read -r P C <<<"$(mk_plane)"
FPNOW=$( ( cd "$P" && bash .claude/battery-result.sh fingerprint ) 2>/dev/null )
rec "$P" 0 70 2475 0 "" "$FPNOW" >/dev/null 2>&1
OUT=$(rd "$P" 2>&1); RC=$?
[ $RC -eq 0 ] && printf '%s' "$OUT" | grep -qi 'VERIFIED' \
  && ok "a supplied fingerprint that DOES describe the tree reads back VERIFIED (T13's refusal is about the value, not about passing the argument at all)" \
  || no "passing the guard's own fingerprint must verify — otherwise the runner's normal path is broken and T13 is passing vacuously (rc=$RC out=$OUT fp=$FPNOW)"

# ── assertion counts vs suite counts (guv eval, 2026-07-27) ───────────────────
# `passed`/`failed` are SUITE counts — that is what the runner has at the top
# level. Recording only those made every downstream QA report describe a
# ~2,468-assertion battery as "71 passing", a 35x understatement. The totals are
# additive and optional, which makes the honest-absence case the one that matters.

# T14 — assertion totals round-trip and are labelled as their own unit.
IFS='|' read -r P C <<<"$(mk_plane)"
rec "$P" 0 71 71 0 "" "" 2468 0 >/dev/null 2>&1
OUT=$(rd "$P" 2>&1); RC=$?
[ $RC -eq 0 ] && printf '%s' "$OUT" | grep -qE 'assertions:[[:space:]]*2468 passed' \
  && printf '%s' "$OUT" | grep -qE 'suites:[[:space:]]*71 total' \
  && ok "assertion totals round-trip alongside suite counts, each named as its own unit (a reader cannot quote 71 as the test count)" \
  || no "the record must carry assertions distinctly from suites, or every QA report understates the battery by ~35x (rc=$RC out=$OUT)"

# T14b — the absence case, which is the whole reason the pair is optional. A record
# with no assertion totals must SAY they are missing. Reading back a zero here would
# be worse than the understatement it replaces: "0 failed" over a total nobody
# counted is a claim, not a gap.
IFS='|' read -r P C <<<"$(mk_plane)"
rec "$P" 0 71 71 0 >/dev/null 2>&1
OUT=$(rd "$P" 2>&1); RC=$?
[ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'NOT RECORDED' \
  && ! printf '%s' "$OUT" | grep -qE 'assertions:[[:space:]]*[0-9]' \
  && ok "a record with no assertion totals says NOT RECORDED rather than reading back as zero (an uncounted total must not present as a counted one)" \
  || no "missing assertion totals must be announced, not defaulted — a silent 0 passed/0 failed is a fabricated measurement (rc=$RC out=$OUT)"

# T14c — the totals are a PAIR. Half of one is not a partial measurement, it is a
# misleading one: a lone passed-count read beside a null failed-count is exactly
# the "and nothing failed" implication nobody recorded.
IFS='|' read -r P C <<<"$(mk_plane)"
rec "$P" 0 71 71 0 "" "" 2468 >/dev/null 2>&1
OUT=$(rd "$P" 2>&1); RC=$?
[ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'NOT RECORDED' \
  && ok "a lone assertion count is discarded, not recorded half-complete (passed-without-failed would read as 'and nothing failed')" \
  || no "an unpaired assertion total must be refused; recording it alone implies a failure count that was never measured (rc=$RC out=$OUT)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
