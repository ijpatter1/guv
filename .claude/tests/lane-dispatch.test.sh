#!/bin/bash
# Tests for .claude/lane-dispatch.sh — the lane-dispatch orchestrator ([7.5]).
#
# Built on Spike A fallback B: prompt discipline plus DETERMINISTIC
# diff-confinement detection at the merge gate (no lane-discriminator hook is
# available, so confinement is detected, not prevented — mechanically
# equivalent at the join per the spec's Pre-Resolved Decision). The orchestrator
# is the deterministic JOIN over lanes that have already executed:
#   confine <id>     the lane's diff must not touch the shared surface the
#                    orchestrator owns — the trackers (single-writer) and the
#                    docFragment-target prose (CHANGELOG/README). Drift is
#                    detected here and refused.
#   harvest <id>     the lane-failure contract: a failed/garbage/drifted lane is
#                    REFUSED; a failure report is captured to the control plane
#                    BEFORE any cleanup and survives it; the tracker is untouched.
#   assemble <out>…  docFragments (changelog/README deltas) applied SERIALLY by
#                    the orchestrator — lanes never touch shared prose, so two
#                    lanes' fragments assemble without conflict.
#   dispatch <id>…   the whole join: confine+harvest all, land the ok lanes
#                    through the [7.4] merge queue, assemble fragments, capture
#                    reports for the refused — and emit a summary.
#
# Split fixture: control plane (cwd, tracker) + code repo (roots.code, lanes +
# shared prose). Lanes are guv-lane worktrees; a lane "executes" in the fixture
# by committing in its worktree and writing .lane-output.json at the worktree root.
# Pure bash + git + jq. Run: bash .claude/tests/lane-dispatch.test.sh
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$CLAUDE_DIR/lane-dispatch.sh"
LANE="$CLAUDE_DIR/guv-lane.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

setup() {
  rm -rf "$WORK/code" "$WORK/proj"
  CODE="$WORK/code"
  mkdir -p "$CODE"
  git -C "$CODE" init -q -b main
  git -C "$CODE" config user.email t@t; git -C "$CODE" config user.name t
  printf '# Changelog\n' > "$CODE/CHANGELOG.md"
  printf '# Readme\n' > "$CODE/README.md"
  echo base > "$CODE/base.txt"
  # provision the code repo as a guv lane target ([10.10]) so `guv-lane create` is satisfied
  mkdir -p "$CODE/.claude"
  jq -n '{roots:{control:".",code:"."},name:"t",language:"shell",commands:{},scaffoldCheck:"true",ceremony:"task"}' \
    > "$CODE/.claude/project.json"
  git -C "$CODE" add -A; git -C "$CODE" commit -qm base
  P="$WORK/proj"
  mkdir -p "$P/.claude" "$P/docs"
  jq -n '{roots:{control:".",code:"../code"},name:"t",language:"node",commands:{},scaffoldCheck:"true",ceremony:"phased",lanes:{protectedProse:["(^|/)(CHANGELOG|README)(\\.template)?\\.md$","(^|/)plugin/"]}}' \
    > "$P/.claude/project.json"
  printf '# Tracker\n- ⬜ **[7.A]** thing `[deps: none]`\n' > "$P/docs/PHASE_STATUS.md"
}
run() { ( cd "$P" && bash "$SCRIPT" "$@" ) 2>&1; }
mklane() { ( cd "$P" && bash "$LANE" "$@" ) >/dev/null 2>&1; }

# A lane "executes": commit $file=$content in its worktree, then write its
# .lane-output.json. $1=id $2=file $3=content $4=status $5=docfrag-target(optional)
laneexec() {
  local id="$1" file="$2" content="$3" status="$4" frag="${5:-}"
  local wt="$CODE/.worktrees/lane-$id"
  printf '%s' "$content" > "$wt/$file"
  git -C "$wt" add -A
  git -C "$wt" -c user.email=t@t -c user.name=t commit -qm "lane $id work"
  if [ -n "$frag" ]; then
    jq -n --arg id "$id" --arg status "$status" --arg f "$frag" --arg id2 "$id" \
      '{id:$id, status:$status, docFragments:[{file:$f, content:("- [" + $id2 + "] landed\n")}], notes:"ok"}' \
      > "$wt/.lane-output.json"
  else
    jq -n --arg id "$id" --arg status "$status" '{id:$id, status:$status, docFragments:[], notes:"n"}' \
      > "$wt/.lane-output.json"
  fi
}

# ── T1 — confine: a lane whose diff is within its own scope passes ──
setup
mklane create 7.A scopea
laneexec 7.A base.txt "edited-by-A" ok
OUT=$(run confine 7.A); RC=$?
[ $RC -eq 0 ] \
  && ok "confine: a lane confined to its own scope passes (exit 0)" \
  || no "confine of a confined lane must pass (rc=$RC): $OUT"

# ── T2 — confine: a lane that touches a TRACKER drifts → refused ──
setup
mklane create 7.A drifttrk
( cd "$CODE/.worktrees/lane-7.A" && mkdir -p docs && printf 'x\n' >> docs/PHASE_STATUS.md \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm "drift: wrote tracker" ) >/dev/null 2>&1
OUT=$(run confine 7.A); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -q "PHASE_STATUS" \
  && ok "confine: a lane touching a tracker is refused, naming the path" \
  || no "confine must refuse a lane that touches a tracker (rc=$RC): $OUT"

# ── T3 — confine: a lane that edits SHARED PROSE (CHANGELOG) drifts → refused ──
# (changelog deltas must route through docFragments, never a direct edit.)
setup
mklane create 7.A driftprose
( cd "$CODE/.worktrees/lane-7.A" && printf -- '- snuck a line\n' >> CHANGELOG.md \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm "drift: edited changelog" ) >/dev/null 2>&1
OUT=$(run confine 7.A); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -qi "CHANGELOG" \
  && ok "confine: a lane editing shared prose (CHANGELOG) is refused (use docFragments)" \
  || no "confine must refuse a lane that edits shared prose (rc=$RC): $OUT"

# ── T3b — confine: a lane that edits the DERIVED plugin/ tree drifts → refused ──
# plugin/ is GENERATED (maintainers/build-plugin.sh) and rebuilt at the join — a
# lane edits the SOURCE (.claude/ or maintainers/plugin-src/) and the join owns
# the derived tree. A lane diff onto plugin/ is work the rebuild will overwrite;
# refuse it, and keep the source/derived boundary crisp (the [9.2] dead-hook
# lesson: blur it and a lane wires plugin mode in the wrong tree — or avoids
# both and ships the hook dead). plugin-src/ (real source) must NOT be caught.
setup
mklane create 7.A driftplugin
( cd "$CODE/.worktrees/lane-7.A" && mkdir -p plugin/hooks && printf '{}\n' > plugin/hooks/hooks.json \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm "drift: hand-edited derived plugin/" ) >/dev/null 2>&1
OUT=$(run confine 7.A); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -q "plugin/hooks/hooks.json" \
  && ok "confine: a lane editing the derived plugin/ tree is refused (edit the source; the join rebuilds)" \
  || no "confine must refuse a lane that edits the derived plugin/ tree (rc=$RC): $OUT"

# ── T3c — confine: a lane editing real plugin SOURCE (plugin-src/) passes ──
# The boundary's other half: maintainers/plugin-src/ is hand-authored SOURCE a
# lane edits like any other — only the derived plugin/ is off-limits. A guard
# that swept plugin-src/ too is exactly the over-confinement that left [9.2]'s
# hook dead, so this asserts plugin-src/ is NOT refused.
setup
mklane create 7.A srcplugin
( cd "$CODE/.worktrees/lane-7.A" && mkdir -p maintainers/plugin-src/hooks \
  && printf '{}\n' > maintainers/plugin-src/hooks/extra.json \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm "edit real plugin source" ) >/dev/null 2>&1
OUT=$(run confine 7.A); RC=$?
[ $RC -eq 0 ] \
  && ok "confine: a lane editing maintainers/plugin-src/ (real source) passes — only derived plugin/ is protected" \
  || no "confine must NOT refuse a lane editing real plugin-src/ source (rc=$RC): $OUT"

# ── T3d — DEFAULT confinement ([10.10] G3): with no lanes.protectedProse, a foreign
#          code repo's OWN README is lane-editable, while the single-writer trackers
#          stay protected unconditionally. (Hardcoded prose protection wrongly blocked a
#          consumer's own README — the clean-room finding.) ──
setup
jq 'del(.lanes)' "$P/.claude/project.json" > "$P/.claude/p.tmp" && mv "$P/.claude/p.tmp" "$P/.claude/project.json"
mklane create 7.A readme-own
( cd "$CODE/.worktrees/lane-7.A" && printf -- '- a consumer readme edit\n' >> README.md \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm "edit own README" ) >/dev/null 2>&1
OUT=$(run confine 7.A); RC=$?
[ $RC -eq 0 ] \
  && ok "confine: default config lets a lane edit the repo's OWN README (G3 fix)" \
  || no "default confine must NOT refuse a consumer's own README (rc=$RC): $OUT"
mklane create 7.B trackertouch
( cd "$CODE/.worktrees/lane-7.B" && mkdir -p docs && printf 'x\n' > docs/PHASE_STATUS.md \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm "touch tracker" ) >/dev/null 2>&1
OUT=$(run confine 7.B); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -q "PHASE_STATUS" \
  && ok "confine: the single-writer tracker stays protected even with default config" \
  || no "default confine must still refuse a tracker touch (rc=$RC): $OUT"

# ── T4 — harvest: a clean, confined, status=ok lane harvests ──
setup
mklane create 7.A okharv
laneexec 7.A base.txt "A-done" ok CHANGELOG.md
OUT=$(run harvest 7.A); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qi "ok" \
  && ok "harvest: a clean ok confined lane harvests (exit 0)" \
  || no "harvest of an ok lane must succeed (rc=$RC): $OUT"

# ── T5 — the lane-failure contract: a failed lane is refused, a report is
#         captured BEFORE cleanup and SURVIVES it, and the tracker is untouched ──
setup
TRK_BEFORE=$(md5 -q "$P/docs/PHASE_STATUS.md" 2>/dev/null || md5sum "$P/docs/PHASE_STATUS.md")
mklane create 7.A failharv
laneexec 7.A base.txt "A-broken" failed
OUT=$(run harvest 7.A); RC=$?
[ $RC -ne 0 ] \
  && ok "harvest: a status=failed lane is refused (the contract)" \
  || no "harvest must refuse a failed lane (rc=$RC): $OUT"
REPORT=$(ls "$P/.lane-reports/"lane-7.A* 2>/dev/null | head -1)
[ -n "$REPORT" ] && [ -f "$REPORT" ] \
  && ok "harvest: a failure report artifact is written to the control plane" \
  || no "a failed harvest must capture a failure report artifact"
echo "$OUT" | grep -qi "report" \
  && ok "harvest: the refusal points at the captured report" \
  || no "the refusal should name the report it captured: $OUT"
# the report survives destroying the lane worktree
( cd "$P" && bash "$LANE" destroy 7.A --force ) >/dev/null 2>&1
[ -f "$REPORT" ] \
  && ok "harvest: the failure report survives the worktree being destroyed" \
  || no "the failure report must survive cleanup"
TRK_AFTER=$(md5 -q "$P/docs/PHASE_STATUS.md" 2>/dev/null || md5sum "$P/docs/PHASE_STATUS.md")
[ "$TRK_BEFORE" = "$TRK_AFTER" ] \
  && ok "harvest: the tracker is byte-identical through a lane failure (untouched)" \
  || no "the tracker must be untouched through a lane failure"

# ── T6 — harvest: a garbage lane (no/invalid .lane-output.json) is refused ──
setup
mklane create 7.A garbage
( cd "$CODE/.worktrees/lane-7.A" && echo x > base.txt && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm work ) >/dev/null 2>&1
# no .lane-output.json written -> garbage
OUT=$(run harvest 7.A); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -qi "output" \
  && ok "harvest: a lane with no structured output is refused as garbage" \
  || no "harvest must refuse a lane missing .lane-output.json (rc=$RC): $OUT"

# ── T7 — assemble: two lanes' docFragments apply SERIALLY without conflict ──
setup
mklane create 7.A fragA; laneexec 7.A base.txt one ok CHANGELOG.md
mklane create 7.B fragB
( cd "$CODE/.worktrees/lane-7.B" && echo two > other.txt && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm work ) >/dev/null 2>&1
jq -n '{id:"7.B",status:"ok",docFragments:[{file:"CHANGELOG.md",content:"- [7.B] landed\n"}],notes:"n"}' \
  > "$CODE/.worktrees/lane-7.B/.lane-output.json"
OUT=$(run assemble "$CODE/.worktrees/lane-7.A/.lane-output.json" "$CODE/.worktrees/lane-7.B/.lane-output.json"); RC=$?
[ $RC -eq 0 ] || no "assemble of two fragments must succeed (rc=$RC): $OUT"
grep -q "7.A" "$CODE/CHANGELOG.md" && grep -q "7.B" "$CODE/CHANGELOG.md" \
  && ok "assemble: both lanes' CHANGELOG fragments are present" \
  || no "both docFragments must be applied to CHANGELOG"
grep -qE '^(<<<<<<<|=======|>>>>>>>)' "$CODE/CHANGELOG.md" \
  && no "assemble must not leave conflict markers (it appends serially)" \
  || ok "assemble: no conflict markers — fragments applied serially"
# both fragments say "landed"; they must land on SEPARATE lines (a substring grep
# wouldn't catch a run-on, so count the lines — the newline-preservation guard).
[ "$(grep -c 'landed' "$CODE/CHANGELOG.md")" -eq 2 ] \
  && ok "assemble: the two fragments are on separate lines (no run-on)" \
  || no "assemble must keep fragments on separate lines, got $(grep -c 'landed' "$CODE/CHANGELOG.md") line(s)"

# ── T7b — assemble refuses an escaping docFragment target, writing nothing ──
setup
jq -n '{id:"x",status:"ok",docFragments:[{file:"../escape.md",content:"x\n"}],notes:"n"}' > "$WORK/bad.json"
OUT=$( ( cd "$P" && bash "$SCRIPT" assemble "$WORK/bad.json" ) 2>&1 ); RC=$?
[ $RC -ne 0 ] && ! [ -f "$WORK/escape.md" ] \
  && ok "assemble: a path-escaping docFragment target (../) is refused, nothing written" \
  || no "assemble must refuse an escaping docFragment target (rc=$RC)"

# ── T8 — dispatch: a two-lane join lands both through the queue + assembles ──
setup
mklane create 7.A da; laneexec 7.A base.txt "A-change" ok CHANGELOG.md
mklane create 7.B db
( cd "$CODE/.worktrees/lane-7.B" && echo b > newb.txt && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm "lane 7.B work" ) >/dev/null 2>&1
jq -n '{id:"7.B",status:"ok",docFragments:[{file:"README.md",content:"- [7.B] note\n"}],notes:"n"}' \
  > "$CODE/.worktrees/lane-7.B/.lane-output.json"
OUT=$(run dispatch 7.A 7.B); RC=$?
[ $RC -eq 0 ] || no "dispatch of two independent confined lanes must succeed (rc=$RC): $OUT"
git -C "$CODE" log --oneline main | grep -q "lane 7.A work" \
  && git -C "$CODE" log --oneline main | grep -q "lane 7.B work" \
  && ok "dispatch: both lanes landed through the queue (commits on integration)" \
  || no "dispatch must land both lanes through the queue"
grep -q "7.A" "$CODE/CHANGELOG.md" && grep -q "7.B" "$CODE/README.md" \
  && ok "dispatch: docFragments assembled into shared prose at the join" \
  || no "dispatch must assemble docFragments at the join"
echo "$OUT" | grep -qiE "landed|dispatch" \
  && ok "dispatch: emits a summary of what landed" \
  || no "dispatch must emit a summary"

# ── T9 — dispatch with a failed lane: the ok lane lands, the failed is reported,
#         tracker untouched (the contract holds inside the join) ──
setup
mklane create 7.A okl; laneexec 7.A base.txt "A-ok" ok
mklane create 7.B badl; laneexec 7.B base.txt "B-bad" failed
OUT=$(run dispatch 7.A 7.B); RC=$?
git -C "$CODE" log --oneline main | grep -q "lane 7.A work" \
  && ok "dispatch: the ok lane lands even when a sibling fails" \
  || no "the ok lane must land despite a sibling failure"
ls "$P/.lane-reports/"lane-7.B* >/dev/null 2>&1 \
  && ok "dispatch: the failed lane gets a captured report" \
  || no "the failed lane must get a failure report"
git -C "$CODE" log --oneline main | grep -q "lane 7.B work" \
  && no "a failed lane must NOT land" \
  || ok "dispatch: the failed lane did not land"

# ── T10 — loud stops: unknown lane, corrupt manifest ──
setup
OUT=$(run confine 9.9); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -q "9.9" \
  && ok "confine: unknown lane fails loud, naming it" \
  || no "confine of an unknown lane must fail loud (rc=$RC): $OUT"
PC="$WORK/corrupt"; mkdir -p "$PC/.claude"; echo '{bad' > "$PC/.claude/project.json"
OUT=$( ( cd "$PC" && bash "$SCRIPT" confine 7.A ) 2>&1 ); RC=$?
[ $RC -eq 4 ] && echo "$OUT" | grep -qi json \
  && ok "corrupt manifest -> loud error (exit 4)" \
  || no "corrupt manifest must fail loud (rc=$RC): $OUT"
OUT=$(run 2>&1); RC=$?
[ $RC -eq 2 ] && ok "no args -> usage (exit 2)" || no "no args must be exit 2 (rc=$RC)"

# ── T11 — harvest validates the docFragment channel AT THE GATE (untrusted) ──
setup
mklane create 7.A badtgt
( cd "$CODE/.worktrees/lane-7.A" && echo x > base.txt && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm "lane 7.A work" ) >/dev/null 2>&1
jq -n '{id:"7.A",status:"ok",docFragments:[{file:"docs/REQUIREMENTS.md",content:"x\n"}],notes:"n"}' \
  > "$CODE/.worktrees/lane-7.A/.lane-output.json"
OUT=$(run harvest 7.A); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -qi "docfragment" \
  && ok "harvest: a docFragment target naming a tracker is refused at the gate (single-writer)" \
  || no "harvest must refuse a tracker-targeting docFragment (rc=$RC): $OUT"
jq -n '{id:"7.A",status:"ok",docFragments:[{file:"../../escape.md",content:"x\n"}],notes:"n"}' \
  > "$CODE/.worktrees/lane-7.A/.lane-output.json"
OUT=$(run harvest 7.A); RC=$?
[ $RC -ne 0 ] \
  && ok "harvest: a docFragment target that escapes the repo is refused at the gate" \
  || no "harvest must refuse an escaping docFragment target (rc=$RC): $OUT"

# ── T12 — dispatch with a SINGLE ok lane that conflicts at land: no crash ──
# (the Critical's reachable path — OK>0 but LANDED=0 must not abort under set -u.)
setup
mklane create 7.A confl; laneexec 7.A conflictfile.txt "lane-version" ok
( cd "$CODE" && echo "main-version" > conflictfile.txt && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm "main adds conflictfile" ) >/dev/null 2>&1
OUT=$(run dispatch 7.A); RC=$?
[ $RC -eq 0 ] \
  && ok "dispatch: an OK lane that conflicts at land does not crash (empty-LANDED guarded)" \
  || no "dispatch must not crash when no lane lands (rc=$RC): $OUT"
echo "$OUT" | grep -qiE "conflict" && echo "$OUT" | grep -q "landed=\[\]" \
  && ok "dispatch: reports the conflict and an empty landed set" \
  || no "dispatch must report the conflict + empty landed set: $OUT"

# ── T13 — dispatch skips an unknown lane id, the valid sibling still lands ──
setup
mklane create 7.A solo; laneexec 7.A base.txt "ok" ok
OUT=$(run dispatch 7.A 9.9); RC=$?
echo "$OUT" | grep -qiE "9.9.*skip|skip.*9.9|unknown-skipped=1" \
  && ok "dispatch: an unknown lane id is skipped, not fatal to the batch" \
  || no "dispatch must skip an unknown lane id, not abort: $OUT"
git -C "$CODE" log --oneline main | grep -q "lane 7.A work" \
  && ok "dispatch: the valid lane still lands despite an unknown sibling id" \
  || no "the valid lane must land despite an unknown sibling"

# ── T15 — dispatch destroys each landed lane (lifecycle ends at destroy) ──
# Without cleanup the .worktrees/ and lane/* refs accumulate across dispatches
# (UAT-F5). A landed lane is merged, so destroy needs no --force.
setup
mklane create 7.A landdes; laneexec 7.A base.txt "A-change" ok
OUT=$(run dispatch 7.A); RC=$?
[ $RC -eq 0 ] || no "dispatch (single ok lane) must succeed (rc=$RC): $OUT"
git -C "$CODE" log --oneline main | grep -q "lane 7.A work" \
  || no "precondition: the lane should have landed"
[ -d "$CODE/.worktrees/lane-7.A" ] \
  && no "dispatch must destroy the landed lane's worktree (UAT-F5)" \
  || ok "dispatch: the landed lane's worktree is destroyed"
git -C "$CODE" branch --list 'lane/7.A-*' | grep -q . \
  && no "dispatch must delete the landed lane's branch (UAT-F5)" \
  || ok "dispatch: the landed lane's branch is deleted"
echo "$OUT" | grep -q "destroyed=1" \
  && ok "dispatch: the summary reports destroyed=1" \
  || no "dispatch summary must report the destroyed count: $OUT"

# ── T16 — harvest emits a build-artifact advisory (lanes commit sources only) ──
# A lane that staged a __pycache__ file (UAT-F2) still harvests ok — it is not a
# confinement breach — but harvest warns so the orchestrator sees it.
setup
mklane create 7.A artifacts
WT="$CODE/.worktrees/lane-7.A"
mkdir -p "$WT/pkg/__pycache__"
printf 'src\n' > "$WT/mod.py"
printf 'cache\n' > "$WT/pkg/__pycache__/mod.cpython-311.pyc"
git -C "$WT" add -A
git -C "$WT" -c user.email=t@t -c user.name=t commit -qm "lane 7.A with artifacts" >/dev/null 2>&1
jq -n '{id:"7.A",status:"ok",docFragments:[],notes:"n"}' > "$WT/.lane-output.json"
OUT=$(run harvest 7.A); RC=$?
[ $RC -eq 0 ] \
  && ok "harvest: a lane carrying build artifacts still harvests ok (advisory, not refusal)" \
  || no "harvest must not refuse on build artifacts — advisory only (rc=$RC): $OUT"
echo "$OUT" | grep -qi "advisory" && echo "$OUT" | grep -q "__pycache__" \
  && ok "harvest: emits a build-artifact advisory naming the artifact path (UAT-F2)" \
  || no "harvest must advise on build artifacts in the lane diff: $OUT"

# ── T14 — .lane-reports/ is gitignored in the guv-core block (no scratch leak) ──
ROOT="$(cd "$CLAUDE_DIR/.." && pwd)"
if grep -q '^# guv-core-start' "$ROOT/.gitignore" 2>/dev/null; then
  awk '/^# guv-core-start/,/^# guv-core-end/' "$ROOT/.gitignore" | grep -q '^\.lane-reports/$' \
    && ok ".lane-reports/ present in the guv-core gitignore block" \
    || no ".lane-reports/ must be in the guv-core gitignore block"
else
  echo "  - no guv-core gitignore block (plane/consumer shape) — gitignore check skips"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
