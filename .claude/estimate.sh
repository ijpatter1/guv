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
# Shape: { "9.6": 1, "9.7": 3, ... } — ID → integer ≥ 1. The default is 1
# (the harness pushes deliverables toward session-sized); anything above 1 is
# a flagged balloon, surfaced at the plan-time confirm gate. This is a
# deterministic read/write/validate helper (Rule 12: no judgment, no LLM) —
# the judgment (proposing the number, ratifying it) lives in /plan
# and /replan, which call set after the user confirms.
#
# (Ships byte-identical into both install modes; under a plugin install the
# commands are guv:-namespaced — /guv:plan and /guv:replan.)
#
# Usage:
#   bash .claude/estimate.sh default                     # print the default (1)
#   bash .claude/estimate.sh get ID [SIDECAR]            # estimate for ID, default 1
#   bash .claude/estimate.sh set ID N [SIDECAR]          # ratify ID → N (N int ≥ 1)
#   bash .claude/estimate.sh validate [SIDECAR]          # check the shape
#   bash .claude/estimate.sh list [SIDECAR]              # emit the sidecar JSON
#   bash .claude/estimate.sh balloons [SIDECAR]          # IDs whose estimate > 1
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
  echo "usage: bash .claude/estimate.sh default|get|set|validate|list|balloons … (header comment has the arity)" >&2
  exit 2
}
die5() { echo "estimate: MALFORMED — $1" >&2; exit 5; }

# An integer ≥ 1, with no leading-zero / sign / float slop. The `0*` arm
# rejects leading zeros (01, 007) and a bare 0 so the stored shape is canonical
# — jq would otherwise coerce `01` to 1, accepting non-canonical input silently.
is_estimate() { case "$1" in '' | *[!0-9]* | 0*) return 1 ;; esac; [ "$1" -ge 1 ] 2>/dev/null; }

# Validate a sidecar against the shape: a JSON object whose every value is an
# integer ≥ 1. An absent file is valid (no ratifications yet). Names the first
# offending key on failure.
validate_sidecar() { # path
  local s="$1"
  [ -f "$s" ] || return 0
  jq -e 'type == "object"' "$s" >/dev/null 2>&1 \
    || die5 "$s is not a JSON object (the sidecar is { \"ID\": estimate, ... })"
  # Find any value that is not an integer ≥ 1; jq names the key.
  local bad
  bad=$(jq -r 'to_entries[] | select((.value | type) != "number" or (.value | floor) != .value or .value < 1) | .key' "$s" 2>/dev/null) \
    || die5 "$s is not valid JSON"
  [ -z "$bad" ] || die5 "$s has out-of-shape estimate(s) (must be integer ≥ 1): $(echo "$bad" | tr '\n' ' ')"
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
      # jq -e returns the value or, on null/absent, falls back to the default.
      V=$(jq -r --arg k "$ID" '.[$k] // empty' "$S" 2>/dev/null)
      [ -n "$V" ] && echo "$V" || echo "$DEFAULT_ESTIMATE"
    else
      echo "$DEFAULT_ESTIMATE"
    fi
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
    # IDs whose ratified estimate exceeds the default — the flagged balloons.
    jq -r --argjson d "$DEFAULT_ESTIMATE" 'to_entries[] | select(.value > $d) | "\(.key) (\(.value))"' "$S"
    ;;

  *) usage ;;
esac
exit 0
