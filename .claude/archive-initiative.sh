#!/bin/bash
# .claude/archive-initiative.sh
# The scriptable half of initiative archival, used by /plan-initiative (the
# judgment half — spec analysis, doc generation, lineage wording — stays in the
# command). Operates on the CONTROL root: run it from ${roots.control}.
#
# Lifecycle model (see the phase-docs skill): REQUIREMENTS + PHASE_STATUS
# describe WORK — they complete and freeze into docs/initiatives/NNN-<name>/.
# ARCHITECTURE describes the SYSTEM — it persists at top level and is only
# snapshot-copied into the archive. docs/sessions/ (continuous journal) and
# docs/spec/ (accumulating sources) are never archived.
#
# Usage:
#   bash .claude/archive-initiative.sh --check
#       Exit 0  status=COMPLETE  max_phase=N   — every deliverable is ✅
#       Exit 3  status=INCOMPLETE              — lists each incomplete line
#       Exit 4  status=NONE                    — no PHASE_STATUS.md (fresh project)
#       Exit 5  status=MALFORMED               — tracker has no recognizable
#               deliverable bullets / phase headers; fix it by hand first
#   bash .claude/archive-initiative.sh --archive <name> [--force]
#       Moves REQUIREMENTS.md + PHASE_STATUS.md to docs/initiatives/NNN-<slug>/
#       (NNN = highest existing index + 1, so a gap in the sequence never
#       re-issues a frozen archive's index), snapshot-copies ARCHITECTURE.md
#       alongside, prints archive_dir= and
#       phase_range=. Refuses (exit 3) on incomplete deliverables unless
#       --force, which stamps an ABANDONED note into the archived tracker
#       (honest record, not deletion). Exit 5 on a malformed tracker.
set -u

TRACKER="docs/PHASE_STATUS.md"
REQS="docs/REQUIREMENTS.md"
ARCH="docs/ARCHITECTURE.md"

# Deliverable lines are status-marker bullets; anything not ✅ is incomplete.
incomplete_lines() { grep -E '^\s*-\s*(⬜|🔄|❌)' "$TRACKER"; }
done_count() { grep -cE '^\s*-\s*✅' "$TRACKER"; }
max_phase() { grep -Eo '^##+ Phase [0-9]+' "$TRACKER" | grep -Eo '[0-9]+' | sort -n | tail -1; }
min_phase() { grep -Eo '^##+ Phase [0-9]+' "$TRACKER" | grep -Eo '[0-9]+' | sort -n | head -1; }

# A tracker with no marker bullets at all, or no "## Phase N" headers, is not a
# tracker this script can reason about — fail loud rather than read it as done.
malformed() {
  [ "$(done_count)" -eq 0 ] && [ -z "$(incomplete_lines)" ] && return 0
  [ -z "$(max_phase)" ] && return 0
  return 1
}

check() {
  if [ ! -f "$TRACKER" ]; then
    echo "status=NONE"
    return 4
  fi
  if malformed; then
    echo "status=MALFORMED — $TRACKER has no recognizable deliverable bullets / phase headers" >&2
    return 5
  fi
  local inc
  inc=$(incomplete_lines)
  if [ -n "$inc" ]; then
    echo "status=INCOMPLETE"
    echo "$inc"
    return 3
  fi
  echo "status=COMPLETE"
  echo "max_phase=$(max_phase)"
  return 0
}

archive() {
  local name="$1" force="${2:-}"
  if [ ! -f "$TRACKER" ] || [ ! -f "$REQS" ]; then
    echo "status=NONE — nothing to archive (no $TRACKER / $REQS)" >&2
    return 4
  fi
  if malformed; then
    echo "status=MALFORMED — $TRACKER has no recognizable deliverable bullets / phase headers; fix it before archiving" >&2
    return 5
  fi
  local inc
  inc=$(incomplete_lines)
  if [ -n "$inc" ] && [ "$force" != "--force" ]; then
    echo "status=INCOMPLETE — refusing to archive. Finish these or re-run with --force to abandon:" >&2
    echo "$inc" >&2
    return 3
  fi

  # kebab-case slug; NNN = highest existing index + 1 (count-based numbering
  # would re-issue an index after a gap and could merge into a frozen archive).
  local slug max nnn dir
  slug=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//')
  if [ -z "$slug" ]; then
    echo "usage: --archive <name> — name must contain at least one alphanumeric character" >&2
    return 2
  fi
  max=$(ls -d docs/initiatives/[0-9][0-9][0-9]-* 2>/dev/null | sed 's|.*/\([0-9]\{3\}\)-.*|\1|' | sort -n | tail -1)
  nnn=$(printf '%03d' $(( 10#${max:-0} + 1 )))   # 10#: don't octal-parse "008"
  dir="docs/initiatives/$nnn-$slug"
  mkdir -p "$dir"

  local range="$(min_phase)-$(max_phase)"
  if [ -n "$inc" ]; then
    printf '\n> **ABANDONED %s** — archived with incomplete deliverables (see unchecked items above).\n' \
      "$(date +%Y-%m-%d)" >> "$TRACKER"
  fi
  mv "$REQS" "$dir/REQUIREMENTS.md"
  mv "$TRACKER" "$dir/PHASE_STATUS.md"
  [ -f "$ARCH" ] && cp "$ARCH" "$dir/ARCHITECTURE.md"   # snapshot; original persists

  echo "archive_dir=$dir"
  echo "phase_range=$range"
  return 0
}

case "${1:-}" in
  --check)   check; exit $? ;;
  --archive) [ -n "${2:-}" ] || { echo "usage: --archive <name> [--force]" >&2; exit 2; }
             archive "$2" "${3:-}"; exit $? ;;
  *)         echo "usage: bash .claude/archive-initiative.sh --check | --archive <name> [--force]" >&2
             exit 2 ;;
esac
