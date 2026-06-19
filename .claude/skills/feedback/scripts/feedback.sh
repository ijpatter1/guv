#!/bin/bash
# feedback.sh — the LOCAL feedback-log mutation helper ([15.4]).
#
# The feedback log (.claude/feedback/feedback.ndjson, one JSON object per line)
# is data, not behavior — an append-only record of guv friction. The triage
# operations on it (append a `new` entry, `list` the open ones, set a terminal
# `status`, append a `| TRIAGE/GRADUATED (date, session): …` provenance note,
# the whole-file rewrite) were hand-rolled jq pasted from the skill doc. A pasted
# command is a deterministic transform that drifts: this helper mechanizes them
# (Rule 12 — a deterministic transform is code, not a pasted command), mirroring
# estimate.sh / replan.sh (the sibling deterministic read/write/validate helpers).
#
# This is the LOCAL mutation verb. feedback-submit.sh (sibling) is the SUBMIT/
# drain-upstream transport — it drafts issues against the source tracker. The two
# do not overlap: feedback.sh never touches a tracker; it only rewrites the log.
#
# Every write is SCHEMA-VALIDATED before it lands and ATOMIC (mktemp + mv): a
# rejected mutation leaves the log byte-identical, and a no-op rewrite (triage to
# the status an entry already holds) changes NOTHING (the byte-stable round-trip
# the log's append-only contract requires). triage/graduate/note match on the
# unique `id` (ts alone collides at second resolution); an unknown id is a loud
# refusal (Rule 15 — never a silent no-op).
#
# (Ships byte-identical into both install modes; under a plugin install the
# command is guv:-namespaced — /feedback resolves as /guv:feedback.)
#
# Usage:
#   bash feedback.sh new --category C --summary S --severity SEV --routing R \
#                        [--artifact A] [--detail D] [--session SESS] [--log PATH]
#   bash feedback.sh list [--all] [--log PATH]        # open entries (—all: every entry)
#   bash feedback.sh triage ID STATUS [NOTE] [--log PATH]   # set terminal status
#   bash feedback.sh graduate ID NOTE [--log PATH]    # status=graduated; NOTE REQUIRED
#   bash feedback.sh note ID NOTE [--log PATH]        # append note to detail; status unchanged
#
#   --log overrides the log path (tests); default is control-plane relative:
#   .claude/feedback/feedback.ndjson. `new` creates the dir/file on first use; a
#   read (list) against an absent log is a clean no-op, not an error.
#
#   STATUS for triage is one of the terminal states: resolved | wontfix |
#   graduated (open is the creation state, not a triage target). A graduate
#   carries a provenance note — `graduate` REFUSES without one; `triage ID
#   graduated` likewise requires the NOTE.
#
# Exit: 0 ok · 2 usage · 4 no log (a mutation target that does not exist) ·
#       5 SCHEMA (out-of-set status/category/severity/routing, or a graduate
#       without a provenance note) · 6 REFUSED (unknown id — the mutation has no
#       target). A non-zero exit writes NOTHING.
set -u

LOG_DEFAULT=".claude/feedback/feedback.ndjson"

# Allowed enum sets — the schema contract (mirrors the SKILL.md field table and
# the sets the feedback-log test guards). Space-delimited for a portable membership
# check (no associative arrays — match the sibling helpers' plain-bash style).
CATEGORIES="broken-command inapplicable-setting doc-drift manifest-gap hook-misfire friction other"
SEVERITIES="blocker major minor"
ROUTINGS="upstream local unsure"
STATUSES_TERMINAL="resolved wontfix graduated"

usage() {
  echo "usage: bash feedback.sh new|list|triage|graduate|note … (header comment has the arity)" >&2
  exit 2
}
die2() { echo "feedback: USAGE — $1" >&2; exit 2; }
die4() { echo "feedback: NO-LOG — $1" >&2; exit 4; }
die5() { echo "feedback: SCHEMA — $1" >&2; exit 5; }
die6() { echo "feedback: REFUSED — $1" >&2; exit 6; }

# Whitespace-delimited membership: in_set VALUE "a b c".
in_set() {
  local v="$1" set="$2" x
  for x in $set; do [ "$x" = "$v" ] && return 0; done
  return 1
}

# An entry with this id exists in the log. Used to make every mutation that
# targets an id a loud refusal rather than a silent no-op (Rule 15).
id_exists() { # id  log
  [ -f "$2" ] || return 1
  [ -n "$(jq -c --arg id "$1" 'select(.id==$id)' "$2" 2>/dev/null)" ]
}

# Atomic whole-file rewrite through a jq program. Reads $LOG, applies the program
# (with the passed --arg pairs already in the args array), writes a sibling temp,
# then mv — so a failed jq leaves the log byte-identical. The log is small; a
# whole-file rewrite is the same discipline triage/feedback-submit already use.
rewrite() { # jq_program  [--arg k v ...]
  local prog="$1"; shift
  local tmp="$LOG.tmp.$$"
  jq -c "$@" "$prog" "$LOG" > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; die5 "$LOG is not valid NDJSON — refusing to rewrite (log untouched)"; }
  mv "$tmp" "$LOG"
}

cmd="${1:-}"
[ -n "$cmd" ] || usage
shift || true

case "$cmd" in

  new)
    # Append one schema-valid entry (status open). Required: category, summary,
    # severity, routing. Optional: artifact, detail, session. id/ts derived.
    CATEGORY=""; SUMMARY=""; SEVERITY=""; ROUTING=""
    ARTIFACT=""; DETAIL=""; SESSION=""; LOG="$LOG_DEFAULT"
    while [ $# -gt 0 ]; do
      case "$1" in
        --category) CATEGORY="${2:-}"; shift 2 ;;
        --summary)  SUMMARY="${2:-}";  shift 2 ;;
        --severity) SEVERITY="${2:-}"; shift 2 ;;
        --routing)  ROUTING="${2:-}";  shift 2 ;;
        --artifact) ARTIFACT="${2:-}"; shift 2 ;;
        --detail)   DETAIL="${2:-}";   shift 2 ;;
        --session)  SESSION="${2:-}";  shift 2 ;;
        --log)      LOG="${2:-}";      shift 2 ;;
        *) die2 "unknown argument to new: '$1'" ;;
      esac
    done
    [ -n "$SUMMARY" ]  || die2 "new requires --summary (one line: what didn't fit)"
    in_set "$CATEGORY" "$CATEGORIES" || die5 "category '$CATEGORY' not in {$CATEGORIES}"
    in_set "$SEVERITY" "$SEVERITIES" || die5 "severity '$SEVERITY' not in {$SEVERITIES}"
    in_set "$ROUTING"  "$ROUTINGS"   || die5 "routing '$ROUTING' not in {$ROUTINGS}"
    # Derive session from the latest handoff if not supplied (the documented rule).
    if [ -z "$SESSION" ]; then
      SESSION=$(ls -t docs/sessions/session-*.md 2>/dev/null | head -1 | xargs -r basename | sed 's/\.md$//')
      SESSION="${SESSION:-n/a}"
    fi
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$(dirname "$LOG")"
    jq -cn \
      --arg id "${TS}-${RANDOM}${RANDOM}" \
      --arg ts "$TS" \
      --arg session "$SESSION" \
      --arg category "$CATEGORY" \
      --arg artifact "$ARTIFACT" \
      --arg summary "$SUMMARY" \
      --arg detail "$DETAIL" \
      --arg severity "$SEVERITY" \
      --arg routing "$ROUTING" \
      '{id:$id, ts:$ts, session:$session, category:$category, artifact:$artifact,
        summary:$summary, detail:$detail, severity:$severity, routing:$routing, status:"open"}' \
      >> "$LOG" \
      || die4 "could not append to $LOG"
    ;;

  list)
    # Open entries as a readable id·severity·routing·summary table (the scan view
    # to pick an id to triage). --all lists every entry regardless of status. An
    # absent log is a clean empty result, not an error.
    ALL=0; LOG="$LOG_DEFAULT"
    while [ $# -gt 0 ]; do
      case "$1" in
        --all) ALL=1; shift ;;
        --log) LOG="${2:-}"; shift 2 ;;
        *) die2 "unknown argument to list: '$1'" ;;
      esac
    done
    [ -f "$LOG" ] || exit 0
    SEL='select(.status=="open")'
    [ "$ALL" = "1" ] && SEL='.'
    jq -r "$SEL"' | "\(.id)\t\(.severity)\t\(.routing)\t\(.status)\t\(.summary)"' "$LOG" \
      | { column -t -s "$(printf '\t')" 2>/dev/null || cat; }
    ;;

  triage)
    # Set a terminal status on the entry matched by unique id, optionally appending
    # a provenance note to detail. A graduate REQUIRES the note (the auditable-close
    # contract); resolved/wontfix may flip bare. STATUS must be in the terminal set.
    [ $# -ge 2 ] || die2 "triage needs: ID STATUS [NOTE] [--log PATH]"
    ID="$1"; STATUS="$2"; shift 2
    NOTE=""; LOG="$LOG_DEFAULT"
    # A positional NOTE may precede --log; consume one non-flag positional as NOTE.
    if [ $# -gt 0 ] && [ "$1" != "--log" ]; then NOTE="$1"; shift; fi
    while [ $# -gt 0 ]; do
      case "$1" in
        --log) LOG="${2:-}"; shift 2 ;;
        *) die2 "unknown argument to triage: '$1'" ;;
      esac
    done
    in_set "$STATUS" "$STATUSES_TERMINAL" \
      || die5 "status '$STATUS' not in the terminal set {$STATUSES_TERMINAL} (open is the creation state, not a triage target)"
    [ "$STATUS" = "graduated" ] && [ -z "$NOTE" ] \
      && die5 "a graduate carries provenance — supply a NOTE naming what resolved it (use \`note\` for a status-less annotation)"
    [ -f "$LOG" ] || die4 "no feedback log at $LOG"
    id_exists "$ID" "$LOG" || die6 "no entry with id '$ID' in $LOG (triage matches the unique id)"
    rewrite \
      'if .id==$id then .status=$s | (if $note=="" then . else .detail=((.detail // "") + " | " + $note) end) else . end' \
      --arg id "$ID" --arg s "$STATUS" --arg note "$NOTE"
    ;;

  graduate)
    # status=graduated WITH a required provenance note — the common close verb,
    # thin over triage so the note-required contract lives in one place.
    [ $# -ge 1 ] || die2 "graduate needs: ID NOTE [--log PATH]"
    ID="$1"; shift
    NOTE=""; LOG="$LOG_DEFAULT"
    if [ $# -gt 0 ] && [ "$1" != "--log" ]; then NOTE="$1"; shift; fi
    while [ $# -gt 0 ]; do
      case "$1" in
        --log) LOG="${2:-}"; shift 2 ;;
        *) die2 "unknown argument to graduate: '$1'" ;;
      esac
    done
    [ -n "$NOTE" ] \
      || die5 "graduate REFUSES without a provenance note — name what resolved it (deliverable/commit/release)"
    [ -f "$LOG" ] || die4 "no feedback log at $LOG"
    id_exists "$ID" "$LOG" || die6 "no entry with id '$ID' in $LOG (graduate matches the unique id)"
    rewrite \
      'if .id==$id then .status="graduated" | .detail=((.detail // "") + " | " + $note) else . end' \
      --arg id "$ID" --arg note "$NOTE"
    ;;

  note)
    # Append a provenance/context note to detail WITHOUT changing status — the
    # status-less annotation (e.g. "investigating", a cross-reference).
    [ $# -ge 2 ] || die2 "note needs: ID NOTE [--log PATH]"
    ID="$1"; NOTE="$2"; shift 2
    LOG="$LOG_DEFAULT"
    while [ $# -gt 0 ]; do
      case "$1" in
        --log) LOG="${2:-}"; shift 2 ;;
        *) die2 "unknown argument to note: '$1'" ;;
      esac
    done
    [ -n "$NOTE" ] || die2 "note needs a non-empty NOTE"
    [ -f "$LOG" ] || die4 "no feedback log at $LOG"
    id_exists "$ID" "$LOG" || die6 "no entry with id '$ID' in $LOG (note matches the unique id)"
    rewrite \
      'if .id==$id then .detail=((.detail // "") + " | " + $note) else . end' \
      --arg id "$ID" --arg note "$NOTE"
    ;;

  *) usage ;;
esac
exit 0
