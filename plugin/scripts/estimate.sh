#!/bin/bash
# .claude/estimate.sh — the estimate sidecar helper ([9.6] of the plan-as-data
# spec / A-003, the governor's meter).
#
# Estimates are INTERPRETATION (what we guess a deliverable will cost in
# sessions); the tracker is EVIDENCE (what is). The two never mix: estimates
# live in a sidecar JSON object keyed by deliverable ID, BESIDE the tracker and
# never inside it. Editing an estimate therefore costs no grammar change, no
# contract change, and leaves the tracker byte-identical — this script never
# writes the tracker, only the sidecar. The shape is documented in
# .claude/estimate.shape.md (published alongside the other shapes).
#
# Shape (dual-form, [13.2]): a value keyed by ID is EITHER
#   - a legacy integer ≥ 1 (back-compat — existing plans still resolve), OR
#   - a SIZED object { "sessions": 1, "fraction": F, "size": "light|medium|heavy" }
#     where 0 < F ≤ 1 is the deliverable's share of the [9.2] occupancy budget.
# e.g. { "9.6": {"sessions":1,"fraction":0.5,"size":"medium"}, "9.7": 3 }.
# The default is 1 (guv pushes deliverables toward session-sized). A
# deliverable larger than one session is a BALLOON — SPLIT, never stored as N
# ([13.2]); `set-sized` refuses it. `get` returns the SESSIONS integer for both
# forms, so the projection's quantity reader is transparent to the shape. This is
# a deterministic read/write/validate helper (Rule 12: no judgment, no LLM) — the
# judgment (which size class) lives in /plan and /replan, which call set-sized
# after the user confirms.
#
# (Ships byte-identical into both install modes; under a plugin install the
# commands are guv:-namespaced — /guv:plan and /guv:replan.)
#
# Usage:
#   bash .claude/estimate.sh default                     # print the default (1)
#   bash .claude/estimate.sh get ID [SIDECAR]            # SESSIONS for ID, default 1
#   bash .claude/estimate.sh fraction ID [SIDECAR]       # context-fraction, empty if unsized
#   bash .claude/estimate.sh size ID [SIDECAR]           # rubric class, empty if unsized
#   bash .claude/estimate.sh rubric                      # the size → fraction map (data)
#   bash .claude/estimate.sh set ID N [SIDECAR]          # ratify ID → N (legacy, N int ≥ 1)
#   bash .claude/estimate.sh set-sized ID SIZE [SIDECAR] # ratify via the rubric; balloon refused
#   bash .claude/estimate.sh validate [SIDECAR]          # check the shape (both forms)
#   bash .claude/estimate.sh list [SIDECAR]              # emit the sidecar JSON
#   bash .claude/estimate.sh balloons [SIDECAR]          # IDs whose sessions > 1
#
#   SIDECAR defaults to docs/estimates.json (cwd = the control plane root,
#   beside docs/PHASE_STATUS.md — the same default-and-override convention the
#   resolver and replan engine use for the tracker). A read never creates the
#   file; an absent sidecar reads as all-default and validates trivially.
#
# Exit: 0 ok · 2 usage · 5 MALFORMED (invalid JSON, wrong type, value < 1 or
#       non-integer — the shape contract). set refuses an out-of-shape value
#       with exit 5 and writes nothing.
set -u

DEFAULT_ESTIMATE=1
SIDECAR_DEFAULT="docs/estimates.json"

usage() {
  echo "usage: bash .claude/estimate.sh default|get|fraction|size|rubric|set|set-sized|validate|list|balloons … (header comment has the arity)" >&2
  exit 2
}
die5() { echo "estimate: MALFORMED — $1" >&2; exit 5; }

# An integer ≥ 1, with no leading-zero / sign / float slop. The `0*` arm
# rejects leading zeros (01, 007) and a bare 0 so the stored shape is canonical
# — jq would otherwise coerce `01` to 1, accepting non-canonical input silently.
is_estimate() { case "$1" in '' | *[!0-9]* | 0*) return 1 ;; esac; [ "$1" -ge 1 ] 2>/dev/null; }

# The sizing rubric ([13.2]): a size class → a fraction of the [9.2] occupancy
# budget (the per-session context setpoint, project.json → occupancy.threshold).
# Three STORABLE classes; "balloon" is NOT a class — it is the signal to SPLIT a
# deliverable that exceeds one session, never a stored estimate. The mapping is
# deterministic (Rule 12); the judgment — which class a deliverable is — lives in
# /plan and /replan. The fractions are the dogfooded anchors (session-007 seed).
rubric_json() { printf '{"light":0.35,"medium":0.5,"heavy":0.9}\n'; }
# Echo the fraction for a size class; return 3 specifically for "balloon" (so the
# caller can give the split instruction) and 1 for an unknown word.
rubric_fraction() { # size
  case "$1" in
    light)   echo 0.35 ;;
    medium)  echo 0.5  ;;
    heavy)   echo 0.9  ;;
    balloon) return 3  ;;
    *)       return 1  ;;
  esac
}

# Validate a sidecar against the dual-form shape ([13.2]): a JSON object whose
# every value is EITHER a legacy integer ≥ 1 OR a sized object
# {sessions:int≥1, fraction:0<F≤1, size:light|medium|heavy}. An absent file is
# valid (no ratifications yet). Names the first offending key on failure.
validate_sidecar() { # path
  local s="$1"
  [ -f "$s" ] || return 0
  jq -e 'type == "object"' "$s" >/dev/null 2>&1 \
    || die5 "$s is not a JSON object (the sidecar is { \"ID\": estimate, ... })"
  # A value is valid if it is EITHER a legacy integer ≥ 1, OR a sized object
  # {sessions: int≥1, fraction: 0<F≤1, size: light|medium|heavy} ([13.2]). A
  # fraction above 1 is a stored balloon — forbidden (balloons are SPLIT, never
  # stored). jq short-circuits `and`, so okint/oksized are safe on either form;
  # it names the first offending key.
  local bad
  bad=$(jq -r '
      def okint:   type == "number" and (floor) == . and . >= 1;
      def oksized: type == "object"
          and ((.sessions?) | type == "number" and (floor) == . and . >= 1)
          and ((.fraction?) | type == "number" and . > 0 and . <= 1)
          and ((.size?)     | . == "light" or . == "medium" or . == "heavy");
      to_entries[] | select(((.value | okint) or (.value | oksized)) | not) | .key
    ' "$s" 2>/dev/null) \
    || die5 "$s is not valid JSON"
  [ -z "$bad" ] || die5 "$s has out-of-shape estimate(s) (legacy integer ≥ 1, or {sessions, fraction ≤ 1, size ∈ light|medium|heavy}): $(echo "$bad" | tr '\n' ' ')"
  return 0
}

cmd="${1:-}"
case "$cmd" in

  default)
    echo "$DEFAULT_ESTIMATE"
    ;;

  get)
    [ $# -ge 2 ] || usage
    ID="$2"; S="${3:-$SIDECAR_DEFAULT}"
    validate_sidecar "$S"
    if [ -f "$S" ]; then
      # The SESSIONS integer for both forms — legacy integer → itself, sized
      # object → .sessions; absent ID → default. The projection's quantity reader
      # expects this integer regardless of the entry's shape ([13.2] back-compat).
      V=$(jq -r --arg k "$ID" '(.[$k] | if type == "object" then .sessions else . end) // empty' "$S" 2>/dev/null)
      [ -n "$V" ] && echo "$V" || echo "$DEFAULT_ESTIMATE"
    else
      echo "$DEFAULT_ESTIMATE"
    fi
    ;;

  fraction)
    # The sized context-fraction for ID ([13.2]); EMPTY for a legacy or absent
    # entry (which carries no fraction) — a caller distinguishes "unsized" from a
    # real fraction by the empty output, never guesses one. [13.3] reads this.
    [ $# -ge 2 ] || usage
    ID="$2"; S="${3:-$SIDECAR_DEFAULT}"
    validate_sidecar "$S"
    [ -f "$S" ] && jq -r --arg k "$ID" '(.[$k] | if type == "object" then .fraction else empty end) // empty' "$S" 2>/dev/null
    ;;

  size)
    # The rubric class (light|medium|heavy) for ID; empty for a legacy/absent entry.
    [ $# -ge 2 ] || usage
    ID="$2"; S="${3:-$SIDECAR_DEFAULT}"
    validate_sidecar "$S"
    [ -f "$S" ] && jq -r --arg k "$ID" '(.[$k] | if type == "object" then .size else empty end) // empty' "$S" 2>/dev/null
    ;;

  rubric)
    # The published size → fraction map: the documented rubric AS DATA, so /plan
    # and /replan ratify a class to the same fraction every time (Rule 12).
    rubric_json
    ;;

  set)
    [ $# -ge 3 ] || usage
    ID="$2"; N="$3"; S="${4:-$SIDECAR_DEFAULT}"
    is_estimate "$N" \
      || die5 "estimate must be an integer ≥ 1 (got: $N) — there is no zero-session deliverable; sessions are whole"
    validate_sidecar "$S"   # never extend a sidecar that is already malformed
    # Atomic, sidecar-only write: merge ID→N into the existing object (or a
    # fresh {}), to a sibling temp, then mv. The tracker is never a target.
    TMP="$S.tmp.$$"
    if [ -f "$S" ]; then
      jq --arg k "$ID" --argjson v "$N" '.[$k] = $v' "$S" > "$TMP" || { rm -f "$TMP"; die5 "$S is not valid JSON"; }
    else
      mkdir -p "$(dirname "$S")" 2>/dev/null
      jq -n --arg k "$ID" --argjson v "$N" '{($k): $v}' > "$TMP" || { rm -f "$TMP"; die5 "could not write sidecar"; }
    fi
    mv "$TMP" "$S"
    ;;

  set-sized)
    # Ratify ID through the rubric ([13.2]): a size class → its fraction, stored
    # as {sessions:1, fraction, size}. A balloon is REFUSED — the discipline that
    # keeps "one deliverable ≈ one session" true by construction (split it, never
    # store N>1). This is the path /plan and /replan use for new deliverables; the
    # legacy `set ID N` above stays for back-compat and bare-integer revisions.
    [ $# -ge 3 ] || usage
    ID="$2"; SIZE="$3"; S="${4:-$SIDECAR_DEFAULT}"
    F=$(rubric_fraction "$SIZE"); RFRC=$?
    case "$RFRC" in
      0) : ;;
      3) die5 "[$ID] is a BALLOON (larger than one session) — SPLIT it into deliverables that each fit one session and size each piece; a balloon is never stored as an estimate (keeps 'one deliverable ≈ one session' true by construction)." ;;
      *) die5 "unknown size '$SIZE' — the rubric is light|medium|heavy (a balloon is split, never stored)" ;;
    esac
    validate_sidecar "$S"   # never extend a sidecar that is already malformed
    OBJ=$(jq -cn --argjson f "$F" --arg sz "$SIZE" '{sessions: 1, fraction: $f, size: $sz}')
    TMP="$S.tmp.$$"
    if [ -f "$S" ]; then
      jq --arg k "$ID" --argjson v "$OBJ" '.[$k] = $v' "$S" > "$TMP" || { rm -f "$TMP"; die5 "$S is not valid JSON"; }
    else
      mkdir -p "$(dirname "$S")" 2>/dev/null
      jq -n --arg k "$ID" --argjson v "$OBJ" '{($k): $v}' > "$TMP" || { rm -f "$TMP"; die5 "could not write sidecar"; }
    fi
    mv "$TMP" "$S"
    ;;

  validate)
    S="${2:-$SIDECAR_DEFAULT}"
    validate_sidecar "$S"
    ;;

  list)
    S="${2:-$SIDECAR_DEFAULT}"
    validate_sidecar "$S"
    [ -f "$S" ] && jq -S '.' "$S" || echo '{}'
    ;;

  balloons)
    S="${2:-$SIDECAR_DEFAULT}"
    validate_sidecar "$S"
    [ -f "$S" ] || exit 0
    # IDs whose effective session count exceeds the default — the flagged balloons.
    # A sized entry ([13.2]) is one session by construction, so only residual
    # legacy N>1 entries surface here; read effective sessions per form.
    jq -r --argjson d "$DEFAULT_ESTIMATE" '
      to_entries[]
      | (.value | if type == "object" then .sessions else . end) as $s
      | select($s > $d) | "\(.key) (\($s))"' "$S"
    ;;

  *) usage ;;
esac
exit 0
