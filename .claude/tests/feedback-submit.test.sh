#!/bin/bash
# Tests for .claude/feedback-submit.sh — feedback-transport submit mode ([10.8]).
# Pure bash + jq, no test runner required. Run: bash .claude/tests/feedback-submit.test.sh
#
# These tests verify INTENT, not "runs without crashing" (Rule 8). The submit mode
# DRAINS open routing:upstream feedback entries into the guv source repo as issues:
#   - it DRAFTS an issue per open upstream entry that has no upstream link yet
#     (title + body) and records the draft annotation back onto the entry, so a
#     re-run is a no-op (idempotency by id, via the writeback marker);
#   - issue FILING is user-gated — the permission classifier denies an agent's
#     `gh issue create` — so the transport NEVER calls `gh issue create`. It builds
#     the draft/dedupe/writeback machinery; the user files. This suite asserts the
#     no-`gh issue create` contract on the source AND on every produced command;
#   - non-upstream entries, already-linked entries, and non-open entries are skipped;
#   - --dry-run lists what would be filed WITHOUT writing the log;
#   - the transport degrades LOUDLY (non-zero, message) if the issue tracker is
#     unreachable — it never drops an entry silently (Rule 15).
#
# Real `gh` is NEVER invoked: a stub on PATH (GUV_GH seam) services the reachability
# probe and the repo-slug resolution, so the suite is hermetic and fixture-driven.
set -u

CLAUDE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$CLAUDE_DIR/feedback-submit.sh"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A `gh` stub: a reachable tracker resolves its slug and `repo view` succeeds; an
# unreachable one exits non-zero. Selected by GUV_GH=reachable|unreachable so a
# fixture controls the probe without ever touching the network. The submit script
# must route its tracker calls through this stub (never the real binary in a test).
STUB_DIR="$WORK/bin"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh-reachable" <<'EOF'
#!/bin/bash
# minimal gh: `repo view --json nameWithOwner -q .nameWithOwner` resolves the slug;
# bare `repo view` is the reachability probe (exit 0 = reachable).
case "$1 $2" in
  "repo view")
    if [ "$3" = "--json" ]; then echo "ijpatter1/guv"; fi
    exit 0 ;;
  *) echo "gh-stub: unexpected call: $*" >&2; exit 99 ;;
esac
EOF
cat > "$STUB_DIR/gh-unreachable" <<'EOF'
#!/bin/bash
echo "could not connect to api.github.com" >&2
exit 1
EOF
# A `gh` stub that plays the USER filing the drafted issue: it services `repo view`
# like gh-reachable, and on `issue create ... --body-file -` it captures the title
# (from --title) and the body (from stdin) to $GH_FILER_OUT so a test can assert the
# emitted block actually delivers the drafted body. This stub is used ONLY to run the
# emitted block in T10 — the submit script itself is still tested against gh-reachable
# (which exits 99 on any non-repo-view call), so the no-`issue create`-invocation
# contract (T6) is untouched.
cat > "$STUB_DIR/gh-filer" <<'EOF'
#!/bin/bash
if [ "$1 $2" = "repo view" ]; then
  if [ "$3" = "--json" ]; then echo "ijpatter1/guv"; fi
  exit 0
fi
if [ "$1 $2" = "issue create" ]; then
  title=""; bodyfile=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)     title="$2"; shift 2 ;;
      --body-file) bodyfile="$2"; shift 2 ;;
      -R)          shift 2 ;;
      *)           shift ;;
    esac
  done
  { echo "TITLE: $title"; echo "--- BODY ---"; [ "$bodyfile" = "-" ] && cat; } > "$GH_FILER_OUT"
  echo "https://github.com/ijpatter1/guv/issues/123"
  exit 0
fi
echo "gh-filer: unexpected call: $*" >&2; exit 99
EOF
chmod +x "$STUB_DIR/gh-reachable" "$STUB_DIR/gh-unreachable" "$STUB_DIR/gh-filer"

# A project root with a control-plane feedback log and a manifest pointing at a
# code repo whose remote is the guv source. Echoes the project dir.
make_project() {
  local p="$WORK/proj.$RANDOM$RANDOM"
  rm -rf "$p"
  mkdir -p "$p/.claude/feedback"
  jq -n '{roots:{control:".",code:"."},name:"t",language:"shell",ceremony:"phased"}' \
    > "$p/.claude/project.json"
  echo "$p"
}

# Append one feedback entry to a log. $1 log  $2 id  $3 routing  $4 status  $5 detail
add_entry() {
  jq -cn --arg id "$2" --arg routing "$3" --arg status "$4" --arg detail "$5" \
    '{id:$id, ts:"2026-06-14T00:00:00Z", session:"session-2026-06-14-001",
      category:"friction", artifact:".claude/x.md", summary:("friction "+$id),
      detail:$detail, severity:"minor", routing:$routing, status:$status}' \
    >> "$1"
}

LOG_REL=".claude/feedback/feedback.ndjson"

# ── RED until built ──────────────────────────────────────────────────────────
[ -f "$SCRIPT" ] \
  && ok "submit script exists at .claude/feedback-submit.sh" \
  || no "submit script missing at .claude/feedback-submit.sh"

# ── T1 — a submit run drafts an issue per open upstream entry lacking a link ──
# and writes the draft annotation back so the entry is now linked. Two drainable
# entries (u1, u2); the run must report drafting BOTH and leave each with a marker.
P=$(make_project); LOG="$P/$LOG_REL"
add_entry "$LOG" "u1" "upstream" "open" "ergonomics friction one"
add_entry "$LOG" "u2" "upstream" "open" "ergonomics friction two"
OUT=$( cd "$P" && GUV_GH="$STUB_DIR/gh-reachable" bash "$SCRIPT" submit ) 2>"$WORK/t1.err"; RC=$?
[ $RC -eq 0 ] \
  && ok "submit exits 0 on a reachable tracker (rc=$RC)" \
  || no "submit should exit 0 on reachable tracker (rc=$RC, err=$(cat "$WORK/t1.err"))"
echo "$OUT" | grep -q "u1" && echo "$OUT" | grep -q "u2" \
  && ok "submit reports drafting both open upstream entries (u1, u2)" \
  || no "submit must report drafting both drainable entries (out=$OUT)"
# Writeback: every previously-drainable entry now carries an upstream-link marker
# in detail, and the log stays valid NDJSON.
U1=$(jq -c 'select(.id=="u1")' "$LOG"); U2=$(jq -c 'select(.id=="u2")' "$LOG")
echo "$U1" | jq -er '.detail' | grep -qiE 'issue|github.com|drafted' \
  && echo "$U2" | jq -er '.detail' | grep -qiE 'issue|github.com|drafted' \
  && ok "writeback records a link/draft marker on each entry's detail" \
  || no "each drained entry must carry an upstream-link marker after submit (u1=$U1)"
echo "$U1" | jq -er '.detail' | grep -qF "ergonomics friction one" \
  && ok "writeback APPENDS to detail (original context preserved)" \
  || no "writeback must preserve the original detail, not replace it (u1=$U1)"
while IFS= read -r l; do echo "$l" | jq -e . >/dev/null 2>&1 || no "post-submit line not valid JSON"; done < "$LOG"
ok "log is valid NDJSON after the writeback"

# ── T2 — a second run is a NO-OP: deduped by id via the writeback marker ──────
# Re-running over the same log must draft nothing (both already linked) and leave
# the log byte-identical — the idempotency the acceptance bar demands.
BEFORE=$(cat "$LOG")
OUT2=$( cd "$P" && GUV_GH="$STUB_DIR/gh-reachable" bash "$SCRIPT" submit ) 2>"$WORK/t2.err"; RC2=$?
AFTER=$(cat "$LOG")
[ $RC2 -eq 0 ] && [ "$BEFORE" = "$AFTER" ] \
  && ok "second run is a no-op: log byte-identical (deduped by id)" \
  || no "re-run must not re-draft already-linked entries (rc=$RC2)"
echo "$OUT2" | grep -qiE '0 .*draft|no .*draft|nothing|up to date|no-op' \
  && ok "second run reports nothing to draft" \
  || no "second run should report that there is nothing to draft (out=$OUT2)"

# ── T3 — non-upstream and already-linked entries are SKIPPED ──────────────────
P3=$(make_project); LOG3="$P3/$LOG_REL"
add_entry "$LOG3" "loc1" "local"  "open" "a local misfit"
add_entry "$LOG3" "uns1" "unsure" "open" "routing unclear"
add_entry "$LOG3" "lnk1" "upstream" "open" "already filed | Issue: https://github.com/ijpatter1/guv/issues/9"
add_entry "$LOG3" "res1" "upstream" "resolved" "fixed before any release"
add_entry "$LOG3" "drn1" "upstream" "open" "the one genuinely drainable entry"
BEFORE3=$(cat "$LOG3")
OUT3=$( cd "$P3" && GUV_GH="$STUB_DIR/gh-reachable" bash "$SCRIPT" submit ) 2>"$WORK/t3.err"; RC3=$?
[ $RC3 -eq 0 ] && ok "submit exits 0 with a mix of skippable entries (rc=$RC3)" \
  || no "submit should exit 0 (rc=$RC3, err=$(cat "$WORK/t3.err"))"
echo "$OUT3" | grep -q "drn1" \
  && ok "the genuinely drainable upstream entry is drafted" \
  || no "drn1 must be drafted (out=$OUT3)"
for skip in loc1 uns1 lnk1 res1; do
  echo "$OUT3" | grep -q "$skip" \
    && no "$skip must be SKIPPED, not drafted (out=$OUT3)" \
    || ok "$skip skipped (non-upstream / already-linked / non-open)"
done
# The skipped entries' lines are untouched (only drn1 changed).
for skip in loc1 uns1 lnk1 res1; do
  B=$(echo "$BEFORE3" | grep "\"id\":\"$skip\"")
  A=$(jq -c "select(.id==\"$skip\")" "$LOG3")
  [ "$B" = "$A" ] && ok "$skip line byte-identical after submit" \
    || no "$skip must be untouched (before=$B after=$A)"
done

# ── T4 — --dry-run LISTS what would be filed WITHOUT writing the log ──────────
P4=$(make_project); LOG4="$P4/$LOG_REL"
add_entry "$LOG4" "dry1" "upstream" "open" "would be drafted"
add_entry "$LOG4" "dry2" "upstream" "open" "would also be drafted"
BEFORE4=$(cat "$LOG4")
OUT4=$( cd "$P4" && GUV_GH="$STUB_DIR/gh-reachable" bash "$SCRIPT" submit --dry-run ) 2>"$WORK/t4.err"; RC4=$?
AFTER4=$(cat "$LOG4")
[ $RC4 -eq 0 ] && ok "dry-run exits 0 (rc=$RC4)" \
  || no "dry-run should exit 0 (rc=$RC4, err=$(cat "$WORK/t4.err"))"
echo "$OUT4" | grep -q "dry1" && echo "$OUT4" | grep -q "dry2" \
  && ok "dry-run lists what would be filed (dry1, dry2)" \
  || no "dry-run must list the drainable entries (out=$OUT4)"
[ "$BEFORE4" = "$AFTER4" ] \
  && ok "dry-run does NOT write the log (byte-identical)" \
  || no "dry-run must not mutate the feedback log"
echo "$OUT4" | grep -qiE 'dry.?run' \
  && ok "dry-run announces itself as a dry run" \
  || no "dry-run output should announce the dry run (out=$OUT4)"

# ── T5 — degrade LOUDLY if the issue tracker is unreachable (Rule 15) ─────────
# Never drop entries silently: a non-zero exit AND a message, and the log MUST be
# left byte-identical (no half-writeback against an unverified tracker).
P5=$(make_project); LOG5="$P5/$LOG_REL"
add_entry "$LOG5" "unr1" "upstream" "open" "would drain if tracker were up"
BEFORE5=$(cat "$LOG5")
OUT5=$( cd "$P5" && GUV_GH="$STUB_DIR/gh-unreachable" bash "$SCRIPT" submit 2>&1 ); RC5=$?
AFTER5=$(cat "$LOG5")
[ $RC5 -ne 0 ] \
  && ok "unreachable tracker -> non-zero exit (loud, rc=$RC5)" \
  || no "unreachable tracker must exit non-zero, not 0 (rc=$RC5)"
echo "$OUT5" | grep -qiE 'unreach|could not|tracker|degrad|connect' \
  && ok "unreachable tracker -> an explanatory message (never a silent drop)" \
  || no "unreachable tracker must surface a message (out=$OUT5)"
[ "$BEFORE5" = "$AFTER5" ] \
  && ok "unreachable tracker leaves the log byte-identical (no half-writeback)" \
  || no "an unreachable tracker must not mutate the log"
# dry-run must ALSO degrade loud on an unreachable tracker (it announces what it
# *would* file against a tracker it claims to have probed).
OUT5d=$( cd "$P5" && GUV_GH="$STUB_DIR/gh-unreachable" bash "$SCRIPT" submit --dry-run 2>&1 ); RC5d=$?
[ $RC5d -ne 0 ] \
  && ok "dry-run on an unreachable tracker also degrades loud" \
  || no "dry-run must not claim success against an unreachable tracker (rc=$RC5d)"

# ── T6 — the no-`gh issue create` contract (issue filing is user-gated) ──────
# CRITICAL: the agent CANNOT file issues. The submit machinery must never EXECUTE
# `gh issue create`. The script legitimately EMITS that command as text for the
# user to run (drafting is the whole point), so a blunt grep for the words would
# false-positive on the emitted command and the doc. The real contract is that the
# script never INVOKES it through the gh seam: assert no `"$GH" issue create` (the
# only way an executed filing could be written) appears in the source.
grep -nE '"\$GH"[[:space:]]+issue[[:space:]]+create|\$GH[[:space:]]+issue[[:space:]]+create|\$\{GH\}[[:space:]]+issue[[:space:]]+create' "$SCRIPT" \
  && no "source must NOT INVOKE 'gh issue create' through the seam (filing is user-gated)" \
  || ok "source never invokes 'gh issue create' (it only emits it for the user; drafts only)"
# The run never executes the real binary either — proven hermetically: with the
# stub denying any non-(repo view) call (exit 99), T1/T3 exited 0, so the script
# made ONLY repo-view calls. Assert that contract directly on a fresh run.
P6=$(make_project); LOG6="$P6/$LOG_REL"
add_entry "$LOG6" "c1" "upstream" "open" "draft me"
ERR6=$( cd "$P6" && GUV_GH="$STUB_DIR/gh-reachable" bash "$SCRIPT" submit 2>&1 1>/dev/null )
echo "$ERR6" | grep -q "unexpected call" \
  && no "submit invoked the tracker with a non-(repo view) call: $ERR6" \
  || ok "submit only ever calls 'gh repo view' on the tracker (no create)"

# ── T7 — stderr is clean on the happy path (the empty-stderr gate) ───────────
P7=$(make_project); LOG7="$P7/$LOG_REL"
add_entry "$LOG7" "s1" "upstream" "open" "clean-stderr check"
( cd "$P7" && GUV_GH="$STUB_DIR/gh-reachable" bash "$SCRIPT" submit ) >/dev/null 2>"$WORK/t7.err"
[ ! -s "$WORK/t7.err" ] \
  && ok "happy-path run keeps stderr clean" \
  || no "happy-path run wrote to stderr: $(cat "$WORK/t7.err")"

# ── T8 — usage / no-manifest guards (loud, deterministic exits) ──────────────
( cd "$WORK" && GUV_GH="$STUB_DIR/gh-reachable" bash "$SCRIPT" bogus ) >/dev/null 2>"$WORK/t8.err"; RCU=$?
[ $RCU -eq 2 ] && ok "unknown subcommand -> exit 2 (usage)" || no "unknown subcommand should exit 2 (rc=$RCU)"
NOMAN=$(mktemp -d)
( cd "$NOMAN" && GUV_GH="$STUB_DIR/gh-reachable" bash "$SCRIPT" submit ) >/dev/null 2>"$WORK/t8b.err"; RCM=$?
[ $RCM -eq 4 ] && ok "no manifest -> exit 4 (cwd must be project root)" || no "no manifest should exit 4 (rc=$RCM)"
rm -rf "$NOMAN"

# ── T9 — a missing/empty log is a clean no-op, never an error ────────────────
P9=$(make_project)  # no log file created
OUT9=$( cd "$P9" && GUV_GH="$STUB_DIR/gh-reachable" bash "$SCRIPT" submit 2>"$WORK/t9.err" ); RC9=$?
[ $RC9 -eq 0 ] \
  && ok "missing feedback log -> clean no-op exit 0" \
  || no "missing log should be a no-op, not an error (rc=$RC9, err=$(cat "$WORK/t9.err"))"

# ── T10 — the emitted block DELIVERS the drafted body (the drafting contract) ──
# The whole value of "agent drafts, user files" is that the user copy-pastes the
# emitted block and the FILED issue carries the full body — the entry id, the detail,
# the cite-on-close footer. A regression where the body is computed but never piped
# (a dead $BODY) would emit a command that files an empty issue. This test runs the
# emitted block exactly as a user would (gh -> the filer stub via PATH) and asserts
# the captured title AND body. It is the guard that the body actually reaches gh.
P10=$(make_project); LOG10="$P10/$LOG_REL"
add_entry "$LOG10" "body1" "upstream" "open" "the detail text that must reach the issue body"
OUT10=$( cd "$P10" && GUV_GH="$STUB_DIR/gh-reachable" bash "$SCRIPT" submit ) 2>"$WORK/t10.err"
# Extract the emitted heredoc block (the `gh issue create` line through its closing
# delimiter) verbatim from the run output — this is precisely what a user copy-pastes.
BLOCK=$(printf '%s\n' "$OUT10" | awk '
  /^gh issue create / {f=1}
  f {print}
  f && /^GUV-FEEDBACK-BODY$/ {exit}')
[ -n "$BLOCK" ] \
  && ok "submit emits a runnable 'gh issue create' heredoc block" \
  || no "submit must emit a copy-pasteable gh issue create block (out=$OUT10)"
# Run the block as the user would: put a `gh` on PATH that IS the filer stub (a copy
# named `gh`), so the literal `gh issue create …` in the emitted block resolves to it.
# The stub records the title and the stdin body. The block must carry the body so the
# filed issue is not empty.
FILER_OUT="$WORK/filer.out"
GHDIR="$WORK/ghbin"; mkdir -p "$GHDIR"; cp "$STUB_DIR/gh-filer" "$GHDIR/gh"; chmod +x "$GHDIR/gh"
printf '%s\n' "$BLOCK" > "$WORK/t10-block.sh"
( cd "$P10" && PATH="$GHDIR:$PATH" GH_FILER_OUT="$FILER_OUT" bash "$WORK/t10-block.sh" ) \
  >/dev/null 2>"$WORK/t10b.err"
if [ -s "$FILER_OUT" ]; then
  grep -q "TITLE: \[feedback\]" "$FILER_OUT" \
    && ok "the filed issue carries the drafted title" \
    || no "emitted block must file with the drafted title (filer=$(cat "$FILER_OUT"))"
  # The body is the dead-code guard: it MUST be non-empty and carry the entry id +
  # detail + the cite-on-close footer. An empty body here is exactly the Critical.
  BODY_CAP=$(awk '/^--- BODY ---$/{f=1;next} f' "$FILER_OUT")
  [ -n "$BODY_CAP" ] \
    && ok "the emitted block pipes a NON-EMPTY body to gh (not the dead-\$BODY defect)" \
    || no "emitted block produced an EMPTY issue body — the drafted body never reached gh"
  printf '%s' "$BODY_CAP" | grep -qF "body1" \
    && printf '%s' "$BODY_CAP" | grep -qF "the detail text that must reach the issue body" \
    && printf '%s' "$BODY_CAP" | grep -qiF "cite this entry id" \
    && ok "the delivered body carries the entry id, the detail, and the cite-on-close footer" \
    || no "the delivered body must carry id+detail+cite footer (body=$BODY_CAP)"
else
  no "running the emitted block recorded nothing — the user's copy-paste does not work (err=$(cat "$WORK/t10b.err"))"
fi

# ── T11 — a real issue-URL writeback also dedupes (the closed-loop end-state) ──
# After the user files and pastes the real issue URL back into detail, a re-run must
# skip that entry on the URL (not only the DRAFTED marker) — the documented end-state
# the acceptance bar names. Proves the dedupe matches the live issue link too.
P11=$(make_project); LOG11="$P11/$LOG_REL"
add_entry "$LOG11" "url1" "upstream" "open" "filed and linked | Issue: https://github.com/ijpatter1/guv/issues/77"
BEFORE11=$(cat "$LOG11")
OUT11=$( cd "$P11" && GUV_GH="$STUB_DIR/gh-reachable" bash "$SCRIPT" submit ) 2>"$WORK/t11.err"; RC11=$?
AFTER11=$(cat "$LOG11")
[ $RC11 -eq 0 ] && [ "$BEFORE11" = "$AFTER11" ] \
  && ! echo "$OUT11" | grep -q "url1" \
  && ok "an entry carrying the real issue URL is skipped (loop closed, byte-identical)" \
  || no "a real-URL-linked entry must be deduped, not re-drafted (rc=$RC11, out=$OUT11)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
