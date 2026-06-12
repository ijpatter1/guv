#!/bin/bash
# .claude/replan.sh
# Deterministic tracker-mutation engine behind /replan ([6.3] of the
# plan-as-data spec). The grammar is defined ONCE in the phase-docs skill
# ("Tracker grammar"); this engine mutates docs/PHASE_STATUS.md only —
# REQUIREMENTS and ARCHITECTURE edits are judgment calls owned by the
# /replan command, which mandates REQUIREMENTS-first and then verifies the
# verbatim-sync contract here (sync-check). Every candidate result is
# validated by resolve-ready.sh before the write lands (one grammar dialect,
# two enforcement layers, no third validator), and writes are atomic: a
# rejected mutation leaves the tracker byte-identical.
# (This file ships byte-identical into both install modes; under a plugin
# install the command name is guv:-namespaced — /replan resolves as
# /guv:replan.)
#
# Usage:
#   bash .claude/replan.sh next-ordinal PHASE [TRACKER]
#   bash .claude/replan.sh guard TARGET [TRACKER]            # TARGET = N or N.M
#   bash .claude/replan.sh insert SESSION OP WORDING [TRACKER]
#   bash .claude/replan.sh descope SESSION OP ID NOTE [TRACKER]
#   bash .claude/replan.sh reword SESSION OP ID WORDING [TRACKER [SUMMARY]]
#   bash .claude/replan.sh sync-check ID [TRACKER [REQUIREMENTS]]
#
#   reword's SUMMARY is a one-line "what changed" for the amendment record;
#   pass '' for TRACKER to keep the default. When the deps token changed the
#   record carries the old → new diff automatically (the summary appends);
#   when only wording changed the record carries the summary, defaulting to
#   "wording amended" — a record never goes out with an empty detail.
#
#   TRACKER defaults to docs/PHASE_STATUS.md, REQUIREMENTS to
#   docs/REQUIREMENTS.md. WORDING is the full deliverable wording, leading
#   bold ID through trailing deps token, exactly as it appears in
#   REQUIREMENTS. OP is the /replan verb being executed (reorder, split,
#   merge, insert, descope, abandon, deps-amend) — composed verbs (split,
#   merge, reorder) make several engine calls, each recorded under the verb.
#
# Every mutation appends an amendment record to the tracker header
# (format defined in the phase-docs skill, "Amendment records"):
#   > - YYYY-MM-DD — OP [IDs] (SESSION)[ — detail]
#
# Exit: 0 ok · 2 usage · 4 no tracker · 5 MALFORMED (validation failed,
#       unknown target, sync drift) · 6 REFUSED (completed phase, LEGACY
#       tracker, ✅ descope, ordinal mismatch — the append-only rules)
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVER="$DIR/resolve-ready.sh"

ID_RE='\*\*\[[0-9]+\.[0-9]+\]\*\*'
DEPS_RE='`\[deps: (none|[0-9]+\.[0-9]+(, [0-9]+\.[0-9]+)*)\]`'
LEAD_RE="^[[:space:]]*-[[:space:]]*(✅|🔄|⬜|❌)[[:space:]]*$ID_RE"
VERBS="reorder split merge insert descope abandon deps-amend"

usage() { echo "usage: bash .claude/replan.sh next-ordinal|guard|insert|descope|reword|sync-check … (header comment has the arity)" >&2; exit 2; }
die2() { echo "status=USAGE — $1" >&2; exit 2; }
die4() { echo "status=NONE — no tracker at $1" >&2; exit 4; }
die5() { echo "status=MALFORMED — $1" >&2; exit 5; }
die6() { echo "status=REFUSED — $1" >&2; exit 6; }

need_tracker() { [ -f "$1" ] || die4 "$1"; }

# Pre-flight: the engine only operates on a well-formed GRAMMAR tracker.
# The resolver re-gates well-formedness and owns dep semantics; reuse it.
preflight() {
  local out rc
  out=$("$BASH" "$RESOLVER" "$1" 2>&1); rc=$?
  [ "$rc" -eq 5 ] && die5 "tracker fails validation before any mutation — fix it first:
$out"
  [ "$rc" -ne 0 ] && die4 "$1"
  echo "$out" | grep -q '^mode=LEGACY' \
    && die6 "$1 is LEGACY (no grammar tokens); /replan mutations require the DAG grammar — see the phase-docs skill ('Tracker grammar')"
}
BASH="${BASH:-bash}"

marker_bullets() { grep -E '^\s*-\s*(✅|🔄|⬜|❌)' "$1"; }

phase_exists() { grep -qE "^##+ Phase $2([^0-9]|\$)" "$1"; }
id_line()      { marker_bullets "$1" | grep -E "^[[:space:]]*-[[:space:]]*(✅|🔄|⬜|❌)[[:space:]]*\*\*\[$(echo "$2" | sed 's/\./\\./')\]\*\*" | head -1; }

# A phase is completed when it has deliverables and none of them is open
# (⬜ or 🔄) — all ✅/❌. Completed phases are immutable.
phase_completed() {
  local lines
  lines=$(marker_bullets "$1" | grep -E "\*\*\[$2\.[0-9]+\]\*\*")
  [ -n "$lines" ] || return 1
  echo "$lines" | grep -qE '^\s*-\s*(⬜|🔄)' && return 1
  return 0
}

guard_target() { # tracker, target (N or N.M)
  local t="$1" tgt="$2" phase
  case "$tgt" in
    *.*) [ -n "$(id_line "$t" "$tgt")" ] || die5 "unknown ID [$tgt] — not in $t"
         phase="${tgt%%.*}" ;;
    *)   phase_exists "$t" "$tgt" || die5 "no phase $tgt in $t"
         phase="$tgt" ;;
  esac
  phase_completed "$t" "$phase" \
    && die6 "phase $phase is completed and immutable; target the current or a future phase (append-only: ordinals are never reused, history is never rewritten)"
  return 0
}

next_ordinal() { # tracker, phase
  phase_exists "$1" "$2" || die5 "no phase $2 in $1"
  local max
  max=$(marker_bullets "$1" | grep -oE "\*\*\[$2\.[0-9]+\]\*\*" \
        | grep -oE '[0-9]+\.[0-9]+' | cut -d. -f2 | sort -n | tail -1)
  echo "$2.$(( ${max:-0} + 1 ))"
}

valid_op() { case " $VERBS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ── Atomic write machinery: mutate a sibling temp copy, validate with the
# resolver, then mv into place — or report and leave the original untouched.
TMP=""
cleanup() { [ -n "$TMP" ] && rm -f "$TMP"; }
trap cleanup EXIT
mk_tmp() { TMP="$(dirname "$1")/.replan.$$"; cp "$1" "$TMP"; }
commit_tmp() { # tracker
  local out rc
  out=$("$BASH" "$RESOLVER" "$TMP" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && die5 "mutation rejected, tracker unchanged:
$out"
  mv "$TMP" "$1"; TMP=""
}

# Append one amendment record to the header block: into the existing
# **Amendments:** block, else a new block at the end of the header
# blockquote, else at the top of a header-less tracker. Record lines use
# plain bracketed IDs (no bold, no deps shape) so they stay parse-inert.
append_record() { # op, ids, session, detail
  local rec="> - $(date +%F) — $1 [$2] ($3)" first_hdr at total
  [ -n "$4" ] && rec="$rec — $4"
  total=$(wc -l < "$TMP" | tr -d ' ')
  first_hdr=$(grep -n '^## ' "$TMP" | head -1 | cut -d: -f1)
  [ -z "$first_hdr" ] && first_hdr=$(( total + 1 ))
  if at=$(head -n "$(( first_hdr - 1 ))" "$TMP" | grep -n '^> \*\*Amendments:\*\*' | head -1 | cut -d: -f1) && [ -n "$at" ]; then
    # last contiguous '>' line at or after the Amendments marker
    while [ "$at" -lt "$(( first_hdr - 1 ))" ] \
          && sed -n "$(( at + 1 ))p" "$TMP" | grep -q '^>'; do at=$(( at + 1 )); done
    insert_after "$at" "$rec"
  elif at=$(head -n "$(( first_hdr - 1 ))" "$TMP" | grep -n '^>' | tail -1 | cut -d: -f1) && [ -n "$at" ]; then
    insert_after "$at" ">
> **Amendments:**
$rec"
  else
    insert_after 0 "> **Amendments:**
$rec"
  fi
}

insert_after() { # line number (0 = top), text
  local out="$TMP.ins"
  { head -n "$1" "$TMP"; printf '%s\n' "$2"; tail -n "+$(( $1 + 1 ))" "$TMP"; } > "$out"
  mv "$out" "$TMP"
}

# Wording must run leading bold ID through trailing deps token.
check_wording() { # wording
  printf '%s\n' "$1" | grep -qE "^$ID_RE .*$DEPS_RE\$" \
    || die5 "wording must run leading bold **[N.M]** through trailing \`[deps: …]\` token (got: $1)"
}
wording_id() { printf '%s\n' "$1" | grep -oE "^$ID_RE" | grep -oE '[0-9]+\.[0-9]+'; }

# Strip a deliverable line to its wording: drop the '- MARKER ' lead and the
# annotation zone after the LAST deps-shaped construct (the documented parse).
line_wording() {
  printf '%s\n' "$1" | sed -E 's/^[[:space:]]*-[[:space:]]*(✅|🔄|⬜|❌)[[:space:]]*//' \
    | sed -E 's/(.*`\[deps:[^]]*\]`).*/\1/'
}
deps_token_of() { printf '%s\n' "$1" | grep -oE '`\[deps:[^]]*\]`' | tail -1 | sed -E 's/^`\[deps: //; s/\]`$//'; }

cmd="${1:-}"
case "$cmd" in

  next-ordinal)
    [ $# -ge 2 ] || usage
    T="${3:-docs/PHASE_STATUS.md}"; need_tracker "$T"; preflight "$T"
    next_ordinal "$T" "$2"
    ;;

  guard)
    [ $# -ge 2 ] || usage
    T="${3:-docs/PHASE_STATUS.md}"; need_tracker "$T"; preflight "$T"
    guard_target "$T" "$2"
    ;;

  insert)
    [ $# -ge 4 ] || usage
    SESSION="$2"; OP="$3"; WORDING="$4"; T="${5:-docs/PHASE_STATUS.md}"
    [ -n "$SESSION" ] || die2 "SESSION is mandatory — the amendment record names it"
    valid_op "$OP" || die2 "op '$OP' is not a /replan verb ($VERBS)"
    need_tracker "$T"; preflight "$T"
    check_wording "$WORDING"
    ID=$(wording_id "$WORDING"); PHASE="${ID%%.*}"
    guard_target "$T" "$PHASE"
    EXPECT=$(next_ordinal "$T" "$PHASE")
    [ "$ID" = "$EXPECT" ] \
      || die6 "insert must take the next ordinal **[$EXPECT]** at the end of phase $PHASE (got **[$ID]**); ordinals are never reused or reshuffled"
    # Land after the phase's last bullet (or its header if the phase is empty).
    start=$(grep -nE "^##+ Phase $PHASE([^0-9]|\$)" "$T" | head -1 | cut -d: -f1)
    end=$(tail -n "+$(( start + 1 ))" "$T" | grep -n '^## ' | head -1 | cut -d: -f1)
    [ -n "$end" ] && end=$(( start + end - 1 )) || end=$(( $(wc -l < "$T") + 1 ))
    at=$(sed -n "$start,$(( end - 1 ))p" "$T" | grep -nE '^\s*-\s*(✅|🔄|⬜|❌)' | tail -1 | cut -d: -f1)
    if [ -n "$at" ]; then
      at=$(( start + at - 1 ))
    else
      # Empty phase: land below its _Goal:_ line when present, else the header.
      at=$(sed -n "$start,$(( end - 1 ))p" "$T" | grep -nE '^_Goal' | tail -1 | cut -d: -f1)
      [ -n "$at" ] && at=$(( start + at - 1 )) || at="$start"
    fi
    mk_tmp "$T"
    insert_after "$at" "- ⬜ $WORDING"
    append_record "$OP" "$ID" "$SESSION" ""
    commit_tmp "$T"
    ;;

  descope)
    [ $# -ge 5 ] || usage
    SESSION="$2"; OP="$3"; ID="$4"; NOTE="$5"; T="${6:-docs/PHASE_STATUS.md}"
    [ -n "$SESSION" ] || die2 "SESSION is mandatory — the amendment record names it"
    valid_op "$OP" || die2 "op '$OP' is not a /replan verb ($VERBS)"
    [ -n "$NOTE" ] || die2 "the dated note is mandatory — a descoped line must say why"
    need_tracker "$T"; preflight "$T"
    guard_target "$T" "$ID"
    LINE=$(id_line "$T" "$ID")
    printf '%s\n' "$LINE" | grep -qE '^\s*-\s*✅' \
      && die6 "[$ID] is ✅ complete; a completed deliverable cannot be descoped"
    WORD="descoped"; [ "$OP" = "abandon" ] && WORD="abandoned"
    at=$(grep -nxF -e "$LINE" "$T" | head -1 | cut -d: -f1)
    NEW=$(printf '%s\n' "$LINE" | sed -E "s/^([[:space:]]*-[[:space:]]*)(✅|🔄|⬜|❌)/\1❌/")
    NEW="$NEW ($WORD $(date +%F): $NOTE)"
    mk_tmp "$T"
    { head -n "$(( at - 1 ))" "$TMP"; printf '%s\n' "$NEW"; tail -n "+$(( at + 1 ))" "$TMP"; } > "$TMP.ins"
    mv "$TMP.ins" "$TMP"
    append_record "$OP" "$ID" "$SESSION" "$NOTE"
    commit_tmp "$T"
    ;;

  reword)
    [ $# -ge 5 ] || usage
    SESSION="$2"; OP="$3"; ID="$4"; WORDING="$5"; T="${6:-docs/PHASE_STATUS.md}"; SUMMARY="${7:-}"
    [ -n "$SESSION" ] || die2 "SESSION is mandatory — the amendment record names it"
    valid_op "$OP" || die2 "op '$OP' is not a /replan verb ($VERBS)"
    need_tracker "$T"; preflight "$T"
    guard_target "$T" "$ID"
    check_wording "$WORDING"
    [ "$(wording_id "$WORDING")" = "$ID" ] \
      || die2 "wording carries **[$(wording_id "$WORDING")]** but the target is [$ID] — IDs are immutable; insert+descope to renumber is not a thing either"
    LINE=$(id_line "$T" "$ID")
    OLD_DEPS=$(deps_token_of "$(line_wording "$LINE")")
    NEW_DEPS=$(deps_token_of "$WORDING")
    # Rebuild the line: lead marker + new wording + untouched annotation zone
    # (everything after the last deps-shaped construct — the documented parse).
    PRE=$(printf '%s\n' "$LINE" | sed -E "s/^([[:space:]]*-[[:space:]]*(✅|🔄|⬜|❌)[[:space:]]*).*/\1/")
    ANN="${LINE##*\]\`}"
    at=$(grep -nxF -e "$LINE" "$T" | head -1 | cut -d: -f1)
    # The record must tell what changed: the deps diff when the token moved,
    # the caller's summary otherwise — never an empty detail (a record that
    # under-tells is the defect the records exist to prevent).
    if [ "$OLD_DEPS" != "$NEW_DEPS" ]; then
      DETAIL="deps: $OLD_DEPS → $NEW_DEPS"
      [ -n "$SUMMARY" ] && DETAIL="$DETAIL; $SUMMARY"
    else
      DETAIL="${SUMMARY:-wording amended}"
    fi
    mk_tmp "$T"
    { head -n "$(( at - 1 ))" "$TMP"; printf '%s\n' "$PRE$WORDING$ANN"; tail -n "+$(( at + 1 ))" "$TMP"; } > "$TMP.ins"
    mv "$TMP.ins" "$TMP"
    append_record "$OP" "$ID" "$SESSION" "$DETAIL"
    commit_tmp "$T"
    ;;

  sync-check)
    [ $# -ge 2 ] || usage
    ID="$2"; T="${3:-docs/PHASE_STATUS.md}"; R="${4:-docs/REQUIREMENTS.md}"
    need_tracker "$T"; [ -f "$R" ] || die4 "$R"
    ESC=$(echo "$ID" | sed 's/\./\\./')
    TL=$(id_line "$T" "$ID")
    [ -n "$TL" ] || die5 "[$ID] not in $T"
    RL=$(grep -E "^[[:space:]]*[0-9]+\.[[:space:]]+\*\*\[$ESC\]\*\*" "$R" | head -1)
    [ -n "$RL" ] || die5 "[$ID] not in $R — the tracker line has no REQUIREMENTS source (wording changes happen in REQUIREMENTS first)"
    TW=$(line_wording "$TL")
    RW=$(printf '%s\n' "$RL" | sed -E 's/^[[:space:]]*[0-9]+\.[[:space:]]+//' \
         | sed -E 's/(.*`\[deps:[^]]*\]`).*/\1/')
    [ "$TW" = "$RW" ] || die5 "[$ID] drifted from the verbatim-sync contract:
  tracker:      $TW
  REQUIREMENTS: $RW"
    ;;

  *) usage ;;
esac
exit 0
