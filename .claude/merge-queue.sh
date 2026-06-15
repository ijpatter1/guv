#!/bin/bash
# .claude/merge-queue.sh — the gated merge queue ([7.4]).
#
# Lands lane branches (lane/<id>-<slug> in the CODE repo, made by guv-lane.sh —
# one per deliverable ID) sequentially onto the integration branch (the code
# repo's checked-out HEAD). The discipline, in four deterministic moves the
# orchestrator drives:
#
#   precheck <id>        cheap gates BEFORE the evaluator spends a token —
#                        a dirty lane worktree or a WIP/fixup commit message is
#                        refused; the diff footprint is computed and surfaced.
#   preview <id>…        git merge-tree --write-tree previews each lane's
#                        conflicts WITHOUT touching a working tree, and the
#                        queue is ordered cheapest-first (clean before
#                        conflicting, then smallest footprint). A pairwise
#                        conflict among queued lanes is flagged (exit 1).
#                        Needs git >= 2.38 for --write-tree; preview probes for
#                        it and stops loud on an older git (a silent mis-preview
#                        is worse than a refusal — Rule 15).
#   gate-input <id>      extracts the deliverable's acceptance block from the
#                        control plane's REQUIREMENTS by ID and bundles it with
#                        the footprint — what counts as good is ROUTED to the
#                        checker, not reconstructed by it (Rule 12: the model
#                        grades, code assembles the input).
#   land <id>            rebase the lane onto the post-merge integration head
#                        (in the lane's own worktree, never disturbing main),
#                        then fast-forward land. A rebase that conflicts is the
#                        conflict-as-DAG-lint heavy path: refuse (exit 7), land
#                        nothing, and propose a /replan deps-amend so the lanes
#                        serialize. The model improvises the repair, never the
#                        route (Rule 15).
#
# Lanes resolve through guv-lane.sh (harvest), so the queue inherits the one
# lane-id→branch lookup rather than re-deriving it. cwd must be the project root
# (the control plane: roots.code names the lane repo, docs/REQUIREMENTS.md holds
# the acceptance). Ships byte-identical into both install modes; siblings
# resolve it location-relative (the [7.7] precedent).
#
# Exit: 0 ok · 2 usage · 4 no/corrupt manifest or no code repo ·
#       5 unknown lane or unknown deliverable ID · 6 refused (dirty/WIP
#       pre-check) · 7 heavy conflict (DAG-lint route).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LANE="$HERE/guv-lane.sh"
METER_QUEUE="$HERE/meter-queue.sh"   # [9.4] queue-boundary cost-and-performance writer

die() { echo "merge-queue: $2" >&2; exit "$1"; }

# A hi-res clock in seconds (bash + coreutils only); degrades to integer seconds on
# a date without %N (stock macOS) — the same clock meter.sh uses, kept local so the
# queue measures the land's wall-clock itself (never an agent value).
now_s() {
  local t; t=$(date +%s.%N 2>/dev/null)
  case "$t" in *N|"") date +%s ;; *) printf '%s' "$t" ;; esac
}

# The diff footprint as three numbers ("files insertions deletions") — the SAME
# measure footprint() surfaces, parsed back to discrete fields for the metering
# writer. Reused, not recomputed differently.
footprint_nums() {  # $1=branch -> "files insertions deletions"
  local br="$1" base
  base=$(git -C "$CODE" merge-base "$(integ)" "$br" 2>/dev/null) || { echo "0 0 0"; return; }
  git -C "$CODE" diff --numstat "$base..$br" 2>/dev/null \
    | awk '{f++; i+=($1=="-"?0:$1); d+=($2=="-"?0:$2)} END{printf "%d %d %d", f+0, i+0, d+0}'
}

# Resolve the CODE repo the same way every sibling does — through the shared
# [11.2] resolver (string roots.code = the single primary; named map addresses
# each repo by name). A manifest that exists but won't parse is a loud stop,
# never the single-repo fallback (landing into the wrong repo is the worst
# version of this mistake; Rule 15).
# shellcheck source=/dev/null
. "$HERE/roots.sh"

# Per-repo selector & worktree namespacing ([11.3]). A TRAILING <repo> token
# names which code repo this queue invocation acts on (default = the primary);
# when present, the worktree is repo-namespaced at .worktrees/<repo>/lane-<id>/
# (matching guv-lane.sh) and the lane lookup is forwarded to that repo. On a
# string roots.code the trailing token never matches a repo name, so single-repo
# stays a flat-path no-op (back-compat). Peel it off $@ before the verb dispatch.
[ $# -ge 1 ] || die 2 "usage: bash .claude/merge-queue.sh precheck <id> [<repo>] | preview <id>… [<repo>] | gate-input <id> [<repo>] | land <id> [<repo>]"
REPO=""; NS=""
if [ $# -ge 2 ]; then
  _last="${!#}"
  if _roots_is_repo_name "$_last"; then REPO="$_last"; NS="$REPO/"; set -- "${@:1:$#-1}"; fi
fi
CODE=$(roots_code_path "$REPO") || die 4 "could not resolve code repo '${REPO:-<primary>}' from the manifest"
git -C "$CODE" rev-parse --git-dir >/dev/null 2>&1 \
  || die 4 "no git repo at roots.code ($CODE)"

# The integration branch — the queue lands onto the code repo's checked-out
# branch. A detached HEAD has no branch to advance: loud stop.
integ() {
  git -C "$CODE" symbolic-ref --short HEAD 2>/dev/null \
    || die 4 "code repo HEAD is detached — the queue lands onto a branch"
}

# Resolve a lane id → its branch via guv-lane harvest (the one lookup).
# Echoes "branch dirty" on success; RETURNS 5 on failure (never die) — the die
# must fire in the MAIN shell, not here: lane_state is always read inside a
# command substitution, where an internal `exit` would only kill the subshell
# and the caller would limp on with an empty branch (the UAT-F6 defect class, the
# same one fixed in lane-dispatch's INTEG). Every caller does
# `STATE=$(lane_state "$id") || die 5 …` so an unknown id loud-stops (Rule 15).
lane_state() {
  local id="$1" out rc br dirty
  # Forward the peeled <repo> so guv-lane resolves the SAME named repo + namespaced
  # worktree (a bare REPO is the primary, the single-repo no-op).
  out=$(bash "$LANE" harvest "$id" $REPO 2>/dev/null); rc=$?
  [ $rc -eq 0 ] || return 5
  br=$(printf '%s' "$out" | grep -oE 'branch=[^ ]+' | head -1 | cut -d= -f2-)
  dirty=$(printf '%s' "$out" | grep -oE 'dirty=[^ ]+' | head -1 | cut -d= -f2-)
  printf '%s %s' "$br" "$dirty"
}
# Resolve in the main shell so the die propagates (callers must not inline the
# substitution into a herestring, which swallows the exit status).
no_lane() { die 5 "no lane for id $1 (expected lane/$1-<slug>)"; }

# files insertions deletions of the lane's own commits (merge-base..branch).
footprint() {
  local br="$1" base
  base=$(git -C "$CODE" merge-base "$(integ)" "$br" 2>/dev/null) \
    || die 5 "cannot find a merge-base for $br"
  git -C "$CODE" diff --numstat "$base..$br" \
    | awk '{f++; i+=($1=="-"?0:$1); d+=($2=="-"?0:$2)} END{printf "files=%d insertions=%d deletions=%d", f+0, i+0, d+0}'
}

# Extract the deliverable's acceptance block (by ID) from a REQUIREMENTS file:
# from the deliverable's lead line through to the next deliverable lead or a
# section boundary. Empty if the ID is absent.
acceptance_block() {
  local id="$1" file="$2"
  awk -v id="$id" '
    function is_lead(l) { return (l ~ /\*\*\[[0-9]+\.[0-9]+\]\*\*/) }
    BEGIN { cap=0; idpat="\\*\\*\\[" id "\\]\\*\\*" }
    {
      if (!cap && $0 ~ idpat) { cap=1; print; next }
      if (cap && (is_lead($0) || $0 ~ /^## / || $0 ~ /^---/)) { cap=0 }
      if (cap) print
    }
  ' "$file"
}

VERB="$1"; shift

case "$VERB" in
  precheck)
    [ $# -eq 1 ] || die 2 "usage: precheck <id>"
    ID="$1"
    STATE=$(lane_state "$ID") || no_lane "$ID"
    read -r BR DIRTY <<<"$STATE"
    [ "$DIRTY" = "1" ] \
      && die 6 "lane $ID worktree is dirty — commit or discard before queueing (refused before any agent invocation)"
    BASE=$(git -C "$CODE" merge-base "$(integ)" "$BR")
    if git -C "$CODE" log --format='%s' "$BASE..$BR" | grep -qiE '^(wip|fixup!|squash!|amend!)'; then
      die 6 "lane $ID carries a WIP/fixup commit message — clean the history before queueing"
    fi
    echo "precheck=ok lane=$ID footprint $(footprint "$BR")"
    ;;

  gate-input)
    [ $# -eq 1 ] || die 2 "usage: gate-input <id>"
    ID="$1"
    REQ="docs/REQUIREMENTS.md"
    [ -f "$REQ" ] || die 4 "no $REQ (cwd must be the control plane)"
    ACC=$(acceptance_block "$ID" "$REQ")
    [ -n "$ACC" ] || die 5 "no deliverable [$ID] in $REQ — acceptance criteria not found"
    STATE=$(lane_state "$ID") || no_lane "$ID"
    read -r BR DIRTY <<<"$STATE"
    HEAD=$(git -C "$CODE" rev-parse "$BR")
    echo "=== gate-input for [$ID] — evaluator grading bundle ==="
    echo "deliverable: $ID"
    echo "lane: $BR head=$HEAD"
    echo "footprint $(footprint "$BR")"
    echo "--- acceptance criteria (from $REQ; what counts as good) ---"
    printf '%s\n' "$ACC"
    ;;

  preview)
    [ $# -ge 1 ] || die 2 "usage: preview <id>…"
    INTEG=$(integ)
    # merge-tree --write-tree (git >= 2.38) is the conflict-preview primitive;
    # a silent mis-preview on an older git would mis-order the queue (Rule 15).
    git -C "$CODE" merge-tree --write-tree "$INTEG" "$INTEG" >/dev/null 2>&1 \
      || die 4 "git merge-tree --write-tree unsupported — preview needs git >= 2.38 (have $(git --version 2>/dev/null))"
    declare -a IDS=() BRS=() FP=() CVI=()
    for id in "$@"; do
      state=$(lane_state "$id") || no_lane "$id"
      read -r br dirty <<<"$state"
      base=$(git -C "$CODE" merge-base "$INTEG" "$br")
      lines=$(git -C "$CODE" diff --numstat "$base..$br" | awk '{i+=($1=="-"?0:$1); d+=($2=="-"?0:$2)} END{print i+d+0}')
      cvi=0
      git -C "$CODE" merge-tree --write-tree "$INTEG" "$br" >/dev/null 2>&1 || cvi=1
      IDS+=("$id"); BRS+=("$br"); FP+=("$lines"); CVI+=("$cvi")
      echo "lane=$id branch=$br footprint_lines=$lines conflicts_integration=$cvi"
    done
    # Pairwise conflict detection among queued lanes (the manufactured-conflict
    # case: each clean vs integration, but they collide with each other).
    conflict=0
    n=${#IDS[@]}
    for ((a=0; a<n; a++)); do
      for ((b=a+1; b<n; b++)); do
        if ! git -C "$CODE" merge-tree --write-tree "${BRS[a]}" "${BRS[b]}" >/dev/null 2>&1; then
          conflict=1
          echo "conflict: lane ${IDS[a]} and lane ${IDS[b]} touch the same lines"
        fi
      done
    done
    # Order cheapest-first: clean-vs-integration before conflicting, then by
    # smallest footprint, then by id.
    ORDER=$(for ((i=0; i<n; i++)); do echo "${CVI[i]} ${FP[i]} ${IDS[i]}"; done \
            | sort -k1,1n -k2,2n -k3,3 | awk '{printf "%s ", $3}' | sed 's/ $//')
    echo "order=$ORDER"
    [ "$conflict" -eq 0 ] && { for c in "${CVI[@]}"; do [ "$c" = "0" ] || conflict=1; done; }
    exit "$conflict"
    ;;

  land)
    [ $# -eq 1 ] || die 2 "usage: land <id>"
    ID="$1"
    INTEG=$(integ)
    STATE=$(lane_state "$ID") || no_lane "$ID"
    read -r BR DIRTY <<<"$STATE"
    WT="$CODE/.worktrees/${NS}lane-$ID"   # repo-namespaced when a <repo> was named ([11.3])
    [ -d "$WT" ] || die 5 "lane $ID has no worktree at $WT to land from"
    # Snapshot the footprint BEFORE the rebase: the rebase replays the lane onto
    # the post-merge head and moves the merge-base, so the gate's footprint must be
    # read here, against the pre-rebase base — the same number precheck surfaced.
    read -r LF_F LF_I LF_D <<<"$(footprint_nums "$BR")"
    LAND_START=$(now_s)   # the queue measures the land's wall-clock itself ([9.4])
    # Rebase onto the post-merge integration head IN THE LANE'S OWN WORKTREE,
    # so the main worktree is never disturbed. A conflict here is the heavy
    # path: abort cleanly, land nothing, route to /replan (Rule 15).
    if ! git -C "$WT" rebase "$INTEG" >/dev/null 2>&1; then
      git -C "$WT" rebase --abort >/dev/null 2>&1
      echo "land=refused lane=$ID reason=heavy-conflict (rebase onto $INTEG conflicts)"
      echo "conflict-as-DAG-lint: land the lane it collides with first, then re-dispatch [$ID] serially."
      echo "Proposed: /replan (/guv:replan under the plugin) deps-amend [$ID] — add the conflicting deliverable as a dep so the queue serializes them (the model improvises the repair, never the route)."
      # Burn profile ([9.4]): the routed-out lane is the most diagnostically
      # interesting retry case, so surface its cost-and-performance entry —
      # dispatch_outcome=conflict-routed, the footprint snapshotted BEFORE the rebase
      # (reused, never recomputed; the rebase that just aborted moved no base), and
      # wallclock 0 (a routed lane never landed, so there is no land wall-clock to
      # measure). `emit` PRINTS the entry — it does NOT append to the metering log:
      # the log records LANDINGS, and a refused lane owes no log line (same rule as
      # the harvest-refused burn profile in lane-dispatch.sh). Best-effort: a metering
      # hiccup must never change the route (the lane is already refused; Rule 15).
      if [ -f "$METER_QUEUE" ]; then
        echo "burn profile (queue-boundary cost-and-performance, [9.4]) — diagnostic input to the retry (not a landing; never written to the metering log):"
        bash "$METER_QUEUE" emit \
          --deliverable "$ID" --outcome conflict-routed \
          --files "$LF_F" --insertions "$LF_I" --deletions "$LF_D" --wallclock 0 \
          2>/dev/null \
          || echo "merge-queue: note — burn profile unavailable (lane still routed out; metering is non-fatal exhaust)" >&2
      fi
      exit 7
    fi
    # The lane now fast-forwards onto integration; advance it in the main worktree.
    if ! git -C "$CODE" merge --ff-only "$BR" >/dev/null 2>&1; then
      die 1 "ff-merge of $BR onto $INTEG failed (integration worktree dirty or not on $INTEG?)"
    fi
    LAND_WALLCLOCK=$(awk -v a="$LAND_START" -v b="$(now_s)" 'BEGIN{ d=b-a; if (d<0) d=0; printf "%.3f", d }')
    echo "landed=$ID branch=$BR head=$(git -C "$CODE" rev-parse "$INTEG")"
    # Queue-boundary capture ([9.4]): append the landing's per-deliverable cost-and-
    # performance entry — the gate's footprint (reused), the queue-measured land
    # wall-clock, and dispatch_outcome=landed; tokens are harvested by the writer.
    # BEST-EFFORT and NON-FATAL: the land already succeeded and metering is exhaust
    # — a metering hiccup must never fail a real land (Rule 15 designed degradation).
    if [ -f "$METER_QUEUE" ]; then
      bash "$METER_QUEUE" capture \
        --deliverable "$ID" --outcome landed \
        --files "$LF_F" --insertions "$LF_I" --deletions "$LF_D" \
        --wallclock "$LAND_WALLCLOCK" >/dev/null 2>&1 \
        || echo "merge-queue: note — queue-boundary metering capture skipped (land succeeded; metering is non-fatal exhaust)" >&2
    fi
    ;;

  *) die 2 "unknown verb '$VERB' (precheck | preview | gate-input | land)" ;;
esac
