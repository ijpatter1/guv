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
  git -C "$CODE" add -A; git -C "$CODE" commit -qm base
  P="$WORK/proj"
  mkdir -p "$P/.claude" "$P/docs"
  jq -n '{roots:{control:".",code:"../code"},name:"t",language:"node",commands:{},scaffoldCheck:"true",ceremony:"phased"}' \
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
