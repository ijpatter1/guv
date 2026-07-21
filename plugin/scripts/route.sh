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
#   known doors (init|onboard|next|phase|task|spike); a typo is a
#   caller bug (exit 2), not a redirect.
#
# Output (name=value, one per line — the resolve-ready.sh contract shape):
#   door=<name>     the entry door that applies (omitted on a loud stop)
#   reason=<text>   why this door (or why the loud stop) — state for a person
#   match=yes|no    --for only: does the invoked door apply here
#
# Exit: 0 routed (a door selected, or a confirm/redirect under --for)
#       2 usage (unknown flag, --for an unknown door, or jq missing)
#       3 AMBIGUOUS — loud stop (unknown ceremony, or a phased project whose
#         tracker is MALFORMED): an EXISTING project whose state cannot select a
#         door, so the router refuses and names why rather than guess (rule 15).
#         No door= is emitted; the reason= preserves the state for a person.
#       4 PRE-SCAFFOLD — no manifest here yet: there is no project to route, but
#         this is NOT ambiguity. The scaffolding doors (init, onboard)
#         are about to WRITE the manifest this router would have read, so under
#         --for they CONFIRM and PROCEED (match=yes, exit 0); the live-plan doors
#         (next, phase, task) have nothing to resume and see exit 4 so
#         their Step 0 defers to a scaffolding door. Plain (no --for) emits no
#         door — which of the two scaffolding doors applies is a content decision
#         (is there a spec? existing code?), not a state one — but names the
#         scaffolding route in reason=. This is the fix for the canonical
#         onboard/init entry being misrouted into an exit-3 stop.
set -u

USAGE="usage: bash .claude/route.sh [--for <door>]"
MANIFEST=".claude/project.json"
RESOLVER="$(cd "$(dirname "$0")" && pwd)/resolve-ready.sh"
TRACKER="docs/PHASE_STATUS.md"

# The closed door vocabulary — the router knows exactly these (the [8.1] entry
# split left five; spike is the sixth, the exploration door for free-form work).
# The routing collapse is the function over them. A --for outside this set is a
# caller typo, not a redirect target.
KNOWN_DOORS="init onboard next phase task spike"

# The SCAFFOLDING doors — the two that write the manifest into a fresh repo. On
# the PRE-SCAFFOLD state (no manifest) these PROCEED rather than stop, because
# they are about to create the very manifest the router would have read. Which
# of the two applies is a content decision (spec → init; existing code →
# onboard), not a state one — so the router confirms either under --for but
# names neither as the single door in plain mode.
SCAFFOLD_DOORS="init onboard"

# jq is on the critical path in every mode below (manifest parse, resolver-free
# state). Guard it loud and early — without this, a missing jq surfaces as the
# misleading "manifest is not valid JSON" loud stop instead of an accurate
# environment error. Mirrors resolve-ready.sh's jq guard: exit 2 (a genuine
# IO/usage error, the stderr+exit-2 channel — not an ambiguous project state).
command -v jq >/dev/null 2>&1 || { echo "route: requires jq, which is not on PATH — install jq" >&2; exit 2; }

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
# gate, reserved for genuine IO/usage errors). This is for AMBIGUITY in an
# EXISTING project — unknown ceremony, malformed plan — never for a fresh repo.
stop() {
  echo "reason=$1"
  exit 3
}

# prescaffold REASON — the PRE-SCAFFOLD state (no manifest here yet): NOT
# ambiguity, so NOT exit 3. Under --for, a SCAFFOLDING door (init,
# onboard) CONFIRMS and proceeds (match=yes, exit 0) — it is about to write the
# manifest; a live-plan door (next, phase, task) gets match=no + exit 4
# and defers to a scaffolding door. Plain (no --for) emits no door — the
# scaffold-door choice is content-driven — and names the scaffolding route in
# reason= so a person (or the door's Step 0) routes correctly rather than seeing
# a halt. stdout stays the name=value contract; exit 4 is the machine signal.
prescaffold() {
  if [ -n "$FOR" ]; then
    case " $SCAFFOLD_DOORS " in
      *" $FOR "*)
        # A scaffolding door owns the pre-scaffold state — confirm and proceed.
        echo "match=yes"
        echo "door=$FOR"
        echo "reason=$1"
        exit 0
        ;;
    esac
    # A live-plan door has nothing to resume here — match=no, exit 4 (defer).
    echo "match=no"
  fi
  echo "reason=$1"
  exit 4
}

# ── (a) manifest: its absence is the PRE-SCAFFOLD state, not ambiguity. There
# is no ceremony to read yet — but a fresh repo is exactly what the scaffolding
# doors (init, onboard) exist to handle: they are about to WRITE this
# manifest. So this is exit 4 (pre-scaffold), distinct from the exit-3 stop a
# malformed EXISTING project gets — the scaffolding doors proceed, the live-plan
# doors defer (see prescaffold()). This is the fix for the canonical onboard/init
# entry being told to STOP on a manifest-less repo.
if [ ! -f "$MANIFEST" ]; then
  prescaffold "no manifest at $MANIFEST yet — this is a pre-scaffold repo; init (from a spec) or onboard (existing code) is the door that writes it"
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
  spike)
    emit spike "ceremony=spike — free-form exploration, no phase DAG"
    ;;
  phased)
    : # fall through to the phased decision below
    ;;
  *)
    # Not in the schema enum (phased|onboard|task|spike) — including empty. The
    # router will not invent a door for a ceremony it does not recognize.
    stop "unrecognized ceremony '${CEREMONY:-<missing>}' — expected one of phased|onboard|task|spike (fix .claude/project.json)"
    ;;
esac

# ── phased: greenfield vs. live plan ─────────────────────────────────────────
# Greenfield = phased intent with no phase docs yet (the project hasn't been
# scaffolded into a plan). init is the door that lays them down; it
# handles the NOT_SCAFFOLDED state itself. The absence of the tracker is the
# clean single signal — a scaffoldCheck that also fails only corroborates it.
if [ ! -f "$TRACKER" ]; then
  emit init "ceremony=phased but no $TRACKER — greenfield; init scaffolds the plan"
fi

# A tracker that EXISTS but carries ONLY verbatim placeholder stubs is still
# GREENFIELD ([23.1]): the skeleton scaffold seeds `- ⬜ [Deliverable N …]` stubs
# that init/plan overwrite with authored wording ([19.1] placeholder-as-
# unauthored). A split scaffold writes that skeleton tracker FIRST, so the `! -f`
# probe above does not fire — and without this the resolver below reads the ⬜
# stubs as an open (LEGACY) frontier and the router misroutes to next instead of
# the door that AUTHORS the plan. Detect it structurally, the same notion archive-
# initiative.sh uses: marker bullets are present, but every one is a verbatim
# `[Deliverable N` placeholder (zero authored lines). A partially-authored tracker
# (any real deliverable line) is past greenfield and falls through to the resolver.
PLACEHOLDER_RE='^\s*-\s*(✅|🔄|⬜|❌|🔒)\s*\[Deliverable [0-9]'
MARKER_RE='^\s*-\s*(✅|🔄|⬜|❌|🔒)'
if grep -qE "$MARKER_RE" "$TRACKER" 2>/dev/null \
   && ! grep -E "$MARKER_RE" "$TRACKER" 2>/dev/null | grep -qvE "$PLACEHOLDER_RE"; then
  emit init "ceremony=phased but $TRACKER carries only verbatim placeholder stubs (unauthored) — greenfield; init authors the plan"
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

# LEGACY tracker → next is the LEGACY-appropriate door: the resolver returns
# the first-⬜ serial pick (no deps graph to traverse), and next presents it
# as a plain pick and notes the tracker predates the grammar. The reason names
# the mode so the door degrades to a list, not an invented graph.
if [ "$MODE" = "LEGACY" ]; then
  emit next "ceremony=phased, mode=LEGACY — token-free tracker; next presents the first-⬜ pick (no DAG to resolve)"
fi

# GRAMMAR: mid-phase vs. complete is "is there open work?" The frontier is
# empty exactly when every deliverable is ✅ (or ❌) — nothing in_progress,
# ready, or blocked. No open work → phase (the boundary/next-decision door: cross
# into the next phase, or the initiative is complete — a deliberate decision, not a
# resume).
IN_PROGRESS=$(echo "$RES" | grep -E '^in_progress=' | head -1 | sed 's/^in_progress=//')
READY=$(echo "$RES" | grep -E '^ready=' | head -1 | sed 's/^ready=//')
BLOCKED=$(echo "$RES" | grep -E '^blocked=' | head -1 | sed 's/^blocked=//')
PHASE=$(echo "$RES" | grep -E '^phase=' | head -1 | sed 's/^phase=//')

if [ -n "$IN_PROGRESS" ] || [ -n "$READY" ] || [ -n "$BLOCKED" ]; then
  # Open frontier — but distinguish FIRST ENTRY to the Current Phase (a boundary)
  # from a mid-phase resume ([23.1]). The Current Phase (the resolver's phase=, the
  # first phase with open work) is freshly entered when it carries ZERO started
  # (✅/🔄) deliverables — you just crossed in, nothing is done or underway there.
  # That is the boundary door (phase): it runs the spec-alignment + deep-architecture
  # + UAT ritual the light door (next) skips. Any ✅/🔄 in the Current Phase means
  # work is underway → next. This is a structural boundary check on the Current
  # Phase's own markers, not a dispatch decision — the resolver remains the dispatch
  # oracle (it already gave us the frontier above); we only ask whether its reported
  # phase has been started yet.
  STARTED=""
  [ -n "$PHASE" ] && STARTED=$(grep -E "^\s*-\s*(✅|🔄)\s*\*\*\[$PHASE\.[0-9]+\]\*\*" "$TRACKER" 2>/dev/null)
  if [ -n "$PHASE" ] && [ -z "$STARTED" ]; then
    emit phase "ceremony=phased, mode=GRAMMAR, open frontier but zero ✅/🔄 in Current Phase $PHASE — first entry/boundary; phase runs the spec-alignment + architecture + UAT ritual the light door skips"
  fi
  emit next "ceremony=phased, mode=GRAMMAR, open frontier with work underway in Current Phase $PHASE — mid-phase; next presents the ready frontier"
else
  emit phase "ceremony=phased, mode=GRAMMAR, empty frontier — every deliverable is terminal (✅ done or ❌ descoped); phase is the boundary/next-decision door"
fi
