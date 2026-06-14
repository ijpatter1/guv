#!/bin/bash
# .claude/resolve-ready.sh
# Deterministic ready-frontier resolver ([6.2] of the plan-as-data spec).
# Implements the resolver contract in the phase-docs skill ("Resolver
# contract"); the grammar itself is defined once there ("Tracker grammar")
# and validated for well-formedness by archive-initiative.sh — this script
# repeats the well-formedness gate (a resolver must not compute on a
# malformed tracker) and owns the dep SEMANTICS the archive script does not:
# unknown IDs, cycles. (Forward cross-phase deps were MALFORMED until [7.6]
# repealed the lint with the phase barrier whose companion it was — a
# forward dep is now an ordinary edge.)
#
# Usage:
#   bash .claude/resolve-ready.sh [tracker-path] [--json]   # default docs/PHASE_STATUS.md
#
#   --json emits the SAME parse and frontier as canonical status.json (shape
#   documented in the phase-docs skill alongside the grammar — it is contract
#   surface per the A-001 one-parser decision; every other reader of plan
#   state consumes this JSON and never parses the tracker). Exit codes and
#   stderr are identical in both modes, with one exception: --json needs jq
#   and refuses exit 2 before resolving when it is absent.
#
# Output (name=value, one per line):
#   mode=GRAMMAR|LEGACY
#   phase=N            first phase with open work (⬜ or 🔄) — reporting
#                      only, never gates dispatch ([7.6]); GRAMMAR only
#   in_progress=…      🔄 IDs, document order (finish before starting new work)
#   ready=…            every ⬜ whose deps are all ✅ — document order,
#                      across ALL phases (deps are the only ordering; the
#                      phase barrier stopped gating dispatch at [7.6])
#   blocked=…          every open ⬜ with an unsatisfied dep, as ID:ROOT —
#                      ROOT is the transitive blocking ID (the deepest
#                      unsatisfied dep that is itself ready, in progress,
#                      or ❌)
#   serial=…           serial resume: first 🔄, else first ready. In LEGACY
#                      mode this is line *text* (no IDs exist) — the first
#                      🔄's, else the first ⬜'s (finish before start) —
#                      and ready=, in_progress=, and blocked= are all
#                      emitted explicitly empty (nothing to list IDs for;
#                      an in-flight line surfaces via serial=). Document
#                      order encodes dependency order, exactly as before.
#   A 🔄 anywhere wins serial= over any ready item — in-flight work is
#   finished first, wherever it sits; phases remain the unit of narrative,
#   review, and UAT — dispatch is deps-only.
# Exit: 0 resolved (a complete tracker is an empty frontier, not an error)
#       2 usage · 4 no tracker · 5 MALFORMED (offenders named on stderr)
set -u

TRACKER="docs/PHASE_STATUS.md"
JSON=0
USAGE="usage: bash .claude/resolve-ready.sh [tracker-path] [--json]"
case "${1:-}" in
  --json) JSON=1 ;;
  "") ;;
  -?*)
    echo "error: unknown argument '$1' — $USAGE" >&2
    exit 2
    ;;
  *) TRACKER="$1" ;;
esac
# Only the literal --json is recognized past the path — anything else refuses
# loud rather than being silently ignored (the allow-list IS the grammar),
# and the grammar has exactly two positions: extras refuse too.
if [ "$#" -gt 2 ]; then
  echo "error: unexpected argument '$3' — $USAGE" >&2
  exit 2
fi
if [ -n "${2:-}" ]; then
  if [ "$2" = "--json" ] && [ "$JSON" -eq 0 ]; then
    JSON=1
  elif [ "$2" = "--json" ]; then
    echo "error: duplicate --json — $USAGE" >&2
    exit 2
  elif [ "$JSON" -eq 1 ]; then
    echo "error: tracker path comes first — $USAGE" >&2
    exit 2
  else
    echo "error: unknown argument '$2' — $USAGE" >&2
    exit 2
  fi
fi

# --json's one extra dependency is guarded loud: without this, a missing jq
# emits EMPTY stdout under exit 0 — a silently-empty status.json is the
# stale-view-worse-than-none failure class this surface exists to prevent.
if [ "$JSON" -eq 1 ] && ! command -v jq >/dev/null 2>&1; then
  echo "error: --json requires jq, which is not on PATH — install jq or use the name=value output" >&2
  exit 2
fi

# Marker → status word for the JSON surface (it never carries emoji).
status_word() {
  case "$1" in
    ✅) printf 'done' ;;
    🔄) printf 'in_progress' ;;
    ⬜) printf 'todo' ;;
    ❌) printf 'descoped' ;;
  esac
}

[ -f "$TRACKER" ] || { echo "status=NONE — no tracker at $TRACKER" >&2; exit 4; }

ID_RE='\*\*\[[0-9]+\.[0-9]+\]\*\*'
DEPS_RE='`\[deps: (none|[0-9]+\.[0-9]+(, [0-9]+\.[0-9]+)*)\]`'
LEAD_RE="^[[:space:]]*-[[:space:]]*(✅|🔄|⬜|❌)[[:space:]]*$ID_RE"

LINES=$(grep -E '^\s*-\s*(✅|🔄|⬜|❌)' "$TRACKER")

die5() { echo "status=MALFORMED — $1" >&2; exit 5; }

# A tracker with no deliverable bullets at all is not resolvable — fail loud
# (archive-initiative.sh exits 5 on the same shape; a corrupt tracker must
# not read as "nothing to do" to the resume door).
[ -n "$LINES" ] || die5 "$TRACKER has no recognizable deliverable bullets"

# ── LEGACY: token-free trackers keep today's semantics exactly (same gate as
# archive-initiative.sh: lead-position IDs / deps-shaped constructs only).
if ! echo "$LINES" | grep -qE "$LEAD_RE" \
   && ! echo "$LINES" | grep -qE '`?\[deps:[^]]*\]`?'; then
  serial=$(echo "$LINES" | grep -E '^\s*-\s*🔄' | head -1 | sed -E 's/^[[:space:]]*-[[:space:]]*🔄[[:space:]]*//')
  [ -z "$serial" ] && serial=$(echo "$LINES" | grep -E '^\s*-\s*⬜' | head -1 | sed -E 's/^[[:space:]]*-[[:space:]]*⬜[[:space:]]*//')
  if [ "$JSON" -eq 1 ]; then
    # Document order, EMPTY deps (LEGACY has no edges — degrade, don't
    # invent), null ids/phase, text carried for the renderer's plain list.
    dj=$(echo "$LINES" | while IFS= read -r l; do
      m=$(printf '%s\n' "$l" | grep -oE '✅|🔄|⬜|❌' | head -1)
      txt=$(printf '%s\n' "$l" | sed -E 's/^[[:space:]]*-[[:space:]]*(✅|🔄|⬜|❌)[[:space:]]*//')
      jq -cn --arg st "$(status_word "$m")" --arg text "$txt" \
        '{id:null, phase:null, status:$st, deps:[], text:$text}'
    done)
    printf '%s\n' "$dj" | jq -s \
      --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg serial "$serial" \
      '{generated:$generated, mode:"LEGACY", phase:null, phases:[], deliverables:.,
        frontier:{in_progress:[], ready:[], blocked:[],
                  serial:(if $serial=="" then null else $serial end)}}'
  else
    echo "mode=LEGACY"
    echo "in_progress="
    echo "ready="
    echo "blocked="
    echo "serial=$serial"
  fi
  exit 0
fi

# ── Well-formedness (the grammar's MALFORMED list; offenders named) ──
bad=$(echo "$LINES" | grep -vE "$LEAD_RE")
[ -n "$bad" ] && die5 "missing or misplaced **[N.M]** ID:
$bad"
bad=$(echo "$LINES" | while IFS= read -r l; do
  tok=$(printf '%s\n' "$l" | grep -oE '`?\[deps:[^]]*\]`?' | tail -1)
  printf '%s\n' "$tok" | grep -qE "^$DEPS_RE\$" || printf '%s\n' "$l"
done)
[ -n "$bad" ] && die5 "missing or malformed \`[deps: …]\` token:
$bad"
dups=$(echo "$LINES" | grep -oE "$LEAD_RE" | grep -oE '[0-9]+\.[0-9]+' | sort | uniq -d)
[ -n "$dups" ] && die5 "duplicate deliverable IDs:
$dups"

# ── Parse into ordered parallel state. IDs are validated digits-only, so
# eval-backed maps (marker_6_2 etc.) are safe; bash 3.2 has no associative
# arrays and this must run on a stock macOS bash.
ids=""
while IFS= read -r l; do
  id=$(printf '%s\n' "$l" | grep -oE "$LEAD_RE" | grep -oE '[0-9]+\.[0-9]+')
  marker=$(printf '%s\n' "$l" | grep -oE '✅|🔄|⬜|❌' | head -1)
  deps=$(printf '%s\n' "$l" | grep -oE '`?\[deps:[^]]*\]`?' | tail -1 \
         | sed -E 's/^`?\[deps: //; s/\]`?$//; s/,/ /g')
  [ "$deps" = "none" ] && deps=""
  txt=$(printf '%s\n' "$l" | sed -E 's/^[[:space:]]*-[[:space:]]*(✅|🔄|⬜|❌)[[:space:]]*//')
  v=${id//./_}
  eval "marker_$v=\$marker"
  eval "deps_$v=\$deps"
  eval "text_$v=\$txt"
  ids="$ids $id"
done <<EOF
$LINES
EOF
ids=${ids# }

marker_of() { eval "printf '%s' \"\$marker_${1//./_}\""; }
deps_of()   { eval "printf '%s' \"\$deps_${1//./_}\""; }
text_of()   { eval "printf '%s' \"\$text_${1//./_}\""; }
has_id()    { case " $ids " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ── Dep semantics: unknown IDs, cycles — the whole semantic MALFORMED set
# post-[7.6] (a forward cross-phase dep is an ordinary edge; the lint
# repealed with the phase barrier it accompanied) ──
for id in $ids; do
  for d in $(deps_of "$id"); do
    has_id "$d" || die5 "unknown dep ID: $id depends on $d, which does not exist"
  done
done

# Iterative cycle check: repeatedly remove nodes with no remaining in-graph
# deps; anything left participates in (or depends on) a cycle.
remaining=" $ids "
while :; do
  removed=0
  for id in $ids; do
    case "$remaining" in *" $id "*) ;; *) continue ;; esac
    pending=0
    for d in $(deps_of "$id"); do
      case "$remaining" in *" $d "*) pending=1; break ;; esac
    done
    if [ "$pending" -eq 0 ]; then
      remaining=${remaining/ $id / }
      removed=1
    fi
  done
  [ "$removed" -eq 0 ] && break
done
remaining=$(echo "$remaining" | sed -E 's/^ +//; s/ +$//')
[ -n "$remaining" ] && die5 "dependency cycle among (or depending on a cycle): $remaining"

# ── Frontier: phase = first phase with open work (⬜ or 🔄) — reporting
# only; ready/blocked span all phases ──
phase=""
for id in $ids; do
  m=$(marker_of "$id")
  if [ "$m" = "⬜" ] || [ "$m" = "🔄" ]; then phase=${id%%.*}; break; fi
done

satisfied() { [ "$(marker_of "$1")" = "✅" ]; }

# Transitive root blocker: first unsatisfied dep, followed down until it is
# itself dispatchable (ready), in progress, or ❌ (descoped/blocked — the
# spec's "a ❌ prior-phase item propagates blockage").
root_blocker() {
  local id="$1" d
  for d in $(deps_of "$id"); do
    satisfied "$d" && continue
    case "$(marker_of "$d")" in
      🔄|❌) printf '%s' "$d"; return ;;
    esac
    local inner
    inner=$(root_blocker "$d")
    if [ -n "$inner" ]; then printf '%s' "$inner"; else printf '%s' "$d"; fi
    return
  done
}

in_progress=""; ready=""; blocked=""
for id in $ids; do
  m=$(marker_of "$id")
  [ "$m" = "🔄" ] && in_progress="$in_progress $id"
  [ "$m" = "⬜" ] || continue
  open=0
  for d in $(deps_of "$id"); do satisfied "$d" || { open=1; break; }; done
  if [ "$open" -eq 0 ]; then
    ready="$ready $id"
  else
    blocked="$blocked $id:$(root_blocker "$id")"
  fi
done
in_progress=${in_progress# }; ready=${ready# }; blocked=${blocked# }

serial=${in_progress%% *}
[ -z "$serial" ] && serial=${ready%% *}

if [ "$JSON" -eq 1 ]; then
  dj=""
  plist=""
  for id in $ids; do
    p=${id%%.*}
    case " $plist " in *" $p "*) ;; *) plist="$plist $p" ;; esac
    dj="$dj$(jq -cn --arg id "$id" --argjson phase "$p" \
      --arg st "$(status_word "$(marker_of "$id")")" \
      --arg deps "$(deps_of "$id")" --arg text "$(text_of "$id")" \
      '{id:$id, phase:$phase, status:$st,
        deps:($deps | split(" ") | map(select(. != ""))), text:$text}')
"
  done
  plist=${plist# }
  bj=""
  for b in $blocked; do
    bj="$bj$(jq -cn --arg id "${b%%:*}" --arg by "${b#*:}" '{id:$id, blocked_by:$by}')
"
  done
  frontier=$(jq -cn \
    --arg ip "$in_progress" --arg rd "$ready" --arg serial "$serial" \
    --argjson blocked "$(printf '%s' "$bj" | jq -s '.')" \
    '{in_progress:($ip | if .=="" then [] else split(" ") end),
      ready:($rd | if .=="" then [] else split(" ") end),
      blocked:$blocked,
      serial:(if $serial=="" then null else $serial end)}')
  printf '%s' "$dj" | jq -s \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson phase "${phase:-null}" \
    --argjson phases "$(jq -cn --arg p "$plist" \
      '$p | if .=="" then [] else split(" ") end | map(tonumber)')" \
    --argjson frontier "$frontier" \
    '{generated:$generated, mode:"GRAMMAR", phase:$phase, phases:$phases,
      deliverables:., frontier:$frontier}'
else
  echo "mode=GRAMMAR"
  echo "phase=$phase"
  echo "in_progress=$in_progress"
  echo "ready=$ready"
  echo "blocked=$blocked"
  echo "serial=$serial"
fi
exit 0
