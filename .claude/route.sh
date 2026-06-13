#!/bin/bash
# .claude/route.sh
# Deterministic entry-door router ([8.1] of the plan-as-data spec — "routing
# collapse"). Manifest + repo state SELECT the entry door; no LLM in the loop
# (rule 12), no user disambiguation. This is the decision table that makes
# misroutes impossible rather than documented: the three entry doors the entry
# split ([7.2]) prepared collapse into one deterministically-routed entry, and
# an ambiguous/unknown state is a LOUD STOP (rule 15) — never a silent wrong
# door.
#
# Inputs, all deterministic:
#   (a) manifest `ceremony`            — .claude/project.json (jq)
#   (b) phase-docs presence            — docs/PHASE_STATUS.md
#   (c) scaffold state                 — the manifest's scaffoldCheck
#   (d) resolver state (mode+frontier) — resolve-ready.sh (the single dispatch
#                                        oracle; never hand-read the tracker)
#
# Usage:
#   bash .claude/route.sh                 # which entry door applies here
#   bash .claude/route.sh --for <door>    # does <door> apply, or redirect?
#
#   --for is how an entry command asks "is this the right door?" A wrong-door
#   invocation REDIRECTS (match=no, door=<correct>) rather than errors —
#   redirect is a route, not a failure (exit 0). <door> must be one of the
#   known doors (init-project|onboard|resume|start-phase|task); a typo is a
#   caller bug (exit 2), not a redirect.
#
# Output (name=value, one per line — the resolve-ready.sh contract shape):
#   door=<name>     the entry door that applies (omitted on a loud stop)
#   reason=<text>   why this door (or why the loud stop) — state for a person
#   match=yes|no    --for only: does the invoked door apply here
#
# Exit: 0 routed (a door selected, or a confirm/redirect under --for)
#       2 usage (unknown flag, or --for an unknown door)
#       3 AMBIGUOUS — loud stop (no manifest, unknown ceremony, or a phased
#         project whose tracker is MALFORMED): the state cannot select a door,
#         so the router refuses and names why rather than guess (rule 15). No
#         door= is emitted; the reason= preserves the state for a person.
set -u

USAGE="usage: bash .claude/route.sh [--for <door>]"
MANIFEST=".claude/project.json"
RESOLVER="$(cd "$(dirname "$0")" && pwd)/resolve-ready.sh"
TRACKER="docs/PHASE_STATUS.md"

# The closed door vocabulary — the router knows exactly these (the entry split
# left five; the routing collapse is the function over them). A --for outside
# this set is a caller typo, not a redirect target.
KNOWN_DOORS="init-project onboard resume start-phase task"

FOR=""
case "${1:-}" in
  "") ;;
  --for)
    FOR="${2:-}"
    [ -n "$FOR" ] || { echo "error: --for needs a door name — $USAGE" >&2; exit 2; }
    case " $KNOWN_DOORS " in
      *" $FOR "*) ;;
      *) echo "error: unknown door '$FOR' — known doors: $KNOWN_DOORS" >&2; exit 2 ;;
    esac
    [ "$#" -le 2 ] || { echo "error: unexpected argument '$3' — $USAGE" >&2; exit 2; }
    ;;
  *) echo "error: unknown argument '$1' — $USAGE" >&2; exit 2 ;;
esac

# emit DOOR REASON — the resolved-door path. Under --for, fold in the
# match verdict (yes if the invoked door IS the resolved one, else a redirect).
emit() {
  local door="$1" reason="$2"
  if [ -n "$FOR" ]; then
    if [ "$FOR" = "$door" ]; then
      echo "match=yes"
    else
      echo "match=no"
    fi
  fi
  echo "door=$door"
  echo "reason=$reason"
  exit 0
}

# stop REASON — the loud stop (rule 15): no door, exit 3, state named on
# stdout (the reason is for a person; stderr stays clean for the empty-stderr
# gate, reserved for genuine IO/usage errors).
stop() {
  echo "reason=$1"
  exit 3
}

# ── (a) manifest: its absence is the first ambiguity — without ceremony there
# is no door to compute. Loud stop, not a guessed default.
if [ ! -f "$MANIFEST" ]; then
  stop "no manifest at $MANIFEST — cannot determine ceremony; run from the project root or scaffold first"
fi
if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
  stop "$MANIFEST exists but is not valid JSON — fix the manifest before routing"
fi

CEREMONY=$(jq -r '.ceremony // empty' "$MANIFEST")

case "$CEREMONY" in
  task)
    emit task "ceremony=task — scoped change, no phase ceremony"
    ;;
  onboard)
    emit onboard "ceremony=onboard — existing repo, conventions inferred not scaffolded"
    ;;
  phased)
    : # fall through to the phased decision below
    ;;
  *)
    # Not in the schema enum (phased|onboard|task) — including empty. The
    # router will not invent a door for a ceremony it does not recognize.
    stop "unrecognized ceremony '${CEREMONY:-<missing>}' — expected one of phased|onboard|task (fix .claude/project.json)"
    ;;
esac

# ── phased: greenfield vs. live plan ─────────────────────────────────────────
# Greenfield = phased intent with no phase docs yet (the project hasn't been
# scaffolded into a plan). init-project is the door that lays them down; it
# handles the NOT_SCAFFOLDED state itself. The absence of the tracker is the
# clean single signal — a scaffoldCheck that also fails only corroborates it.
if [ ! -f "$TRACKER" ]; then
  emit init-project "ceremony=phased but no $TRACKER — greenfield; init-project scaffolds the plan"
fi

# A live plan exists — the resolver is the single oracle for its state. Its
# exit code and mode select among mid-phase / complete / LEGACY; a MALFORMED
# tracker is an ambiguity the router refuses to resolve past (rule 15).
RES=$(bash "$RESOLVER" "$TRACKER" 2>/dev/null); RRC=$?
case "$RRC" in
  5)
    stop "the tracker at $TRACKER is MALFORMED — the resolver cannot compute a frontier (run resolve-ready.sh to see the offenders); routing refuses a broken plan rather than guess a door"
    ;;
  4)
    # The tracker existed at the -f test above but the resolver reports none —
    # a race or an unreadable file. Ambiguous; loud stop.
    stop "the resolver found no tracker at $TRACKER though it exists — unreadable or removed mid-route; stopping rather than guess"
    ;;
  0) : ;;
  *)
    stop "the resolver exited $RRC on $TRACKER — an unexpected state; stopping rather than guess a door"
    ;;
esac

MODE=$(echo "$RES" | grep -E '^mode=' | head -1 | sed 's/^mode=//')

# LEGACY tracker → resume is the LEGACY-appropriate door: the resolver returns
# the first-⬜ serial pick (no deps graph to traverse), and resume presents it
# as a plain pick and notes the tracker predates the grammar. The reason names
# the mode so the door degrades to a list, not an invented graph.
if [ "$MODE" = "LEGACY" ]; then
  emit resume "ceremony=phased, mode=LEGACY — token-free tracker; resume presents the first-⬜ pick (no DAG to resolve)"
fi

# GRAMMAR: mid-phase vs. complete is "is there open work?" The frontier is
# empty exactly when every deliverable is ✅ (or ❌) — nothing in_progress,
# ready, or blocked. Open work → resume (the daily/mid-phase door). No open
# work → start-phase (the boundary/next-decision door: cross into the next
# phase, or the initiative is complete — a deliberate decision, not a resume).
IN_PROGRESS=$(echo "$RES" | grep -E '^in_progress=' | head -1 | sed 's/^in_progress=//')
READY=$(echo "$RES" | grep -E '^ready=' | head -1 | sed 's/^ready=//')
BLOCKED=$(echo "$RES" | grep -E '^blocked=' | head -1 | sed 's/^blocked=//')

if [ -n "$IN_PROGRESS" ] || [ -n "$READY" ] || [ -n "$BLOCKED" ]; then
  emit resume "ceremony=phased, mode=GRAMMAR, open frontier — mid-phase; resume presents the ready frontier"
else
  emit start-phase "ceremony=phased, mode=GRAMMAR, empty frontier — every deliverable is ✅; start-phase is the boundary/next-decision door"
fi
