#!/bin/bash
# Tests for .claude/merge-queue.sh — the gated merge queue ([7.4]).
#
# The queue lands lane branches (lane/<id>-<slug> in the CODE repo, one per
# deliverable ID) sequentially onto the integration branch: cheapest-first by
# merge-tree conflict preview, deterministic pre-checks before the evaluator
# spends a token, the deliverable's acceptance block extracted from the control
# plane's REQUIREMENTS and handed to the evaluator as explicit grading input,
# and the conflict-as-DAG-lint heavy path (land A, route B to serial
# re-dispatch, propose a /replan deps-amend).
#
# Split fixture: a control plane (cwd, carries docs/REQUIREMENTS.md) + a sibling
# code repo (roots.code) where the lanes live — the real dogfooding topology.
# Lanes are made with guv-lane.sh, the same primitive the queue resolves through.
# Pure bash + git + jq, no test runner required.
# Run: bash .claude/tests/merge-queue.test.sh
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$CLAUDE_DIR/merge-queue.sh"
LANE="$CLAUDE_DIR/guv-lane.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A code repo with one base commit on `main`, and a control plane pointing at it.
# REQ_BODY lets a test supply its own REQUIREMENTS deliverable block.
setup() {
  rm -rf "$WORK/code" "$WORK/proj"
  CODE="$WORK/code"
  mkdir -p "$CODE"
  git -C "$CODE" init -q -b main
  git -C "$CODE" config user.email t@t; git -C "$CODE" config user.name t
  printf 'alpha\nbeta\ngamma\n' > "$CODE/shared.txt"
  echo "base" > "$CODE/base.txt"
  # provision the code repo as a guv lane target ([10.10]) so `guv-lane create` is satisfied
  mkdir -p "$CODE/.claude"
  jq -n '{roots:{control:".",code:"."},name:"t",language:"shell",commands:{},scaffoldCheck:"true",ceremony:"task"}' \
    > "$CODE/.claude/project.json"
  git -C "$CODE" add -A; git -C "$CODE" commit -qm base
  P="$WORK/proj"
  mkdir -p "$P/.claude" "$P/docs"
  jq -n '{roots:{control:".",code:"../code"},name:"t",language:"node",commands:{},scaffoldCheck:"true",ceremony:"phased"}' \
    > "$P/.claude/project.json"
  cat > "$P/docs/REQUIREMENTS.md" <<'REQ'
# Requirements

## Phase 7

4. **[7.4]** Gated merge queue: sequential landing with merge-tree preview `[deps: 7.1, 7.3]`
   - *Acceptance:* a clean fixture lands both; dirty-worktree fixture refused
     before any agent invocation; the evaluator receives the acceptance block
     ACCEPTANCE-SENTINEL-7-4, asserted on the constructed input.
5. **[7.5]** Lane dispatch: the orchestrator dispatches lanes `[deps: 6.2, 7.4]`
   - *Acceptance:* a two-lane dispatch completes ACCEPTANCE-SENTINEL-7-5.

## Phase 8
REQ
}
run() { ( cd "$P" && bash "$SCRIPT" "$@" ) 2>&1; }
mklane() { ( cd "$P" && bash "$LANE" "$@" ) >/dev/null 2>&1; }

# Commit some work inside a lane's worktree. $1=id $2=file $3=content $4=msg
lanecommit() {
  local id="$1" file="$2" content="$3" msg="$4"
  printf '%s' "$content" > "$CODE/.worktrees/lane-$id/$file"
  git -C "$CODE/.worktrees/lane-$id" add -A
  git -C "$CODE/.worktrees/lane-$id" -c user.email=t@t -c user.name=t commit -qm "$msg"
}

# ── T1 — precheck: a clean lane reports its diff footprint, exit 0 ──
setup
mklane create 7.4 queue
lanecommit 7.4 base.txt "base+queue" "feat: queue work"
OUT=$(run precheck 7.4); RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qi "footprint" \
  && ok "precheck: clean lane passes and computes a diff footprint" \
  || no "precheck clean lane must pass with a footprint (rc=$RC): $OUT"
echo "$OUT" | grep -qE "files=1" \
  && ok "precheck: footprint counts the changed file (files=1)" \
  || no "precheck footprint must report files=1: $OUT"

# ── T2 — precheck: a dirty lane worktree is refused BEFORE any gate input ──
echo "uncommitted" > "$CODE/.worktrees/lane-7.4/scratch.txt"
OUT=$(run precheck 7.4); RC=$?
[ $RC -eq 6 ] && echo "$OUT" | grep -qi "dirty" \
  && ok "precheck: dirty worktree refused (exit 6) before any agent invocation" \
  || no "precheck must refuse a dirty worktree with exit 6 (rc=$RC): $OUT"
rm "$CODE/.worktrees/lane-7.4/scratch.txt"

# ── T3 — precheck: a WIP commit message is refused ──
lanecommit 7.4 wip.txt "x" "WIP: not done yet"
OUT=$(run precheck 7.4); RC=$?
[ $RC -eq 6 ] && echo "$OUT" | grep -qiE "wip" \
  && ok "precheck: WIP commit message refused (exit 6)" \
  || no "precheck must refuse a WIP commit message with exit 6 (rc=$RC): $OUT"

# ── T4 — gate-input: the acceptance block is extracted by ID and handed out ──
# (the evaluator's grading input is CONSTRUCTED here, asserted on the bundle,
#  not on model behavior — the [7.4] acceptance bar.)
setup
mklane create 7.4 queue
lanecommit 7.4 base.txt "base+q" "feat: queue"
OUT=$(run gate-input 7.4); RC=$?
[ $RC -eq 0 ] \
  && ok "gate-input: exits 0 for a known deliverable" \
  || no "gate-input must succeed for a known ID (rc=$RC): $OUT"
echo "$OUT" | grep -q "ACCEPTANCE-SENTINEL-7-4" \
  && ok "gate-input: bundle carries the deliverable's acceptance block (by ID)" \
  || no "gate-input must include the acceptance block: $OUT"
echo "$OUT" | grep -q "ACCEPTANCE-SENTINEL-7-5" \
  && no "gate-input bled in the NEXT deliverable's acceptance (boundary leak)" \
  || ok "gate-input: stops at the deliverable boundary (no next-block bleed)"
echo "$OUT" | grep -qi "footprint" \
  && ok "gate-input: bundle also carries the diff footprint (explicit input)" \
  || no "gate-input must include the diff footprint: $OUT"

# ── T5 — gate-input: an unknown deliverable ID fails loud, naming it ──
OUT=$(run gate-input 9.9); RC=$?
[ $RC -eq 5 ] && echo "$OUT" | grep -q "9.9" \
  && ok "gate-input: unknown deliverable ID fails loud (exit 5), naming it" \
  || no "gate-input must fail loud on an unknown ID (rc=$RC): $OUT"

# ── T6 — preview: two independent clean lanes, ordered cheapest-first ──
setup
mklane create 7.4 big
lanecommit 7.4 base.txt "$(printf 'a\nb\nc\nd\ne\nf\n')" "feat: big change"
mklane create 7.5 small
lanecommit 7.5 newfile.txt "x" "feat: small change"
OUT=$(run preview 7.4 7.5); RC=$?
[ $RC -eq 0 ] \
  && ok "preview: exits 0 with no inter-lane conflict" \
  || no "preview of two clean lanes must exit 0 (rc=$RC): $OUT"
ORDER=$(echo "$OUT" | grep -i "^order=" | head -1)
echo "$ORDER" | grep -q "7.5" && echo "$ORDER" | grep -q "7.4" \
  && ok "preview: emits an order over both lanes" \
  || no "preview must emit order= over both lanes, got: $ORDER"
# cheapest-first: 7.5 (1 file, 1 line) before 7.4 (1 file, 6 lines)
if echo "$ORDER" | grep -qE "7\.5([^0-9].*)?7\.4"; then
  ok "preview: cheapest-first — the smaller-footprint lane is ordered first"
else
  no "preview must order the cheaper lane (7.5) before 7.4: $ORDER"
fi

# ── T7 — land: a clean lane fast-forwards onto integration, head advances ──
setup
mklane create 7.4 land1
lanecommit 7.4 base.txt "landed" "feat: landable"
HEAD0=$(git -C "$CODE" rev-parse main)
OUT=$(run land 7.4); RC=$?
[ $RC -eq 0 ] || no "land of a clean lane must succeed (rc=$RC): $OUT"
HEAD1=$(git -C "$CODE" rev-parse main)
[ "$HEAD0" != "$HEAD1" ] \
  && ok "land: integration head advances after landing" \
  || no "land must advance the integration head"
git -C "$CODE" log --oneline main | grep -q "feat: landable" \
  && ok "land: the lane commit is now on integration" \
  || no "land must put the lane commit on integration"

# ── T8 — land both clean lanes sequentially (rebase onto post-merge head) ──
setup
mklane create 7.4 seqA
lanecommit 7.4 base.txt "A-change" "feat: A"
mklane create 7.5 seqB
lanecommit 7.5 newB.txt "B" "feat: B"
run land 7.4 >/dev/null 2>&1; RA=$?
OUT=$(run land 7.5); RB=$?
[ $RA -eq 0 ] && [ $RB -eq 0 ] \
  && ok "land: two non-conflicting lanes land sequentially" \
  || no "two clean lanes must both land (rA=$RA rB=$RB): $OUT"
git -C "$CODE" log --oneline main | grep -q "feat: A" \
  && git -C "$CODE" log --oneline main | grep -q "feat: B" \
  && ok "land: both lane commits reached integration" \
  || no "both lane commits must reach integration"

# ── T9 — conflict-as-DAG-lint: land A, B conflicts on rebase → routed out ──
# Two lanes edit the SAME line of shared.txt: they merge cleanly individually
# vs base but conflict against each other once A lands.
setup
mklane create 7.4 confA
lanecommit 7.4 shared.txt "$(printf 'A-EDIT\nbeta\ngamma\n')" "feat: A edits line1"
mklane create 7.5 confB
lanecommit 7.5 shared.txt "$(printf 'B-EDIT\nbeta\ngamma\n')" "feat: B edits line1"
# preview must flag the pairwise conflict
OUT=$(run preview 7.4 7.5); RC=$?
[ $RC -ne 0 ] && echo "$OUT" | grep -qi "conflict" \
  && ok "preview: a manufactured pairwise conflict is detected and flagged" \
  || no "preview must flag the manufactured conflict (rc=$RC): $OUT"
# land A (cheapest/first), then B must be routed to serial re-dispatch
run land 7.4 >/dev/null 2>&1
HEADA=$(git -C "$CODE" rev-parse main)
OUT=$(run land 7.5); RC=$?
[ $RC -eq 7 ] \
  && ok "land: the conflicted lane routes to the DAG-lint path (exit 7)" \
  || no "a heavy conflict must exit 7 (DAG-lint), got rc=$RC: $OUT"
echo "$OUT" | grep -qiE "replan|deps[- ]amend" \
  && ok "land: the heavy-conflict path proposes a /replan deps amendment" \
  || no "the DAG-lint path must propose a /replan deps amendment: $OUT"
[ "$(git -C "$CODE" rev-parse main)" = "$HEADA" ] \
  && ok "land: a refused conflicted lane leaves integration intact (A landed, B not)" \
  || no "a conflicted lane must not mutate integration"
git -C "$CODE" log --oneline main | grep -q "feat: A edits line1" \
  && ok "land: A (the clean lane) did land — only B was routed out" \
  || no "the first lane should have landed"
# T9b — the routed-out lane is left USABLE for re-dispatch: the rebase was
# aborted cleanly (worktree not mid-rebase, no conflict markers), and harvest
# still resolves it (the failure-report/re-dispatch path in [7.5] depends on it).
[ -z "$(git -C "$CODE/.worktrees/lane-7.5" status --porcelain 2>/dev/null)" ] \
  && ok "land: a routed-out lane's worktree is clean (rebase --abort left no mess)" \
  || no "a routed-out lane must be left clean, not mid-rebase"
( cd "$P" && bash "$LANE" harvest 7.5 ) >/dev/null 2>&1 \
  && ok "land: a routed-out lane still harvests (usable for re-dispatch)" \
  || no "a routed-out lane must remain harvestable"

# ── T10 — corrupt manifest is a loud error before any queue op (Rule 15) ──
PC="$WORK/corrupt"; mkdir -p "$PC/.claude"
echo '{not json' > "$PC/.claude/project.json"
OUT=$( ( cd "$PC" && bash "$SCRIPT" precheck 7.4 ) 2>&1 ); RC=$?
[ $RC -eq 4 ] && echo "$OUT" | grep -qi "json" \
  && ok "corrupt manifest -> loud error (exit 4) before any queue op" \
  || no "corrupt manifest must fail loud (rc=$RC): $OUT"

# ── T11 — usage: no verb / bad verb is exit 2 ──
OUT=$(run 2>&1); RC=$?
[ $RC -eq 2 ] && ok "no args -> usage (exit 2)" || no "no args must be exit 2 (rc=$RC)"
OUT=$(run bogus 7.4); RC=$?
[ $RC -eq 2 ] && ok "unknown verb -> usage (exit 2)" || no "unknown verb must be exit 2 (rc=$RC)"

# ── T12 — gate-input with REQUIREMENTS absent is a loud stop (Rule 15) ──
setup
mklane create 7.4 noreq
lanecommit 7.4 base.txt "x" "feat: work"
rm -f "$P/docs/REQUIREMENTS.md"
OUT=$(run gate-input 7.4); RC=$?
[ $RC -eq 4 ] && echo "$OUT" | grep -qi "REQUIREMENTS" \
  && ok "gate-input: REQUIREMENTS absent -> loud stop (exit 4)" \
  || no "gate-input must fail loud when REQUIREMENTS is absent (rc=$RC): $OUT"

# ── T13 — a detached HEAD in the code repo is refused (no branch to land onto) ──
setup
mklane create 7.4 det
lanecommit 7.4 base.txt "x" "feat: work"
git -C "$CODE" checkout -q --detach main
OUT=$(run preview 7.4); RC=$?
[ $RC -eq 4 ] && echo "$OUT" | grep -qi "detached" \
  && ok "preview: detached code-repo HEAD refused (exit 4) — the queue lands onto a branch" \
  || no "a detached HEAD must be refused with exit 4 (rc=$RC): $OUT"

# ── T14 — an UNKNOWN lane id loud-stops (exit 5), it does not limp on ──
# lane_state resolves inside a $()-substitution; a die there would only kill the
# subshell, so an unknown id would leave an empty branch and emit raw git fatals
# (UAT-F6). precheck/preview/land resolve the lane first, so an unknown id hits
# the no_lane path directly.
setup
for verb in precheck preview land; do
  OUT=$(run "$verb" 7.9); RC=$?
  [ $RC -eq 5 ] && echo "$OUT" | grep -q "7.9" \
    && ok "$verb: an unknown lane id loud-stops (exit 5), naming it" \
    || no "$verb of an unknown lane id must be exit 5, not a limp-on (rc=$RC): $OUT"
done
# gate-input checks the acceptance block FIRST, so an absent id stops there, not at
# no_lane. To exercise gate-input's OWN lane resolution, use a deliverable that IS
# in REQUIREMENTS ([7.5]) but has no lane in this fixture — that reaches no_lane.
OUT=$(run gate-input 7.5); RC=$?
[ $RC -eq 5 ] && echo "$OUT" | grep -q "7.5" \
  && ok "gate-input: a deliverable in REQUIREMENTS but with no lane loud-stops (exit 5, no_lane path)" \
  || no "gate-input must loud-stop via no_lane when the deliverable exists but the lane doesn't (rc=$RC): $OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
